import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/database/reopenable_executor.dart';
import 'package:path/path.dart' as p;

/// The on-disk database's executor must (1) retry an open that failed —
/// drift's own LazyDatabase replays the first failure forever, which turned a
/// locked-device background launch into a bricked process — and (2) let the
/// file be deleted and recreated under a live database, which is what makes
/// Reset app a factory reset instead of a re-keyed, quarantined leftover.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mallow_reopenable_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File dbFile() => File(p.join(tmp.path, 'mallow.sqlite'));

  test('a failed open is retried on the next call instead of cached', () async {
    var attempts = 0;
    final executor = ReopenableExecutor(() async {
      attempts++;
      if (attempts == 1) throw StateError('keystore locked');
      return NativeDatabase(dbFile());
    });
    final db = MallowDatabase.forTesting(executor);
    addTearDown(db.close);

    await expectLater(db.hasAnyWallets(), throwsA(isA<StateError>()));
    // Same database object, next query: the opener runs again and succeeds.
    expect(await db.hasAnyWallets(), isFalse);
    expect(attempts, 2);
    expect(executor.generation, 2);
  });

  test('reset deletes the file while closed and reopens a fresh one', () async {
    var opens = 0;
    final executor = ReopenableExecutor(() async {
      opens++;
      return NativeDatabase(dbFile());
    });
    final db = MallowDatabase.forTesting(executor);
    addTearDown(db.close);

    await db.upsertSeedPhrase(
      SeedPhrasesCompanion.insert(id: 's1', name: 'Seed 1', createdAt: 0),
    );
    expect(await db.getAllSeedPhrases(), hasLength(1));
    expect(dbFile().existsSync(), isTrue);

    var deletedWhileClosed = false;
    await executor.reset(() async {
      // Nothing holds the file now: deleting it must succeed.
      dbFile().deleteSync();
      deletedWhileClosed = !dbFile().existsSync();
    });

    expect(deletedWhileClosed, isTrue);
    // The same MallowDatabase keeps working: the next query opens a new file
    // (onCreate runs on it) and sees none of the old rows.
    expect(await db.getAllSeedPhrases(), isEmpty);
    expect(dbFile().existsSync(), isTrue);
    expect(opens, 2);
    expect(executor.generation, 2);
  });

  test(
    'a reset whose callback throws still installs a fresh delegate',
    () async {
      // File-based, like the reset test above. Every in-memory open produces
      // an empty database anyway, so "no rows after the reset" would prove
      // nothing there; here the row was on disk before the callback threw.
      var opens = 0;
      final executor = ReopenableExecutor(() async {
        opens++;
        return NativeDatabase(dbFile());
      });
      final db = MallowDatabase.forTesting(executor);
      addTearDown(db.close);

      await db.upsertSeedPhrase(
        SeedPhrasesCompanion.insert(id: 's1', name: 'Seed 1', createdAt: 0),
      );
      expect(await db.getAllSeedPhrases(), hasLength(1));

      // The file goes, then a sidecar refuses to: the caller deletes the
      // `-wal`/`-shm` sidecars too, and either delete can throw.
      await expectLater(
        executor.reset(() async {
          dbFile().deleteSync();
          throw const FileSystemException('sidecar is busy');
        }),
        throwsA(isA<FileSystemException>()),
      );

      // reset itself replaced the closed delegate, before it ran the callback.
      // Leaving the closed one in place bricks the process on the production
      // executor, whose ensureOpen keeps reporting success after close, so the
      // discard-and-retry path in ensureOpen never runs.
      expect(executor.generation, 2);

      expect(await db.getAllSeedPhrases(), isEmpty);
      expect(opens, 2);
      // Still 2: the fresh delegate opened cleanly, so nothing here came from
      // the failed-open recovery path.
      expect(executor.generation, 2);
    },
  );

  test('a statement that straddles a reset opens the fresh delegate', () async {
    final executor = ReopenableExecutor(() async => NativeDatabase(dbFile()));
    final db = MallowDatabase.forTesting(executor);
    addTearDown(db.close);
    // Creates the file and teaches the executor which QueryExecutorUser drift
    // opens with.
    expect(await db.hasAnyWallets(), isFalse);

    // drift runs a statement in two steps — `ensureOpen(user)` and, after an
    // async gap, the run call — so a reset can land between them. The run step
    // then reaches a delegate nothing has opened.
    await executor.ensureOpen(db);
    final reset = executor.reset(() async => dbFile().deleteSync());
    final rows = executor.runSelect(
      'SELECT COUNT(*) AS c FROM seed_phrases;',
      const [],
    );

    await reset;
    // Reads the recreated file, so the fresh delegate was opened and migrated
    // rather than dereferenced uninitialised.
    expect(await rows, [
      {'c': 0},
    ]);
  });

  test(
    'queries issued during a reset wait for it rather than failing',
    () async {
      final executor = ReopenableExecutor(() async => NativeDatabase(dbFile()));
      final db = MallowDatabase.forTesting(executor);
      addTearDown(db.close);
      expect(await db.hasAnyWallets(), isFalse);

      late Future<bool> duringReset;
      await executor.reset(() async {
        dbFile().deleteSync();
        duringReset = db.hasAnyWallets();
        // Give the query a chance to run while the reset is still in flight.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });

      expect(await duringReset, isFalse);
    },
  );
}
