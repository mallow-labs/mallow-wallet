import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/pagination/drain_pages.dart';
import '../../../shared/pagination/pagination_bloc.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/pagination/pagination_scroll_listener.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/metadata_host.dart';
import '../../../shared/utils/token_standard_label.dart';
import '../../../shared/widgets/animated_tab_content.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/expandable_text.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_pill_chip.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/new_curation_sheet.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/user_handle_text.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../../artwork/services/artwork_download_actions.dart';
import '../../artwork/services/artwork_hidden_signal.dart';
import '../../artwork/services/artwork_hide_actions.dart';
import '../../portfolio/widgets/hidden_artwork_badge.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../artwork/services/artwork_removal_signal.dart';
import '../../artwork/services/artwork_permission_service.dart';
import '../../artwork/services/bulk_artwork_download.dart';
import '../../artwork/widgets/add_to_curation_sheet.dart';
import '../../artwork/widgets/artwork_context_menu_sheet.dart';
import '../../artwork/widgets/burn_artwork_flow.dart';
import '../../artwork/widgets/transfer_artwork_flow.dart';
import '../../cast/models/cast_queue.dart';
import '../../cast/services/cast_actions.dart';
import '../../cast/services/cast_bloc.dart';
import '../../mint/pickers/category_picker_sheet.dart';
import '../../portfolio/screens/portfolio_group_screen.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/widgets/all_art_detail.dart';
import '../../portfolio/widgets/all_art_masonry.dart';
import '../../portfolio/widgets/sort_bottom_sheet.dart';
import '../../curations/data/curation_repository.dart';
import '../../search/services/recently_viewed_recorder.dart';
import '../data/user_profile_repository.dart';
import '../models/user_profile.dart';
import '../widgets/collection_options_sheet.dart';
import '../widgets/profile_banner.dart';
import '../widgets/profile_required_sheet.dart';
import '../widgets/profile_you_own_banner.dart';

part 'collection_screen/collection_header.dart';
part 'collection_screen/collection_sort_bar.dart';
part 'collection_screen/collection_sections.dart';
part 'collection_screen/artwork_views.dart';
part 'collection_screen/download_dialog.dart';

/// Screen showing all artworks within a collection. Layout mirrors
/// [UserProfileScreen] — banner / header / action bar / "You own" banner /
/// stacked sections / sort bar / artwork list. The filtered "You own in this
/// collection" drilldown lives in [PortfolioGroupScreen].
class CollectionScreen extends StatefulWidget {
  const CollectionScreen({required this.group, this.profile, super.key});

  /// Collection group. Must have `type == ArtGroupType.collection`.
  final ArtGroup group;

  /// Creator profile if already loaded by the caller. When null the screen
  /// fetches it via [UserProfileRepository.getUserProfile] using
  /// [ArtGroup.artistAddress].
  final UserProfile? profile;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  /// Seeded from the app-wide artwork preference in [initState], so a
  /// collection opens in the layout the user last picked anywhere.
  ArtworkViewMode _viewMode = ArtworkViewMode.masonry;
  PortfolioSortOption _sort = PortfolioSortOption.recent;

  UserProfile? _profile;
  api.CollectionFullRender? _collection;

  /// First page of the viewer-owned slice — thumbnails for the "You own"
  /// banner and the non-empty check that shows it. NOT the count: it is capped
  /// at one page, so [_youOwnTotal] carries that.
  List<PortfolioArtwork>? _youOwnArtworks;

  /// Server-side count of the viewer-owned slice, which is what the banner
  /// shows. `_youOwnArtworks.length` maxes out at `pageSize` and would tell a
  /// viewer who owns 30 pieces that they own 20 — the same trap
  /// [UserProfileRepository.getYouOwnArtworks] documents for the artist banner.
  int _youOwnTotal = 0;

  /// Mirrors the webapp's optimistic Hide/Unhide toggle. Seeded from
  /// `_collection.isCreatorHidden` once the detail fetch resolves; null
  /// while we still don't know.
  bool? _isUserHidden;

