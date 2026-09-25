import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' show ContentType;
import 'package:share_plus/share_plus.dart';

import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/artwork_web_link.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/filled_heart_svg.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/nsfw_obscured.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/sheet_menu_row.dart';
import '../../cast/services/cast_actions.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../profile/widgets/profile_required_sheet.dart';
import '../../moderation/services/moderation_actions.dart';
import '../../moderation/services/report_context.dart';
import '../data/artwork_repository.dart';
import '../models/on_chain_asset.dart';
import '../services/artwork_permission_service.dart';

/// Shows the artwork context menu bottom sheet.
///
/// This is the single artwork options menu used everywhere: profile grids,
/// collection/curation screens, activity detail, and the artwork detail
/// screen's dots menu. Surfaces differ only via the flags below (e.g. the
/// curation screen passes [showRemoveFromCuration]; the artwork detail
/// screen hides [showViewArtwork] and enables [showSyncToken]).
///
/// The menu shows a full options shimmer until permissions resolve, then builds
/// only the actions the current user may take. The artwork detail screen passes
/// [liveState] so its prefetch is reused and an open menu follows live changes.
/// Other single-artwork surfaces may pass [permissionsFuture] to reuse a
/// lookup started before the menu opens. When neither is supplied, the sheet
/// starts the lookup on open as usual.
///
/// Signing-dependent actions are automatically hidden when the active wallet
/// is view-only (canSign = false).
///
/// Pure-navigation actions (Share, View artist, View collection, Edit) are
/// handled here and return null; everything else is returned to the caller,
/// which owns the flow (transfer/burn snackbars, list mutation, refresh).
///
/// A single sheet at a time is enforced via [runGuardedSheet]: because this is
/// the one options menu behind every kebab in the app, rapidly tapping several
/// kebab buttons would otherwise stack overlapping sheets. The guard spans the
/// [getActiveWallet] await (the widest part of the race) and releases once the
/// sheet is dismissed, before any navigation await below.
Future<ArtworkContextMenuAction?> showArtworkContextMenu(
  BuildContext context, {
  required PortfolioArtwork artwork,
  bool showRemoveFromCuration = false,
  bool showViewArtwork = true,
  bool showHide = true,
  bool showSyncToken = false,
  bool showViewMasterEdition = false,
  bool inGroupedSale = false,
  String? collectionMint,
  bool? canCastOverride,
  bool? initialIsLiked,
  VoidCallback? onToggleLike,

  /// Pop the calling route after a successful report. Set by the artwork
  /// *detail* screen: reporting must hide the content from the reporter
  /// immediately, and a full-screen view of the reported artwork is the one
  /// surface that can't just drop a row — it has to be left. Grids stay put
  /// and drop the tile via `ArtworkRemovalSignal` instead.
  bool dismissOnReport = false,

  /// When non-empty, widens the Transfer / Burn / Edit gates across the current
  /// session's wallets (not just the active one). Only callers that wire the
  /// signer auto-switch (the artwork detail screen) pass this; other screens
  /// leave it empty so their menu stays active-wallet-only.
  Set<String> sessionAddresses = const {},
  Future<ArtworkPermissions>? permissionsFuture,
  ValueListenable<ArtworkContextMenuState?>? liveState,
}) async {
  final action = await runGuardedSheet<ArtworkContextMenuAction>(
    'artworkContextMenu',
    () async {
      final wallet = liveState == null
          ? await sl<WalletRepository>().getActiveWallet()
          : null;
      final canSign = liveState == null
          ? wallet?.canSign ?? true
          : liveState.value?.canSign ?? false;

      if (!context.mounted) return null;

      return showMallowSheet<ArtworkContextMenuAction>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _ArtworkContextMenuSheet(
          artwork: artwork,
          canSign: canSign,
          showRemoveFromCuration: showRemoveFromCuration,
          showViewArtwork: showViewArtwork,
          showHide: showHide,
          showSyncToken: showSyncToken,
          showViewMasterEdition: showViewMasterEdition,
          inGroupedSale: inGroupedSale,
          showViewCollection: collectionMint != null,
          canCastOverride: canCastOverride,
          initialIsLiked: initialIsLiked,
          onToggleLike: onToggleLike,
          sessionAddresses: sessionAddresses,
          permissionsFuture: permissionsFuture,
          liveState: liveState,
        ),
      );
    },
  );
  if (!context.mounted) return null;

  switch (action) {
    case ArtworkContextMenuAction.share:
      final url = artworkWebUrl(artwork.mintAccount);
      await SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
      return null;
    case ArtworkContextMenuAction.viewArtist:
      final username = artwork.artistUsername;
      if (username != null && username.isNotEmpty) {
        await context.push(AppRoutes.profileByUsernamePath(username));
      }
      return null;
    case ArtworkContextMenuAction.viewCollection:
      if (collectionMint != null) {
        await context.push(AppRoutes.collectionPath(collectionMint));
      }
      return null;
    case ArtworkContextMenuAction.edit:
      await context.push(AppRoutes.editNftPath(artwork.mintAccount));
      return null;
    case ArtworkContextMenuAction.reportArtwork:
      // Handled here rather than returned, so every surface behind this sheet
      // (profile grids, collection, curation, portfolio group, activity
      // detail, the detail screen) gets Report without each one adding a case
      // to its own switch — several of those end in `default: break`, where a
      // returned action would silently do nothing.
      final reported = await runReportArtworkFlow(
        context,
        mintAccount: artwork.mintAccount,
        screen: currentScreenName(context),
      );
      if (reported && dismissOnReport && context.mounted) context.pop();
      return null;
    default:
      return action;
  }
}

