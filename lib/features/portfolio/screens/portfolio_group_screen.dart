import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart'
    show CollectionFullRender, HolderEntry;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/pagination/drain_pages.dart';
import '../../../shared/pagination/pagination_bloc.dart';
import '../../../shared/pagination/pagination_scroll_listener.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_menu_row.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../../artwork/services/artwork_permission_service.dart';
import '../../artwork/services/artwork_hidden_signal.dart';
import '../../artwork/services/artwork_removal_signal.dart';
import '../../artwork/services/bulk_artwork_download.dart';
import '../../artwork/widgets/artwork_context_menu_actions.dart';
import '../../artwork/widgets/burn_artwork_flow.dart';
import '../../cast/models/cast_queue.dart';
import '../../cast/services/cast_actions.dart';
import '../../cast/widgets/now_casting_bar.dart';
import '../../profile/data/user_profile_repository.dart';
import '../../profile/screens/collection_screen.dart';
import '../../profile/widgets/collection_options_sheet.dart';
import '../../profile/widgets/profile_required_sheet.dart';
import '../../profile/widgets/sort_view_mode_bar.dart';
import '../data/portfolio_repository.dart';
import '../services/portfolio_bloc.dart';
import '../services/portfolio_refresh_signal.dart';
import '../widgets/all_art_detail.dart';
import '../widgets/all_art_grid.dart';
import '../widgets/all_art_masonry.dart';

/// The shared "You own" drilldown: pushed from the portfolio group rows, the
/// profile "You own" banner, and the collection-screen "You own" banner — each
/// seeds an [ArtGroup] (artist or collection) whose owned slice this screen
/// pages via [PortfolioRepository.getGroupArtworks]. Owns its own paged fetch
/// so the parent screen's state is not disturbed while drilling in. Header:
/// a small back / group-type / kebab bar, then avatar + name + "You own
/// • N artworks" + a Follow / Download / Cast action row, over the artwork list.
class PortfolioGroupScreen extends StatefulWidget {
  const PortfolioGroupScreen({required this.group, super.key});

  final ArtGroup group;

  @override
  State<PortfolioGroupScreen> createState() => _PortfolioGroupScreenState();
}

class _PortfolioGroupScreenState extends State<PortfolioGroupScreen> {
  /// Seeded from the app-wide artwork preference in [initState], shared with
  /// every other artwork surface.
  ArtworkViewMode _viewMode = ArtworkViewMode.masonry;
  PortfolioSortOption _sort = PortfolioSortOption.recent;

  /// Optimistic Hide/Unhide state for a collection group, seeded from the
  /// collection detail fetched lazily when the kebab opens. Null until known.
  bool? _isUserHidden;

  /// The collection's own image, resolved from the collection record on entry
  /// (see [_resolveCollectionImage]). Null until it lands, or when the
  /// collection has no image of its own.
  String? _collectionImageUrl;

  /// Follow state for this group's artist/creator, seeded from the cached
  /// login result and toggled optimistically. Hidden entirely when there's
  /// no follow target (see [_followTarget]).
  late bool _isFollowing;

  /// Fade-out range above the pinned sort/view-mode bar — same cross-fade
  /// behaviour as [CurationScreen].
  static const double _topFadeRange = 20;
  final _scrollController = ScrollController();
  final GlobalKey _pinHeaderBoxKey = GlobalKey();
  double _topContentOpacity = 1;

  late final PortfolioRepository _repository;
  late final PaginationBloc<PortfolioArtwork> _bloc;
  late final PaginationScrollListener _paginationListener;

  /// One page of this group's owned artworks. Shared by [_bloc] (which stops
  /// at whatever the user scrolled to) and [_downloadOwned] (which walks the
  /// whole feed) so both see the same rows and the same backfill.
  Future<PaginatedPage<PortfolioArtwork>> _fetchArtworkPage(int page) async {
    final result = await _repository.getGroupArtworks(
      widget.group.id,
      page: page,
    );
    return PaginatedPage(
      // The drilldown rows don't carry collectionName — for a collection
      // group the group itself IS the collection, so backfill from it.
      items: widget.group.type == ArtGroupType.collection
          ? [
              for (final a in result.artworks)
                a.withCollectionName(widget.group.name),
            ]
          : result.artworks,
      hasMore: result.nextPage != null,
    );
  }

  /// Listens for the global "art set changed" signal so a send/burn/edit made
  /// while drilled into this group re-fetches it (the same signal the My Art
  /// tab uses — this screen owns a separate [PaginationBloc] the signal can't
  /// reach on its own).
  StreamSubscription<void>? _refreshSignalSub;

  /// Optimistic removal: drops a transferred/burnt artwork from this group's
  /// list the instant it leaves the wallet, without waiting for the reindex
  /// refetch [_refreshSignalSub] fires seconds later.
  StreamSubscription<String>? _removalSignalSub;

