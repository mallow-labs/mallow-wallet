import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

// Re-exports `pending_evm_tx.dart` (PendingEvmTx and friends).
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart' show Chain;
import '../../../shared/utils/explorer_utils.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_kv_row.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../services/pending_tx_actions.dart';
import '../utils/pending_tx_fee.dart';
import 'pending_activity_cell.dart';

/// Compact detail for one pending (wallet, nonce) slot, opened by tapping a
/// [PendingActivityCell].
///
/// Deliberately not a technical dump: what the transaction is, how long it has
/// been waiting, what it is currently bidding, and the same two actions the
/// cell offers. The per-candidate hash list was rejected — the newest hash is
/// the only one worth linking, and which candidate actually mines is decided by
/// the chain, not by anything the user can act on here.
Future<void> showPendingTxDetailSheet(
  BuildContext context,
  PendingEvmTx entry,
) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PendingTxDetailSheet(entry: entry),
  );
}

class _PendingTxDetailSheet extends StatefulWidget {
  const _PendingTxDetailSheet({required this.entry});

  final PendingEvmTx entry;

  @override
  State<_PendingTxDetailSheet> createState() => _PendingTxDetailSheetState();
}

class _PendingTxDetailSheetState extends State<_PendingTxDetailSheet> {
  /// USD per ETH, shared with the Speed up / Cancel prompts
  /// ([pendingTxEthPriceUsd]). Null until it lands, or when the price is
  /// unknown, in which case the fee row shows ETH alone.
  double? _ethPriceUsd;

  /// The slot as the tracker currently holds it. Seeded from the entry the cell
  /// was tapped on, then kept live off [PendingEvmTxTracker.watch] — the sheet
  /// stays open across Speed up / Cancel, and a cancel that has been broadcast
  /// must stop offering Cancel here just as it does in the list. Re-cancelling
  /// off the pre-cancel candidates bids at or below the cancel already in the
  /// mempool, which the node rejects as "replacement transaction underpriced".
  late PendingEvmTx _entry = widget.entry;

  StreamSubscription<List<PendingEvmTx>>? _entriesSub;

  @override
  void initState() {
    super.initState();
    _entriesSub = sl<PendingEvmTxTracker>().watch().listen(_onEntries);
    _loadEthPrice();
  }

  @override
  void dispose() {
    _entriesSub?.cancel();
    super.dispose();
  }

  void _onEntries(List<PendingEvmTx> entries) {
    if (!mounted) return;
    final slot = widget.entry;
    for (final entry in entries) {
      if (entry.nonce == slot.nonce &&
          entry.walletAddress.toLowerCase() ==
              slot.walletAddress.toLowerCase()) {
        setState(() => _entry = entry);
        return;
      }
    }
    // The slot resolved (mined, reverted, or taken by another client) while the
    // sheet was open: there is nothing left to detail or to replace, and the
    // resolution toast reports the outcome. Only dismiss when this sheet is the
    // top route — a Speed up / Cancel prompt open over it owns the screen, and
    // popping from under it would close *that* instead.
    if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop();
  }

  Future<void> _loadEthPrice() async {
    final price = await pendingTxEthPriceUsd(widget.entry.walletAddress);
    if (!mounted) return;
    setState(() => _ethPriceUsd = price);
  }

  /// Whether this session holds the key for the wallet the slot belongs to.
  /// A view-only wallet's pending transaction is readable but not replaceable
  /// — only its own wallet can sign a replacement for its nonce.
  bool get _signable {
    final signable = {
      for (final address in sl<SessionManager>().signableSessionAddresses)
        address.toLowerCase(),
    };
    return signable.contains(_entry.walletAddress.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final metadata = _entry.metadata;

    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingSm,
                MallowTheme.spacing20,
                0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    metadata.title,
                    style: MallowTheme.uiTitle.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  if (metadata.subtitle case final subtitle?
                      when subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: MallowTheme.uiBody.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: MallowTheme.spacingSm),
                  Text(
                    _statusLine(),
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.positive,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  MallowKvList(
                    rows: [
                      MallowKvRow(
                        label: 'Max fee',
                        value: pendingTxMaxFeeLabel(_entry, _ethPriceUsd),
                      ),
                      MallowKvRow(label: 'Nonce', value: '${_entry.nonce}'),
                    ],
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  MallowButton(
                    label: 'View on ${txExplorerName(Chain.ethereum)}',
                    variant: MallowButtonVariant.secondary,
                    isFullWidth: true,
                    onPressed: _openExplorer,
                  ),
                  if (_signable) ...[
                    const SizedBox(height: MallowTheme.spacingMd),
                    PendingTxActionRow(
                      entry: _entry,
                      onSpeedUp: () => promptSpeedUp(context, _entry),
                      onCancel: () => promptCancel(context, _entry),
                    ),
                  ],
                  const SizedBox(height: MallowTheme.spacingMd),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Pending · 4m" / "Cancelling · 4m". A derived external entry has no
  /// broadcast time of its own (we only inferred the nonce), so it shows the
  /// state alone.
  String _statusLine() {
    final state = _entry.isCancelling ? 'Cancelling' : 'Pending';
    final createdAt = _entry.createdAt;
    if (createdAt <= 0) return state;
    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(createdAt * 1000),
    );
    return '$state · ${_elapsedLabel(elapsed)}';
  }

  Future<void> _openExplorer() async {
    final hash = _entry.newestHash;
    // A derived external entry has no hash of ours — the wallet's address page
    // is the closest thing to "the transaction holding this nonce".
    final url = hash == null || hash.isEmpty
        ? buildAccountExplorerUrlForChain(_entry.walletAddress, Chain.ethereum)
        : buildTxExplorerUrlForChain(hash, Chain.ethereum);
    await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
  }
}

String _elapsedLabel(Duration elapsed) {
  if (elapsed.inMinutes < 1) return '${elapsed.inSeconds.clamp(0, 59)}s';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h';
  return '${elapsed.inDays}d';
}