/// Fully resolved state for a live artwork-detail options sheet.
///
/// A null value in the listenable passed to [showArtworkContextMenu] means
/// that one or more permission inputs are still being resolved. Keeping the
/// artwork alongside the verdicts lets an already-open sheet react to live
/// ownership, listing, auction, and edition-supply changes.
@immutable
class ArtworkContextMenuState {
  const ArtworkContextMenuState({
    required this.artwork,
    required this.permissions,
    required this.canCast,
    required this.canSign,
    required this.inGroupedSale,
  });

  final PortfolioArtwork artwork;
  final ArtworkPermissions permissions;
  final bool canCast;
  final bool canSign;
  final bool inGroupedSale;
}

/// Actions the user can take from the artwork context menu.
///
/// [share], [viewArtist], [viewCollection], [edit] and [reportArtwork] are
/// consumed inside [showArtworkContextMenu]; callers never see them.
enum ArtworkContextMenuAction {
  share,
  addToCuration,
  removeFromCuration,
  download,
  castToScreen,
  addToCastQueue,
  syncToken,
  viewMasterEdition,
  viewArtist,
  viewArtwork,
  viewCollection,
  hideArtwork,
  transfer,
  edit,
  burn,
  reportArtwork,
}

class _ArtworkContextMenuSheet extends StatefulWidget {
  const _ArtworkContextMenuSheet({
    required this.artwork,
    required this.canSign,
    required this.showRemoveFromCuration,
    required this.showViewArtwork,
    required this.showHide,
    required this.showSyncToken,
    required this.showViewMasterEdition,
    required this.inGroupedSale,
    required this.showViewCollection,
    required this.canCastOverride,
    required this.initialIsLiked,
    required this.onToggleLike,
    this.sessionAddresses = const {},
    this.permissionsFuture,
    this.liveState,
  });

  final PortfolioArtwork artwork;
  final bool canSign;

  /// Session-wide signer set for the Transfer / Burn / Edit gates; empty for
  /// screens that don't wire the auto-switch. See [showArtworkContextMenu].
  final Set<String> sessionAddresses;
  final Future<ArtworkPermissions>? permissionsFuture;
  final ValueListenable<ArtworkContextMenuState?>? liveState;

  /// Shown when opened from a curation the viewer owns.
  final bool showRemoveFromCuration;

  /// Hidden on the artwork detail screen (the viewer is already there).
  final bool showViewArtwork;

  /// Whether to offer the Hide / Unhide row. Suppressed on surfaces that
  /// can't supply the artwork's real hidden state (e.g. activity detail
  /// builds synthetic artworks from tx data, so [PortfolioArtwork.isHidden]
  /// is always false there — showing the row would mislabel and re-hide).
  final bool showHide;

  /// Artwork-detail-only rows.
  final bool showSyncToken;
  final bool showViewMasterEdition;

  /// Webapp parity: Edit is hidden when the artwork is part of a
  /// multi-edition grouped sale, even if the chain would allow the edit.
  /// Only the detail payload carries grouped-sale info; grids pass false.
  final bool inGroupedSale;

  /// Only true when the caller can navigate to the collection (i.e. it has
  /// the collection mint — `PortfolioArtwork` alone doesn't carry it).
  final bool showViewCollection;

