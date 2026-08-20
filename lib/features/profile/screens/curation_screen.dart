import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/artwork_thumbnail.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/filled_heart_svg.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/new_curation_sheet.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/text_span_tap_targets.dart';
import '../../artwork/services/artwork_download_actions.dart';
import '../../artwork/services/artwork_hide_actions.dart';
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
import '../../curations/data/curation_repository.dart';
import '../../curations/services/curation_attribution_store.dart';
import '../../moderation/services/moderation_actions.dart';
import '../../moderation/services/report_context.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/widgets/all_art_detail.dart';
import '../../portfolio/widgets/all_art_grid.dart';
import '../../portfolio/widgets/all_art_masonry.dart';
import '../../search/services/recently_viewed_recorder.dart';
import '../data/user_profile_repository.dart';
import '../widgets/profile_required_sheet.dart';
import '../widgets/sort_view_mode_bar.dart';

/// Screen showing all artworks within a curation.
class CurationScreen extends StatefulWidget {
  const CurationScreen({
    required this.group,
    required this.ownerAddress,
    this.isFollowing = false,
    this.isEphemeral = false,
    this.preloadedArtworks,
    this.customFetchArtworks,
    super.key,
  });

  final ArtGroup group;

  /// The wallet address of the curation owner, used to fetch artworks.
  final String ownerAddress;
  final bool isFollowing;

  /// Whether this is a recommended/ephemeral curation (hides Follow/Like/Share/Options).
  final bool isEphemeral;
  final List<PortfolioArtwork>? preloadedArtworks;

  /// Optional custom fetch function. When provided, overrides the default
  /// UserProfileRepository-based fetch. Used for exhibitions which don't
  /// have an owner address.
  final Future<List<PortfolioArtwork>> Function()? customFetchArtworks;

  @override
  State<CurationScreen> createState() => _CurationScreenState();
}

class _CurationScreenState extends State<CurationScreen> {
  /// Seeded from the app-wide artwork preference in [initState], the same one
  /// the portfolio, profile, collection and search surfaces read.
  ArtworkViewMode _viewMode = ArtworkViewMode.masonry;
  PortfolioSortOption _sort = PortfolioSortOption.recent;
  List<PortfolioArtwork> _artworks = [];
  bool _loading = true;

  /// Curation name, kept in state so an in-place edit updates the header.
  late String _name = widget.group.name;

  /// Whether the viewer follows the curation's creator. Seeded from the
  /// caller (profile screen passes live bloc state) or the cached login
  /// follow list, then toggled optimistically by [_onFollowTap].
  late bool _isFollowing =
      widget.isFollowing || sl<AuthService>().isFollowing(widget.ownerAddress);

  /// Whether the curation is private, loaded from the detail endpoint.
  /// Used to prefill the Edit Curation sheet's private toggle.
  bool _isPrivate = false;

  /// Exhibition slug from the detail endpoint — the `targetId` a curation
  /// report must carry, because the moderation alert's deep link is
  /// `mallow.art/e/<slug>` and an id there is a dead link. Null until the
  /// detail load lands (and on the ephemeral/exhibition path, where
  /// [ArtGroup.id] already *is* the slug).
  String? _slug;

  /// The curation's 8-letter share slug from the detail endpoint — the token
  /// a purchase is attributed to (see [_recordCurationAttribution]). Null
  /// until the detail load lands, and for curations created before the
  /// backend's slug backfill ran.
  String? _shareSlug;

  /// Whether the viewer likes this curation. Seeded from the device-local
  /// liked set and persisted back on toggle — see [_toggleCurationLike].
  late bool _isCurationLiked = sl<PreferencesService>().isCurationLiked(
    widget.group.id,
  );

  /// First four artwork images in original curation order, pinned when the
  /// artworks load so re-sorting doesn't reshuffle the header mosaic.
  List<String> _mosaicImageUrls = [];

