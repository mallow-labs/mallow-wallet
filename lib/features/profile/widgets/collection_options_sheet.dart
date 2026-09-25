import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../artwork/models/on_chain_asset.dart';
import '../../cast/services/cast_actions.dart';

/// Action selected from the collection-options bottom sheet.
enum CollectionMenuAction {
  viewCollection,
  share,
  cast,
  addToCast,
  downloadArtworks,
  syncToken,
  hideToggle,
  exportHolders,
  addArtworks,
  edit,
  burn,
}

/// Shows the collection options sheet. The label of the Hide/Unhide row
/// reflects [isUserHidden]; pass `null` to render no Hide row at all
/// (e.g. while initial state is still loading).
///
/// [permissionsFuture] gates the Add/Edit/Burn rows on the on-chain DAS
/// roundtrip (update authority / mutability / empty-collection rules).
/// It only applies to creators.
///
/// [ownedArtworksAvailableFuture] is for callers whose initial owned-artwork
/// page is still loading. While either supplied future is pending, every action
/// row shimmers so the menu never mixes resolved actions with placeholders.
Future<CollectionMenuAction?> showCollectionOptionsSheet(
  BuildContext context, {
  required String title,
  required bool isCreator,
  required bool canCast,
  required bool canDownload,
  String? subtitle,
  String? imageUrl,
  bool? isUserHidden,
  Future<ArtworkPermissions>? permissionsFuture,
  Future<bool>? ownedArtworksAvailableFuture,
  bool showViewCollection = false,
}) {
  return showMallowSheet<CollectionMenuAction>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CollectionOptionsSheet(
      title: title,
      subtitle: subtitle,
      imageUrl: imageUrl,
      isCreator: isCreator,
      canCast: canCast,
      canDownload: canDownload,
      isUserHidden: isUserHidden,
      permissionsFuture: permissionsFuture,
      ownedArtworksAvailableFuture: ownedArtworksAvailableFuture,
      showViewCollection: showViewCollection,
    ),
  );
}

class _CollectionOptionsSheet extends StatelessWidget {
  const _CollectionOptionsSheet({
    required this.title,
    required this.isCreator,
    required this.canCast,
    required this.canDownload,
    this.subtitle,
    this.imageUrl,
    this.isUserHidden,
    this.permissionsFuture,
    this.ownedArtworksAvailableFuture,
    this.showViewCollection = false,
  });

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final bool isCreator;
  final bool canCast;
  final bool canDownload;
  final bool? isUserHidden;
  final Future<ArtworkPermissions>? permissionsFuture;
  final Future<bool>? ownedArtworksAvailableFuture;

