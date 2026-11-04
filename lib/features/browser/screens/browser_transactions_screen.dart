import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../settings/widgets/settings_page_scaffold.dart';
import '../services/browser_transaction_tracker.dart';
import '../widgets/browser_settings_rows.dart';

/// Transactions sent from websites in the browser, newest first, with the
/// status the tracker last saw.
class BrowserTransactionsScreen extends StatelessWidget {
  const BrowserTransactionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tracker = BrowserTransactionTracker.instance;
    return SettingsPageScaffold(
      title: 'Recent transactions',
      onBack: () => Navigator.of(context).maybePop(),
      child: ListenableBuilder(
        listenable: tracker,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          children: [
            const BrowserSettingsCaption(
              'Status continues updating after you leave a website. Pending '
              'or uncertain does not mean failed.',
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            if (tracker.records.isEmpty)
              const BrowserSettingsPlaceholder(
                'No recent browser transactions',
              ),
            for (final record in tracker.records)
              _TransactionRow(record: record),
          ],
        ),
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({required this.record});
  final BrowserTransactionRecord record;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final (label, tone) = switch (record.status) {
      BrowserTransactionStatus.pending => ('Pending', colors.warning),
      BrowserTransactionStatus.confirmed => ('Confirmed', colors.positive),
      BrowserTransactionStatus.failed => ('Failed', colors.error),
      BrowserTransactionStatus.uncertain => (
        'Status uncertain',
        colors.textTertiary,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Flexible(
                child: Text(
                  label,
                  style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Flexible(
                child: Text(
                  record.chain,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiMeta.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(
            record.signature,
            style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
