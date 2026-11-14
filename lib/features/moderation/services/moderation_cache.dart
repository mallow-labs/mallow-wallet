import 'package:drift/drift.dart';

import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../../../core/network/auth_service.dart';
import '../../../di.dart';

/// Where the moderation stores keep their last known state on the device, one
/// entry per signed-in address and [section].
///
/// The block list can only be read from the server with a signed login, and a
/// hardware, Seed Vault or social session often cannot produce one without
/// asking the user. Reports are never read back at all. So both are kept here
/// too: a block still applies while the proof is missing, and a reported item
/// stays hidden after a restart.
///
/// The values are the viewer's private data (who they blocked, what they
/// reported), so an implementation must not use plain preferences.
abstract interface class ModerationCache {
  /// The JSON stored for [account], or null when there is none.
  Future<String?> read(String section, String account);

  Future<void> write(String section, String account, String json);

  Future<void> remove(String section, String account);
}

/// Section names. Prefixed so they cannot collide with the portfolio's own
/// sections in the table [DatabaseModerationCache] shares with it.
abstract final class ModerationCacheSection {
  static const blocks = 'moderation.blocks';
  static const reports = 'moderation.reports';
}

/// [ModerationCache] over the encrypted database.
///
/// It stores its rows in the per-session JSON table the portfolio cache uses
/// (session key, section, JSON), under its own section names. That table is
/// already keyed the way these lists are, lives in the encrypted database, and
/// is emptied by a full reset. A table of its own would say what it holds more
/// plainly, and can replace this class without touching the stores.
class DatabaseModerationCache implements ModerationCache {
  DatabaseModerationCache(this._database);

  /// The device cache, or null where no database is registered (unit tests
  /// that do not bootstrap the service locator). The stores then keep their
  /// state in memory only.
  static ModerationCache? ofDevice() => sl.isRegistered<MallowDatabase>()
      ? DatabaseModerationCache(() => sl<MallowDatabase>())
      : null;

  /// Looked up per call: the database object is registered lazily and must not
  /// be opened just because a store was constructed.
  final MallowDatabase Function() _database;

  @override
  Future<String?> read(String section, String account) async {
    final row = await _database().getPortfolioCache(account, section);
    return row?.jsonData;
  }

  @override
  Future<void> write(String section, String account, String json) {
    return _database().upsertPortfolioCache(
      CachedPortfoliosCompanion(
        sessionKey: Value(account),
        section: Value(section),
        jsonData: Value(json),
        cachedAt: Value(CacheFreshness.nowEpochSeconds()),
      ),
    );
  }

  @override
  Future<void> remove(String section, String account) async {
    final db = _database();
    await (db.delete(db.cachedPortfolios)..where(
          (t) => t.sessionKey.equals(account) & t.section.equals(section),
        ))
        .go();
  }
}

/// True when [auth] reports a session that was ended, as opposed to one that
/// is being replaced.
///
/// A wallet switch also passes through "no address", but it moves straight on
/// to logging the next wallet in, so by the time listeners hear of it the
/// state is `loading` (or `error` when that login failed). Only a logout
/// leaves no address *and* the untouched initial state. The stores drop their
/// device copy on a logout and keep it across a switch.
bool sessionEnded(AuthService auth) =>
    auth.currentAddress == null && auth.sessionState == SessionState.initial;
