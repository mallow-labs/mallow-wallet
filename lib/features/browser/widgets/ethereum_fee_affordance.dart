import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../services/ethereum_dapp_adapter.dart';
import 'browser_tap.dart';

/// The Speed row's "tier · Edit" control on a website transaction review,
/// opening the same Edit Gas Fee sheet as the app's own Ethereum sends.
class EthereumFeeAffordance extends StatelessWidget {
  const EthereumFeeAffordance({
    required this.prepared,
    required this.onTap,
    super.key,
  });

  final PreparedEthereumTransaction prepared;
  final VoidCallback onTap;

  /// "Site suggested" until the user picks a fee, then the tier and its
  /// wait estimate, as the in-app send shows them.
  String get label {
    final selection = prepared.selection;
    if (selection == null) return 'Default';
    if (prepared.feeFromSite) return 'Site suggested';
    return selection.speedEta == '—'
        ? selection.modeLabel
        : '${selection.modeLabel} · ${selection.speedEta}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return BrowserTap(
      key: const Key('edit-network-fee'),
      onTap: onTap,
      label: '$label, edit network fee',
      minHitSize: 44,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Text(
            'Edit',
            style: MallowTheme.uiCaption.copyWith(color: colors.accent),
          ),
          Icon(Icons.chevron_right, size: 16, color: colors.accent),
        ],
      ),
    );
  }
}