  /// Fade-out range above the pinned sort/display bar. Mirrors the
  /// behaviour in [UserProfileScreen].
  static const double _topFadeRange = 20;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _pinHeaderBoxKey = GlobalKey();
  double _topContentOpacity = 1;

  /// Pagination is driven by a generic [PaginationBloc]. The collection
  /// endpoint has no `hasMore` flag, so we infer end-of-feed from an empty
  /// page (matching the prior bespoke logic).
  late final PaginationBloc<PortfolioArtwork> _bloc;
  late final PaginationScrollListener _paginationListener;

  /// Fires when an artwork in this collection (or the collection itself) is
  /// edited — refetches the list + header. See [initState].
  StreamSubscription<String>? _editedSignalSub;

  /// Optimistic removal: drops a transferred/burnt artwork from the paged list
  /// and the viewer-owned slice the instant it leaves the wallet. See
  /// [initState].
  StreamSubscription<String>? _removalSignalSub;

  /// Optimistic hide/unhide: flips an artwork's badge in the paged list the
  /// instant the `/v0/hide` write returns. See [initState].
  StreamSubscription<ArtworkHiddenChange>? _hiddenSignalSub;

  /// True if the authenticated user is the creator of this collection.
  /// Checked against the creator profile when one was passed/fetched, with
  /// a fallback to the collection detail's creator address — entry points
  /// like the portfolio drilldown don't carry the creator profile.
  bool get _isCollectionCreator {
    final me = sl<AuthService>().currentAddress;
    // Creator status spans every wallet in the current session (Profile /
    // Account), not just the active one: casting the whole collection is a
    // no-signing gate, and the Edit / Burn actions this flag also reveals stay
    // separately gated by the active-wallet on-chain `checkPermissions`.
    final mine = <String>{?me, ...sl<SessionManager>().sessionAddresses}
      ..removeWhere((a) => a.isEmpty);
    return mine.contains(_profile?.address) ||
        mine.contains(_collection?.creatorAddress);
  }

  /// Artworks the action-bar Cast button should cast: the full collection if
  /// the viewer is the creator, otherwise just the slice the viewer owns.
  ///
  /// This is the loaded prefix — enough to answer "is there anything to cast",
  /// not what actually gets cast. [_resolveCastableList] walks every page; see
  /// [drainPages].
  List<PortfolioArtwork> get _castableList =>
      _isCollectionCreator ? _bloc.state.items : (_youOwnArtworks ?? const []);

  bool get _canCast => _castableList.isNotEmpty;

  /// Every castable artwork, not just the pages scrolled into memory — a
  /// 90-piece collection would otherwise cast the 20 rows the list happens to
  /// hold.
  Future<List<PortfolioArtwork>?> _resolveCastableList() =>
      drainPagesWhilePreparing(
        context,
        _isCollectionCreator ? _fetchCollectionPage : _fetchYouOwnPage,
      );

  Future<void> _castCollection() async {
    if (!_canCast) return;
    final list = await _resolveCastableList();
    if (list == null || list.isEmpty) return;
    unawaited(
      castArtworksWithVerify(
        list.map(CastQueueItemFromArtwork.fromPortfolioArtwork).toList(),
      ),
    );
  }

  Future<void> _addCollectionToCast() async {
    if (!_canCast) return;
    final list = await _resolveCastableList();
    if (list == null || list.isEmpty || !mounted) return;
    addArtworksToCastQueue(
      list.map(CastQueueItemFromArtwork.fromPortfolioArtwork).toList(),
    );
    AppSnackBar.show(context, 'Added to cast');
  }

