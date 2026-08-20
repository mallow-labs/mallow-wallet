import 'package:flutter/material.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

import 'mallow_svg_icon.dart';
import 'tap_target_expander.dart';

class MallowCheckbox extends StatelessWidget {
  const MallowCheckbox({
    required this.value,
    required this.onChanged,
    super.key,
    this.label,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String? label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: value,
      enabled: enabled,
      label: label,
      child: TapTargetExpander(
        child: GestureDetector(
          onTap: enabled ? () => onChanged(!value) : null,
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  color: value ? context.mallowColors.accent : null,
                  border: value
                      ? null
                      : Border.all(
                          color: enabled
                              ? context.mallowColors.divider
                              : context.mallowColors.dividerLight,
                          width: 1.5,
                        ),
                ),
                child: value
                    ? Padding(
                        padding: const EdgeInsets.all(6),
                        child: MallowSvgIcon(
                          'assets/icons/checkmark.svg',
                          width: 10,
                          height: 10,
                          color: context.mallowColors.bgSurface,
                        ),
                      )
                    : null,
              ),
              if (label != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label!,
                    style: MallowTheme.uiMeta.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
