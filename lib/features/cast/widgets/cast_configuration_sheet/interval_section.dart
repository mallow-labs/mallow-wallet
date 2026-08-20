part of '../cast_configuration_sheet.dart';

class _IntervalSection extends StatelessWidget {
  const _IntervalSection({
    required this.seconds,
    required this.onChanged,
    required this.colors,
  });

  final int seconds;
  final ValueChanged<int> onChanged;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    final canDecrement = seconds > _kIntervalMin;
    final canIncrement = seconds < _kIntervalMax;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacing20,
        vertical: MallowTheme.spacingMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Change Interval',
                  style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
                ),
              ),
              Text(
                '$_kIntervalStep second step',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: colors.surfaceMuted),
              borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
            ),
            child: Row(
              children: [
                _StepperButton(
                  iconAsset: 'assets/icons/minus.svg',
                  enabled: canDecrement,
                  onTap: () => onChanged(
                    (seconds - _kIntervalStep).clamp(
                      _kIntervalMin,
                      _kIntervalMax,
                    ),
                  ),
                  colors: colors,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '$seconds seconds',
                      textAlign: TextAlign.center,
                      style: MallowTheme.uiBody.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
                _StepperButton(
                  iconAsset: 'assets/icons/plus.svg',
                  enabled: canIncrement,
                  onTap: () => onChanged(
                    (seconds + _kIntervalStep).clamp(
                      _kIntervalMin,
                      _kIntervalMax,
                    ),
                  ),
                  colors: colors,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.iconAsset,
    required this.enabled,
    required this.onTap,
    required this.colors,
  });

  final String iconAsset;
  final bool enabled;
  final VoidCallback onTap;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacingMd,
          vertical: MallowTheme.spacingMd,
        ),
        child: MallowSvgIcon(
          iconAsset,
          width: 20,
          height: 20,
          color: enabled ? colors.textPrimary : colors.textTertiary,
        ),
      ),
    );
  }
}