  @override
  void initState() {
    super.initState();
    _profile = widget.profile;
    _scrollController.addListener(_onScroll);

    _bloc = PaginationBloc<PortfolioArtwork>(fetchPage: _fetchCollectionPage);

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

    _bloc.add(const PaginationLoadRequested());

    loadArtworkViewMode().then((mode) {
      if (mounted) setState(() => _viewMode = mode);
    });

    final artistAddress = widget.group.artistAddress;
    if (_profile == null && artistAddress != null && artistAddress.isNotEmpty) {
      _fetchProfile(artistAddress);
    }

    _fetchCollectionDetail();
    _fetchYouOwnArtworks();

    RecentlyViewedRecorder.recordCollection(
      name: widget.group.name,
      slug: widget.group.collectionMint ?? widget.group.id,
      thumbnailUrl: widget.group.thumbnailUrl,
      curatorUsername: widget.group.creatorName,
      curatorAddress: widget.group.artistAddress,
    );

    // An edit of this collection or of any artwork inside it lands after the
    // screen is already built — refetch the list + header when the indexer
    // acks so name/thumbnail/membership changes show.
    if (sl.isRegistered<ArtworkEditedSignal>()) {
      _editedSignalSub = sl<ArtworkEditedSignal>().stream.listen((_) {
        if (!mounted) return;
        _bloc.add(const PaginationRefreshRequested());
        unawaited(_fetchCollectionDetail());
      });
    }

    // Optimistic removal on a confirmed transfer/burn — drop from the paged
    // list, and from the viewer-owned slice when it's showing.
    if (sl.isRegistered<ArtworkRemovalSignal>()) {
      _removalSignalSub = sl<ArtworkRemovalSignal>().stream.listen((mint) {
        if (!mounted) return;
        _bloc.removeWhere((a) => a.mintAccount == mint);
        final youOwn = _youOwnArtworks;
        if (youOwn != null && youOwn.any((a) => a.mintAccount == mint)) {
          setState(() {
            _youOwnArtworks = [
              for (final a in youOwn)
                if (a.mintAccount != mint) a,
            ];
            // The banner counts the server total, not this list — drop it too
            // or the count keeps claiming the piece that just left the wallet.
            if (_youOwnTotal > 0) _youOwnTotal--;
          });
        }
      });
    }

    // Optimistic hide/unhide — flip the badge on the matching tile.
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
    _editedSignalSub?.cancel();
    _removalSignalSub?.cancel();
    _hiddenSignalSub?.cancel();
    _paginationListener.detach();
    _scrollController.dispose();
    _bloc.close();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (!mounted) return;
    _updateTopFade();
  }

