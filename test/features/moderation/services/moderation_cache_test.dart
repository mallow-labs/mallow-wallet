import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_cache.dart';

// The device copy of the block list and of the reports lives in the encrypted
// database, in the per-session JSON table the portfolio cache uses.

void main() {
  late MallowDatabase db;
  late DatabaseModerationCache cache;

  setUp(() {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    cache = DatabaseModerationCache(() => db);
  });

  tearDown(() => db.close());

  test('reads back what was written, per account and section', () async {
    await cache.write(ModerationCacheSection.blocks, 'A', '["x"]');
    await cache.write(ModerationCacheSection.blocks, 'B', '["y"]');
    await cache.write(ModerationCacheSection.reports, 'A', '{"artworks":[]}');

    expect(await cache.read(ModerationCacheSection.blocks, 'A'), '["x"]');
    expect(await cache.read(ModerationCacheSection.blocks, 'B'), '["y"]');
    expect(
      await cache.read(ModerationCacheSection.reports, 'A'),
      '{"artworks":[]}',
    );
    expect(await cache.read(ModerationCacheSection.reports, 'B'), isNull);
  });

  test('a later write replaces the earlier one', () async {
    await cache.write(ModerationCacheSection.blocks, 'A', '["x"]');
    await cache.write(ModerationCacheSection.blocks, 'A', '[]');
    expect(await cache.read(ModerationCacheSection.blocks, 'A'), '[]');
  });

  test('remove deletes one account\'s section and nothing else', () async {
    await cache.write(ModerationCacheSection.blocks, 'A', '["x"]');
    await cache.write(ModerationCacheSection.reports, 'A', '{}');
    await cache.write(ModerationCacheSection.blocks, 'B', '["y"]');

    await cache.remove(ModerationCacheSection.blocks, 'A');

    expect(await cache.read(ModerationCacheSection.blocks, 'A'), isNull);
    expect(await cache.read(ModerationCacheSection.reports, 'A'), '{}');
    expect(await cache.read(ModerationCacheSection.blocks, 'B'), '["y"]');
  });

  // A single-wallet session's portfolio cache is keyed by the same address.
  test('it shares the table with the portfolio cache without touching its '
      'rows', () async {
    await db.upsertPortfolioCache(
      const CachedPortfoliosCompanion(
        sessionKey: Value('A'),
        section: Value('artworks'),
        jsonData: Value('{"portfolio":true}'),
        cachedAt: Value(1),
      ),
    );
    await cache.write(ModerationCacheSection.blocks, 'A', '["x"]');
    await cache.remove(ModerationCacheSection.blocks, 'A');

    final portfolio = await db.getPortfolioCache('A', 'artworks');
    expect(portfolio?.jsonData, '{"portfolio":true}');
  });

  test('a full reset takes the copies with everything else', () async {
    await cache.write(ModerationCacheSection.blocks, 'A', '["x"]');
    await cache.write(ModerationCacheSection.reports, 'A', '{}');

    await db.clearAll();

    expect(await cache.read(ModerationCacheSection.blocks, 'A'), isNull);
    expect(await cache.read(ModerationCacheSection.reports, 'A'), isNull);
  });
}
