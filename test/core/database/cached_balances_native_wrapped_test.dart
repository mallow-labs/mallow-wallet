import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';

/// Native SOL and wrapped SOL share the same mint (`So111…112`) and differ only
/// by [TokenBalance.isNative]. The balances cache must persist them as two rows,
/// otherwise the cached portfolio total under-counts by one of them — which is
/// what made the header's instantly-shown (cached) value never match the
/// final animated (fresh-fetch) value on refresh. `isNative` is therefore part
/// of the `cached_balances` primary key.
void main() {
  late MallowDatabase db;

  setUp(() => db = MallowDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  const wallet = 'TestWallet1111111111111111111111111111111111';
  const mint = TokenBalance.solMint;

  CachedBalancesCompanion row({
    required bool isNative,
    required double uiBalance,
    required double total,
  }) {
    return CachedBalancesCompanion.insert(
      walletAddress: wallet,
      mint: mint,
      symbol: 'SOL',
      name: 'Solana',
      decimals: 9,
      rawBalance: (uiBalance * 1e9).round(),
      uiBalance: uiBalance,
      pricePerToken: const Value(100),
      totalUsdValue: Value(total),
      isNative: Value(isNative),
      cachedAt: 0,
    );
  }

  test(
    'native + wrapped SOL persist as separate rows (no PK collision)',
    () async {
      await db.upsertBalances([
        row(isNative: true, uiBalance: 2, total: 200), // native SOL
        row(isNative: false, uiBalance: 1, total: 100), // wrapped SOL
      ]);

      final rows = await db.getBalances(wallet);

      // Both survive — neither overwrites the other.
      expect(rows.length, 2);
      expect(rows.where((r) => r.isNative).length, 1);
      expect(rows.where((r) => !r.isNative).length, 1);

      // The cached total now matches the sum a fresh fetch would produce.
      final cachedTotal = rows.fold<double>(
        0,
        (s, r) => s + (r.totalUsdValue ?? 0),
      );
      expect(cachedTotal, 300);
    },
  );

  test(
    're-caching the same wallet replaces rows by (mint, isNative)',
    () async {
      await db.upsertBalances([row(isNative: true, uiBalance: 2, total: 200)]);
      // A later fetch updates the native row in place rather than appending.
      await db.upsertBalances([row(isNative: true, uiBalance: 3, total: 300)]);

      final rows = await db.getBalances(wallet);
      expect(rows.length, 1);
      expect(rows.single.totalUsdValue, 300);
    },
  );
}
