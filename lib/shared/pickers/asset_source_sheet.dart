import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import '../widgets/mallow_sheet.dart';
import '../widgets/sheet_drag_handle.dart';
import '../widgets/sheet_menu_row.dart';

/// Where the bytes for an upload come from.
enum AssetSource {
  /// `image_picker`. On iOS 14+ this is `PHPickerViewController`, which runs
  /// out of process and therefore needs no photo-library permission — the app
  /// only ever receives the one item the user tapped.
  photos,

  /// `file_selector`'s document browser. The only source that can reach the
  /// non-photo formats (html / glb). How much it filters is the caller's
  /// choice — the image boxes pass a UTI type group, the mint slot opens
  /// unfiltered — so in neither case is the extension allowlist enforced by
  /// the picker itself; it is applied after the pick.
  files,
}

/// Chooser shown before an upload: pick from the photo library or browse the
/// Files app. Returns null when dismissed.
///
/// Every upload box in the app opens this first, so the two sources are
/// always offered together; the branches converge on the same validation in
/// the caller, making the choice purely about which system picker is
/// presented.
Future<AssetSource?> showAssetSourceSheet(BuildContext context) {
  return showMallowSheet<AssetSource>(
    context: context,
    builder: (_) => const _AssetSourceSheet(),
  );
}

class _AssetSourceSheet extends StatelessWidget {
  const _AssetSourceSheet();

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
          SheetMenuRow(
            assetPath: 'assets/icons/photo.svg',
            label: 'Photo Library',
            onTap: () => Navigator.of(context).pop(AssetSource.photos),
          ),
          SheetMenuRow(
            assetPath: 'assets/icons/folder.svg',
            label: 'Browse Files…',
            onTap: () => Navigator.of(context).pop(AssetSource.files),
          ),
          SizedBox(height: sheetBottomInset(context)),
        ],
      ),
    );
  }
}
