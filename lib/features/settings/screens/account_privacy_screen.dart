import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../widgets/settings_page_scaffold.dart';

const _privacyKey = 'mallow_account_privacy';

enum _PrivacyMode { public, invisible }

/// Account Privacy screen — choose between public or invisible profile.
class AccountPrivacyScreen extends StatefulWidget {
  const AccountPrivacyScreen({super.key});

  @override
  State<AccountPrivacyScreen> createState() => _AccountPrivacyScreenState();
}

class _AccountPrivacyScreenState extends State<AccountPrivacyScreen> {
  _PrivacyMode _mode = _PrivacyMode.public;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_privacyKey);
    if (!mounted) return;
    setState(() {
      _mode = stored == 'invisible'
          ? _PrivacyMode.invisible
          : _PrivacyMode.public;
      _loaded = true;
    });
  }

  Future<void> _select(_PrivacyMode mode) async {
    setState(() => _mode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_privacyKey, mode.name);
    // TODO: sync privacy preference to backend (PATCH /v1/profile or equivalent)
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Account privacy',
      child: _loaded
          ? _Body(mode: _mode, onSelect: _select)
          : const SizedBox.shrink(),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.mode, required this.onSelect});

  final _PrivacyMode mode;
  final ValueChanged<_PrivacyMode> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      children: [
        _PrivacyRow(
          iconAsset: 'assets/icons/public.svg',
          title: 'Public',
          subtitle: 'Profile and wallets searchable by anyone',
          selected: mode == _PrivacyMode.public,
          onTap: () => onSelect(_PrivacyMode.public),
        ),
        const SizedBox(height: 8),
        _PrivacyRow(
          iconAsset: 'assets/icons/invisible.svg',
          title: 'Invisible',
          subtitle: 'Profile and wallets undiscoverable everywhere',
          selected: mode == _PrivacyMode.invisible,
          onTap: () => onSelect(_PrivacyMode.invisible),
        ),
      ],
    );
  }
}

class _PrivacyRow extends StatelessWidget {
  const _PrivacyRow({
    required this.iconAsset,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String iconAsset;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final titleColor = selected ? colors.accent : colors.textPrimary;

    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: MallowSvgIcon(
                  iconAsset,
                  width: 24,
                  height: 24,
                  color: selected ? colors.accent : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: MallowTheme.uiBody.copyWith(color: titleColor),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: MallowTheme.uiCaption.copyWith(
                        color: context.mallowColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                MallowSvgIcon(
                  'assets/icons/checkmark.svg',
                  width: 16,
                  height: 16,
                  color: colors.accent,
                )
              else
                const SizedBox(width: 16),
            ],
          ),
        ),
      ),
    );
  }
}