  /// Optimistic hide/unhide: flips an artwork's badge the instant the
  /// `/v0/hide` write returns.
  StreamSubscription<ArtworkHiddenChange>? _hiddenSignalSub;

  /// Set when a refresh was kicked off by the signal (vs the initial load), so
  /// the consumer can pop the screen if the group came back empty — e.g. the
  /// artwork just sent was the group's last item.
  bool _popIfEmptyAfterRefresh = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateTopFade);
    loadArtworkViewMode().then((mode) {
      if (mounted) setState(() => _viewMode = mode);
    });
    _isFollowing = sl<AuthService>().isFollowing(
      widget.group.artistAddress ?? '',
    );
    final repository = sl<PortfolioRepository>();
    _repository = repository;
    _bloc = PaginationBloc<PortfolioArtwork>(fetchPage: _fetchArtworkPage)
      ..add(const PaginationLoadRequested());
    unawaited(_resolveCollectionImage());

    _paginationListener = PaginationScrollListener(
      controller: _scrollController,
      onLoadMore: () => _bloc.add(const PaginationLoadMoreRequested()),
      canLoadMore: () {
        final s = _bloc.state;
        return s is PaginationLoaded<PortfolioArtwork> &&
            s.hasMore &&
            !s.isLoadingMore;
      },
    )..attach();

    if (sl.isRegistered<PortfolioRefreshSignal>()) {
      _refreshSignalSub = sl<PortfolioRefreshSignal>().stream.listen((_) {
        if (!mounted) return;
        _popIfEmptyAfterRefresh = true;
        _bloc.add(const PaginationRefreshRequested());
      });
    }

    if (sl.isRegistered<ArtworkRemovalSignal>()) {
      _removalSignalSub = sl<ArtworkRemovalSignal>().stream.listen((mint) {
        if (!mounted) return;
        _bloc.removeWhere((a) => a.mintAccount == mint);
      });
    }

    if (sl.isRegistered<ArtworkHiddenSignal>()) {
      _hiddenSignalSub = sl<ArtworkHiddenSignal>().stream.listen((change) {
        if (!mounted) return;
        _bloc.updateWhere(
          (a) => a.mintAccount == change.mintAccount,
          (a) => a.copyWithHidden(change.isHidden),
        );
      });
    }
  }

  @override
  void dispose() {
    _refreshSignalSub?.cancel();
    _removalSignalSub?.cancel();
    _hiddenSignalSub?.cancel();
    _paginationListener.detach();
    _scrollController.dispose();
    _bloc.close();
    super.dispose();
  }

  /// Compute the opacity of content above the in-flow sort/view-mode bar —
  /// same notch-approach trigger as [CurationScreen].
  void _updateTopFade() {
    if (!mounted) return;
    final ctx = _pinHeaderBoxKey.currentContext;
    if (ctx == null) return;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return;
    final dy = ro.localToGlobal(Offset.zero).dy;
    final safeAreaTop = MediaQuery.of(context).padding.top;
    final fade = ((dy - safeAreaTop) / _topFadeRange).clamp(0.0, 1.0);
    if ((fade - _topContentOpacity).abs() > 0.005) {
      setState(() => _topContentOpacity = fade);
    }
  }

  void _onPaginationState(
    BuildContext context,
    PaginationState<PortfolioArtwork> state,
  ) {
    if (state is! PaginationLoaded<PortfolioArtwork>) return;

    // Pop the group screen when a signal-driven refresh leaves it empty (the
    // last artwork in the group was sent/burnt) — but only while it's the
    // top-most route, so a refresh that resolves while the artwork detail is
    // still open doesn't yank the screen out from under it. The refresh's
    // in-flight emission still carries the pre-refresh items — hold the flag
    // until the refetched result lands.
    if (state.isRefreshing) return;
    if (!_popIfEmptyAfterRefresh) return;
    _popIfEmptyAfterRefresh = false;
    if (state.items.isEmpty &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).pop();
    }
  }

  /// Pull-to-refresh: refetch the group's artworks from the first page,
  /// holding the indicator until the refetch settles. Deliberately does not
  /// set [_popIfEmptyAfterRefresh] — a user-initiated refresh that empties
  /// the group should show the empty state, not yank the screen away.
  Future<void> _refresh() {
    _bloc.add(const PaginationRefreshRequested());
    return _bloc.stream.firstWhere(
      (s) => s is! PaginationLoaded<PortfolioArtwork> || !s.isRefreshing,
    );
  }

  void _applySort(PortfolioSortOption sort) {
    setState(() => _sort = sort);
  }

  /// Sort is applied as a derived view of the bloc's items so loadMore can
  /// keep appending without merging sorted slices. Memoized on the list
  /// instance — the builder reruns on every scroll-fade setState, so the
  /// sort only recomputes when the bloc emits a new list.
  List<PortfolioArtwork>? _sortedByName;
  List<PortfolioArtwork>? _sortedByNameSource;

  List<PortfolioArtwork> _sorted(List<PortfolioArtwork> items) {
    if (_sort != PortfolioSortOption.name) return items;
    if (!identical(items, _sortedByNameSource)) {
      _sortedByNameSource = items;
      _sortedByName = List<PortfolioArtwork>.of(
        items,
      )..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return _sortedByName!;
  }

  /// Header subtitle. The drilldown always shows the slice the viewer owns,
  /// so it's labelled uniformly regardless of group type.
  String _subtitle(int artworkCount) =>
      'You own • $artworkCount artwork${artworkCount == 1 ? '' : 's'}';

  /// The address the Follow button targets — the artist for artist groups,
  /// the collection's creator for collection groups. Null (button hidden)
  /// when the address is unknown or is the active user (can't follow self).
  String? get _followTarget {
    final address = widget.group.artistAddress;
    if (address == null || address.isEmpty) return null;
    // Self spans every wallet in the current session, not just the active one:
    // the drilldown aggregates over all session wallets, so a group whose
    // artist is a non-active session wallet is still the viewer — can't follow
    // self. Mirrors the session-wide idiom used by [CollectionScreen].
    final me = sl<AuthService>().currentAddress;
    final mine = <String>{?me, ...sl<SessionManager>().sessionAddresses}
      ..removeWhere((a) => a.isEmpty);
    if (mine.contains(address)) return null;
    return address;
  }

  Future<void> _toggleFollow() async {
    final target = _followTarget;
    if (target == null) return;
    // Following is a social action gated behind a Profile; in Account
    // mode this prompts switch/create. View-only wallets can't act.
    if (!await requireProfile(context)) return;
    if (!mounted) return;
    final wallet = await sl<WalletRepository>().getActiveWallet();
    if (!mounted) return;
    if (wallet != null && !wallet.canSign) {
      await showViewOnlyPrompt(context);
      return;
    }
    final wasFollowing = _isFollowing;
    setState(() => _isFollowing = !wasFollowing);
    try {
      final repo = sl<UserProfileRepository>();
      if (wasFollowing) {
        await repo.unfollowUser(target);
      } else {
        await repo.followUser(target);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isFollowing = wasFollowing);
      AppSnackBar.show(context, 'Failed: $e');
    }
  }

  String get _sortLabel => switch (_sort) {
    PortfolioSortOption.count => 'Count',
    PortfolioSortOption.name => 'Name',
    PortfolioSortOption.recent => 'Recent',
  };

  /// Cycle masonry → detail → grid, persisting to the app-wide artwork
  /// preference.
  void _toggleViewMode() {
    final next = _viewMode.next;
    setState(() => _viewMode = next);
    unawaited(saveArtworkViewMode(next));
  }

  /// Centred header label — the group type, mirroring the Curation screen's
  /// "Curation" header.
  String get _typeLabel => switch (widget.group.type) {
    ArtGroupType.artist => 'Artist',
    ArtGroupType.collection => 'Collection',
    ArtGroupType.curation => 'Curation',
  };

  /// Whether the kebab is shown for this group. Collection groups need a
  /// mint, artist groups need an address; curation groups never reach this
  /// screen (they open the full [CurationScreen] — see `_openGroup`).
  bool get _showKebab {
    final group = widget.group;
    switch (group.type) {
      case ArtGroupType.artist:
        return (group.artistAddress ?? '').isNotEmpty;
      case ArtGroupType.collection:
        return (group.collectionMint ?? '').isNotEmpty;
      case ArtGroupType.curation:
        return false;
    }
  }

  /// True if a wallet in the current session created this collection group —
  /// gates the creator-only rows the same way [CollectionScreen] does. Spans
  /// the whole session rather than the active signer alone: the drilldown
  /// aggregates over every session wallet, so a collection created by a
  /// linked-but-inactive one is still the viewer's (same idiom as
  /// [_followTarget]). The on-chain permission check still has the final say
  /// on whether Edit/Burn enable.
  bool get _isCollectionCreator {
    final group = widget.group;
    if (group.type != ArtGroupType.collection) return false;
    final mint = group.collectionMint;
    if (mint == null || mint.isEmpty) return false;
    return sl<SessionManager>().ownsAddress(group.artistAddress);
  }

  /// The owned slice already loaded in the drilldown — what Cast/Download act
  /// on for both collection and artist groups (a held-art view, so casting or
  /// downloading exactly what the user holds is the right semantic).
  List<PortfolioArtwork> get _ownedItems => _bloc.state.items;

  Future<void> _showGroupMenu() async {
    switch (widget.group.type) {
      case ArtGroupType.collection:
        await _showCollectionMenu();
      case ArtGroupType.artist:
        await _showArtistMenu();
      case ArtGroupType.curation:
        break;
    }
  }

  /// Collection drilldown menu — reuses the shared [showCollectionOptionsSheet]
  /// (same sheet as [CollectionScreen]) so the full row set stays in one place.
  /// The collection detail is re-fetched on open for a current Hide-state
  /// label, mirroring [CollectionScreen]'s lazy `owned` fetch.
  Future<void> _showCollectionMenu() async {
    final mint = widget.group.collectionMint;
    if (mint == null || mint.isEmpty) return;
    final action = await runGuardedSheet<CollectionMenuAction>(
      'portfolioGroupMenu',
      () async {
        // Creator visibility (which gates the Edit/Burn rows) is session-scoped
        // — a Profile must not offer creator actions via a wallet outside its
        // linked set. Download/cast below gate on `items`, the session's own
        // holdings. The detail fetch swallows its own errors → null.
        final owned = sl<SessionManager>().sessionAddresses;
        final detail = await sl<UserProfileRepository>().getCollectionByMint(
          mint,
        );
        if (!mounted) return null;
        _isUserHidden = detail?.isCreatorHidden;
        // Same record the header resolves from on entry — reuse it rather than
        // let the sheet show the owned-artwork thumbnail the header rejected.
        _applyCollectionImage(detail);
        final items = _ownedItems;
        final isCreator =
            _isCollectionCreator || owned.contains(detail?.creatorAddress);
        final creator = widget.group.creatorName;
        return showCollectionOptionsSheet(
          context,
          title: widget.group.name,
          subtitle: (creator != null && creator.isNotEmpty)
              ? 'Collection • $creator'
              : 'Collection',
          imageUrl: _headerImageUrl,
          isCreator: isCreator,
          canCast: items.isNotEmpty,
          canDownload: items.isNotEmpty,
          isUserHidden: detail?.isCreatorHidden,
          // Edit/Burn share the artwork permission rules: edit needs update
          // authority + mutability, burn additionally needs the collection to
          // be empty (Core) or the supply-0 token in the wallet (legacy).
          permissionsFuture: isCreator
              ? sl<ArtworkPermissionService>().checkPermissions(mint)
              : null,
          // The drilldown isn't the collection screen — keep a way in.
          showViewCollection: true,
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case CollectionMenuAction.viewCollection:
        _navigateToEntity();
      case CollectionMenuAction.share:
        await _shareCollection();
      case CollectionMenuAction.cast:
        await _castOwned();
      case CollectionMenuAction.addToCast:
        await _addOwnedToCast();
      case CollectionMenuAction.downloadArtworks:
        await _downloadOwned();
      case CollectionMenuAction.syncToken:
        await _syncCollection();
      case CollectionMenuAction.hideToggle:
        await _toggleHidden();
      case CollectionMenuAction.exportHolders:
        await _exportHolders();
      case CollectionMenuAction.addArtworks:
        await _addArtworks();
      case CollectionMenuAction.edit:
        await _editCollection();
      case CollectionMenuAction.burn:
        await _burnCollection();
    }
  }

  /// Artist drilldown menu. There is no shared artist options sheet, so this
  /// is a small bespoke sheet: View artist plus the owned-slice Cast/Download
  /// actions shared with the collection path. No creator/permission rows —
  /// there's nothing to edit/burn at the artist level.
  Future<void> _showArtistMenu() async {
    final address = widget.group.artistAddress;
    if (address == null || address.isEmpty) return;
    final items = _ownedItems;
    final choice = await runGuardedSheet<_ArtistMenuChoice>(
      'portfolioGroupMenu',
      () => showMallowSheet<_ArtistMenuChoice>(
        context: context,
        builder: (_) => _ArtistGroupSheet(
          canCast: items.isNotEmpty,
          canDownload: items.isNotEmpty,
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _ArtistMenuChoice.view:
        _navigateToEntity();
      case _ArtistMenuChoice.share:
        await _shareArtist();
      case _ArtistMenuChoice.cast:
        await _castOwned();
      case _ArtistMenuChoice.addToCast:
        await _addOwnedToCast();
      case _ArtistMenuChoice.download:
        await _downloadOwned();
    }
  }

  /// Every owned artwork in the group. Like [_downloadOwned], the loaded page
  /// only gates the action — casting `state.items` would queue the 20 rows in
  /// memory and call a 90-artwork group done.
  Future<List<PortfolioArtwork>?> _resolveOwnedItems() =>
      drainPagesWhilePreparing(context, _fetchArtworkPage);

  Future<void> _castOwned() async {
    if (_ownedItems.isEmpty) return;
    final items = await _resolveOwnedItems();
    if (items == null || items.isEmpty) return;
    unawaited(
      castArtworksWithVerify(
        items.map(CastQueueItemFromArtwork.fromPortfolioArtwork).toList(),
      ),
    );
  }

  Future<void> _addOwnedToCast() async {
    if (_ownedItems.isEmpty) return;
    final items = await _resolveOwnedItems();
    if (items == null || items.isEmpty || !mounted) return;
    addArtworksToCastQueue(
      items.map(CastQueueItemFromArtwork.fromPortfolioArtwork).toList(),
    );
    AppSnackBar.show(context, 'Added to cast');
  }

  Future<void> _downloadOwned() async {
    // The loaded page only gates the action; the download itself walks every
    // page, or a 90-artwork group would save the 20 rows in memory.
    if (_ownedItems.isEmpty || !mounted) return;
    await runBulkArtworkDownload(
      context,
      resolveArtworks: (isCancelled) =>
          drainPages(_fetchArtworkPage, shouldStop: isCancelled),
      albumName: 'mallow / ${widget.group.name}',
    );
  }

  Future<void> _shareCollection() async {
    final url = 'https://mallow.art/collection/${widget.group.collectionMint}';
    await SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
  }

  Future<void> _shareArtist() async {
    final group = widget.group;
    // Canonical profile URL: prefer the username link (`/u/<username>`),
    // fall back to the address link (`/a/<address>`) — see [UserProfileScreen].
    final username = group.artistUsername;
    final path = (username != null && username.isNotEmpty)
        ? AppRoutes.deepLinkProfileByUsernamePath(username)
        : AppRoutes.deepLinkProfilePath(group.artistAddress!);
    await SharePlus.instance.share(
      ShareParams(uri: Uri.parse('https://mallow.art$path')),
    );
  }

  Future<void> _syncCollection() async {
    final mint = widget.group.collectionMint;
    if (mint == null) return;
    try {
      await sl<UserProfileRepository>().syncCollection(mint);
      if (!mounted) return;
      AppSnackBar.show(context, 'Metadata update requested');
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.show(context, 'Sync failed: $e');
    }
  }

  Future<void> _toggleHidden() async {
    final mint = widget.group.collectionMint;
    if (mint == null) return;
    final previous = _isUserHidden ?? false;
    final next = !previous;
    setState(() => _isUserHidden = next);
    try {
      final repo = sl<UserProfileRepository>();
      if (next) {
        await repo.hideMint(mint);
      } else {
        await repo.unhideMint(mint);
      }
      if (!mounted) return;
      AppSnackBar.show(context, next ? 'Hidden' : 'Unhidden');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isUserHidden = previous);
      AppSnackBar.show(context, 'Failed: $e');
    }
  }

  Future<void> _exportHolders() async {
    final mint = widget.group.collectionMint;
    if (mint == null) return;
    AppSnackBar.show(
      context,
      'Exporting holders…',
      duration: const Duration(seconds: 30),
    );
    try {
      final holders = await sl<UserProfileRepository>().getDetailedHolders(
        mint,
      );
      final csv = _holdersToCsv(holders);
      final tempDir = await getTemporaryDirectory();
      final filename = 'holders-$mint.csv';
      final file = File(p.join(tempDir.path, filename));
      await file.writeAsString(csv);
      AppSnackBar.dismiss();
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: filename,
        ),
      );
    } catch (e) {
      AppSnackBar.dismiss();
      if (!mounted) return;
      AppSnackBar.show(context, 'Export failed: $e');
    }
  }

  Future<void> _addArtworks() async {
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    await context.push(
      '${AppRoutes.collectionArtworksPath(widget.group.collectionMint!)}'
      '?name=${Uri.encodeQueryComponent(widget.group.name)}',
    );
  }

  Future<void> _editCollection() async {
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    // Header name/thumbnail come from the parent screen's groups feed and
    // refresh with it — nothing on this screen to re-fetch after an edit.
    await context.push(
      AppRoutes.editCollectionPath(widget.group.collectionMint!),
    );
  }

  Future<void> _burnCollection() async {
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    final group = widget.group;
    final burned = await runBurnArtworkFlow(
      context,
      artwork: PortfolioArtwork(
        mintAccount: group.collectionMint!,
        title: group.name,
        imageUrl: group.thumbnailUrl ?? '',
        artistName: group.creatorName ?? '',
        updateAuth: group.artistAddress,
      ),
      isCollection: true,
    );
    if (!burned || !mounted) return;
    AppSnackBar.show(context, 'Collection burned');
    Navigator.of(context).pop();
  }

  void _navigateToEntity() {
    final group = widget.group;
    switch (group.type) {
      case ArtGroupType.artist:
        final address = group.artistAddress;
        if (address != null && address.isNotEmpty) {
          context.goToProfile(address);
        }
      case ArtGroupType.collection:
        final mint = group.collectionMint;
        if (mint != null && mint.isNotEmpty) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CollectionScreen(
                group: ArtGroup(
                  id: mint,
                  type: ArtGroupType.collection,
                  name: group.name,
                  thumbnailUrl: group.thumbnailUrl,
                  artworkCount: group.artworkCount,
                  artistAddress: group.artistAddress,
                  collectionMint: mint,
                  creatorName: group.creatorName,
                ),
              ),
            ),
          );
        }
      case ArtGroupType.curation:
        break;
    }
  }

  void _openArtworkDetail(PortfolioArtwork artwork) {
    context.push(AppRoutes.artworkDetailPath(artwork.mintAccount));
  }

  Future<void> _showArtworkContextMenu(PortfolioArtwork artwork) {
    // Removal is handled globally via [ArtworkRemovalSignal] (see initState) so
    // the item also drops from the My Art tab underneath, not just this screen.
    return showAndHandleArtworkContextMenu(context, artwork: artwork);
  }

  /// Look up the collection's own image so the header shows the collection
  /// rather than a piece out of it. The grouped feed's [ArtGroup.thumbnailUrl]
  /// is the first owned artwork whenever the collection record carries no
  /// image, so it can't be trusted as the collection's identity. Prefers the
  /// curated image (what [CollectionScreen] shows), then the collection
  /// token's own metadata image. Silent on failure — the feed thumbnail stays.
  Future<void> _resolveCollectionImage() async {
    final group = widget.group;
    if (group.type != ArtGroupType.collection) return;
    final mint = group.collectionMint;
    if (mint == null || mint.isEmpty) return;
    // Swallows its own errors → null.
    _applyCollectionImage(
      await sl<UserProfileRepository>().getCollectionByMint(mint),
    );
  }

  /// Take the collection's own image out of a fetched collection record. The
  /// curated image wins over the collection token's metadata image; both are
  /// optional and the curated one defaults to empty, so an empty string counts
  /// as absent rather than as "no image".
  void _applyCollectionImage(CollectionFullRender? detail) {
    final curated = detail?.imageUrl;
    final url = (curated != null && curated.isNotEmpty)
        ? curated
        : detail?.nft?.imageUrl;
    if (!mounted || url == null || url.isEmpty) return;
    setState(() => _collectionImageUrl = url);
  }

  /// The image the header identifies the group by: the artist's profile
  /// picture for an artist group, the collection's own image for a collection.
  /// [ArtGroup.thumbnailUrl] is the last resort — the grouped feed fills it
  /// with one of the owned artworks when it has nothing better, which reads as
  /// if the group *is* that artwork.
  String? get _headerImageUrl {
    final group = widget.group;
    final preferred = switch (group.type) {
      ArtGroupType.artist => group.avatarUrl,
      ArtGroupType.collection => _collectionImageUrl,
      ArtGroupType.curation => null,
    };
    if (preferred != null && preferred.isNotEmpty) return preferred;
    return group.thumbnailUrl;
  }

  /// 48px header avatar — the artist's pfp / the collection's image (see
  /// [_headerImageUrl]), falling back to a generated identicon seeded from the
  /// group's identifiers.
  Widget _buildAvatar() {
    const size = 48.0;
    final fallback = AccountAvatar(
      seed: avatarSeedOf(
        address: widget.group.artistAddress,
        username: widget.group.artistUsername,
        id: widget.group.id,
      ),
      size: size,
      borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
    );
    final url = _headerImageUrl;
    if (url == null || url.isEmpty) return fallback;
    return MallowNetworkImage(
      imageUrl: url,
      logicalSize: size,
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      errorBuilder: (_) => fallback,
    );
  }

  /// Header identity row: avatar + group name + owned-count subtitle.
  Widget _buildIdentity(int artworkCount) {
    final colors = context.mallowColors;
    return Row(
      children: [
        _buildAvatar(),
        const SizedBox(width: MallowTheme.spacing12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.group.name,
                style: MallowTheme.editorialSection.copyWith(
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: MallowTheme.spacingXs),
              Text(
                _subtitle(artworkCount),
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Follow / Download / Cast row beneath the header identity. Follow is
  /// hidden when there's no target (see [_followTarget]); Download and Cast
  /// disable while the owned slice is empty.
  Widget _buildActionRow({required bool canAct}) {
    final colors = context.mallowColors;
    return Wrap(
      spacing: MallowTheme.spacingSm,
      runSpacing: MallowTheme.spacingSm,
      children: [
        if (_followTarget != null)
          _HeaderActionButton(
            label: _isFollowing ? 'Following' : 'Follow',
            foreground: _isFollowing
                ? colors.textSecondary
                : colors.textPrimary,
            onTap: _toggleFollow,
          ),
        _HeaderActionButton(
          label: 'Download',
          iconAsset: 'assets/icons/download.svg',
          onTap: canAct ? () => unawaited(_downloadOwned()) : null,
        ),
        _HeaderActionButton(
          label: 'Cast',
          iconAsset: 'assets/icons/cast.svg',
          onTap: canAct ? _castOwned : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final safeAreaTop = MediaQuery.of(context).padding.top;
    final showKebab = _showKebab;

    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body:
          BlocConsumer<
            PaginationBloc<PortfolioArtwork>,
            PaginationState<PortfolioArtwork>
          >(
            bloc: _bloc,
            listener: _onPaginationState,
            builder: (context, state) {
              final isLoading =
                  state is PaginationInitial<PortfolioArtwork> ||
                  state is PaginationLoading<PortfolioArtwork>;
              final loaded = state is PaginationLoaded<PortfolioArtwork>
                  ? state
                  : null;
              final artworks = _sorted(state.items);
              // The paged endpoint only reveals the exact count once the
              // last page is in; fall back to the tile's count until then.
              final artworkCount = (loaded != null && !loaded.hasMore)
                  ? artworks.length
                  : widget.group.artworkCount;

              return Stack(
                children: [
                  MallowRefreshIndicator(
                    edgeOffset: safeAreaTop,
                    onRefresh: _refresh,
                    child: CustomScrollView(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        // --- Header bar: back · group type · kebab ---
                        SliverOpacity(
                          opacity: _topContentOpacity,
                          sliver: SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: MallowTheme.spacing20,
                                right: MallowTheme.spacing20,
                                top: safeAreaTop + MallowTheme.spacingMd,
                              ),
                              child: SizedBox(
                                height: 40,
                                child: Row(
                                  children: [
                                    TapTargetExpander(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () =>
                                            Navigator.of(context).pop(),
                                        child: SizedBox(
                                          width: 24,
                                          height: 40,
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: SvgPicture.asset(
                                              'assets/icons/arrow_left.svg',
                                              width: 16,
                                              height: 16,
                                              colorFilter: ColorFilter.mode(
                                                colors.textPrimary,
                                                BlendMode.srcIn,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        _typeLabel,
                                        textAlign: TextAlign.center,
                                        style: MallowTheme.uiCaption.copyWith(
                                          color: colors.textPrimary,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 24,
                                      height: 40,
                                      child: showKebab
                                          ? TapTargetExpander(
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: _showGroupMenu,
                                                child: Align(
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child: SvgPicture.asset(
                                                    'assets/icons/dots_vertical.svg',
                                                    width: 16,
                                                    height: 16,
                                                    colorFilter:
                                                        ColorFilter.mode(
                                                          colors.textPrimary,
                                                          BlendMode.srcIn,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            )
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),

                        // --- Title + subtitle ---
                        SliverOpacity(
                          opacity: _topContentOpacity,
                          sliver: SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: MallowTheme.spacing20,
                                right: MallowTheme.spacing20,
                                top: MallowTheme.spacing20,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildIdentity(artworkCount),
                                  const SizedBox(height: 16),
                                  _buildActionRow(canAct: artworks.isNotEmpty),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // In-flow sort/view-mode bar. The floating overlay (in
                        // the parent Stack) takes over with a safe-area inset
                        // as this bar approaches the notch — see
                        // [SortViewModeBar] and the cross-fade logic below.
                        SliverOpacity(
                          opacity: _topContentOpacity,
                          sliver: SliverToBoxAdapter(
                            child: SortViewModeBar(
                              key: _pinHeaderBoxKey,
                              sortLabel: _sortLabel,
                              currentSort: _sort,
                              viewModeIcon: _viewMode.iconAsset,
                              onSortChanged: _applySort,
                              onViewModeToggle: _toggleViewMode,
                            ),
                          ),
                        ),

                        // --- Content ---
                        if (isLoading)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(child: MallowLoadingIndicator()),
                          )
                        else if (artworks.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Text(
                                'No artworks yet',
                                style: MallowTheme.uiMeta.copyWith(
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                          )
                        else
                          switch (_viewMode) {
                            ArtworkViewMode.masonry => AllArtMasonry(
                              artworks: artworks,
                              onTap: _openArtworkDetail,
                              onLongPress: _showArtworkContextMenu,
                            ),
                            ArtworkViewMode.detail => AllArtDetail(
                              artworks: artworks,
                              onTap: _openArtworkDetail,
                              onLongPress: _showArtworkContextMenu,
                            ),
                            ArtworkViewMode.grid => AllArtGrid(
                              artworks: artworks,
                              onTap: _openArtworkDetail,
                              onLongPress: _showArtworkContextMenu,
                            ),
                          },

                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: MallowTheme.spacingMd,
                            ),
                            child: (loaded?.isLoadingMore ?? false)
                                ? const Center(child: MallowLoadingIndicator())
                                : const SizedBox.shrink(),
                          ),
                        ),
                        const SliverToBoxAdapter(
                          child: NavBarBottomReserve(base: 120),
                        ),
                      ],
                    ),
                  ),

                  // Floating sort/view-mode bar with safe-area inset that
                  // fades in as the in-flow bar approaches the notch. Slides
                  // 20px into place during the fade so the row stays aligned
                  // with the in-flow bar during the cross-fade.
                  Positioned(
                    top: _topFadeRange * _topContentOpacity,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: _topContentOpacity > 0.5,
                      child: Opacity(
                        opacity: 1 - _topContentOpacity,
                        child: SortViewModeBar(
                          sortLabel: _sortLabel,
                          currentSort: _sort,
                          viewModeIcon: _viewMode.iconAsset,
                          onSortChanged: _applySort,
                          onViewModeToggle: _toggleViewMode,
                          topInset: safeAreaTop,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }
}

/// Small outlined pill in the header action row (Follow / Download / Cast).
/// Hugs its content; disables (greyed, non-tappable) when [onTap] is null.
class _HeaderActionButton extends StatelessWidget {
  const _HeaderActionButton({
    required this.label,
    this.iconAsset,
    this.foreground,
    this.onTap,
  });

  final String label;
  final String? iconAsset;

  /// Overrides the label/icon colour (e.g. the Follow/Following toggle).
  /// Defaults to textPrimary when enabled, textSecondary when disabled.
  final Color? foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final enabled = onTap != null;
    final fg =
        foreground ?? (enabled ? colors.textPrimary : colors.textSecondary);
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing12,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: colors.dividerLight),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (iconAsset != null) ...[
                SvgPicture.asset(
                  iconAsset!,
                  width: 14,
                  height: 14,
                  colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
                ),
                const SizedBox(width: MallowTheme.spacingXs),
              ],
              Text(label, style: MallowTheme.uiCaption.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the artist group kebab sheet resolved to.
enum _ArtistMenuChoice { view, share, cast, addToCast, download }

/// Bottom sheet for the artist drilldown kebab. Collection groups use the
/// shared [showCollectionOptionsSheet] instead; artists have no shared sheet,
/// so this small one mirrors the same row styling. Cast/Download act on the
/// owned-by-this-artist slice already loaded in the drilldown.
class _ArtistGroupSheet extends StatelessWidget {
  const _ArtistGroupSheet({required this.canCast, required this.canDownload});

  final bool canCast;
  final bool canDownload;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              width: 60,
              height: 3,
              decoration: BoxDecoration(
                color: colors.divider,
                borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SheetMenuRow(
            assetPath: 'assets/icons/profile.svg',
            label: 'View artist',
            onTap: () => Navigator.of(context).pop(_ArtistMenuChoice.view),
          ),
          SheetMenuRow(
            assetPath: 'assets/icons/export.svg',
            label: 'Share artist',
            onTap: () => Navigator.of(context).pop(_ArtistMenuChoice.share),
          ),
          if (canCast)
            SheetMenuRow(
              assetPath: 'assets/icons/cast.svg',
              label: 'Cast to screen',
              onTap: () => Navigator.of(context).pop(_ArtistMenuChoice.cast),
            ),
          // "Add to cast" only makes sense when there's already a queue to
          // append to.
          if (canCast && isCastActive)
            SheetMenuRow(
              assetPath: 'assets/icons/add_to_cast.svg',
              label: 'Add to cast',
              onTap: () =>
                  Navigator.of(context).pop(_ArtistMenuChoice.addToCast),
            ),
          if (canDownload)
            SheetMenuRow(
              assetPath: 'assets/icons/download.svg',
              label: 'Download artworks',
              onTap: () =>
                  Navigator.of(context).pop(_ArtistMenuChoice.download),
            ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }
}

/// Webapp-parity CSV builder. Matches the conditional shape used by the
/// collection screen's export: include the Edition Number column only when at
/// least one row carries one.
String _holdersToCsv(List<HolderEntry> holders) {
  final hasEditions = holders.any((h) => h.editionNumber > 0);
  if (hasEditions) {
    final sorted = [...holders]
      ..sort((a, b) => a.editionNumber.compareTo(b.editionNumber));
    return 'Edition Number,Asset ID,Owner\n'
        '${sorted.map((h) => '${h.editionNumber},${h.assetId},${h.owner}').join('\n')}';
  }
  return 'Asset ID,Owner\n'
      '${holders.map((h) => '${h.assetId},${h.owner}').join('\n')}';
}