  /// Overrides the on-chain cast gate (owner/update-authority) when the
  /// caller has richer creator info, e.g. the detail screen's royalty-split
  /// and linked-address checks. Null falls back to on-chain permissions.
  final bool? canCastOverride;

  /// Seeds the like row when the caller has authoritative like state
  /// (detail screen's bloc); null falls back to the [AuthService] cache.
  final bool? initialIsLiked;

  /// When set, like taps are delegated to the caller (e.g. the detail
  /// screen's bloc, which also refreshes the on-screen like count) instead
  /// of hitting [ArtworkRepository] directly.
  final VoidCallback? onToggleLike;

  @override
  State<_ArtworkContextMenuSheet> createState() =>
      _ArtworkContextMenuSheetState();
}

class _ArtworkContextMenuSheetState extends State<_ArtworkContextMenuSheet> {
  Future<ArtworkPermissions>? _permissionsFuture;
  late bool _isLiked;
  bool _likeInFlight = false;

  @override
  void initState() {
    super.initState();
    if (widget.liveState == null) {
      _permissionsFuture =
          widget.permissionsFuture ??
          sl<ArtworkPermissionService>().checkPermissions(
            widget.artwork.mintAccount,
            sessionAddresses: widget.sessionAddresses,
            listingType: widget.artwork.listingType,
            inGroupedSale: widget.inGroupedSale,
          );
    }
    _isLiked =
        widget.initialIsLiked ??
        sl<AuthService>().isLiked(widget.artwork.mintAccount, ContentType.nft);
  }