  /// Opt-in row shown only when the sheet is opened from a surface that is
  /// *not* the collection screen (i.e. the portfolio group drilldown), where
  /// "View collection" is still a useful destination. `CollectionScreen`
  /// leaves this false — the user is already there.
  final bool showViewCollection;

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
          _CollectionHeader(
            title: title,
            subtitle: subtitle,
            imageUrl: imageUrl,
          ),
          Divider(height: 1, color: colors.dividerLight),
          // The menu grows the sheet until it runs out of room under the
          // header, and only then scrolls.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  _buildActions(context),
                  SizedBox(height: sheetBottomInset(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final future = ownedArtworksAvailableFuture;
    if (future == null) {
      return _buildActionsWithPermissions(
        context,
        canCast: canCast,
        canDownload: canDownload,
        ownedAvailabilityPending: false,
      );
    }
    return FutureBuilder<bool>(
      future: future,
      builder: (context, snapshot) {
        final isPending = !snapshot.hasData && !snapshot.hasError;
        final available = snapshot.data ?? false;
        return _buildActionsWithPermissions(
          context,
          canCast: available,
          canDownload: available,
          ownedAvailabilityPending: isPending,
        );
      },
    );
  }

  Widget _buildActionsWithPermissions(
    BuildContext context, {
    required bool canCast,
    required bool canDownload,
    required bool ownedAvailabilityPending,
  }) {
    final future = isCreator ? permissionsFuture : null;
    if (future == null) {
      return _buildActionList(
        context,
        canCast: canCast,
        canDownload: canDownload,
        ownedAvailabilityPending: ownedAvailabilityPending,
        permissionsPending: false,
        permissions: null,
      );
    }
    return FutureBuilder<ArtworkPermissions>(
      future: future,
      builder: (context, snapshot) => _buildActionList(
        context,
        canCast: canCast,
        canDownload: canDownload,
        ownedAvailabilityPending: ownedAvailabilityPending,
        permissionsPending: !snapshot.hasData && !snapshot.hasError,
        permissions: snapshot.data ?? ArtworkPermissions.none,
      ),
    );
  }

  Widget _buildActionList(
    BuildContext context, {
    required bool canCast,
    required bool canDownload,
    required bool ownedAvailabilityPending,
    required bool permissionsPending,
    required ArtworkPermissions? permissions,
  }) {
    if (ownedAvailabilityPending || permissionsPending) {
      return _CollectionActionsShimmer(
        rowCount: _actionRowCount(
          canCast: canCast,
          canDownload: canDownload,
          ownedAvailabilityPending: ownedAvailabilityPending,
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showViewCollection)
          _MenuItem(
            assetPath: 'assets/icons/view_collection.svg',
            label: 'View collection',
            onTap: () =>
                Navigator.of(context).pop(CollectionMenuAction.viewCollection),
          ),
        _MenuItem(
          assetPath: 'assets/icons/export.svg',
          label: 'Share collection',
          onTap: () => Navigator.of(context).pop(CollectionMenuAction.share),
        ),
        if (canCast)
          _MenuItem(
            assetPath: 'assets/icons/cast.svg',
            label: 'Cast collection',
            onTap: () => Navigator.of(context).pop(CollectionMenuAction.cast),
          ),
        // "Add to cast" only makes sense when there's already a queue to
        // append to.
        if (canCast && isCastActive)
          _MenuItem(
            assetPath: 'assets/icons/add_to_cast.svg',
            label: 'Add to cast',
            onTap: () =>
                Navigator.of(context).pop(CollectionMenuAction.addToCast),
          ),
        if (canDownload)
          _MenuItem(
            assetPath: 'assets/icons/download.svg',
            label: 'Download artworks',
            onTap: () => Navigator.of(
              context,
            ).pop(CollectionMenuAction.downloadArtworks),
          ),
        if (isCreator) ...[
          _MenuItem(
            assetPath: 'assets/icons/sync.svg',
            label: 'Sync token',
            onTap: () =>
                Navigator.of(context).pop(CollectionMenuAction.syncToken),
          ),
          if (isUserHidden != null)
            _MenuItem(
              assetPath: isUserHidden!
                  ? 'assets/icons/eye.svg'
                  : 'assets/icons/invisible.svg',
              label: isUserHidden! ? 'Unhide' : 'Hide',
              onTap: () =>
                  Navigator.of(context).pop(CollectionMenuAction.hideToggle),
            ),
          _MenuItem(
            assetPath: 'assets/icons/view_doc.svg',
            label: 'Export holders',
            onTap: () =>
                Navigator.of(context).pop(CollectionMenuAction.exportHolders),
          ),
          if (permissionsFuture != null) ...[
            _MenuItem(
              assetPath: 'assets/icons/add_to_collection.svg',
              label: 'Add artworks',
              isDisabled: !(permissions?.canEdit ?? false),
              onTap: () =>
                  Navigator.of(context).pop(CollectionMenuAction.addArtworks),
            ),
            _MenuItem(
              assetPath: 'assets/icons/edit.svg',
              label: 'Edit collection',
              isDisabled: !(permissions?.canEdit ?? false),
              onTap: () => Navigator.of(context).pop(CollectionMenuAction.edit),
            ),
            _MenuItem(
              assetPath: 'assets/icons/burn.svg',
              label: 'Burn collection',
              isDestructive: true,
              isDisabled: !(permissions?.canBurn ?? false),
              onTap: () => Navigator.of(context).pop(CollectionMenuAction.burn),
            ),
          ],
        ],
      ],
    );
  }

  int _actionRowCount({
    required bool canCast,
    required bool canDownload,
    required bool ownedAvailabilityPending,
  }) {
    var count = (showViewCollection ? 1 : 0) + 1;
    if (ownedAvailabilityPending) {
      count += 2 + (isCastActive ? 1 : 0);
    } else {
      if (canCast) count += 1 + (isCastActive ? 1 : 0);
      if (canDownload) count++;
    }
    if (isCreator) {
      count += 2 + (isUserHidden != null ? 1 : 0);
      if (permissionsFuture != null) count += 3;
    }
    return count;
  }
}

class _CollectionActionsShimmer extends StatelessWidget {
  const _CollectionActionsShimmer({required this.rowCount});

  final int rowCount;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('collection-actions-loading'),
    mainAxisSize: MainAxisSize.min,
    children: List.generate(
      rowCount,
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
  );
}

class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({required this.title, this.subtitle, this.imageUrl});

  final String title;
  final String? subtitle;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.all(MallowTheme.spacing20),
      child: Row(
        children: [
          if (imageUrl != null && imageUrl!.isNotEmpty)
            MallowNetworkImage(
              imageUrl: imageUrl!,
              logicalSize: 52,
              width: 52,
              height: 52,
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              errorIconSize: 20,
            )
          else
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: colors.divider,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              ),
            ),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: MallowTheme.editorialQuote.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: MallowTheme.spacingXs),
                  Text(
                    subtitle!,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.label,
    required this.onTap,
    this.assetPath,
    this.isDestructive = false,
    this.isDisabled = false,
  });

  final String label;
  final VoidCallback onTap;
  final String? assetPath;
  final bool isDestructive;
  final bool isDisabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final baseColor = isDestructive ? colors.error : colors.textPrimary;
    final textColor = isDisabled ? baseColor.withValues(alpha: 0.4) : baseColor;

    return GestureDetector(
      key: ValueKey('collection-action-$label'),
      behavior: HitTestBehavior.opaque,
      onTap: isDisabled ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: 14,
        ),
        child: Row(
          children: [
            if (assetPath != null) ...[
              SvgPicture.asset(
                assetPath!,
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(textColor, BlendMode.srcIn),
              ),
              const SizedBox(width: MallowTheme.spacingMd),
            ],
            Text(label, style: MallowTheme.uiBody.copyWith(color: textColor)),
          ],
        ),
      ),
    );
  }
}
