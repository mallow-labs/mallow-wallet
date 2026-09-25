import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';

/// A full reset must empty *every* table. The hand-written list it replaced
/// had drifted five tables behind the schema — `CachedPortfolios` among them,
/// which holds the previous identity's raw portfolio JSON keyed by its
/// addresses. Iterating `allTables` makes the next forgotten table impossible;
/// this test makes it visible if someone reintroduces a list.
void main() {
  late MallowDatabase db;

  setUp(() {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test(
    'clearAll empties every table, including the caches a list forgot',
    () async {
      await db.upsertPortfolioCache(
        CachedPortfoliosCompanion.insert(
          sessionKey: 'sess',
          section: 'tokens',
          jsonData: '{"addresses":["old-identity"]}',
          cachedAt: 1,
        ),
      );
      await db
          .into(db.cachedJupiterTokenList)
          .insert(
            CachedJupiterTokenListCompanion.insert(mint: 'mint-1', cachedAt: 0),
          );
      await db.upsertSeedPhrase(
        SeedPhrasesCompanion.insert(id: 's1', name: 'Seed 1', createdAt: 0),
      );

      await db.clearAll();

      for (final table in db.allTables) {
        final rows = await db.select(table).get();
        expect(rows, isEmpty, reason: '${table.actualTableName} not cleared');
      }
    },
  );

  test('clearCache drops the identity-scoped portfolio cache', () async {
    await db.upsertPortfolioCache(
      CachedPortfoliosCompanion.insert(
        sessionKey: 'sess',
        section: 'tokens',
        jsonData: '{}',
        cachedAt: 1,
      ),
    );

    await db.clearCache();

    expect(await db.select(db.cachedPortfolios).get(), isEmpty);
  });
}
