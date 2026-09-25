import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// The open-path recovery for an undecryptable database must preserve the
/// file (rename-aside) instead of deleting it. Deleting on SQLITE_NOTADB is
/// what used to permanently destroy wallet metadata after a keystore misread
/// — the file is bit-identical recoverable the moment the right key
/// resurfaces, so destruction is never acceptable.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mallow_db_quarantine_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File dbFile() => File(p.join(tmp.path, 'mallow.sqlite'));

  List<String> quarantinedNames() => tmp
      .listSync()
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .where((n) => n.contains('.invalid-'))
      .toList();

  group('quarantineCorruptDatabase', () {
    test('renames the db and sidecars aside instead of deleting them', () {
      final file = dbFile()..writeAsStringSync('main-bytes');
      File('${file.path}-wal').writeAsStringSync('wal-bytes');
      File('${file.path}-shm').writeAsStringSync('shm-bytes');

      quarantineCorruptDatabase(file);

      expect(file.existsSync(), isFalse);
      expect(File('${file.path}-wal').existsSync(), isFalse);
      expect(File('${file.path}-shm').existsSync(), isFalse);

      final names = quarantinedNames();
      expect(names, hasLength(3));
      final mainCopy = names.singleWhere(
        (n) => n.startsWith('mallow.sqlite.invalid-'),
      );
      // The bytes survive untouched — that is the whole point.
      expect(File(p.join(tmp.path, mainCopy)).readAsStringSync(), 'main-bytes');
    });

    test('works with no sidecar files present', () {
      final file = dbFile()..writeAsStringSync('main-bytes');

      quarantineCorruptDatabase(file);

      expect(file.existsSync(), isFalse);
      expect(quarantinedNames(), hasLength(1));
    });

    test('prunes previously quarantined copies so they never accumulate', () {
      File(
        p.join(tmp.path, 'mallow.sqlite.invalid-1111'),
      ).writeAsStringSync('old-main');
      File(
        p.join(tmp.path, 'mallow.sqlite-wal.invalid-1111'),
      ).writeAsStringSync('old-wal');
      final file = dbFile()..writeAsStringSync('new-main');

      quarantineCorruptDatabase(file);

      final names = quarantinedNames();
      expect(names, hasLength(1));
      expect(
        File(p.join(tmp.path, names.single)).readAsStringSync(),
        'new-main',
      );
    });
  });

  // A factory reset deletes the database file and the DB encryption key. A
  // quarantined copy left beside them still holds real wallet rows — the key
  // is gone, so they are unreadable, but "unreadable with today's key" is not
  // what a user asking to erase the app means. resetStorage runs this for the
  // same reason quarantineCorruptDatabase prunes with it.
  group('deleteQuarantinedCopies', () {
    test('deletes main and sidecar copies, leaves everything else', () {
      final file = dbFile()..writeAsStringSync('live-db');
      File('${file.path}-wal').writeAsStringSync('live-wal');
      File(
        p.join(tmp.path, 'mallow.sqlite.invalid-1111'),
      ).writeAsStringSync('old-main');
      File(
        p.join(tmp.path, 'mallow.sqlite-wal.invalid-1111'),
      ).writeAsStringSync('old-wal');
      File(
        p.join(tmp.path, 'mallow.sqlite-shm.invalid-2222'),
      ).writeAsStringSync('older-shm');
      File(p.join(tmp.path, 'other.sqlite')).writeAsStringSync('not-ours');

      deleteQuarantinedCopies(file);

      expect(quarantinedNames(), isEmpty);
      expect(file.existsSync(), isTrue);
      expect(File('${file.path}-wal').existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'other.sqlite')).existsSync(), isTrue);
    });

    test('is a no-op when the directory is gone', () {
      final file = dbFile();
      tmp.deleteSync(recursive: true);

      expect(() => deleteQuarantinedCopies(file), returnsNormally);
    });
  });

  group('probeEncryptedDatabase', () {
    // Mirrors the probe query from _makeSetupEncryption without the cipher
    // pragmas (the test host's sqlite3 build has no cipher support; unknown
    // pragmas would be silently ignored anyway).
    void headerCheck(sqlite3.Database db) {
      db.execute('SELECT count(*) FROM sqlite_master;');
    }

    test('quarantines a file whose header cannot be read (NOTADB)', () {
      // An encrypted-with-a-lost-key database is indistinguishable from this:
      // the header check fails with SQLITE_NOTADB.
      final file = dbFile()
        ..writeAsStringSync('not a sqlite database'.padRight(1024, 'x'));

      probeEncryptedDatabase(file, headerCheck);

      expect(file.existsSync(), isFalse);
      expect(quarantinedNames(), hasLength(1));
    });

    test('leaves a healthy database untouched', () {
      final file = dbFile();
      final db = sqlite3.sqlite3.open(file.path);
      db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY);');
      db.dispose();

      probeEncryptedDatabase(file, headerCheck);

      expect(file.existsSync(), isTrue);
      expect(quarantinedNames(), isEmpty);
    });
  });
}