  Future<void> _toggleLike() async {
    if (_likeInFlight) return;
    // Liking is a social action — gated behind a Profile. In
    // Account mode this prompts the switch/create sheet instead of toggling.
    if (!await requireProfile(context)) return;
    if (!mounted) return;
    final wasLiked = _isLiked;
    // Delegated path (detail screen's bloc) is synchronous — no in-flight
    // guard needed, just flip the heart and hand off.
    final onToggleLike = widget.onToggleLike;
    if (onToggleLike != null) {
      setState(() => _isLiked = !wasLiked);
      onToggleLike();
      return;
    }
    setState(() {
      _isLiked = !wasLiked;
      _likeInFlight = true;
    });
    try {
      final repo = sl<ArtworkRepository>();
      if (wasLiked) {
        await repo.unlikeArtwork(widget.artwork.mintAccount);
      } else {
        await repo.likeArtwork(widget.artwork.mintAccount);
      }
    } catch (e) {
      debugPrint('[ArtworkContextMenu] Like toggle failed, reverting: $e');
      if (mounted) {
        setState(() => _isLiked = wasLiked);
        // Say so — a heart that springs back on its own is indistinguishable
        // from a tap that never landed (webapp `useLikeNft` parity).
        AppSnackBar.show(
          context,
          wasLiked ? 'Failed to unlike' : 'Failed to like',
          type: AppSnackBarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _likeInFlight = false);
    }
  }

  Widget _castRows({required bool visible}) {
    if (!visible) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetMenuRow(
          assetPath: 'assets/icons/cast.svg',
          label: 'Cast to screen',
          onTap: () =>
              Navigator.of(context).pop(ArtworkContextMenuAction.castToScreen),
        ),
        // "Add to cast" only makes sense when there's already a queue to
        // append to.
        if (isCastActive)
          SheetMenuRow(
            assetPath: 'assets/icons/add_to_cast.svg',
            label: 'Add to cast',
            onTap: () => Navigator.of(
              context,
            ).pop(ArtworkContextMenuAction.addToCastQueue),
          ),
      ],
    );
  }

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
          const SheetDragHandle(),
          // Artwork preview header
          _ArtworkHeader(artwork: widget.artwork),
          Divider(height: 1, color: colors.dividerLight),
          // The menu grows the sheet until it runs out of room under the
          // header, and only then scrolls.
          Flexible(child: _buildOptions()),
        ],
      ),
    );
  }

  Widget _buildOptions() {
    final liveState = widget.liveState;
    if (liveState != null) {
      return ValueListenableBuilder<ArtworkContextMenuState?>(
        valueListenable: liveState,
        builder: (context, state, _) => state == null
            ? const _ArtworkOptionsShimmer()
            : _buildResolvedOptions(state),
      );
    }
    return FutureBuilder<ArtworkPermissions>(
      future: _permissionsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const _ArtworkOptionsShimmer();
        }
        final permissions = snapshot.data ?? ArtworkPermissions.none;
        final canCast =
            permissions.canDownload ||
            permissions.canTransfer ||
            permissions.canEdit;
        return _buildResolvedOptions(
          ArtworkContextMenuState(
            artwork: widget.artwork,
            permissions: permissions,
            canCast: canCast,
            canSign: widget.canSign,
            inGroupedSale: widget.inGroupedSale,
          ),
        );
      },
    );
  }

  Widget _buildResolvedOptions(ArtworkContextMenuState state) {
    final artwork = state.artwork;
    final perms = state.permissions;
    final inGroupedSale = state.inGroupedSale;
    final isListed = ArtworkPermissionService.isListedForSale(
      listingType: artwork.listingType,
      inGroupedSale: inGroupedSale,
    );
    final hasOutstandingPrints =
        artwork.isPrintable && (artwork.supply ?? 0) > 0;

    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 12),
          // Group 1 — Primary actions
          SheetMenuRow(
            assetPath: 'assets/icons/export.svg',
            label: 'Share',
            onTap: () =>
                Navigator.of(context).pop(ArtworkContextMenuAction.share),
          ),
          if (widget.showViewArtwork)
            SheetMenuRow(
              assetPath: 'assets/icons/stamp.svg',
              label: 'View artwork',
              onTap: () => Navigator.of(
                context,
              ).pop(ArtworkContextMenuAction.viewArtwork),
            ),
          if (widget.showRemoveFromCuration)
            SheetMenuRow(
              assetPath: 'assets/icons/minus.svg',
              label: 'Remove from curation',
              onTap: () => Navigator.of(
                context,
              ).pop(ArtworkContextMenuAction.removeFromCuration),
            ),
          if (state.canSign) ...[
            SheetMenuRow(
              assetPath: 'assets/icons/add_to_curation.svg',
              label: 'Add to curation',
              onTap: () => Navigator.of(
                context,
              ).pop(ArtworkContextMenuAction.addToCuration),
            ),
            _LikeRow(isLiked: _isLiked, onTap: _toggleLike),
            // Download is offered only for artworks the user owns or created,
            // resolved on-chain against every wallet they control.
            if (perms.canDownload)
              SheetMenuRow(
                assetPath: 'assets/icons/download.svg',
                label: 'Download to device',
                onTap: () => Navigator.of(
                  context,
                ).pop(ArtworkContextMenuAction.download),
              ),
            // Detail's live state includes the richer creator check (royalty
            // splits and linked addresses); other surfaces may override the
            // on-chain owner/update-authority fallback explicitly.
            _castRows(
              visible: widget.liveState != null
                  ? state.canCast
                  : widget.canCastOverride ?? state.canCast,
            ),
            // Hide / Unhide from the owner's profile. Gated on
            // [ArtworkPermissions.canHide], which mirrors the backend's
            // signed-login authorization exactly: the item's owner or
            // creator must be on the LOGIN wallet's profile. This is
            // narrower than Download's session-wide gate — in Account
            // mode an artwork held by a non-login session wallet always
            // 403s, so the row must stay hidden there. Eye/slash + label
            // mirror the webapp's "..." menu and the collection options
            // sheet. Suppressed entirely on surfaces that can't supply
            // the real hidden state (see [showHide]).
            if (widget.showHide && perms.canHide)
              SheetMenuRow(
                assetPath: artwork.isHidden
                    ? 'assets/icons/eye.svg'
                    : 'assets/icons/invisible.svg',
                label: artwork.isHidden ? 'Unhide artwork' : 'Hide artwork',
                onTap: () => Navigator.of(
                  context,
                ).pop(ArtworkContextMenuAction.hideArtwork),
              ),
          ],
          if (widget.showSyncToken)
            SheetMenuRow(
              assetPath: 'assets/icons/sync.svg',
              label: 'Sync token',
              onTap: () =>
                  Navigator.of(context).pop(ArtworkContextMenuAction.syncToken),
            ),
          if (widget.showViewMasterEdition)
            SheetMenuRow(
              assetPath: 'assets/icons/edition.svg',
              label: 'View master edition',
              onTap: () => Navigator.of(
                context,
              ).pop(ArtworkContextMenuAction.viewMasterEdition),
            ),
          // Group 2 — Navigation actions
          if (artwork.artistUsername?.isNotEmpty ?? false)
            SheetMenuRow(
              assetPath: 'assets/icons/user_square.svg',
              label: 'View artist',
              onTap: () => Navigator.of(
                context,
              ).pop(ArtworkContextMenuAction.viewArtist),
            ),
          // Group 3 — Collection actions
          if (widget.showViewCollection)
            SheetMenuRow(
              assetPath: 'assets/icons/view_collection.svg',
              label: 'View collection',
              onTap: () => Navigator.of(
                context,
              ).pop(ArtworkContextMenuAction.viewCollection),
            ),
          // Group 4 — owner actions. Denied actions are omitted entirely.
          if (state.canSign)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isListed && perms.canTransfer)
                  SheetMenuRow(
                    assetPath: 'assets/icons/send.svg',
                    label: 'Transfer artwork',
                    onTap: () => Navigator.of(
                      context,
                    ).pop(ArtworkContextMenuAction.transfer),
                  ),
                if (!inGroupedSale && perms.canEdit)
                  SheetMenuRow(
                    assetPath: 'assets/icons/edit.svg',
                    label: 'Edit artwork',
                    enabled: perms.canEdit,
                    onTap: () => Navigator.of(
                      context,
                    ).pop(ArtworkContextMenuAction.edit),
                  ),
                if (!isListed && !hasOutstandingPrints && perms.canBurn)
                  SheetMenuRow(
                    assetPath: 'assets/icons/burn.svg',
                    label: 'Burn artwork',
                    isDestructive: true,
                    onTap: () => Navigator.of(
                      context,
                    ).pop(ArtworkContextMenuAction.burn),
                  ),
              ],
            ),
          // Group 5 — Moderation. Always offered, on every artwork and
          // for every viewer: an entry point that appears only on
          // "other people's" content is one a reviewer can fail to
          // find, and the owner/creator resolution here is async and
          // occasionally wrong.
          SheetMenuRow(
            assetPath: 'assets/icons/alert_triangle.svg',
            label: 'Report artwork',
            isWarning: true,
            onTap: () => Navigator.of(
              context,
            ).pop(ArtworkContextMenuAction.reportArtwork),
          ),
          // Bottom safe area padding
          SizedBox(height: sheetBottomInset(context)),
        ],
      ),
    );
  }
}

