import 'package:flutter/material.dart';

import '../../../core/result/result.dart';
import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../models/bid_refund_deposit.dart';

class BidRefundDepositsSheet extends StatefulWidget {
  const BidRefundDepositsSheet({required this.loadDeposits, super.key});

  final Future<List<BidRefundDeposit>> Function() loadDeposits;

  @override
  State<BidRefundDepositsSheet> createState() => _BidRefundDepositsSheetState();
}

class _BidRefundDepositsSheetState extends State<BidRefundDepositsSheet> {
  List<BidRefundDeposit>? _deposits;
  String? _error;
  final _destinations = <String, String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _deposits = null;
      _error = null;
    });
    final result = await Result.guard(widget.loadDeposits);
    if (!mounted) return;
    setState(() {
      _deposits = result.valueOrNull;
      _error = result.errorOrNull?.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        0,
        MallowTheme.spacing20,
        sheetBottomInset(context),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          const SizedBox(height: MallowTheme.spacingMd),
          Text(
            'Recover deposits',
            style: MallowTheme.uiTitle.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          Text(
            'Release outstanding refunds to their bidders, then recover the deposits you paid for their accounts.',
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          if (_error case final error?) ...[
            Text(
              error,
              style: MallowTheme.uiBody.copyWith(color: colors.error),
            ),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ] else if (_deposits case final deposits?)
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (deposits.isEmpty)
                      Text(
                        'No deposits are ready to recover.',
                        style: MallowTheme.uiBody.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    for (final deposit in deposits)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: MallowTheme.spacingMd,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Wallet ${truncateAddress(deposit.rentPayer)}',
                              style: MallowTheme.uiCaption.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                            if (deposit.needsRelease) ...[
                              const SizedBox(height: MallowTheme.spacingSm),
                              Text(
                                'Refund goes to bidder ${truncateAddress(deposit.bidder)}. ${deposit.isSol ? 'You pay only the transaction fee.' : 'You pay the transaction fee and rent for any new token account. That rent belongs to the bidder. You can use another usable token account owned by the bidder for this currency.'} Availability can change before confirmation.',
                                style: MallowTheme.uiCaption.copyWith(
                                  color: colors.textSecondary,
                                ),
                              ),
                              if (!deposit.isSol) ...[
                                const SizedBox(height: MallowTheme.spacingSm),
                                TextFormField(
                                  key: ValueKey(
                                    'release-destination-${deposit.claim}',
                                  ),
                                  initialValue: _destinations[deposit.claim],
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration: const InputDecoration(
                                    labelText:
                                        'Bidder token account (optional)',
                                    helperText:
                                        'Leave blank to choose an account automatically.',
                                    helperMaxLines: 2,
                                  ),
                                  onChanged: (value) {
                                    _destinations[deposit.claim] = value.trim();
                                  },
                                ),
                              ],
                            ],
                            const SizedBox(height: MallowTheme.spacingSm),
                            MallowButton(
                              key: ValueKey(
                                '${deposit.needsRelease ? (deposit.isSol ? 'release-sol-refund' : 'release-token-refund') : 'recover-deposit'}-${deposit.claim}',
                              ),
                              label: deposit.needsRelease
                                  ? (deposit.isSol
                                        ? 'Release SOL refund'
                                        : 'Release token refund')
                                  : 'Recover deposit',
                              onPressed: () => Navigator.of(context).pop(
                                deposit.withDestination(
                                  deposit.needsRelease && !deposit.isSol
                                      ? _destinations[deposit.claim]
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            )
          else
            const Center(child: MallowLoader()),
        ],
      ),
    );
  }
}
