import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';

/// A notice the user is told once, as a bottom sheet: a [title], one
/// paragraph per entry of [lines], a primary button and, with [cancelLabel],
/// a second one.
///
/// What it returns says who closed it, which a plain confirm sheet cannot:
///
/// - `true`: the user tapped [confirmLabel];
/// - `false`: the user closed it another way — [cancelLabel], a tap outside
///   the sheet, or the back gesture;
/// - `null`: the app removed it. Replacing the page a sheet sits on removes
///   the sheet too, and its reader may never have seen it.
///
/// Only the first two are answers. A caller that records a notice as seen
/// does so on those and never on `null`.
///
/// The sheet cannot be dragged away: a drag closes a sheet without saying
/// who asked, which is the one thing this sheet has to know.
///
/// Each line is held to [maxLinesPerLine] lines, with an ellipsis, so text
/// the app did not write (the name of a sign-in key) cannot take the sheet
/// over.
Future<bool?> showSocialVaultNoticeSheet(
  BuildContext context, {
  required String title,
  required List<String> lines,
  required String confirmLabel,
  String? cancelLabel,
  int? maxLinesPerLine,
}) => showMallowSheet<bool>(
  context: context,
  isScrollControlled: true,
  enableDrag: false,
  builder: (_) => _NoticeSheet(
    title: title,
    lines: lines,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    maxLinesPerLine: maxLinesPerLine,
  ),
);

class _NoticeSheet extends StatelessWidget {
  const _NoticeSheet({
    required this.title,
    required this.lines,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.maxLinesPerLine,
  });

  final String title;
  final List<String> lines;
  final String confirmLabel;
  final String? cancelLabel;
  final int? maxLinesPerLine;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    // The route never pops on its own, so every way the user has of closing
    // the sheet arrives here first and leaves with an explicit `false`. A
    // removal by the app does not ask: it completes the route with `null`.
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(false);
      },
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            MallowTheme.spacing20,
            MallowTheme.spacingLg,
            MallowTheme.spacing20,
            sheetBottomInset(context),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: MallowTheme.editorialSection.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, line) in lines.indexed) ...[
                        if (index > 0)
                          const SizedBox(height: MallowTheme.spacingSm),
                        Text(
                          line,
                          maxLines: maxLinesPerLine,
                          overflow: maxLinesPerLine == null
                              ? null
                              : TextOverflow.ellipsis,
                          style: MallowTheme.uiBody.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              MallowButton(
                label: confirmLabel,
                isFullWidth: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              if (cancelLabel != null) ...[
                const SizedBox(height: MallowTheme.spacingSm),
                MallowButton(
                  label: cancelLabel!,
                  variant: MallowButtonVariant.secondary,
                  isFullWidth: true,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
