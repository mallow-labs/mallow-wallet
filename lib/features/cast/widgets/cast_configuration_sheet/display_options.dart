part of '../cast_configuration_sheet.dart';

class _DisplayOptionsBody extends StatelessWidget {
  const _DisplayOptionsBody({
    required this.showCaption,
    required this.showQr,
    required this.onCaptionChanged,
    required this.onQrChanged,
    required this.colors,
  });

  final bool showCaption;
  final bool showQr;
  final ValueChanged<bool> onCaptionChanged;
  final ValueChanged<bool> onQrChanged;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: SizedBox(
        height: 85,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 85,
              height: 85,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                child: Image.asset(
                  'assets/images/cast_labeling.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: MallowTheme.spacingMd),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ToggleOptionRow(
                    label: 'Display artwork details',
                    value: showCaption,
                    onChanged: onCaptionChanged,
                    colors: colors,
                  ),
                  _ToggleOptionRow(
                    label: 'Display QR Code',
                    value: showQr,
                    onChanged: onQrChanged,
                    colors: colors,
                  ),
                  Text(
                    'An opaque bar will persist at the bottom of your screen',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
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

class _ToggleOptionRow extends StatelessWidget {
  const _ToggleOptionRow({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          MallowToggle(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _DisplayTypeSelector extends StatelessWidget {
  const _DisplayTypeSelector({
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  final CastDisplayType value;
  final ValueChanged<CastDisplayType> onChanged;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _DisplayTypeOption(
              label: 'Fit to Screen',
              selected: value == CastDisplayType.fitToScreen,
              onTap: () => onChanged(CastDisplayType.fitToScreen),
              previewBuilder: (color) => _FitToScreenPreview(color: color),
              colors: colors,
            ),
          ),
          const SizedBox(width: MallowTheme.spacingLg),
          Expanded(
            child: _DisplayTypeOption(
              label: 'Fill Screen',
              selected: value == CastDisplayType.fillScreen,
              onTap: () => onChanged(CastDisplayType.fillScreen),
              previewBuilder: (color) => _FillScreenPreview(color: color),
              colors: colors,
            ),
          ),
          const SizedBox(width: MallowTheme.spacingLg),
          Expanded(
            child: _DisplayTypeOption(
              label: 'Tile',
              selected: value == CastDisplayType.tile,
              onTap: () => onChanged(CastDisplayType.tile),
              previewBuilder: (color) => _TilePreview(color: color),
              colors: colors,
            ),
          ),
        ],
      ),
    );
  }
}

class _DisplayTypeOption extends StatelessWidget {
  const _DisplayTypeOption({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.previewBuilder,
    required this.colors,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget Function(Color color) previewBuilder;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    final outlineColor = selected ? colors.accent : colors.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 100,
            decoration: BoxDecoration(
              border: Border.all(color: colors.surfaceMuted),
            ),
            padding: const EdgeInsets.all(2),
            child: previewBuilder(outlineColor),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RadioDot(selected: selected, colors: colors),
              const SizedBox(width: MallowTheme.spacingSm),
              Flexible(
                child: Text(
                  label,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected, required this.colors});

  final bool selected;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? colors.accent : colors.textTertiary,
          width: 1.5,
        ),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.accent,
                ),
              ),
            )
          : null,
    );
  }
}

class _FitToScreenPreview extends StatelessWidget {
  const _FitToScreenPreview({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: color)),
      ),
    );
  }
}

class _FillScreenPreview extends StatelessWidget {
  const _FillScreenPreview({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: color)),
    );
  }
}

class _TilePreview extends StatelessWidget {
  const _TilePreview({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 12,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: color),
                bottom: BorderSide(color: color),
                right: BorderSide(color: color),
              ),
            ),
          ),
        ),
        const SizedBox(width: 1),
        Expanded(
          child: Container(
            decoration: BoxDecoration(border: Border.all(color: color)),
          ),
        ),
        const SizedBox(width: 1),
        SizedBox(
          width: 12,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: color),
                bottom: BorderSide(color: color),
                left: BorderSide(color: color),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
