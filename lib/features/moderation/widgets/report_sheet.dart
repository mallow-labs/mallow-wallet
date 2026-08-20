import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_char_counter.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_textarea_field.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../data/moderation_repository.dart';
import '../models/moderation_models.dart';
import '../services/report_context.dart';

/// Opens the report sheet for [targetId] and submits it.
///
/// Resolves to the [ReportOutcome]: [ReportOutcome.submitted] and
/// [ReportOutcome.rateLimited] are both "the user reported it" as far as the
/// caller is concerned (see `moderation_actions.dart`); a dismissed sheet
/// resolves to null and a hard failure keeps the sheet open for retry, so
/// [ReportOutcome.failed] is never returned.
///
/// [screen] is the route/screen name attached to the report `context` so a
/// triager can see where it was filed from.
Future<ReportOutcome?> showReportSheet(
  BuildContext context, {
  required api.ReportTargetType targetType,
  required String targetId,
  required String screen,
}) {
  return showMallowSheet<ReportOutcome>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ReportSheet(
      targetType: targetType,
      targetId: targetId,
      screen: screen,
    ),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({
    required this.targetType,
    required this.targetId,
    required this.screen,
  });

  final api.ReportTargetType targetType;
  final String targetId;
  final String screen;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _noteController = TextEditingController();
  api.ReportReason? _reason;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Keeps the remaining-characters counter in sync with the field.
    _noteController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    final reportContext = await buildReportContext(screen: widget.screen);
    final outcome = await sl<ModerationRepository>().submitReport(
      targetType: widget.targetType,
      targetId: widget.targetId,
      reason: reason,
      note: _noteController.text,
      context: reportContext,
    );
    if (!mounted) return;

    if (outcome == ReportOutcome.failed) {
      // Keep the sheet open: the user's reason and note are still typed in and
      // a silent close would read as "reported" when nothing was sent.
      setState(() {
        _submitting = false;
        _error = 'Couldn’t send that report. Please try again.';
      });
      return;
    }
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    // Advisory only — the field has no `maxLength`. The backend truncates on a
    // char boundary and never rejects, and a hard cap would silently swallow
    // the tail of a pasted report.
    final remaining = reportNoteSoftLimit - _noteController.text.length;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: sheetBottomInset(context, includeKeyboard: false),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetDragHandle(),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      MallowTheme.spacing20,
                      MallowTheme.spacingMd,
                      MallowTheme.spacing20,
                      0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Report ${widget.targetType.noun}',
                          style: MallowTheme.editorialSubhead.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: MallowTheme.spacingSm),
                        Text(
                          'Tell us what’s wrong. A human reviews every report '
                          'within 24 hours.',
                          style: MallowTheme.uiMeta.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: MallowTheme.spacingLg),
                        for (final reason in api.reportableReasons)
                          _ReasonRow(
                            label: reason.label,
                            selected: _reason == reason,
                            enabled: !_submitting,
                            onTap: () => setState(() => _reason = reason),
                          ),
                        const SizedBox(height: MallowTheme.spacingLg),
                        Text(
                          'Add a note (optional)',
                          style: MallowTheme.uiMeta.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: MallowTheme.spacingMd),
                        MallowTextareaField(
                          controller: _noteController,
                          hintText: 'Anything else we should know?',
                          enabled: !_submitting,
                          textCapitalization: TextCapitalization.sentences,
                        ),
                        const SizedBox(height: MallowTheme.spacingSm),
                        Align(
                          alignment: Alignment.centerRight,
                          child: remaining >= 0
                              ? MallowCharCounter(remaining: remaining)
                              // Past the limit the standard counter would read
                              // "0 characters remaining" while the field keeps
                              // accepting input. Say what actually happens.
                              : Text(
                                  'Only the first $reportNoteSoftLimit '
                                  'characters are sent',
                                  style: MallowTheme.uiCaption.copyWith(
                                    color: colors.textSecondary,
                                  ),
                                ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: MallowTheme.spacingMd),
                          Text(
                            _error!,
                            style: MallowTheme.uiMeta.copyWith(
                              color: colors.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  MallowTheme.spacing20,
                  MallowTheme.spacingLg,
                  MallowTheme.spacing20,
                  0,
                ),
                child: MallowButton(
                  label: _submitting ? 'Reporting...' : 'Report',
                  onPressed: _submit,
                  enabled: _reason != null,
                  isLoading: _submitting,
                  isFullWidth: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One reason in the fixed taxonomy, rendered radio-style — a single choice,
/// so the indicator is a circle, not the app's square checkbox.
class _ReasonRow extends StatelessWidget {
  const _ReasonRow({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      label: label,
      child: TapTargetExpander(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? colors.accent : colors.divider,
                      width: selected ? 6 : 1.5,
                    ),
                  ),
                ),
                const SizedBox(width: MallowTheme.spacingMd),
                Expanded(
                  child: Text(
                    label,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
