import 'package:flutter/material.dart';

import '../../../core/utils/price_formatter.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../models/bid_refund_balance.dart';

class BidRefundCard extends StatefulWidget {
  const BidRefundCard({
    required this.balance,
    required this.onWithdraw,
    super.key,
  });
  final BidRefundBalance balance;
  final void Function(String? destination) onWithdraw;

  @override
  State<BidRefundCard> createState() => _BidRefundCardState();
}

class _BidRefundCardState extends State<BidRefundCard> {
  final _destination = TextEditingController();

  @override
  void dispose() {
    _destination.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final refund = widget.balance.refund;
    final isSol = refund.mint == PriceFormatter.solMint;
    return Padding(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Refund available to withdraw',
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          Text(
            PriceFormatter.formatRawAmountWithSymbol(
              double.parse(refund.amount),
              refund.mint,
            ),
            style: MallowTheme.uiBody.copyWith(color: colors.positive),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          if (!isSol) ...[
            TextFormField(
              key: ValueKey('refund-destination-${refund.claim}'),
              controller: _destination,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Alternative token account (optional)',
              ),
            ),
            const SizedBox(height: MallowTheme.spacingSm),
          ],
          Text(
            isSol
                ? 'Withdraw SOL to your wallet.'
                : 'Leave blank: mallow uses your usual token account or creates a new one if it is blocked. You pay the new account’s rent.',
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          MallowButton(
            key: ValueKey('withdraw-refund-${refund.claim}'),
            label: 'Withdraw refund',
            onPressed: () {
              final destination = _destination.text.trim();
              widget.onWithdraw(
                isSol || destination.isEmpty ? null : destination,
              );
            },
          ),
        ],
      ),
    );
  }
}
