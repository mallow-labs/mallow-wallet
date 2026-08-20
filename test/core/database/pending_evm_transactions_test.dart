import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';

/// CRUD for the pending-EVM-tx table.
///
/// These rows are durable user state, not a cache: while the nonce is
/// unconsumed the transaction is still replaceable, so losing a row loses the
/// user's only in-app way to speed up or cancel a stuck transaction.
void main() {
  late MallowDatabase db;

  PendingEvmTransactionsCompanion row({
    String wallet = '0xaaaa',
    int nonce = 7,
    String kind = 'send',
    String status = 'pending',
  }) => PendingEvmTransactionsCompanion.insert(
    walletAddress: wallet,
    nonce: nonce,
    chainId: 1,
    kind: kind,
    status: status,
    toAddress: '0xbbbb',
    valueWei: '1000000000000000000',
    data: '',
    gasLimit: 25200,
    metadataJson: '{"title":"Send"}',
    candidatesJson: '[]',
    createdAt: 1753840000,
  );

  setUp(() {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('insert and read back by (wallet, nonce)', () async {
    await db.upsertPendingEvmTransaction(row());

    final stored = await db.getPendingEvmTransaction('0xaaaa', 7);
    expect(stored, isNotNull);
    expect(stored!.chainId, 1);
    expect(stored.valueWei, '1000000000000000000');
    expect(stored.gasLimit, 25200);
  });

  test('a partial update keeps the signed payload columns intact', () async {
    // A speed-up appends a candidate to the *same* nonce slot; a second row
    // would render two pending cells for one transaction, and rewriting
    // to/value/data would let the replacement diverge from what was signed.
    await db.upsertPendingEvmTransaction(row());
    await db.updatePendingEvmTransaction(
      '0xaaaa',
      7,
      const PendingEvmTransactionsCompanion(
        status: Value('cancelling'),
        candidatesJson: Value('[{"hash":"0x1"}]'),
      ),
    );

    final all = await db.getPendingEvmTransactions();
    expect(all, hasLength(1));
    expect(all.single.status, 'cancelling');
    expect(all.single.candidatesJson, '[{"hash":"0x1"}]');
    expect(all.single.toAddress, '0xbbbb', reason: 'untouched columns persist');
  });

  test('the same nonce on a different wallet is a separate row', () async {
    await db.upsertPendingEvmTransaction(row());
    await db.upsertPendingEvmTransaction(row(wallet: '0xcccc'));

    expect(await db.getPendingEvmTransactions(), hasLength(2));
  });

  test('rows come back ordered by wallet then nonce ascending', () async {
    // Nonce N+1 cannot mine before N, so ascending nonce is the order they
    // resolve in and the order the Pending section renders.
    await db.upsertPendingEvmTransaction(row(wallet: '0xbbbb', nonce: 3));
    await db.upsertPendingEvmTransaction(row(nonce: 9));
    await db.upsertPendingEvmTransaction(row(nonce: 4));

    final all = await db.getPendingEvmTransactions();
    expect(all.map((r) => '${r.walletAddress}:${r.nonce}'), [
      '0xaaaa:4',
      '0xaaaa:9',
      '0xbbbb:3',
    ]);
  });

  test('delete removes only the resolved slot', () async {
    await db.upsertPendingEvmTransaction(row());
    await db.upsertPendingEvmTransaction(row(nonce: 8));

    await db.deletePendingEvmTransaction('0xaaaa', 7);

    final all = await db.getPendingEvmTransactions();
    expect(all.map((r) => r.nonce), [8]);
  });

  test('deleting a wallet clears only its rows', () async {
    await db.upsertPendingEvmTransaction(row(nonce: 1));
    await db.upsertPendingEvmTransaction(row(nonce: 2));
    await db.upsertPendingEvmTransaction(row(wallet: '0xcccc', nonce: 1));

    await db.deletePendingEvmTransactionsForWallet('0xaaaa');

    final all = await db.getPendingEvmTransactions();
    expect(all.map((r) => r.walletAddress), ['0xcccc']);
  });

  test('clearCache leaves pending transactions alone', () async {
    // The table is durable user state. Wiping it on a cache clear would strand
    // a stuck transaction with no in-app speed-up or cancel.
    await db.upsertPendingEvmTransaction(row());

    await db.clearCache();

    expect(await db.getPendingEvmTransactions(), hasLength(1));
  });

  test('clearAll purges pending transactions', () async {
    // A full reset deletes every wallet, and rows outlive their wallet only
    // because they belong to it. Left behind, re-importing the same address
    // resurfaces a stale actionable Pending cell whose Speed Up would re-sign
    // the stored payload.
    await db.upsertPendingEvmTransaction(row());

    await db.clearAll();

    expect(await db.getPendingEvmTransactions(), isEmpty);
  });

  test('watch re-emits when a row is inserted', () async {
    final emissions = <int>[];
    final sub = db.watchPendingEvmTransactions().listen(
      (rows) => emissions.add(rows.length),
    );
    addTearDown(sub.cancel);

    await pumpEventQueue();
    await db.upsertPendingEvmTransaction(row());
    await pumpEventQueue();

    expect(emissions, containsAllInOrder([0, 1]));
  });
}
