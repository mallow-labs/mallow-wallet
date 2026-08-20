import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/database/database.dart';

import 'generated/schema.dart';

/// Schema-shape verification for [MallowDatabase.migration].
///
/// [database_migration_test.dart] pins that upgrades preserve *data* (wallet
/// rows must survive). This file pins that they produce the right *shape*:
/// every stepwise upgrade must land on a schema identical to what a fresh
/// install gets from `onCreate`/`createAll`.
///
/// That divergence is the failure mode a data-only test cannot see — a
/// `schemaVersion` bump whose `onUpgrade` step forgets a column leaves
/// upgraded users with a different schema than new users, and queries that
/// reference the missing column then fail only on updated devices.
///
/// Snapshots live in `drift_schemas/`. After changing any table definition,
/// bump `schemaVersion`, add the matching `onUpgrade` step, then run:
///
/// ```
/// dart run drift_dev schema dump \
///     lib/core/database/database.dart drift_schemas/
/// dart run drift_dev schema generate \
///     drift_schemas/ test/core/database/generated/
/// ```
void main() {
  // The newest snapshot on disk. The first test pins it to the database's real
  // `schemaVersion`, so it is a safe upgrade target for the loop below.
  final latestVersion = GeneratedHelper.versions.last;

  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('a schema snapshot exists for the current schemaVersion', () {
    final db = MallowDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Fails the moment someone bumps `schemaVersion` without dumping a new
    // snapshot — without this the upgrade tests below silently stop covering
    // the newest step, because they would migrate to the old version and pass.
    expect(
      db.schemaVersion,
      latestVersion,
      reason:
          'schemaVersion is ${db.schemaVersion} but drift_schemas/ only has '
          '${GeneratedHelper.versions}. Run `dart run drift_dev schema dump '
          'lib/core/database/database.dart drift_schemas/` and regenerate.',
    );
  });

  // Every released schema must migrate stepwise to the latest. v0.4.0 shipped
  // 18 and v0.5.0..v0.11.0 shipped 19, so 17 is pre-release only and is covered
  // here purely to pin the destructive-rebuild branch's output shape.
  for (final from in GeneratedHelper.versions.where((v) => v < latestVersion)) {
    test('schema $from migrates to $latestVersion cleanly', () async {
      final connection = await verifier.startAt(from);
      final db = MallowDatabase.forTesting(connection);
      addTearDown(db.close);

      // Runs the real `onUpgrade`, then diffs the resulting sqlite_master
      // against the committed v$latestVersion snapshot.
      await verifier.migrateAndValidate(db, latestVersion);

      // Second, snapshot-independent check: diff the migrated schema against
      // what the *current* table definitions expect. This is what catches a
      // table-definition change made without re-dumping the snapshot — in that
      // case migrateAndValidate compares two equally-stale schemas and passes.
      await db.validateDatabaseSchema();
    });
  }
}
