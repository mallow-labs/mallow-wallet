import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/user_display.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../models/artwork_curation.dart';

/// Shows a bottom sheet listing every curation the artwork appears in.
///
/// Tapping a row dismisses the sheet and invokes [onSelect] with the
/// chosen curation. [usernameByAddress] maps curation creator addresses
/// to resolved usernames for the row subtitle (address fallback when
/// unresolved).
Future<void> showCuratedInSheet(
  BuildContext context, {
  required List<ArtworkCuration> curations,
  required void Function(ArtworkCuration curation) onSelect,
  Map<String, String?> usernameByAddress = const {},
}) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _CuratedInSheet(
      curations: curations,
      onSelect: onSelect,
      usernameByAddress: usernameByAddress,
    ),
  );
}

class _CuratedInSheet extends StatelessWidget {
  const _CuratedInSheet({
    required this.curations,
    required this.onSelect,
    required this.usernameByAddress,
  });

  final List<ArtworkCuration> curations;
  final void Function(ArtworkCuration curation) onSelect;
  final Map<String, String?> usernameByAddress;

  @override
  Widget build(BuildContext context) {
    final bottomPad = sheetBottomInset(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.8;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: BoxDecoration(
          color: context.mallowColors.bgPrimary,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.radiusLg),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacing20,
                0,
              ),
              child: Text(
                'Curated in',
                style: MallowTheme.editorialSubhead.copyWith(
                  color: context.mallowColors.textPrimary,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                padding: EdgeInsets.fromLTRB(
                  MallowTheme.spacing20,
                  MallowTheme.spacingXl,
                  MallowTheme.spacing20,
                  bottomPad,
                ),
                shrinkWrap: true,
                itemCount: curations.length,
                itemBuilder: (context, index) {
                  final curation = curations[index];
                  return Padding(
                    padding: const EdgeInsets.only(
                      bottom: MallowTheme.spacingMd,
                    ),
                    child: _CurationRow(
                      curation: curation,
                      curatorLabel: formatHandleOrAddress(
                        username: usernameByAddress[curation.creatorAddress],
                        address: curation.creatorAddress,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        onSelect(curation);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurationRow extends StatelessWidget {
  const _CurationRow({
    required this.curation,
    required this.curatorLabel,
    required this.onTap,
  });

  final ArtworkCuration curation;

  /// Curator handle (or truncated address); empty when unknown.
  final String curatorLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          if (curation.imageUrl != null)
            MallowNetworkImage(
              imageUrl: curation.imageUrl!,
              logicalSize: 48,
              width: 48,
              height: 48,
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              errorBuilder: (_) => _placeholder(colors),
            )
          else
            _placeholder(colors),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  curation.name,
                  style: MallowTheme.editorialQuote.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (curatorLabel.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    curatorLabel,
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

  Widget _placeholder(MallowColors colors) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
    );
  }
}
