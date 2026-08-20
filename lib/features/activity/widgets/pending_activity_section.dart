import 'package:flutter/material.dart';

import '../../../core/services/pending_evm_tx.dart';
import '../../../shared/theme/mallow_theme.dart';
import 'pending_activity_cell.dart';

/// Which slice of the pending entries a tab shows.
///
/// The activity sheet has no tab bar yet (the design's All / Art transactions /
/// Token transactions row is not built), so every call site passes
/// [PendingActivityFilter.all] today. The mapping lives here so the section is
/// already correct the day the tabs land.
enum PendingActivityFilter {
  /// Everything, including `external` nonce gaps and `other` broadcasts —
  /// those two appear under this tab only.
  all,

  /// Art transactions.
  art,

  /// Token transactions.
  token,
}

/// [entries] narrowed to [filter], preserving the tracker's order (session
/// wallet order, then nonce ascending — replacements mine in nonce order, so
/// the oldest actionable slot leads).
List<PendingEvmTx> pendingEntriesForFilter(
  List<PendingEvmTx> entries,
  PendingActivityFilter filter,
) => [
  for (final entry in entries)
    if (switch (filter) {
      PendingActivityFilter.all => true,
      PendingActivityFilter.art => entry.kind == PendingEvmTxKind.nftTransfer,
      PendingActivityFilter.token =>
        entry.kind == PendingEvmTxKind.send ||
            entry.kind == PendingEvmTxKind.swap,
    })
      entry,
];

/// The "Pending" group — the first section of the activity feed list, ahead of
/// the dated groups: locally tracked EVM transactions that have not been mined
/// yet, plus any nonce gap left by a transaction broadcast from another device.
///
/// Renders nothing when the filtered set is empty, so the sheet looks exactly
/// as it does today for the (usual) case of nothing in flight.
class PendingActivitySection extends StatelessWidget {
  const PendingActivitySection({
    required this.entries,
    required this.signableAddresses,
    super.key,
    this.filter = PendingActivityFilter.all,
    this.onOpenDetail,
    this.onSpeedUp,
    this.onCancel,
  });

  final List<PendingEvmTx> entries;
  final PendingActivityFilter filter;

  /// Wallets this session can sign with
  /// (`SessionManager.signableSessionAddresses`). Passed in rather than read
  /// from the locator so this stays a pure render of what the host already
  /// knows.
  final Set<String> signableAddresses;

  final ValueChanged<PendingEvmTx>? onOpenDetail;

  /// Replacement actions, wired by the host to the shared prompts. A cell only
  /// shows a button when the handler is non-null *and* the entry's wallet is
  /// signable, so a view-only wallet's pending transactions render read-only.
  final ValueChanged<PendingEvmTx>? onSpeedUp;
  final ValueChanged<PendingEvmTx>? onCancel;

  @override
  Widget build(BuildContext context) {
    final visible = pendingEntriesForFilter(entries, filter);
    if (visible.isEmpty) return const SizedBox.shrink();

    // Session addresses keep their EIP-55 casing; tracked entries are
    // lowercased (`apiOwnerAddress`), so the membership test must be too.
    final signable = {
      for (final address in signableAddresses) address.toLowerCase(),
    };

    /// The tap handler for one action on one entry, or null when the action
    /// isn't offered here (no host handler, or a wallet this session can't
    /// sign with).
    VoidCallback? handlerFor(
      ValueChanged<PendingEvmTx>? action,
      PendingEvmTx entry,
    ) {
      if (action == null) return null;
      if (!signable.contains(entry.walletAddress.toLowerCase())) return null;
      return () => action(entry);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Matches ActivityDayHeader so "Pending" reads as another group header.
        Padding(
          padding: const EdgeInsets.only(
            left: MallowTheme.spacing20,
            right: MallowTheme.spacing20,
            top: MallowTheme.spacing20,
            bottom: MallowTheme.spacingSm,
          ),
          child: Text(
            'Pending',
            style: MallowTheme.editorialQuote.copyWith(
              color: context.mallowColors.textPrimary,
            ),
          ),
        ),
        for (final entry in visible)
          Padding(
            padding: const EdgeInsets.only(
              left: MallowTheme.spacing20,
              right: MallowTheme.spacing20,
              bottom: MallowTheme.spacingSm,
            ),
            child: PendingActivityCell(
              entry: entry,
              onTap: onOpenDetail == null ? null : () => onOpenDetail!(entry),
              onSpeedUp: handlerFor(onSpeedUp, entry),
              onCancel: handlerFor(onCancel, entry),
            ),
          ),
      ],
    );
  }
}
