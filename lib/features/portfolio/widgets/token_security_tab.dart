import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/mallow_kv_row.dart';
import '../models/jupiter_token_info.dart';

/// Security tab content for the token detail screen.
///
/// Shows dev holding, top holders, mutability, and mint authority info.
class TokenSecurityTab extends StatelessWidget {
  const TokenSecurityTab({super.key, this.tokenInfo, this.chain});

  final JupiterTokenInfo? tokenInfo;

  /// Chain of the token, so address rows route to the right explorer
  /// (Etherscan for Ethereum). Null falls back to Solana.
  final Chain? chain;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    if (tokenInfo == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingXl),
        child: Center(
          child: Text(
            'Security data unavailable',
            style: MallowTheme.uiCaption.copyWith(color: colors.textTertiary),
          ),
        ),
      );
    }

    final info = tokenInfo!;
    final rows = _buildRows(context, info);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MallowKvList(rows: rows),
        const SizedBox(height: MallowTheme.spacingXl),
      ],
    );
  }

  List<Widget> _buildRows(BuildContext context, JupiterTokenInfo info) {
    final rows = <Widget>[];

    if (info.devAddress != null && info.devAddress!.isNotEmpty) {
      rows.add(
        MallowKvAddressRow(
          label: 'Dev Address',
          address: info.devAddress!,
          isAccount: true,
          chain: chain,
        ),
      );
    }

    if (info.devHoldingPercent != null) {
      final pct = info.devHoldingPercent!;
      rows.add(
        MallowKvRow(
          label: 'Dev Holding',
          value: '${pct.toStringAsFixed(2)}%',
          // Amber warning if dev holds more than 5%
          valueColor: pct > 5 ? context.mallowColors.warning : null,
        ),
      );
    }

    if (info.topHoldersPercent != null) {
      rows.add(
        MallowKvRow(
          label: 'Top 10 Holders',
          value: '${info.topHoldersPercent!.toStringAsFixed(2)}%',
        ),
      );
    }

    rows.add(
      MallowKvRow(
        label: 'Mutable Info',
        value: info.isMutable == true ? 'Yes' : 'No',
      ),
    );

    rows.add(
      MallowKvRow(
        label: 'Mintable',
        value: info.mintAuthority != null ? 'Yes' : 'No',
      ),
    );

    return rows;
  }
}
