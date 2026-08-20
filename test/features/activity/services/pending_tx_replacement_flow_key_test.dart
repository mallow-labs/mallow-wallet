import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx.dart';
import 'package:mallow_wallet/features/activity/services/pending_tx_actions.dart';
import 'package:mallow_wallet/shared/utils/chain.dart' show Chain;

/// Speed-up and cancel sign and broadcast, and their signing funnel
/// (`signAndBroadcastEvmTransfer`) does **not** route through
/// `TransactionAuthGate` — so unlike every other signing site, the kill-switch
/// backstop never sees them. The entry gate in `pending_tx_actions.dart` is the
/// only layer there is, which makes the cell it reads load-bearing: read the
/// wrong one and an operator's kill silently does nothing.
void main() {
  PendingEvmTx entry({
    required PendingEvmTxKind kind,
    String data = '',
    PendingEvmTxStatus status = PendingEvmTxStatus.pending,
  }) => PendingEvmTx(
    walletAddress: '0xabc',
    nonce: 1,
    chainId: 1,
    kind: kind,
    status: status,
    toAddress: '0xdef',
    valueWei: BigInt.zero,
    data: data,
    gasLimit: 21000,
    metadata: const PendingTxMetadata(title: 'Send'),
    candidates: const [],
    createdAt: 0,
  );

  test('a cancel is a native self-send, whatever the original was', () {
    for (final kind in PendingEvmTxKind.values) {
      expect(
        pendingTxReplacementFlowKey(entry(kind: kind), asCancel: true),
        const FlowKey(Chain.ethereum, AppFlow.nativeSend),
      );
    }
  });

  test('a speed-up answers to the original payload cell', () {
    // Killing ERC-20 sends must not also freeze a stuck ETH transfer.
    expect(
      pendingTxReplacementFlowKey(
        entry(kind: PendingEvmTxKind.send),
        asCancel: false,
      ),
      const FlowKey(Chain.ethereum, AppFlow.nativeSend),
    );
    expect(
      pendingTxReplacementFlowKey(
        entry(kind: PendingEvmTxKind.send, data: '0xa9059cbb'),
        asCancel: false,
      ),
      const FlowKey(Chain.ethereum, AppFlow.tokenSend),
    );
    expect(
      pendingTxReplacementFlowKey(
        entry(kind: PendingEvmTxKind.nftTransfer),
        asCancel: false,
      ),
      const FlowKey(Chain.ethereum, AppFlow.nftTransfer),
    );
  });

  test('an unmodelled kind still lands on a real cell, never ungated', () {
    // `swap` / `other` have no EVM cell of their own. Falling through to "no
    // gate" would make the one un-stoppable path the one nobody thought about.
    for (final kind in [
      PendingEvmTxKind.swap,
      PendingEvmTxKind.other,
      PendingEvmTxKind.external,
    ]) {
      final key = pendingTxReplacementFlowKey(
        entry(kind: kind),
        asCancel: false,
      );
      expect(key.chain, Chain.ethereum);
      expect(key.flow.isImplemented(Chain.ethereum), isTrue);
    }
  });

  test('every cell it can return is implemented for Ethereum', () {
    // A cell this build does not implement would hit the "fail loud"
    // backstop — except there is no backstop on this path, so it would simply
    // never match a kill.
    for (final kind in PendingEvmTxKind.values) {
      for (final asCancel in [true, false]) {
        final key = pendingTxReplacementFlowKey(
          entry(kind: kind),
          asCancel: asCancel,
        );
        expect(
          key.flow.isImplemented(key.chain),
          isTrue,
          reason: '$kind (asCancel: $asCancel) -> $key',
        );
      }
    }
  });
}
