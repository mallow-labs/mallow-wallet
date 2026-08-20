import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Single-option row used inside the mint flow's radio groups.
///
/// 14px circular indicator + 8px gap + label, full-width tap target.
/// Selected state fills the indicator and adds a hairline ring (the
/// outer ring stays the same colour as the unselected border so the
/// transition is purely visual).
class MintRadioRow extends StatelessWidget {
  const MintRadioRow({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingXs),
          child: Row(
            children: [
              _Indicator(selected: selected, color: colors.textPrimary),
              const SizedBox(width: MallowTheme.spacingSm),
              Text(
                label,
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color),
        ),
        child: selected
            ? Center(
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
