import 'package:flutter/widgets.dart';

import '../theme/mallow_theme.dart';
import 'tap_target_expander.dart';

/// Horizontally scrollable row of pill-shaped filter chips.
///
/// Active chip: dark fill, white text, circular radius.
/// Inactive chip: border only, dark text.
class ArtMenuTab extends StatelessWidget {
  const ArtMenuTab({
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    super.key,
  });

  final List<String> labels;
  final int? selectedIndex;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _PillChip(
              label: labels[i],
              isSelected: selectedIndex == i,
              onTap: () => onChanged(selectedIndex == i ? null : i),
            ),
          ],
        ],
      ),
    );
  }
}

class _PillChip extends StatelessWidget {
  const _PillChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected
                  ? context.mallowColors.textPrimary
                  : context.mallowColors.dividerLight,
            ),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
