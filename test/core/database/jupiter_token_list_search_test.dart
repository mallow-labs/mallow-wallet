import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';

/// `searchJupiterTokenList` truncates the ~3.9k-row verified catalog with a
/// `LIMIT`, and the swap picker ranks what comes back in Dart
/// (`JupiterVerifiedTokenListService._rank`: exact symbol or mint > symbol
/// prefix > exact name > name prefix > symbol substring > the rest).
///
/// Dart-side ranking can only reorder rows the query actually returned, so the
/// ordering has to exist in SQL too: broad queries (`sol`, `usd`, `ai`) match
/// far more rows than the limit, and an unordered `LIMIT` truncates in
/// insertion order. The one row the user is unambiguously asking for — the
/// exact symbol, or the mint they pasted — is then silently absent from the
/// picker. These tests pin the exact match *inside* the limit window by
/// inserting it last, where insertion order would put it outside.
void main() {
  late MallowDatabase db;

  setUp(() => db = MallowDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  CachedJupiterTokenListCompanion token(
    String mint, {
    required String symbol,
    required String name,
  }) {
    return CachedJupiterTokenListCompanion.insert(
      mint: mint,
      symbol: Value(symbol),
      name: Value(name),
      cachedAt: 0,
    );
  }

  test('exact symbol survives the LIMIT even when inserted last', () async {
    // 150 derivative tokens carrying "sol" in their symbol, then the real SOL.
    // Under rowid order the default limit of 100 cuts everything past the
    // 100th row, so SOL — inserted 151st — never reaches the picker.
    await db.replaceJupiterTokenList([
      for (var i = 0; i < 150; i++)
        token('Derivative$i', symbol: 'xSOL$i', name: 'Staked Sol $i'),
      token(
        'So11111111111111111111111111111111111111112',
        symbol: 'SOL',
        name: 'Solana',
      ),
    ]);

    // Lower-case query against an upper-case symbol: the exact-match tier is
    // case-insensitive, matching `_rank`'s `toLowerCase()` comparison.
    final rows = await db.searchJupiterTokenList('sol');

    expect(rows.length, 100, reason: 'limit still applies');
    expect(
      rows.first.mint,
      'So11111111111111111111111111111111111111112',
      reason: 'the exact symbol match must be the first row, not a dropped one',
    );
  });

  test('exact mint survives the LIMIT even when inserted last', () async {
    const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

    // Impersonators embed the real mint in their name so that pasting that
    // mint surfaces them. They must not be able to crowd the genuine token out
    // of the limit window.
    await db.replaceJupiterTokenList([
      for (var i = 0; i < 150; i++)
        token('Impostor$i', symbol: 'USDC$i', name: 'Claim $usdc airdrop $i'),
      token(usdc, symbol: 'USDC', name: 'USD Coin'),
    ]);

    final rows = await db.searchJupiterTokenList(usdc);

    expect(rows.length, 100, reason: 'limit still applies');
    expect(
      rows.first.mint,
      usdc,
      reason: 'the pasted mint must resolve to the token that owns it',
    );
  });

  test(
    'mint equality stays case-sensitive; symbol matching does not',
    () async {
      const mint = 'So11111111111111111111111111111111111111112';
      await db.replaceJupiterTokenList([
        token(mint, symbol: 'SOL', name: 'Solana'),
      ]);

      // base58 is case-sensitive, so a case-folded mint is a different address
      // and must not be treated as an exact hit.
      expect(await db.searchJupiterTokenList(mint.toLowerCase()), isEmpty);
      // Symbols are matched case-insensitively, as `_rank` does.
      expect((await db.searchJupiterTokenList('sol')).single.mint, mint);
    },
  );

  test('SQL ordering follows the same tiers as the Dart ranking', () async {
    // Inserted worst-first, so the expected result order is exactly the
    // reverse of insertion order — nothing here can pass on rowid order.
    await db.replaceJupiterTokenList([
      token('tier5', symbol: 'ZZZ', name: 'Presol Coin'), // name substring
      token('tier4', symbol: 'xSOL', name: 'Ecks'), // symbol substring
      token('tier3', symbol: 'ABC', name: 'Solana Ecosystem'), // name prefix
      token('tier2', symbol: 'DEF', name: 'Sol'), // exact name
      token('tier1', symbol: 'SOLEND', name: 'Solend'), // symbol prefix
      token('tier0', symbol: 'SOL', name: 'Solana'), // exact symbol
    ]);

    final rows = await db.searchJupiterTokenList('sol');

    expect(rows.map((r) => r.mint), [
      'tier0',
      'tier1',
      'tier2',
      'tier3',
      'tier4',
      'tier5',
    ]);
  });

  test('LIKE wildcards typed by the user still match literally', () async {
    await db.replaceJupiterTokenList([
      token('pct', symbol: 'A%B', name: 'Percent'),
      token('underscore', symbol: 'A_B', name: 'Underscore'),
      token('literal', symbol: 'AZB', name: 'Neither'),
    ]);

    // Unescaped, `%` and `_` would wildcard and drag in the 'AZB' row.
    expect((await db.searchJupiterTokenList('A%B')).single.mint, 'pct');
    expect((await db.searchJupiterTokenList('A_B')).single.mint, 'underscore');
  });
}
