part of '../cast_configuration_sheet.dart';

class _SectionDivider extends StatelessWidget {
  const _SectionDivider({required this.colors});

  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      height: 1,
      color: colors.surfaceMuted,
    );
  }
}

class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.children,
    required this.colors,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
              vertical: MallowTheme.spacingMd,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: MallowTheme.uiMeta.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: MallowSvgIcon(
                    'assets/icons/arrow_down.svg',
                    width: 6,
                    height: 6,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...children,
      ],
    );
  }
}

class _ShuffleRow extends StatelessWidget {
  const _ShuffleRow({
    required this.value,
    required this.onToggle,
    required this.colors,
  });

  final bool value;
  final VoidCallback onToggle;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
            vertical: MallowTheme.spacingSm,
          ),
          child: Row(
            children: [
              MallowSvgIcon(
                'assets/icons/shuffle.svg',
                width: 18,
                height: 18,
                color: colors.textPrimary,
              ),
              const SizedBox(width: MallowTheme.spacingMd),
              Expanded(
                child: Text(
                  'Shuffle Artwork',
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
              ),
              MallowToggle(value: value, onChanged: (_) => onToggle()),
            ],
          ),
        ),
      ),
    );
  }
}