  void _updateTopFade() {
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

  /// Cycle masonry → detail → grid, mirroring [UserProfileScreen], and persist
  /// the choice to the app-wide artwork preference.
  void _cycleViewMode() {
    final next = _viewMode.next;
    setState(() => _viewMode = next);
    unawaited(saveArtworkViewMode(next));
  }

  String get _viewModeIcon => _viewMode.iconAsset;

  Future<void> _fetchProfile(String address) async {
    try {
      final profile = await sl<UserProfileRepository>().getUserProfile(address);
      if (mounted) setState(() => _profile = profile);
    } catch (_) {
      // Profile fetch failure is non-fatal — header falls back to group.creatorName.
    }
  }

  Future<void> _fetchCollectionDetail() async {
    final collection = await sl<UserProfileRepository>().getCollectionByMint(
      widget.group.id,
    );
    if (kDebugMode) {
      debugPrint(
        '[CollectionScreen] detail for ${widget.group.id} → '
        'imageUrl=${collection?.imageUrl}, '
        'bannerUrl=${collection?.bannerUrl}, '
        'description=${(collection?.description ?? '').isNotEmpty}',
      );
    }
    if (mounted) {
      setState(() {
        _collection = collection;
        _isUserHidden = collection?.isCreatorHidden;
      });
    }
  }

  /// One page of this collection, shared by [_bloc] and the creator branch of
  /// [_downloadArtworks] so a bulk download walks the same rows the list shows.
  Future<PaginatedPage<PortfolioArtwork>> _fetchCollectionPage(int page) async {
    final items = await sl<UserProfileRepository>().getCollectionArtworks(
      widget.group.id,
      page: page,
    );
    // Endpoint has no hasMore flag; an empty page means we're done. The
    // previous bespoke logic did the same — keep parity.
    return PaginatedPage(
      // The v1 preview render doesn't carry collectionName — backfill it
      // from the collection this screen is showing so downstream surfaces
      // (context-menu sheet) can label the artwork.
      items: [for (final a in items) a.withCollectionName(widget.group.name)],
      hasMore: items.isNotEmpty,
    );
  }

  /// One page of the viewer-owned slice of this collection, or `null` when
  /// there is no address to scope it to.
  ///
  /// "You own" spans the whole session (every wallet of the active Account, or
  /// every wallet linked to the active Profile) — not just the active address,
  /// and NOT the device-wide download set: a Profile must never list holdings
  /// of a wallet outside its linked set as the user's own. Falls back to the
  /// active address if the session set is empty.
  Future<ProfileArtworksResult?> _fetchYouOwnResult(int page) async {
    final myAddress = sl<AuthService>().currentAddress;
    final owned = sl<SessionManager>().apiOwnerAddresses;
    final addresses = owned.isNotEmpty ? owned : [?myAddress];
    if (addresses.isEmpty) return null;
    return sl<UserProfileRepository>().getUserArtworks(
      addresses,
      page: page,
      tab: api.ApiProfileTab.collected,
      filter: api.ExploreFilter(collections: [widget.group.id]),
    );
  }

  /// The viewer-owned slice as a page — [_fetchYouOwnArtworks] takes just the
  /// first for the banner; the non-creator download branch walks them all.
  Future<PaginatedPage<PortfolioArtwork>> _fetchYouOwnPage(int page) async {
    final result = await _fetchYouOwnResult(page);
    if (result == null) return const PaginatedPage(items: [], hasMore: false);
    return PaginatedPage(
      // Same backfill as the main list — the v1 preview render doesn't
      // carry collectionName.
      items: [
        for (final a in result.artworks)
          a.withCollectionName(widget.group.name),
      ],
      hasMore: result.nextPage != null,
    );
  }

  Future<void> _fetchYouOwnArtworks() async {
    try {
      final result = await _fetchYouOwnResult(0);
      if (result == null || !mounted) return;
      setState(() {
        _youOwnArtworks = [
          for (final a in result.artworks)
            a.withCollectionName(widget.group.name),
        ];
        _youOwnTotal = result.total;
      });
    } catch (_) {
      // Silent failure — banner just won't appear.
    }
  }

  /// Pull-to-refresh: refetch the artwork list and the header data (detail,
  /// creator profile, you-own slice) in parallel, holding the indicator until
  /// the pagination refetch settles.
  Future<void> _refresh() {
    _bloc.add(const PaginationRefreshRequested());
    final artistAddress = widget.group.artistAddress;
    return Future.wait<void>([
      _bloc.stream.firstWhere(
        (s) => s is! PaginationLoaded<PortfolioArtwork> || !s.isRefreshing,
      ),
      // Header fetch failure keeps whatever is on screen — just retract.
      _fetchCollectionDetail().catchError((_) {}),
      _fetchYouOwnArtworks(),
      if (artistAddress != null && artistAddress.isNotEmpty)
        _fetchProfile(artistAddress),
    ]);
  }

  /// Wraps the scroll view in pull-to-refresh.
  Widget _withRefresh(Widget child) => MallowRefreshIndicator(
    // The banner is full-bleed behind the status bar — keep the
    // spinner below the notch.
    edgeOffset: MediaQuery.of(context).padding.top,
    onRefresh: _refresh,
    child: child,
  );

  void _applySort(PortfolioSortOption sort) {
    setState(() => _sort = sort);
  }

  /// Sort is applied as a derived view of the bloc's items so loadMore can
  /// keep appending without us having to merge sorted slices.
  List<PortfolioArtwork> _sorted(List<PortfolioArtwork> items) {
    if (_sort != PortfolioSortOption.name) return items;
    return List<PortfolioArtwork>.of(items)
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  String get _sortLabel => switch (_sort) {
    PortfolioSortOption.count => 'Count',
    PortfolioSortOption.name => 'Name',
    PortfolioSortOption.recent => 'Recent',
  };

  /// Creator username without any `@` prefix — backend handles sometimes
  /// arrive already prefixed, which used to render as `@@`.
  String get _creatorUsername {
    final raw = _profile?.handle.isNotEmpty == true
        ? _profile!.handle
        : _profile?.username ?? widget.group.creatorName ?? '';
    return raw.startsWith('@') ? raw.substring(1) : raw;
  }

  String get _displaySubtitle => 'Collection • $_creatorUsername';

  /// Widget form of [_displaySubtitle] used by the header. The username
  /// portion is a tappable link to the creator's profile.
  Widget _buildSubtitleWidget(BuildContext context) {
    final style = MallowTheme.uiCaption.copyWith(
      color: context.mallowColors.textSecondary,
    );
    final username = _creatorUsername;
    if (username.isEmpty) {
      return Text('Collection', style: style, overflow: TextOverflow.ellipsis);
    }
    return UserHandleText(
      prefix: 'Collection • ',
      username: username,
      address: _profile?.address,
      style: style,
      linkStyle: style.copyWith(color: context.mallowColors.textPrimary),
      showAt: false,
      overflow: TextOverflow.ellipsis,
    );
  }

  void _openYouOwnView() {
    final creator = _creatorUsername;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PortfolioGroupScreen(
          group: ArtGroup(
            id: 'collection:${widget.group.id}',
            type: ArtGroupType.collection,
            name: widget.group.name,
            thumbnailUrl: _collection?.imageUrl ?? widget.group.thumbnailUrl,
            artworkCount: _youOwnArtworks == null
                ? widget.group.artworkCount
                : _youOwnTotal,
            artistAddress: _profile?.address ?? _collection?.creatorAddress,
            collectionMint: widget.group.id,
            creatorName: creator.isEmpty ? null : creator,
          ),
        ),
      ),
    );
  }

