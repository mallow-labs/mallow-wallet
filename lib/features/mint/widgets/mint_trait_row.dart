import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// A single row in the Trait Details section on the Categorization step.
///
/// Layout: 110px left-aligned label, a pill input for the value, and a
/// trash icon that removes the row.
class MintTraitRow extends StatefulWidget {
  const MintTraitRow({
    required this.name,
    required this.value,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  final String name;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onRemove;

  @override
  State<MintTraitRow> createState() => _MintTraitRowState();
}

class _MintTraitRowState extends State<MintTraitRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(covariant MintTraitRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.value = _controller.value.copyWith(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(
            widget.name,
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: MallowTheme.spacingMd),
        Expanded(
          child: MallowPillField(
            controller: _controller,
            hintText: 'Description',
            textCapitalization: TextCapitalization.words,
            onChanged: widget.onChanged,
          ),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        TapTargetExpander(
          child: GestureDetector(
            onTap: widget.onRemove,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(MallowTheme.spacingXs),
              child: MallowSvgIcon(
                'assets/icons/x_circle.svg',
                width: 20,
                height: 20,
                color: colors.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