  /// Fade-out range above the pinned sort/view-mode bar. Content above the
  /// bar fades to fully transparent over the last [_topFadeRange] pixels of
  /// scroll before pinning kicks in.
  static const double _topFadeRange = 20;
  final _scrollController = ScrollController();
  late final _curatorTapRecognizer = TapGestureRecognizer()
    ..onTap = _openCuratorProfile;
  final GlobalKey _pinHeaderBoxKey = GlobalKey();
  double _topContentOpacity = 1;

  /// Fires when an artwork in this curation is edited — refetches the list so
  /// its thumbnail/name update. See [initState].
  StreamSubscription<String>? _editedSignalSub;

  /// Optimistic removal: drops a transferred/burnt artwork from the list the
  /// instant it leaves the wallet. See [initState].
  StreamSubscription<String>? _removalSignalSub;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateTopFade);

    loadArtworkViewMode().then((mode) {
      if (mounted) setState(() => _viewMode = mode);
    });

    if (widget.preloadedArtworks != null) {
      _artworks = List.of(widget.preloadedArtworks!);
      _pinMosaicImages(_artworks);
      _loading = false;
    } else {
      _pinMosaicImages(const []);
      _fetchArtworks();
    }

    // Record into "Recently viewed" only for owner-backed curations: ephemeral
    // / recommended curations (and exhibitions via customFetchArtworks) aren't
    // reliably re-openable by id + owner from the landing row.
    if (!widget.isEphemeral && widget.ownerAddress.isNotEmpty) {
      RecentlyViewedRecorder.recordCuration(
        id: widget.group.id,
        name: widget.group.name,
        artworkCount: widget.group.artworkCount,
        thumbnailUrl: widget.group.thumbnailUrl,
        ownerAddress: widget.ownerAddress,
        ownerUsername: widget.group.creatorName,
      );
    }

    // An edit of any artwork in this curation lands after the screen is built —
    // refetch when the indexer acks so its thumbnail/name update. Guarded so
    // unit tests that don't bootstrap DI simply skip it.
    if (sl.isRegistered<ArtworkEditedSignal>()) {
      _editedSignalSub = sl<ArtworkEditedSignal>().stream.listen((_) {
        if (mounted) unawaited(_refresh());
      });
    }

    // Optimistic removal on a confirmed transfer/burn — drop the item from the
    // list on the spot instead of waiting for the reindex refetch.
    if (sl.isRegistered<ArtworkRemovalSignal>()) {
      _removalSignalSub = sl<ArtworkRemovalSignal>().stream.listen((mint) {
        if (!mounted) return;
        if (!_artworks.any((a) => a.mintAccount == mint)) return;
        setState(() {
          _artworks = [
            for (final a in _artworks)
              if (a.mintAccount != mint) a,
          ];
        });
      });
    }
  }

  @override
  void dispose() {
    _editedSignalSub?.cancel();
    _removalSignalSub?.cancel();
    _scrollController.dispose();
    _curatorTapRecognizer.dispose();
    super.dispose();
  }

  void _openCuratorProfile() {
    if (widget.ownerAddress.isEmpty) return;
    context.push(AppRoutes.profilePath(widget.ownerAddress));
  }

  /// Compute the opacity of content above the in-flow sort/view-mode bar.
  /// Triggers when the in-flow bar's top edge approaches the bottom of the
  /// system safe area (notch). The same value (inverted) drives the
  /// floating overlay's opacity — see [build].
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

  Future<void> _fetchArtworks() async {
    try {
      final List<PortfolioArtwork> artworks;
      if (widget.customFetchArtworks != null) {
        artworks = await widget.customFetchArtworks!();
      } else {
        // The curation detail endpoint returns the full ordered artwork list
        // and gates private curations server-side to the signed-in owner.
        final result = await sl<CurationRepository>().getCurationById(
          widget.group.id,
        );
        artworks = result.artworks;
        _isPrivate = result.detail.visibility == 'private';
        // The moderation alert deep-links a reported curation as
        // `mallow.art/e/<slug>`, so the report's targetId is the slug, not the
        // id. This detail load is the only place the client ever sees it.
        _slug = result.detail.slug;
        _shareSlug = result.detail.shareSlug;
      }
      if (mounted) {
        setState(() {
          _artworks = artworks;
          _pinMosaicImages(artworks);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Pull-to-refresh: refetch the artwork list in place ([_fetchArtworks]
  /// never re-raises [_loading], so no skeleton flash) and re-apply the
  /// active sort, which the fetch resets to curation order. Fetch failures
  /// are swallowed by [_fetchArtworks] — the current list stays on screen.
  Future<void> _refresh() async {
    await _fetchArtworks();
    if (mounted) _applySort(_sort);
  }

  void _applySort(PortfolioSortOption sort) {
    setState(() {
      _sort = sort;
      final sorted = List<PortfolioArtwork>.of(_artworks);
      if (sort == PortfolioSortOption.name) {
        sorted.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      }
      _artworks = sorted;
    });
  }

  /// Cycle masonry → detail → grid, persisting to the app-wide artwork
  /// preference.
  void _toggleViewMode() {
    final next = _viewMode.next;
    setState(() => _viewMode = next);
    unawaited(saveArtworkViewMode(next));
  }

  String get _sortLabel => switch (_sort) {
    PortfolioSortOption.count => 'Count',
    PortfolioSortOption.name => 'Name',
    PortfolioSortOption.recent => 'Recent',
  };

  String get _curatorName => widget.group.creatorName ?? '';

  /// Pins the header mosaic to the first four artworks in curation order.
  /// Falls back to the group thumbnail when no artwork images are available.
  void _pinMosaicImages(List<PortfolioArtwork> artworks) {
    final urls = artworks
        .map((a) => a.imageUrl)
        .where((url) => url.isNotEmpty)
        .take(4)
        .toList();
    final thumbnailUrl = widget.group.thumbnailUrl;
    if (urls.isEmpty && thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
      _mosaicImageUrls = [thumbnailUrl];
    } else {
      _mosaicImageUrls = urls;
    }
  }

  Future<void> _shareCuration() async {
    final url = 'https://mallow.art/curation/${widget.group.id}';
    await SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
  }

  /// The owned/created slice of the curation. Curations can contain other
  /// people's art, so the app-wide download/cast gate is applied per artwork
  /// first — one DAS batch resolving owner/creator against every wallet the
  /// user controls. Shows a brief "Preparing…" toast while the batch resolves;
  /// returns null if the widget unmounts mid-flight.
  Future<List<PortfolioArtwork>?> _ownedOrCreatedArtworks() async {
    final all = _artworks;
    if (all.isEmpty) return const [];
    AppSnackBar.show(
      context,
      'Preparing…',
      duration: const Duration(seconds: 30),
    );
    final allowed = await sl<ArtworkPermissionService>().ownedOrCreatedMints(
      all.map((a) => a.mintAccount).toList(),
    );
    AppSnackBar.dismiss();
    if (!mounted) return null;
    return all.where((a) => allowed.contains(a.mintAccount)).toList();
  }

  Future<void> _castCuration() async {
    final list = await _ownedOrCreatedArtworks();
    if (list == null || !mounted) return;
    if (list.isEmpty) {
      AppSnackBar.show(
        context,
        'No artworks you own or created in this curation',
      );
      return;
    }
    unawaited(
      castArtworksWithVerify(
        list.map(CastQueueItemFromArtwork.fromPortfolioArtwork).toList(),
      ),
    );
  }

  Future<void> _addCurationToCast() async {
    final list = await _ownedOrCreatedArtworks();
    if (list == null || !mounted) return;
    if (list.isEmpty) {
      AppSnackBar.show(
        context,
        'No artworks you own or created in this curation',
      );
      return;
    }
    addArtworksToCastQueue(
      list.map(CastQueueItemFromArtwork.fromPortfolioArtwork).toList(),
    );
    AppSnackBar.show(context, 'Added to cast');
  }

  bool get _isOwnCuration {
    final currentAddress = sl<AuthService>().currentAddress;
    // Curation management is a backend / session-auth action, not a per-wallet
    // signature — a curation created by any wallet in the current session
    // (Profile / Account) is theirs to edit, not just the active signing wallet.
    final mine = <String>{
      ?currentAddress,
      ...sl<SessionManager>().sessionAddresses,
    }..removeWhere((a) => a.isEmpty);
    return mine.contains(widget.ownerAddress);
  }

  /// Whether the ACTIVE session wallet is the curation owner. The backend
  /// curation write routes (edit / delete / add / remove artwork) match on
  /// `owner == req.loginAddress`, so they only accept the active login wallet —
  /// not the widened session set [_isOwnCuration] allows for read-only concerns
  /// (viewing private curations, hiding Follow). Gating write controls on this
  /// avoids surfacing owner actions that would 404 for a linked-but-inactive
  /// owner wallet.
  bool get _canEditCuration {
    final currentAddress = sl<AuthService>().currentAddress;
    return currentAddress != null &&
        currentAddress.isNotEmpty &&
        currentAddress == widget.ownerAddress;
  }

  /// Whether the viewer can remove artworks from this curation — owner-only
  /// (the active login wallet, since removal is a backend write — see
  /// [_canEditCuration]), and never for ephemeral/recommended curations or
  /// exhibitions.
  bool get _canRemoveArtworks =>
      !widget.isEphemeral &&
      widget.customFetchArtworks == null &&
      _canEditCuration;

  void _openArtworkDetail(PortfolioArtwork artwork) {
    _recordCurationAttribution(artwork.mintAccount);
    context.push(AppRoutes.artworkDetailPath(artwork.mintAccount));
  }

  /// Remember that this artwork was opened from inside a real curation, so a
  /// later purchase of it can be credited to the curator (`MarketBloc` reads
  /// the slug back and stamps it on the buy request).
  ///
  /// This screen is the single choke point for every view mode and the context
  /// menu, but it also renders recommended rails and exhibitions — neither is a
  /// curation with a share slug to credit. Records nothing, silently, unless
  /// all three hold: a non-ephemeral screen, a real curation group, and a
  /// detail load that landed carrying a share slug (a tap before the detail
  /// arrives, or a curation predating the backend's slug backfill, records
  /// nothing rather than guessing).
  void _recordCurationAttribution(String mintAccount) {
    final shareSlug = _shareSlug;
    if (shareSlug == null ||
        widget.isEphemeral ||
        widget.group.type != ArtGroupType.curation) {
      return;
    }
    // Guarded so unit tests that don't bootstrap DI simply skip it, matching
    // the signal subscriptions in [initState].
    if (!sl.isRegistered<CurationAttributionStore>()) return;
    sl<CurationAttributionStore>().record(
      mintAccount: mintAccount,
      shareSlug: shareSlug,
    );
  }

  /// Optimistically remove [artwork] from the curation, reverting on failure.
  Future<void> _removeArtwork(PortfolioArtwork artwork) async {
    final index = _artworks.indexWhere(
      (a) => a.mintAccount == artwork.mintAccount,
    );
    if (index < 0) return;
    final removed = _artworks[index];
    setState(() => _artworks = List.of(_artworks)..removeAt(index));
    try {
      await sl<CurationRepository>().removeArtwork(
        widget.group.id,
        artwork.mintAccount,
      );
    } catch (_) {
      if (!mounted) return;
      setState(
        () =>
            _artworks = List.of(_artworks)
              ..insert(math.min(index, _artworks.length), removed),
      );
      AppSnackBar.show(context, 'Failed to remove from curation');
    }
  }

  Future<void> _showArtworkContextMenu(PortfolioArtwork artwork) async {
    final action = await showArtworkContextMenu(
      context,
      artwork: artwork,
      showRemoveFromCuration: _canRemoveArtworks,
      // Curation / exhibition / recommended-drilldown feeds don't carry the
      // owner's real hidden state (the backend doesn't return isOwnerHidden on
      // these endpoints), so [PortfolioArtwork.isHidden] is always false here.
      // Suppress the Hide row rather than mislabel it as an only-re-hide action.
      showHide: false,
    );
    if (!mounted || action == null) return;
    final item = CastQueueItemFromArtwork.fromPortfolioArtwork(artwork);
    switch (action) {
      case ArtworkContextMenuAction.removeFromCuration:
        await _removeArtwork(artwork);
      case ArtworkContextMenuAction.castToScreen:
        unawaited(castArtworkWithVerify(item));
      case ArtworkContextMenuAction.addToCastQueue:
        addArtworksToCastQueue([item]);
        AppSnackBar.show(context, 'Added to cast');
      case ArtworkContextMenuAction.addToCuration:
        await _addArtworkToCuration(artwork);
      case ArtworkContextMenuAction.download:
        await downloadArtworkWithVerify(
          context,
          artwork,
          albumName: 'mallow / $_name',
        );
      case ArtworkContextMenuAction.viewArtwork:
        _openArtworkDetail(artwork);
      case ArtworkContextMenuAction.hideArtwork:
        await toggleArtworkHidden(
          context,
          mintAccount: artwork.mintAccount,
          currentlyHidden: artwork.isHidden,
        );
      case ArtworkContextMenuAction.transfer:
        // Removal is handled globally via [ArtworkRemovalSignal] (see initState)
        // so a session-wallet transfer correctly keeps the item and the drop
        // also reaches the other mounted views.
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
          // Unchecking this curation removes the artwork from the list
          // we're currently looking at.
          if (curationId == widget.group.id) {
            setState(
              () =>
                  _artworks = List.of(_artworks)
                    ..removeWhere((a) => a.mintAccount == artwork.mintAccount),
            );
          }
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

  Future<void> _editCuration() async {
    final result = await showEditCurationSheet(
      context,
      name: _name,
      isPrivate: _isPrivate,
    );
    if (result == null || !mounted) return;
    final nameChanged = result.name != _name;
    final privacyChanged = result.isPrivate != _isPrivate;
    if (!nameChanged && !privacyChanged) return;
    try {
      await sl<CurationRepository>().updateCuration(
        widget.group.id,
        name: nameChanged ? result.name : null,
        isPrivate: privacyChanged ? result.isPrivate : null,
      );
      if (mounted) {
        setState(() {
          _name = result.name;
          _isPrivate = result.isPrivate;
        });
      }
    } catch (_) {
      if (mounted) AppSnackBar.show(context, 'Failed to update curation');
    }
  }

  Future<void> _deleteCuration() async {
    final confirmed = await showConfirmSheet(
      context,
      title: 'Delete curation',
      message:
          'This will permanently delete "$_name". '
          'The artworks in it are not affected.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await sl<CurationRepository>().deleteCuration(widget.group.id);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) AppSnackBar.show(context, 'Failed to delete curation');
    }
  }

  /// Toggle the like state for this curation. Social action — gated behind a
  /// Profile; in Account mode this prompts the switch/create sheet
  /// first. The like is device-local for now: mallow_api exposes no
  /// curation-like endpoint (and the login payload's ContentType has no
  /// `curation` value), so it persists via [PreferencesService] rather than
  /// the server. Wire the server call here when the endpoint lands.
  Future<void> _toggleCurationLike() async {
    if (!await requireProfile(context)) return;
    if (!mounted) return;
    setState(() => _isCurationLiked = !_isCurationLiked);
    unawaited(
      sl<PreferencesService>().setCurationLiked(
        widget.group.id,
        _isCurationLiked,
      ),
    );
  }

  /// Following is a social action — gated behind a Profile. In
  /// Account mode this prompts the switch/create sheet. Follows the
  /// curation's creator (there is no curation-follow endpoint), toggled
  /// optimistically with a revert on failure.
  Future<void> _onFollowTap() async {
    if (!await requireProfile(context)) return;
    if (!mounted || widget.ownerAddress.isEmpty) return;
    final wasFollowing = _isFollowing;
    setState(() => _isFollowing = !wasFollowing);
    try {
      final repo = sl<UserProfileRepository>();
      if (wasFollowing) {
        await repo.unfollowUser(widget.ownerAddress);
      } else {
        await repo.followUser(widget.ownerAddress);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isFollowing = wasFollowing);
      AppSnackBar.show(
        context,
        wasFollowing ? 'Failed to unfollow' : 'Failed to follow',
      );
    }
  }

  /// Bulk-download the owned/created slice of the curation — see
  /// [_ownedOrCreatedArtworks] for the per-artwork gate.
  Future<void> _downloadArtworks() async {
    final list = await _ownedOrCreatedArtworks();
    if (list == null || !mounted) return;
    if (list.isEmpty) {
      AppSnackBar.show(
        context,
        'No artworks you own or created in this curation',
      );
      return;
    }
    await runBulkArtworkDownload(
      context,
      // Curations aren't paged — `getCurationById` returns every artwork — so
      // the gated list here is already the whole set.
      resolveArtworks: (_) async => list,
      albumName: 'mallow / ${widget.group.name}',
    );
  }

  /// Reports this curation and, on success, leaves the screen.
  ///
  /// `targetId` is the **exhibition slug** (`_slug`), not the curation id — the
  /// triage alert builds a `mallow.art/e/<slug>` link off it. Falls back to
  /// [ArtGroup.id], which already is the slug on the exhibition path and is at
  /// least a resolvable identifier if the detail load failed.
  ///
  /// The report's local hide is viewer-side only (`ModerationHideStore`); there
  /// is no app-wide curation-removal signal to piggyback on, and staying on a
  /// full-screen view of content the user just reported would read as "nothing
  /// happened".
  Future<void> _reportCuration() async {
    final reported = await runReportCurationFlow(
      context,
      curationSlug: _slug ?? widget.group.id,
      screen: currentScreenName(context),
    );
    if (reported && mounted) context.pop();
  }

  Future<void> _showOptionsSheet() async {
    await runGuardedSheet<void>(
      'curationOptions',
      () => showMallowSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (outerContext) {
          final isEmpty = _artworks.isEmpty;
          final isOwn = _isOwnCuration;
          // Backend curation writes match `owner == loginAddress`, so Edit /
          // Delete gate on the active login wallet, not the widened session set.
          final canEdit = _canEditCuration;
          // StatefulBuilder so the like row can toggle in place — the open
          // sheet lives in its own route and doesn't rebuild on the screen's
          // setState.
          return StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              final colors = sheetContext.mallowColors;
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
                          borderRadius: BorderRadius.circular(
                            MallowTheme.radiusFull,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _OptionsMenuItem(
                      assetPath: 'assets/icons/heart.svg',
                      iconOverride: _isCurationLiked
                          ? SvgPicture.string(
                              filledHeartSvg,
                              width: 24,
                              height: 24,
                              colorFilter: ColorFilter.mode(
                                colors.accent,
                                BlendMode.srcIn,
                              ),
                            )
                          : null,
                      label: _isCurationLiked
                          ? 'Unlike curation'
                          : 'Like curation',
                      // Toggles in place — the sheet stays open so the state
                      // change is visible.
                      onTap: () async {
                        await _toggleCurationLike();
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                    _OptionsMenuItem(
                      assetPath: 'assets/icons/export.svg',
                      label: 'Share curation',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _shareCuration();
                      },
                    ),
                    // Ownership is resolved on tap (DAS batch), not here —
                    // gating visibility would cost a network roundtrip per
                    // sheet open. The handler no-ops with a snack when the
                    // user owns/created nothing in the curation.
                    _OptionsMenuItem(
                      assetPath: 'assets/icons/download.svg',
                      label: 'Download artworks',
                      isDisabled: isEmpty,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        if (!isEmpty) _downloadArtworks();
                      },
                    ),
                    // Owner-only management actions. Edit / Delete are backend
                    // writes gated on the active login wallet ([canEdit]); Cast
                    // / Add to cast are local display actions kept on the
                    // widened session notion ([isOwn]).
                    if (isOwn) ...[
                      if (canEdit)
                        _OptionsMenuItem(
                          assetPath: 'assets/icons/edit.svg',
                          label: 'Edit curation',
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            _editCuration();
                          },
                        ),
                      _OptionsMenuItem(
                        assetPath: 'assets/icons/cast.svg',
                        label: 'Cast curation',
                        isDisabled: isEmpty,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          if (!isEmpty) _castCuration();
                        },
                      ),
                      // "Add to cast" only makes sense when there's already a
                      // queue to append to.
                      if (isCastActive)
                        _OptionsMenuItem(
                          assetPath: 'assets/icons/add_to_cast.svg',
                          label: 'Add to cast',
                          isDisabled: isEmpty,
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            if (!isEmpty) _addCurationToCast();
                          },
                        ),
                      if (canEdit)
                        _OptionsMenuItem(
                          assetPath: 'assets/icons/trash.svg',
                          label: 'Delete curation',
                          isDestructive: true,
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            _deleteCuration();
                          },
                        ),
                    ],
                    // Moderation — other people's curations only.
                    if (!isOwn)
                      _OptionsMenuItem(
                        assetPath: 'assets/icons/alert_triangle.svg',
                        label: 'Report curation',
                        isWarning: true,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_reportCuration());
                        },
                      ),
                    SizedBox(
                      height: MediaQuery.of(sheetContext).padding.bottom + 16,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final colors = context.mallowColors;
    final artworkCount = _loading ? group.artworkCount : _artworks.length;
    final safeAreaTop = MediaQuery.of(context).padding.top;
    final isOwnCuration = _isOwnCuration;
    // Ephemeral/recommended curations hide the options menu entirely.
    final showKebab = !widget.isEphemeral;

    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: Stack(
        children: [
          MallowRefreshIndicator(
            edgeOffset: safeAreaTop,
            onRefresh: _refresh,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // --- Header bar: back · "Curation" · kebab ---
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
                                onTap: () => Navigator.of(context).pop(),
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
                                'Curation',
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
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _showOptionsSheet,
                                        child: Align(
                                          alignment: Alignment.centerRight,
                                          child: SvgPicture.asset(
                                            'assets/icons/dots_vertical.svg',
                                            width: 16,
                                            height: 16,
                                            colorFilter: ColorFilter.mode(
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
                      child: Row(
                        children: [
                          ArtworkMosaic(
                            imageUrls: _mosaicImageUrls,
                            size: 48,
                            borderRadius: BorderRadius.circular(
                              MallowTheme.radiusPrimary,
                            ),
                          ),
                          const SizedBox(width: MallowTheme.spacing12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _name,
                                  style: MallowTheme.editorialSection.copyWith(
                                    color: colors.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: MallowTheme.spacingXs),
                                TextSpanTapTargets(
                                  span: TextSpan(
                                    children: [
                                      if (_curatorName.isNotEmpty) ...[
                                        const TextSpan(text: 'Curated by '),
                                        TextSpan(
                                          text: _curatorName,
                                          style: TextStyle(
                                            color: colors.textPrimary,
                                          ),
                                          recognizer:
                                              widget.ownerAddress.isNotEmpty
                                              ? _curatorTapRecognizer
                                              : null,
                                        ),
                                        const TextSpan(text: ' • '),
                                      ],
                                      TextSpan(
                                        text:
                                            '$artworkCount artwork${artworkCount == 1 ? '' : 's'}',
                                      ),
                                    ],
                                  ),
                                  style: MallowTheme.uiCaption.copyWith(
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // --- Action bar: Follow (like/send/options moved to the header
                // kebab). Only non-owners of a non-ephemeral curation can follow.
                if (!widget.isEphemeral && !isOwnCuration)
                  SliverOpacity(
                    opacity: _topContentOpacity,
                    sliver: SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: MallowTheme.spacing20,
                          right: MallowTheme.spacing20,
                          top: 24,
                        ),
                        child: Row(
                          children: [
                            _PillButton(
                              label: _isFollowing ? 'Following' : 'Follow',
                              textColor: _isFollowing
                                  ? colors.textSecondary
                                  : colors.textPrimary,
                              onTap: _onFollowTap,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // In-flow sort/view-mode bar. Renders in its natural scroll
                // position, with no safe-area inset. The floating overlay
                // (in the parent Stack) takes over with a safe-area inset
                // as this bar approaches the notch — see [SortViewModeBar]
                // and the cross-fade logic below.
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
                if (_loading)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: MallowLoader(color: colors.textPrimary),
                    ),
                  )
                else if (_artworks.isEmpty)
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
                      artworks: _artworks,
                      onTap: _openArtworkDetail,
                      onLongPress: _showArtworkContextMenu,
                    ),
                    ArtworkViewMode.detail => AllArtDetail(
                      artworks: _artworks,
                      onTap: _openArtworkDetail,
                      onLongPress: _showArtworkContextMenu,
                    ),
                    ArtworkViewMode.grid => AllArtGrid(
                      artworks: _artworks,
                      onTap: _openArtworkDetail,
                      onLongPress: _showArtworkContextMenu,
                    ),
                  },

                SliverToBoxAdapter(
                  child: SizedBox(
                    height: MediaQuery.of(context).padding.bottom + 120,
                  ),
                ),
              ],
            ),
          ),

          // Floating sort/view-mode bar with safe-area inset that fades in
          // as the in-flow bar approaches the notch. Slides 20px into place
          // during the fade so the row stays aligned with the in-flow bar
          // during the cross-fade.
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
      ),
    );
  }
}

/// Single row inside the curation options bottom sheet.
class _OptionsMenuItem extends StatelessWidget {
  const _OptionsMenuItem({
    required this.assetPath,
    required this.label,
    required this.onTap,
    this.isDisabled = false,
    this.isDestructive = false,
    this.isWarning = false,
    this.iconOverride,
  });

  final String assetPath;
  final String label;
  final VoidCallback onTap;
  final bool isDisabled;
  final bool isDestructive;

  /// Cautionary treatment for moderation actions (Report …) — matches
  /// `SheetMenuRow.isWarning`.
  final bool isWarning;

  /// Replaces the [assetPath] icon when set (e.g. the filled accent heart on
  /// the liked state).
  final Widget? iconOverride;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final textColor = isDisabled
        ? colors.textPrimary.withValues(alpha: 0.4)
        : isDestructive
        ? colors.error
        : isWarning
        ? colors.warning
        : colors.textPrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: 14,
        ),
        child: Row(
          children: [
            iconOverride ??
                SvgPicture.asset(
                  assetPath,
                  width: 24,
                  height: 24,
                  colorFilter: ColorFilter.mode(textColor, BlendMode.srcIn),
                ),
            const SizedBox(width: MallowTheme.spacingMd),
            Text(label, style: MallowTheme.uiBody.copyWith(color: textColor)),
          ],
        ),
      ),
    );
  }
}

/// Pill-shaped button used in the action bar.
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onTap, this.textColor});

  final String label;
  final VoidCallback onTap;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing12,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: colors.dividerLight),
            borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(
              color: textColor ?? colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