  void _openArtworkDetail(PortfolioArtwork artwork) {
    context.push(AppRoutes.artworkDetailPath(artwork.mintAccount));
  }

  Future<void> _showArtworkContextMenu(PortfolioArtwork artwork) async {
    final action = await showArtworkContextMenu(context, artwork: artwork);
    if (!mounted) return;
    final item = CastQueueItemFromArtwork.fromPortfolioArtwork(artwork);
    switch (action) {
      case ArtworkContextMenuAction.castToScreen:
        unawaited(castArtworkWithVerify(item));
      case ArtworkContextMenuAction.addToCastQueue:
        sl<CastBloc>().add(CastEvent.addToQueue(item));
        AppSnackBar.show(context, 'Added to cast');
      case ArtworkContextMenuAction.addToCuration:
        await _addArtworkToCuration(artwork);
      case ArtworkContextMenuAction.download:
        await downloadArtworkWithVerify(context, artwork);
      case ArtworkContextMenuAction.hideArtwork:
        await toggleArtworkHidden(
          context,
          mintAccount: artwork.mintAccount,
          currentlyHidden: artwork.isHidden,
        );
      case ArtworkContextMenuAction.transfer:
        // Removal is handled globally via [ArtworkRemovalSignal] (see initState)
        // so a session-wallet transfer correctly keeps the item, and the drop
        // also reaches the "you own" slice and other mounted views.
        final transferred = await runTransferArtworkFlow(
          context,
          artwork: artwork,
        );
        if (transferred && mounted) {
          AppSnackBar.show(context, 'Artwork transferred');
        }
      case ArtworkContextMenuAction.burn:
        final burned = await runBurnArtworkFlow(context, artwork: artwork);
        if (burned && mounted) {
          AppSnackBar.show(context, 'NFT burned');
        }
      default:
        break;
    }
  }

  /// On-chain mint of the collection NFT. Falls back to [ArtGroup.id],
  /// which is the collection mint for groups built from route/explore
  /// entry points.
  String get _collectionMint =>
      _collection?.nft?.mintAccount ??
      widget.group.collectionMint ??
      widget.group.id;

