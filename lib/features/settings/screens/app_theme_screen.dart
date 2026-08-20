import 'package:flutter/material.dart';

import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../widgets/settings_page_scaffold.dart';

class _ThemeOption {
  const _ThemeOption({required this.mode, required this.iconAsset, this.label});
  final ThemeMode mode;
  final String? label;
  final String iconAsset;
}

const _options = [
  _ThemeOption(
    mode: ThemeMode.system,
    iconAsset: 'assets/icons/theme_system.svg',
  ),
  _ThemeOption(
    mode: ThemeMode.dark,
    label: 'Dark mode',
    iconAsset: 'assets/icons/theme_dark.svg',
  ),
  _ThemeOption(
    mode: ThemeMode.light,
    label: 'Light mode',
    iconAsset: 'assets/icons/theme_light.svg',
  ),
];

/// App Theme picker screen.
///
/// Three options: System, Dark, Light. Tapping one persists the choice via
/// [PreferencesService] and immediately updates the [MaterialApp] theme through
/// its [ValueNotifier].
class AppThemeScreen extends StatefulWidget {
  const AppThemeScreen({super.key});

  @override
  State<AppThemeScreen> createState() => _AppThemeScreenState();
}

class _AppThemeScreenState extends State<AppThemeScreen> {
  late ThemeMode _selected;

  @override
  void initState() {
    super.initState();
    _selected = sl<PreferencesService>().themeMode;
  }

  Future<void> _select(ThemeMode mode) async {
    await sl<PreferencesService>().setThemeMode(mode);
    if (!mounted) return;
    setState(() => _selected = mode);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'App Theme',
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        itemCount: _options.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final option = _options[index];
          final isSelected = option.mode == _selected;
          return _ThemeRow(
            option: option,
            isSelected: isSelected,
            onTap: () => _select(option.mode),
          );
        },
      ),
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  final _ThemeOption option;
  final bool isSelected;
  final VoidCallback onTap;

  String _systemLabel(BuildContext context) {
    final isDark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    return isDark ? 'System (Dark mode)' : 'System (Light mode)';
  }

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              MallowSvgIcon(
                option.iconAsset,
                width: 24,
                height: 24,
                color: isSelected ? context.mallowColors.accent : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  option.label ?? _systemLabel(context),
                  style: MallowTheme.uiBody.copyWith(
                    color: isSelected
                        ? context.mallowColors.accent
                        : context.mallowColors.textPrimary,
                  ),
                ),
              ),
              if (isSelected)
                MallowSvgIcon(
                  'assets/icons/checkmark.svg',
                  width: 16,
                  height: 16,
                  color: context.mallowColors.accent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
