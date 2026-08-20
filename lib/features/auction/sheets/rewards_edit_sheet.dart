import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/full_screen_sheet.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_textarea_field.dart';
import '../../../shared/widgets/tappable.dart';

/// Outcome of [showRewardsEditSheet].
sealed class RewardsEditResult {
  const RewardsEditResult();
}

/// User saved their changes — apply [description] to the listing.
class RewardsEditSaved extends RewardsEditResult {
  const RewardsEditSaved(this.description);
  final String description;
}

/// User chose to remove rewards from the sale.
class RewardsEditRemoved extends RewardsEditResult {
  const RewardsEditRemoved();
}

/// Full-screen sheet to edit the rewards description.
///
/// Returns [RewardsEditSaved] when Done is tapped with valid input,
/// [RewardsEditRemoved] when "Remove rewards from sale" is tapped, or
/// `null` when the sheet is dismissed without action.
Future<RewardsEditResult?> showRewardsEditSheet(
  BuildContext context, {
  required String initial,
}) {
  return showFullScreenSheet<RewardsEditResult>(
    context: context,
    child: _RewardsEditSheet(initial: initial),
  );
}

class _RewardsEditSheet extends StatefulWidget {
  const _RewardsEditSheet({required this.initial});

  final String initial;

  @override
  State<_RewardsEditSheet> createState() => _RewardsEditSheetState();
}

class _RewardsEditSheetState extends State<_RewardsEditSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSave => _controller.text.trim().isNotEmpty;

  void _onSave() {
    Navigator.of(context).pop(RewardsEditSaved(_controller.text.trim()));
  }

  void _onRemove() {
    Navigator.of(context).pop(const RewardsEditRemoved());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Padding(
        padding: EdgeInsets.only(
          left: MallowTheme.spacing20,
          right: MallowTheme.spacing20,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              'Rewards details',
              style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowTextareaField(
              controller: _controller,
              hintText:
                  'Add notes regarding your rewards, for example '
                  "'First 5 bidders receive a free airdrop'",
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
            ),
            const Spacer(),
            Text(
              'Physicals and rewards are the responsibility of the seller to '
              'distribute. No disputes will be resolved by mallow. Any abuse '
              'of this feature will result in suspension from selling on mallow.',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                top: MallowTheme.spacingMd,
                bottom: sheetBottomInset(context, includeKeyboard: false),
              ),
              child: Column(
                children: [
                  _SheetButton(
                    label: 'Remove rewards from sale',
                    color: colors.error,
                    onTap: _onRemove,
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  _SheetButton(
                    label: 'Done',
                    color: _canSave ? colors.accent : colors.textTertiary,
                    onTap: _canSave ? _onSave : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({required this.label, required this.color, this.onTap});

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        child: Tappable(
          onTap: onTap,
          child: Center(
            child: Text(
              label,
              style: MallowTheme.uiBody.copyWith(
                color: colors.textOnAccent,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
