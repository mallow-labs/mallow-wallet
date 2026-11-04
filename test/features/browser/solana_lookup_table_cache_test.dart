import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/solana_lookup_table_cache.dart';
import 'package:solana/base58.dart';

const _chain = 'solana:mainnet';

String _address(int seed) => base58encode(List.filled(32, seed));

List<String> _table(int length, {int seed = 1}) => [
  for (var i = 0; i < length; i++) _address((seed + i) % 256),
];

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lookup_tables');
    file = File('${dir.path}/tables.json');
  });
  tearDown(() => dir.delete(recursive: true));

  SolanaLookupTableCache cache({int maxTables = 64, int maxBytes = 1 << 20}) =>
      SolanaLookupTableCache(
        file: () async => file,
        maxTables: maxTables,
        maxBytes: maxBytes,
      );

  test('answers only the indexes it holds', () async {
    final tables = cache();
    await tables.load();
    tables.store(_chain, 'A', _table(3));
    expect(tables.addresses(_chain, 'A', covering: 3), _table(3));
    // The table may have grown since: an index past the end is read again.
    expect(tables.addresses(_chain, 'A', covering: 4), isNull);
    expect(tables.addresses('solana:devnet', 'A', covering: 1), isNull);
  });

  test('keeps the most recently used tables within both limits', () async {
    final byCount = cache(maxTables: 2);
    byCount
      ..store(_chain, 'A', _table(1))
      ..store(_chain, 'B', _table(1))
      ..addresses(_chain, 'A', covering: 1)
      ..store(_chain, 'C', _table(1));
    expect(byCount.addresses(_chain, 'B', covering: 1), isNull);
    expect(byCount.addresses(_chain, 'A', covering: 1), isNotNull);
    expect(byCount.addresses(_chain, 'C', covering: 1), isNotNull);

    // Two 4-address tables fit in 256 bytes; a third evicts the oldest.
    final byBytes = cache(maxBytes: 256);
    byBytes
      ..store(_chain, 'A', _table(4))
      ..store(_chain, 'B', _table(4))
      ..store(_chain, 'C', _table(4));
    expect(byBytes.addresses(_chain, 'A', covering: 1), isNull);
    expect(byBytes.addresses(_chain, 'B', covering: 1), isNotNull);
    expect(byBytes.addresses(_chain, 'C', covering: 1), isNotNull);
  });

  test('survives a restart', () async {
    final first = cache();
    await first.load();
    first
      ..store(_chain, 'A', _table(2))
      ..store(_chain, 'B', _table(256, seed: 9));
    await first.idle;

    final second = cache();
    await second.load();
    expect(second.addresses(_chain, 'A', covering: 2), _table(2));
    expect(second.addresses(_chain, 'B', covering: 256), _table(256, seed: 9));
  });

  test(
    'a restart keeps the saved order of use under a smaller limit',
    () async {
      final first = cache();
      first
        ..store(_chain, 'A', _table(1))
        ..store(_chain, 'B', _table(1))
        ..store(_chain, 'C', _table(1));
      await first.idle;

      final second = cache(maxTables: 2);
      await second.load();
      expect(second.addresses(_chain, 'A', covering: 1), isNull);
      expect(second.addresses(_chain, 'C', covering: 1), isNotNull);
    },
  );

  test('a damaged file is an empty cache', () async {
    await file.writeAsString('{"version": 1, "tables": [{"key": "x y", ');
    final tables = cache();
    await tables.load();
    expect(tables.addresses('x', 'y', covering: 0), isNull);
    tables.store(_chain, 'A', _table(1));
    await tables.idle;
    final again = cache();
    await again.load();
    expect(again.addresses(_chain, 'A', covering: 1), isNotNull);
  });

  test('forgetting and clearing remove tables for good', () async {
    final tables = cache();
    await tables.load();
    tables
      ..store(_chain, 'A', _table(1))
      ..store(_chain, 'B', _table(1))
      ..forget(_chain, 'A');
    await tables.idle;
    final reloaded = cache();
    await reloaded.load();
    expect(reloaded.addresses(_chain, 'A', covering: 1), isNull);
    expect(reloaded.addresses(_chain, 'B', covering: 1), isNotNull);

    tables.store(_chain, 'C', _table(1));
    await tables.clear();
    expect(tables.addresses(_chain, 'B', covering: 1), isNull);
    await tables.idle;
    expect(file.existsSync(), isFalse);
  });

  test('an unavailable store leaves the cache working in memory', () async {
    final tables = SolanaLookupTableCache(
      file: () async => throw const FileSystemException('unavailable'),
    );
    await tables.load();
    tables.store(_chain, 'A', _table(1));
    await tables.idle;
    expect(tables.addresses(_chain, 'A', covering: 1), _table(1));
  });
}
