import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/explorer_utils.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../widgets/settings_page_scaffold.dart';
import '../../../shared/widgets/tap_target_expander.dart';

class _Explorer {
  const _Explorer({
    required this.key,
    required this.label,
    required this.iconAsset,
  });
  final String key;
  final String label;
  final String iconAsset;
}

const _solanaExplorers = [
  _Explorer(
    key: 'solscan',
    label: 'Solscan',
    iconAsset: 'assets/icons/brand_solscan.svg',
  ),
  _Explorer(
    key: 'orb',
    label: 'Orb',
    iconAsset: 'assets/icons/brand_orbmarkets.svg',
  ),
  _Explorer(
    key: 'solana_explorer',
    label: 'Solana Explorer',
    iconAsset: 'assets/icons/solana.svg',
  ),
  _Explorer(
    key: 'solana_beach',
    label: 'Solana Beach',
    iconAsset: 'assets/icons/brand_solana_beach.svg',
  ),
];

// Ethereum explorers are sourced from [ethExplorers] so the URL builders and
// this picker can never drift apart. All share the chain glyph (no per-brand
// icon assets exist).
final _ethereumExplorers = [
  for (final e in ethExplorers)
    _Explorer(
      key: e.key,
      label: e.name,
      iconAsset: 'assets/icons/ethereum.svg',
    ),
];

// Tezos has a single explorer (tzkt), so its section is always-selected.
const _tezosExplorers = [
  _Explorer(key: 'tzkt', label: 'TzKT', iconAsset: 'assets/icons/tezos.svg'),
];

/// Preferred Explorer picker screen.
///
/// Block-explorer picker split into per-chain sections. The Solana selection
/// persists via [PreferencesService.explorer] and the Ethereum selection via
/// [PreferencesService.ethExplorer]; Tezos has a single explorer with no
/// stored preference.
class PreferredExplorerScreen extends StatefulWidget {
  const PreferredExplorerScreen({super.key});

  @override
  State<PreferredExplorerScreen> createState() =>
      _PreferredExplorerScreenState();
}

class _PreferredExplorerScreenState extends State<PreferredExplorerScreen> {
  late String _solanaSelected;
  late String _ethSelected;

  @override
  void initState() {
    super.initState();
    final prefs = sl<PreferencesService>();
    _solanaSelected = prefs.explorer;
    _ethSelected = prefs.ethExplorer;
  }

  Future<void> _selectSolana(String key) async {
    await sl<PreferencesService>().setExplorer(key);
    if (!mounted) return;
    setState(() => _solanaSelected = key);
  }

  Future<void> _selectEth(String key) async {
    await sl<PreferencesService>().setEthExplorer(key);
    if (!mounted) return;
    setState(() => _ethSelected = key);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Preferred Explorer',
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        children: [
          _section(
            context,
            'Solana',
            _solanaExplorers,
            _solanaSelected,
            _selectSolana,
          ),
          const SizedBox(height: 24),
          _section(
            context,
            'Ethereum',
            _ethereumExplorers,
            _ethSelected,
            _selectEth,
          ),
          const SizedBox(height: 24),
          // Single fixed option — tzkt is always selected.
          _section(context, 'Tezos', _tezosExplorers, 'tzkt', (_) {}),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<_Explorer> explorers,
    String selectedKey,
    ValueChanged<String> onSelect,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            title,
            style: MallowTheme.uiLabel.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
        ),
        for (final explorer in explorers)
          _ExplorerRow(
            explorer: explorer,
            isSelected: explorer.key == selectedKey,
            onTap: () => onSelect(explorer.key),
          ),
      ],
    );
  }
}

class _ExplorerRow extends StatelessWidget {
  const _ExplorerRow({
    required this.explorer,
    required this.isSelected,
    required this.onTap,
  });

  final _Explorer explorer;
  final bool isSelected;
  final VoidCallback onTap;

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
              SizedBox(
                width: 24,
                height: 24,
                child: SvgPicture.asset(
                  explorer.iconAsset,
                  width: 24,
                  height: 24,
                  colorFilter: ColorFilter.mode(
                    isSelected
                        ? context.mallowColors.accent
                        : context.mallowColors.textPrimary,
                    BlendMode.srcIn,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  explorer.label,
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
