import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/sheet_menu_row.dart';
import '../../profile/services/collection_download_service.dart';

/// Small chooser shown before a download starts: save into the photo
/// library (the original behavior) or export to the Files app. Returns null
/// when dismissed.
Future<DownloadDestination?> showDownloadDestinationSheet(
  BuildContext context,
) {
  return showMallowSheet<DownloadDestination>(
    context: context,
    builder: (_) => const _DownloadDestinationSheet(),
  );
}

class _DownloadDestinationSheet extends StatelessWidget {
  const _DownloadDestinationSheet();

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
            label: 'Save to Photos',
            onTap: () => Navigator.of(context).pop(DownloadDestination.photos),
          ),
          SheetMenuRow(
            assetPath: 'assets/icons/folder.svg',
            label: 'Save to Files…',
            onTap: () => Navigator.of(context).pop(DownloadDestination.files),
          ),
          SizedBox(height: sheetBottomInset(context)),
        ],
      ),
    );
  }
}