class _ArtworkOptionsShimmer extends StatelessWidget {
  const _ArtworkOptionsShimmer();

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('artwork-options-loading'),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: List.generate(
          8,
          (_) => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                ShimmerBox(width: 24, height: 24),
                SizedBox(width: 16),
                Expanded(child: ShimmerBox(height: 16)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Artwork preview header inside the context menu.
class _ArtworkHeader extends StatelessWidget {
  const _ArtworkHeader({required this.artwork});

  final PortfolioArtwork artwork;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Padding(
      padding: const EdgeInsets.all(MallowTheme.spacing20),
      child: Row(
        children: [
          // Thumbnail — blurred in-place when the artwork is NSFW-flagged so
          // long-pressing a blurred tile can't reveal the raw image here.
          NsfwObscured(
            nsfw: artwork.nsfw,
            contentId: artwork.imageUrl,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
            child: MallowNetworkImage(
              imageUrl: artwork.imageUrl,
              logicalSize: 52,
              width: 52,
              height: 52,
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              errorIconSize: 20,
            ),
          ),
          const SizedBox(width: MallowTheme.spacingMd),
          // Title + collection name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatArtworkName(
                    name: artwork.title,
                    editionNumber: artwork.editionNumber,
                  ),
                  style: MallowTheme.editorialQuote.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: MallowTheme.spacingXs),
                Text(
                  artwork.collectionName ?? 'No Collection',
                  style: MallowTheme.uiCaption.copyWith(
                    color: artwork.collectionName != null
                        ? colors.textSecondary
                        : colors.textTertiary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Like/unlike row. Stays mounted on tap — only the heart fill and label
/// flip so users can toggle their like without dismissing the sheet.
class _LikeRow extends StatelessWidget {
  const _LikeRow({required this.isLiked, required this.onTap});

  final bool isLiked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final textColor = colors.textPrimary;
    final iconWidget = isLiked
        ? SvgPicture.string(
            filledHeartSvg,
            width: 24,
            height: 24,
            colorFilter: ColorFilter.mode(colors.accent, BlendMode.srcIn),
          )
        : SvgPicture.asset(
            'assets/icons/heart.svg',
            width: 24,
            height: 24,
            colorFilter: ColorFilter.mode(textColor, BlendMode.srcIn),
          );

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
            iconWidget,
            const SizedBox(width: MallowTheme.spacingMd),
            Text(
              isLiked ? 'Unlike' : 'Add to liked artworks',
              style: MallowTheme.uiBody.copyWith(color: textColor),
            ),
          ],
        ),
      ),
    );
  }
}