  Future<void> _showOptionsSheet() async {
    // Download visibility spans every wallet the user controls (local DB
    // lookup, no network) — unlike cast, which stays active-wallet-scoped.
    var owned = const <String>{};
    final action = await runGuardedSheet<CollectionMenuAction>(
      'collectionOptions',
      () async {
        owned = await sl<ArtworkPermissionService>().ownedAddresses();
        if (!mounted) return null;
        return showCollectionOptionsSheet(
          context,
          title: widget.group.name,
          subtitle: _displaySubtitle,
          imageUrl: _collection?.imageUrl ?? widget.group.thumbnailUrl,
          isCreator: _isCollectionCreator,
          canCast: _canCast,
          canDownload: _downloadableArtworks(owned).isNotEmpty,
          isUserHidden: _isUserHidden,
          // Edit/Burn share the artwork permission rules: edit needs update
          // authority + mutability, burn additionally needs the collection
          // to be empty (Core) or the supply-0 token in the wallet (legacy).
          permissionsFuture: _isCollectionCreator
              ? sl<ArtworkPermissionService>().checkPermissions(_collectionMint)
              : null,
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case CollectionMenuAction.viewCollection:
        // Not offered here — the sheet is opened without showViewCollection,
        // so the user is already on the collection screen.
        break;
      case CollectionMenuAction.share:
        await _shareCollection();
      case CollectionMenuAction.cast:
        await _castCollection();
      case CollectionMenuAction.addToCast:
        await _addCollectionToCast();
      case CollectionMenuAction.downloadArtworks:
        await _downloadArtworks(owned);
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

  Future<void> _addArtworks() async {
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    await context.push(
      '${AppRoutes.collectionArtworksPath(_collectionMint)}'
      '?name=${Uri.encodeQueryComponent(widget.group.name)}',
    );
    // Best-effort refresh on return — the collection gained members.
    if (mounted) unawaited(_fetchCollectionDetail());
  }

  Future<void> _editCollection() async {
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    await context.push(AppRoutes.editCollectionPath(_collectionMint));
    // Best-effort refresh on return — name/image/description may have
    // changed (subject to indexer lag, same as the webapp).
    if (mounted) unawaited(_fetchCollectionDetail());
  }

  Future<void> _burnCollection() async {
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    final burned = await runBurnArtworkFlow(
      context,
      artwork: PortfolioArtwork(
        mintAccount: _collectionMint,
        title: widget.group.name,
        imageUrl: _collection?.imageUrl ?? widget.group.thumbnailUrl ?? '',
        artistName: _profile?.username ?? widget.group.creatorName ?? '',
        artistUsername: _profile?.handle,
        updateAuth: _collection?.creatorAddress,
      ),
      isCollection: true,
    );
    if (!burned || !mounted) return;
    AppSnackBar.show(context, 'Collection burned');
    Navigator.of(context).pop();
  }

  Future<void> _shareCollection() async {
    final url = 'https://mallow.art/collection/${widget.group.id}';
    await SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
  }

  Future<void> _syncCollection() async {
    try {
      await sl<UserProfileRepository>().syncCollection(widget.group.id);
      if (!mounted) return;
      AppSnackBar.show(context, 'Metadata update requested');
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.show(context, 'Sync failed: $e');
    }
  }

  Future<void> _toggleHidden() async {
    final previous = _isUserHidden ?? false;
    final next = !previous;
    setState(() => _isUserHidden = next);
    try {
      final repo = sl<UserProfileRepository>();
      if (next) {
        await repo.hideMint(widget.group.id);
      } else {
        await repo.unhideMint(widget.group.id);
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
    AppSnackBar.show(
      context,
      'Exporting holders…',
      duration: const Duration(seconds: 30),
    );
    try {
      final holders = await sl<UserProfileRepository>().getDetailedHolders(
        widget.group.id,
      );
      final csv = _holdersToCsv(holders);
      final tempDir = await getTemporaryDirectory();
      final filename = 'holders-${widget.group.id}.csv';
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

  /// The slice of the collection the user may download: everything when a
  /// controlled wallet created the collection, otherwise the pieces they
  /// own. Uses the app-wide owned-address set (every wallet the user
  /// controls) rather than just the active wallet, matching the per-artwork
  /// "Download to device" gate.
  bool _isDownloadCreator(Set<String> owned) =>
      owned.contains(_profile?.address) ||
      owned.contains(_collection?.creatorAddress);

  /// Only asks "is there anything at all to download" — the loaded page is
  /// enough to answer that. The download itself walks every page; see
  /// [_downloadArtworks].
  List<PortfolioArtwork> _downloadableArtworks(Set<String> owned) =>
      _isDownloadCreator(owned)
      ? _bloc.state.items
      : (_youOwnArtworks ?? const []);

  Future<void> _downloadArtworks(Set<String> owned) async {
    if (_downloadableArtworks(owned).isEmpty || !mounted) return;
    final fetchPage = _isDownloadCreator(owned)
        ? _fetchCollectionPage
        : _fetchYouOwnPage;
    await runBulkArtworkDownload(
      context,
      resolveArtworks: (isCancelled) =>
          drainPages(fetchPage, shouldStop: isCancelled),
      albumName: 'mallow / ${widget.group.name}',
    );
  }

  Future<void> _addArtworkToCuration(PortfolioArtwork artwork) async {
    if (!await requireProfile(context)) return;
    if (!mounted) return;
    final repo = sl<CurationRepository>();
    List<UserCuration> curations;
    try {
      curations = await repo.getCurations(mintAccount: artwork.mintAccount);
    } catch (_) {
      curations = [];
    }
    if (!mounted) return;
    await showAddToCurationSheet(
      context,
      artworkTitle: formatArtworkName(
        name: artwork.title,
        editionNumber: artwork.editionNumber,
      ),
      artworkImageUrl: artwork.imageUrl,
      artistUsername: artwork.artistUsername ?? artwork.artistName,
      curations: curations,
      onToggleCuration: (curationId, isSelected) {
        if (isSelected) {
          repo.addArtwork(curationId, artwork.mintAccount);
        } else {
          repo.removeArtwork(curationId, artwork.mintAccount);
        }
      },
      onCreateNew: () async {
        final result = await showNewCurationSheet(context);
        if (result == null) return null;
        try {
          final created = await repo.createCuration(
            result.name,
            isPrivate: result.isPrivate,
          );
          await repo.addArtwork(created.id, artwork.mintAccount);
          return created;
        } catch (_) {
          return null;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final safeAreaTop = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: BlocBuilder<PaginationBloc<PortfolioArtwork>, PaginationState<PortfolioArtwork>>(
        bloc: _bloc,
        builder: (context, state) => Stack(
          children: [
            _withRefresh(
              CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverOpacity(
                    opacity: _topContentOpacity,
                    sliver: ProfileBanner(
                      // Prefer the collection's own banner once detail loads;
                      // fall back to the thumbnail the caller seeded the group
                      // with so the header isn't blank during the detail fetch.
                      bannerUrl:
                          _collection?.bannerUrl ?? widget.group.thumbnailUrl,
                      onBack: () => Navigator.of(context).pop(),
                    ),
                  ),
                  SliverOpacity(
                    opacity: _topContentOpacity,
                    sliver: _CollectionHeader(
                      title: widget.group.name,
                      subtitle: _buildSubtitleWidget(context),
                      // Header avatar is the collection's identity image — the
                      // creator's handle already lives in the subtitle, so the
                      // image slot mirrors the on-chain collection art.
                      avatarUrl:
                          _collection?.imageUrl ?? widget.group.thumbnailUrl,
                      isVerified: _profile?.isVerified ?? false,
                      onMenuTap: _showOptionsSheet,
                      isAdmin: _profile?.roles.contains('admin') ?? false,
                    ),
                  ),
                  SliverOpacity(
                    opacity: _topContentOpacity,
                    sliver: const SliverToBoxAdapter(
                      child: SizedBox(height: 16),
                    ),
                  ),
                  if (_youOwnArtworks != null &&
                      _youOwnArtworks!.isNotEmpty) ...[
                    SliverOpacity(
                      opacity: _topContentOpacity,
                      sliver: ProfileYouOwnBanner(
                        count: _youOwnTotal,
                        thumbnailUrls: _youOwnArtworks!
                            .take(4)
                            .map((a) => a.imageUrl)
                            .where((u) => u.isNotEmpty)
                            .toList(),
                        onTap: _openYouOwnView,
                      ),
                    ),
                    SliverOpacity(
                      opacity: _topContentOpacity,
                      sliver: const SliverToBoxAdapter(
                        child: SizedBox(height: MallowTheme.spacing20),
                      ),
                    ),
                  ],
                  SliverOpacity(
                    opacity: _topContentOpacity,
                    sliver: _CollectionSections(
                      collection: _collection,
                      creatorHandle: _profile?.handle,
                      fallbackMint: widget.group.id,
                      // `CollectionFullRender` omits the wire's `chain`, so
                      // the floor row reads it off a loaded artwork instead.
                      chain: state.items.isEmpty
                          ? null
                          : state.items.first.chain,
                    ),
                  ),
                  SliverOpacity(
                    opacity: _topContentOpacity,
                    sliver: const SliverToBoxAdapter(
                      child: SizedBox(height: 24),
                    ),
                  ),

                  // In-flow sort/display row. The floating overlay (in the parent
                  // Stack) takes over with a safe-area inset as this bar
                  // approaches the notch — see [_CollectionSortBar] and the
                  // cross-fade logic in [_onScroll].
                  SliverOpacity(
                    opacity: _topContentOpacity,
                    sliver: SliverToBoxAdapter(
                      child: _CollectionSortBar(
                        key: _pinHeaderBoxKey,
                        sortLabel: _sortLabel,
                        activeSort: _sort,
                        viewModeIconAsset: _viewModeIcon,
                        onSort: _applySort,
                        onCycleViewMode: _cycleViewMode,
                      ),
                    ),
                  ),

                  ..._buildArtworkSlivers(colors, state),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: MediaQuery.of(context).padding.bottom + 120,
                    ),
                  ),
                ],
              ),
            ),

            // Floating sort/display bar with safe-area inset that fades in as
            // the in-flow bar approaches the notch. Slides 20px into place
            // during the fade so contents stay aligned during the cross-fade.
            Positioned(
              top: _topFadeRange * _topContentOpacity,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: _topContentOpacity > 0.5,
                child: Opacity(
                  opacity: 1 - _topContentOpacity,
                  child: _CollectionSortBar(
                    sortLabel: _sortLabel,
                    activeSort: _sort,
                    viewModeIconAsset: _viewModeIcon,
                    onSort: _applySort,
                    onCycleViewMode: _cycleViewMode,
                    topInset: safeAreaTop,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildArtworkSlivers(
    MallowColors colors,
    PaginationState<PortfolioArtwork> state,
  ) {
    final isLoading =
        state is PaginationInitial<PortfolioArtwork> ||
        state is PaginationLoading<PortfolioArtwork>;
    final loaded = state is PaginationLoaded<PortfolioArtwork> ? state : null;
    final isLoadingMore = loaded?.isLoadingMore ?? false;
    final artworks = _sorted(state.items);

    return [
      if (isLoading)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: MallowLoader(color: colors.textPrimary)),
        )
      else if (artworks.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              'No artworks yet',
              style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
            ),
          ),
        )
      else
        SliverAnimatedTabContent(
          activeIndex: _viewMode.index,
          builder: (context, index) {
            if (index == ArtworkViewMode.masonry.index) {
              return AllArtMasonry(
                artworks: artworks,
                onTap: _openArtworkDetail,
                onLongPress: _showArtworkContextMenu,
              );
            }
            if (index == ArtworkViewMode.detail.index) {
              return AllArtDetail(
                artworks: artworks,
                onTap: _openArtworkDetail,
                onLongPress: _showArtworkContextMenu,
              );
            }
            return _CollectionArtGrid(
              artworks: artworks,
              onTap: _openArtworkDetail,
              onLongPress: _showArtworkContextMenu,
            );
          },
        ),
      if (!isLoading && artworks.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: MallowTheme.spacingMd,
            ),
            child: isLoadingMore
                ? const Center(child: MallowLoadingIndicator())
                : const SizedBox.shrink(),
          ),
        ),
    ];
  }
}
