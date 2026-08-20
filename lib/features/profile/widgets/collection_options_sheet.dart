import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/mallow_theme.dart';
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
/// [permissionsFuture] gates the Edit/Burn rows on the on-chain DAS
/// roundtrip (update authority / mutability / empty-collection rules).
/// They render disabled while it resolves — same async-slot pattern as
/// the artwork dots menu — and only appear at all for the creator.
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
                  if (showViewCollection)
                    _MenuItem(
                      assetPath: 'assets/icons/view_collection.svg',
                      label: 'View collection',
                      onTap: () => Navigator.of(
                        context,
                      ).pop(CollectionMenuAction.viewCollection),
                    ),
                  _MenuItem(
                    assetPath: 'assets/icons/export.svg',
                    label: 'Share collection',
                    onTap: () =>
                        Navigator.of(context).pop(CollectionMenuAction.share),
                  ),
                  if (canCast)
                    _MenuItem(
                      assetPath: 'assets/icons/cast.svg',
                      label: 'Cast collection',
                      onTap: () =>
                          Navigator.of(context).pop(CollectionMenuAction.cast),
                    ),
                  // "Add to cast" only makes sense when there's already
                  // a queue to append to.
                  if (canCast && isCastActive)
                    _MenuItem(
                      assetPath: 'assets/icons/add_to_cast.svg',
                      label: 'Add to cast',
                      onTap: () => Navigator.of(
                        context,
                      ).pop(CollectionMenuAction.addToCast),
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
                      onTap: () => Navigator.of(
                        context,
                      ).pop(CollectionMenuAction.syncToken),
                    ),
                    if (isUserHidden != null)
                      _MenuItem(
                        assetPath: isUserHidden!
                            ? 'assets/icons/eye.svg'
                            : 'assets/icons/invisible.svg',
                        label: isUserHidden! ? 'Unhide' : 'Hide',
                        onTap: () => Navigator.of(
                          context,
                        ).pop(CollectionMenuAction.hideToggle),
                      ),
                    _MenuItem(
                      assetPath: 'assets/icons/view_doc.svg',
                      label: 'Export holders',
                      onTap: () => Navigator.of(
                        context,
                      ).pop(CollectionMenuAction.exportHolders),
                    ),
                    // Edit/Burn slot in async once the DAS permission
                    // check resolves: disabled placeholders during the
                    // roundtrip (the viewer is already known to be the
                    // creator), enabled only if the chain agrees —
                    // mirrors the artwork dots menu.
                    if (permissionsFuture != null)
                      FutureBuilder<ArtworkPermissions>(
                        future: permissionsFuture,
                        builder: (context, snapshot) {
                          final perms =
                              snapshot.data ?? ArtworkPermissions.none;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Adding members shares the edit permission
                              // (update authority + mutability).
                              _MenuItem(
                                assetPath: 'assets/icons/add_to_collection.svg',
                                label: 'Add artworks',
                                isDisabled: !perms.canEdit,
                                onTap: () => Navigator.of(
                                  context,
                                ).pop(CollectionMenuAction.addArtworks),
                              ),
                              _MenuItem(
                                assetPath: 'assets/icons/edit.svg',
                                label: 'Edit collection',
                                isDisabled: !perms.canEdit,
                                onTap: () => Navigator.of(
                                  context,
                                ).pop(CollectionMenuAction.edit),
                              ),
                              _MenuItem(
                                assetPath: 'assets/icons/burn.svg',
                                label: 'Burn collection',
                                isDestructive: true,
                                isDisabled: !perms.canBurn,
                                onTap: () => Navigator.of(
                                  context,
                                ).pop(CollectionMenuAction.burn),
                              ),
                            ],
                          );
                        },
                      ),
                  ],
                  SizedBox(height: sheetBottomInset(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
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
