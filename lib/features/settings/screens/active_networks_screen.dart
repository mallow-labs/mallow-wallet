import 'package:flutter/material.dart';

import '../../../core/services/active_networks.dart';
import '../../../core/session/session_manager.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../profile/data/user_profile_repository.dart';
import '../widgets/settings_page_scaffold.dart';

/// Active Networks settings screen.
///
/// Shows a list of supported blockchain networks with toggles.
/// Solana is always on (disabled toggle); Tezos and Ethereum are user-togglable.
class ActiveNetworksScreen extends StatefulWidget {
  const ActiveNetworksScreen({super.key});

  @override
  State<ActiveNetworksScreen> createState() => _ActiveNetworksScreenState();
}

class _ActiveNetworksScreenState extends State<ActiveNetworksScreen> {
  bool _tezosEnabled = true;
  bool _ethereumEnabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final networks = sl<ActiveNetworks>();
    final tezos = await networks.isEnabled(Chain.tezos);
    final ethereum = await networks.isEnabled(Chain.ethereum);
    if (!mounted) return;
    setState(() {
      _tezosEnabled = tezos;
      _ethereumEnabled = ethereum;
      _loaded = true;
    });
  }

  /// Writes go through [ActiveNetworks] rather than storage directly: the
  /// portfolio behind this screen is already built, and the service's change
  /// signal is what makes a switched-off chain's rows and balances drop out of
  /// it when the user backs out.
  Future<void> _setTezos(bool value) async {
    setState(() => _tezosEnabled = value);
    await sl<ActiveNetworks>().setEnabled(Chain.tezos, value);
    await _syncProfileSettings();
  }

  Future<void> _setEthereum(bool value) async {
    setState(() => _ethereumEnabled = value);
    await sl<ActiveNetworks>().setEnabled(Chain.ethereum, value);
    await _syncProfileSettings();
  }

  /// The chains the user has switched off, in backend wire form. Solana can
  /// never be disabled, so it is never present.
  List<String> get _disabledChains => [
    if (!_tezosEnabled) Chain.tezos.toDbString(),
    if (!_ethereumEnabled) Chain.ethereum.toDbString(),
  ];

  /// In a Profile (signed-login) session, mirror the local active-networks
  /// preference to the user's profile so it persists server-side and is honored
  /// across devices. A no-op for plain account sessions, which keep the setting
  /// device-local.
  Future<void> _syncProfileSettings() async {
    if (!sl<SessionManager>().isProfileMode) return;
    try {
      await sl<UserProfileRepository>().updateSettings(_disabledChains);
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        "Couldn't save networks to your profile",
        type: AppSnackBarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Active networks',
      child: _loaded
          ? _Body(
              tezosEnabled: _tezosEnabled,
              ethereumEnabled: _ethereumEnabled,
              onTezosChanged: _setTezos,
              onEthereumChanged: _setEthereum,
            )
          : const SizedBox.shrink(),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.tezosEnabled,
    required this.ethereumEnabled,
    required this.onTezosChanged,
    required this.onEthereumChanged,
  });

  final bool tezosEnabled;
  final bool ethereumEnabled;
  final ValueChanged<bool> onTezosChanged;
  final ValueChanged<bool> onEthereumChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      children: [
        const _NetworkRow(
          iconAsset: 'assets/icons/solana_padded.svg',
          label: 'Solana',
          enabled: true,
          interactive: false,
          onChanged: null,
        ),
        const SizedBox(height: 8),
        _NetworkRow(
          iconAsset: 'assets/icons/tezos.svg',
          label: 'Tezos',
          enabled: tezosEnabled,
          interactive: true,
          onChanged: onTezosChanged,
        ),
        const SizedBox(height: 8),
        _NetworkRow(
          iconAsset: 'assets/icons/ethereum.svg',
          label: 'Ethereum',
          enabled: ethereumEnabled,
          interactive: true,
          onChanged: onEthereumChanged,
        ),
        const SizedBox(height: 12),
        Text(
          'Solana cannot be switched off',
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.iconAsset,
    required this.label,
    required this.enabled,
    required this.interactive,
    required this.onChanged,
  });

  final String iconAsset;
  final String label;
  final bool enabled;
  final bool interactive;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final canToggle = interactive && onChanged != null;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canToggle ? () => onChanged!(!enabled) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              MallowSvgIcon(iconAsset, width: 24, height: 24),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: MallowTheme.uiBody)),
              MallowToggle(
                value: enabled,
                onChanged: interactive ? onChanged : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
