import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx.dart';
import 'package:mallow_wallet/features/activity/widgets/pending_activity_cell.dart';
import 'package:mallow_wallet/features/activity/widgets/pending_activity_section.dart';

// The Pending group sits above the server-backed activity feed and is the only
// surface that can reach a stuck transaction. Two things must hold: it must
// disappear entirely when nothing is in flight (the common case — it would
// otherwise put a permanent empty header above every user's history), and a
// tab must never hide an entry the user needs to act on except by the mapping
// the spec fixed.

const _signer = '0x1111111111111111111111111111111111111111';
const _viewOnly = '0x2222222222222222222222222222222222222222';

PendingEvmTx _entry({
  required PendingEvmTxKind kind,
  String wallet = _signer,
  int nonce = 1,
  String title = 'Send',
}) => PendingEvmTx(
  walletAddress: wallet,
  nonce: nonce,
  chainId: 1,
  kind: kind,
  status: PendingEvmTxStatus.pending,
  toAddress: '0x3333333333333333333333333333333333333333',
  valueWei: BigInt.zero,
  data: '',
  gasLimit: 21000,
  metadata: PendingTxMetadata(title: title),
  candidates: const [],
  createdAt: 1753840000,
);

Future<void> _pump(
  WidgetTester tester,
  List<PendingEvmTx> entries, {
  PendingActivityFilter filter = PendingActivityFilter.all,
  Set<String> signable = const {_signer},
  ValueChanged<PendingEvmTx>? onSpeedUp,
  ValueChanged<PendingEvmTx>? onCancel,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PendingActivitySection(
          entries: entries,
          filter: filter,
          signableAddresses: signable,
          onSpeedUp: onSpeedUp ?? (_) {},
          onCancel: onCancel ?? (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('nothing in flight renders no section at all', (tester) async {
    await _pump(tester, const []);

    expect(find.text('Pending'), findsNothing);
    expect(find.byType(PendingActivityCell), findsNothing);
  });

  testWidgets('every kind shows under All, in the tracker order', (
    tester,
  ) async {
    // Order is mining order (nonce ascending per wallet) and the section must
    // not re-sort it: nonce N+1 cannot mine before N.
    await _pump(tester, [
      _entry(kind: PendingEvmTxKind.send),
      _entry(kind: PendingEvmTxKind.nftTransfer, nonce: 2, title: 'Transfer'),
      _entry(kind: PendingEvmTxKind.swap, nonce: 3, title: 'Swap'),
      _entry(kind: PendingEvmTxKind.other, nonce: 4, title: 'Transaction'),
      _entry(
        kind: PendingEvmTxKind.external,
        nonce: 5,
        title: 'Pending transaction',
      ),
    ]);

    expect(find.text('Pending'), findsOneWidget);
    expect(find.byType(PendingActivityCell), findsNWidgets(5));
    final titles = tester
        .widgetList<PendingActivityCell>(find.byType(PendingActivityCell))
        .map((cell) => cell.entry.metadata.title)
        .toList();
    expect(titles, [
      'Send',
      'Transfer',
      'Swap',
      'Transaction',
      'Pending transaction',
    ]);
  });

  testWidgets('Art transactions shows NFT transfers only', (tester) async {
    await _pump(tester, [
      _entry(kind: PendingEvmTxKind.send),
      _entry(kind: PendingEvmTxKind.nftTransfer, nonce: 2, title: 'Transfer'),
      _entry(kind: PendingEvmTxKind.swap, nonce: 3, title: 'Swap'),
      _entry(
        kind: PendingEvmTxKind.external,
        nonce: 4,
        title: 'Pending transaction',
      ),
    ], filter: PendingActivityFilter.art);

    expect(find.byType(PendingActivityCell), findsOneWidget);
    expect(find.text('Transfer'), findsOneWidget);
  });

  testWidgets('Token transactions shows sends and swaps only', (tester) async {
    // external/other are unclassifiable movements — they belong under All,
    // where the user can still reach them, not under a typed tab.
    await _pump(tester, [
      _entry(kind: PendingEvmTxKind.send),
      _entry(kind: PendingEvmTxKind.nftTransfer, nonce: 2, title: 'Transfer'),
      _entry(kind: PendingEvmTxKind.swap, nonce: 3, title: 'Swap'),
      _entry(kind: PendingEvmTxKind.other, nonce: 4, title: 'Transaction'),
      _entry(
        kind: PendingEvmTxKind.external,
        nonce: 5,
        title: 'Pending transaction',
      ),
    ], filter: PendingActivityFilter.token);

    expect(find.byType(PendingActivityCell), findsNWidgets(2));
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Swap'), findsOneWidget);
  });

  testWidgets('a filter that matches nothing hides the header too', (
    tester,
  ) async {
    await _pump(tester, [
      _entry(kind: PendingEvmTxKind.send),
    ], filter: PendingActivityFilter.art);

    expect(find.text('Pending'), findsNothing);
  });

  testWidgets('a view-only wallet gets no action buttons', (tester) async {
    // Only the transaction's own wallet can replace its nonce, so a session
    // that can't sign for it must not appear to offer that.
    await _pump(tester, [
      _entry(kind: PendingEvmTxKind.send, wallet: _viewOnly),
    ]);

    expect(find.byType(PendingActivityCell), findsOneWidget);
    expect(find.text('Speed up'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('signability is matched case-insensitively', (tester) async {
    // Tracked entries are lowercased (apiOwnerAddress); session addresses keep
    // their EIP-55 checksum casing. A literal comparison would strip the
    // buttons from every wallet that has an uppercase hex digit.
    await _pump(
      tester,
      [_entry(kind: PendingEvmTxKind.send)],
      signable: {'0x1111111111111111111111111111111111111111'.toUpperCase()},
    );

    expect(find.text('Speed up'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });
}
