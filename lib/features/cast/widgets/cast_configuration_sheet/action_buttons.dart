part of '../cast_configuration_sheet.dart';

class _OutlinedActionButton extends StatelessWidget {
  const _OutlinedActionButton({
    required this.label,
    required this.iconAsset,
    required this.enabled,
    required this.onPressed,
    required this.colors,
  });

  final String label;
  final String iconAsset;
  final bool enabled;
  final VoidCallback onPressed;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    final tint = enabled ? colors.accent : colors.textTertiary;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: tint),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                iconAsset,
                width: 16,
                height: 16,
                colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Text(
                label,
                style: MallowTheme.uiBody.copyWith(
                  color: tint,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryActionButton extends StatelessWidget {
  const _PrimaryActionButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
    required this.colors,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: colors.accent,
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Center(
            child: Text(
              label,
              style: MallowTheme.uiBody.copyWith(
                color: colors.textOnAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DangerActionButton extends StatelessWidget {
  const _DangerActionButton({
    required this.label,
    required this.onPressed,
    required this.colors,
  });

  final String label;
  final VoidCallback onPressed;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: colors.error,
          borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
        ),
        child: Center(
          child: Text(
            label,
            style: MallowTheme.uiBody.copyWith(
              color: colors.textOnAccent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
