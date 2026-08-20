import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx.dart';
import 'package:mallow_wallet/features/activity/widgets/pending_activity_cell.dart';

// A pending cell is the only place a stuck transaction can be acted on, so the
// rules about *which* action it offers carry real money consequences: offering
// Speed up on a transaction we have no payload for would sign nothing useful,
// offering Cancel twice would burn a second fee on a slot already being
// cancelled, and offering either on a view-only wallet promises a signature the
// session cannot produce. These tests pin each of those.

const _wallet = '0x1111111111111111111111111111111111111111';

PendingEvmTx _entry({
  PendingEvmTxKind kind = PendingEvmTxKind.send,
  PendingEvmTxStatus status = PendingEvmTxStatus.pending,
  PendingTxMetadata metadata = const PendingTxMetadata(
    title: 'Send',
    subtitle: 'to 0x4fBj…29dF',
    tokenSymbol: 'ETH',
    amountRaw: '-1000000000000000000',
    decimals: 18,
  ),
  List<PendingTxCandidate> candidates = const [],
  bool canCancelNow = true,
  int nonce = 7,
}) => PendingEvmTx(
  walletAddress: _wallet,
  nonce: nonce,
  chainId: 1,
  kind: kind,
  status: status,
  toAddress: '0x2222222222222222222222222222222222222222',
  valueWei: BigInt.one,
  data: '',
  gasLimit: 21000,
  metadata: metadata,
  candidates: candidates,
  createdAt: 1753840000,
  canCancelNow: canCancelNow,
);

Future<void> _pump(
  WidgetTester tester,
  PendingEvmTx entry, {
  VoidCallback? onSpeedUp,
  VoidCallback? onCancel,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PendingActivityCell(
          entry: entry,
          onSpeedUp: onSpeedUp,
          onCancel: onCancel,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a pending transaction offers both replacements', (tester) async {
    await _pump(tester, _entry(), onSpeedUp: () {}, onCancel: () {});

    expect(find.text('Send'), findsOneWidget);
    expect(find.text('to 0x4fBj…29dF'), findsOneWidget);
    expect(find.text('-1 ETH'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Speed up'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('cancelling swaps Cancel out but keeps Speed up', (tester) async {
    // The cancel is itself a transaction that can get stuck, so bumping it must
    // stay reachable; offering Cancel again would only pay for a second one.
    await _pump(
      tester,
      _entry(status: PendingEvmTxStatus.cancelling),
      onSpeedUp: () {},
      onCancel: () {},
    );

    expect(find.text('Cancelling…'), findsOneWidget);
    expect(find.text('Speed up'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('an external nonce gap is cancel-only and amount-free', (
    tester,
  ) async {
    // We inferred the slot from a nonce gap: no payload to re-sign, and no idea
    // what it moves — claiming an amount here would be a guess.
    await _pump(
      tester,
      _entry(
        kind: PendingEvmTxKind.external,
        metadata: const PendingTxMetadata(title: 'Pending transaction'),
      ),
      onSpeedUp: () {},
      onCancel: () {},
    );

    expect(find.text('Pending transaction'), findsOneWidget);
    expect(find.text('0x111…11111'), findsOneWidget);
    expect(find.text('Speed up'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.textContaining('ETH'), findsNothing);
  });

  testWidgets('an external gap that was already cancelled can be sped up', (
    tester,
  ) async {
    // Once a blind cancel exists there IS a payload to bump — matching
    // PendingEvmTxTracker.speedUp, which only rejects the no-candidate case.
    await _pump(
      tester,
      _entry(
        kind: PendingEvmTxKind.external,
        status: PendingEvmTxStatus.cancelling,
        metadata: const PendingTxMetadata(title: 'Pending transaction'),
        candidates: [
          PendingTxCandidate(
            hash: '0xabc',
            role: PendingTxCandidateRole.cancel.name,
            maxFeePerGas: BigInt.from(20000000000),
            maxPriorityFeePerGas: BigInt.from(1000000000),
            broadcastAt: 1753840100,
          ),
        ],
      ),
      onSpeedUp: () {},
      onCancel: () {},
    );

    expect(find.text('Speed up'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('a gap above the lowest stuck nonce cannot be cancelled yet', (
    tester,
  ) async {
    // Replacements mine in nonce order, so cancelling this one first would pay
    // a fee for a transaction that still cannot be included.
    var cancelled = false;
    await _pump(
      tester,
      _entry(
        kind: PendingEvmTxKind.external,
        metadata: const PendingTxMetadata(title: 'Pending transaction'),
        canCancelNow: false,
        nonce: 8,
      ),
      onCancel: () => cancelled = true,
    );

    expect(find.text('Cancel the earlier transaction first'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(cancelled, isFalse);
  });

  testWidgets('a view-only wallet gets no action buttons', (tester) async {
    // The caller drops both handlers for a wallet outside
    // signableSessionAddresses — no key, so no replacement is possible.
    await _pump(tester, _entry());

    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Speed up'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });
}
