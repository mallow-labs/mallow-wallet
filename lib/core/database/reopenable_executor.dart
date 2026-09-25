import 'dart:async';

import 'package:drift/backends.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// A [QueryExecutor] that delegates to a [LazyDatabase] it can throw away and
/// recreate.
///
/// Two behaviours drift's own [LazyDatabase] does not offer, both needed by
/// the on-disk wallet database:
///
/// 1. **A failed open is not cached.** `LazyDatabase` completes its open
///    future with the error once and replays it to every later call, so one
///    transient failure — the keystore unavailable on a locked-device
///    background launch — bricks the database for the life of the process.
///    Here a failed open discards the lazy delegate; the next call runs the
///    opener again.
/// 2. **The file can be replaced under a live database.** [reset] closes the
///    current delegate, installs a fresh lazy one, then runs a callback while
///    nothing holds the file (the caller deletes it). The owning
///    `GeneratedDatabase` keeps its streams and migration logic; the next
///    query opens the new file and runs `onCreate` on it. Queries that arrive
///    during a reset wait for it rather than hitting a closed handle, and a
///    callback that throws still leaves a usable executor behind.
///
/// Asynchronous members wait for an in-flight [reset], then open the delegate
/// they are about to use if nothing has opened it yet. drift runs a statement
/// in two steps — `ensureOpen(user)` and, after an async gap, the run call on
/// the same executor — so a statement whose open resolved on the previous
/// delegate would otherwise reach the fresh one before anything opened it.
///
/// Synchronous members ([dialect], [beginTransaction], [beginExclusive])
/// delegate directly and cannot do that. Residual window: a transaction whose
/// `ensureOpen` resolved before a [reset] and which calls [beginTransaction]
/// or [beginExclusive] after that reset installed the fresh delegate throws,
/// because drift's `LazyDatabase` dereferences its uninitialised delegate.
/// Retrying the transaction succeeds — the retry's own `ensureOpen` opens the
/// new delegate — and drift calls both only after an `ensureOpen` on this
/// executor, so the window is one reset wide and no wider.
class ReopenableExecutor extends QueryExecutor {
  ReopenableExecutor(this._opener, {SqlDialect dialect = SqlDialect.sqlite})
    : _dialect = dialect,
      _inner = LazyDatabase(_opener, dialect: dialect);

  final DatabaseOpener _opener;
  final SqlDialect _dialect;
  LazyDatabase _inner;

  /// Non-null while a [reset] is in flight; async members await it.
  Future<void>? _resetting;

  /// Whether something has completed an `ensureOpen` on [_inner]. False for a
  /// delegate that [reset] or a failed open has just installed.
  bool _innerOpened = false;

  /// The user drift last passed to [ensureOpen]. Kept so a statement can open
  /// a delegate installed after its own `ensureOpen` already resolved.
  QueryExecutorUser? _user;

  /// Number of delegates created so far. Exposed for tests, which use it to
  /// prove that a failed open really re-ran the opener.
  @visibleForTesting
  int generation = 1;

  @override
  SqlDialect get dialect => _dialect;

  /// Close the current delegate, install a fresh one, then run [whileClosed]
  /// with nothing holding the database file.
  ///
  /// [whileClosed] is where the caller deletes the file (and its sidecars);
  /// it runs even if closing the old delegate throws — an executor whose open
  /// failed throws on close, and there is nothing to close in that case. An
  /// error from [whileClosed] propagates to the caller, which reports the
  /// failed reset.
  ///
  /// The fresh delegate goes in *before* [whileClosed] runs so that a throwing
  /// callback — a `-wal` sidecar that will not delete, say — cannot leave the
  /// closed one behind. That state does not heal: the production delegate is
  /// an isolate-backed connection whose `ensureOpen` caches its "the server is
  /// open" answer across `close()`, so [ensureOpen] keeps succeeding, the
  /// discard-and-retry path below never fires, and every later statement
  /// throws "connection was closed" until the process is force-quit. Ordering
  /// it first is safe because the delegate is lazy and anything that would
  /// open it waits on [_resetting] until [whileClosed] has finished.
  Future<void> reset(Future<void> Function() whileClosed) async {
    final completer = Completer<void>();
    _resetting = completer.future;
    try {
      final old = _inner;
      try {
        await old.close();
      } catch (_) {
        // Never opened, or open failed: nothing holds the file.
      }
      _inner = LazyDatabase(_opener, dialect: _dialect);
      _innerOpened = false;
      generation++;
      await whileClosed();
    } finally {
      _resetting = null;
      completer.complete();
    }
  }

  /// The current delegate, once any in-flight [reset] has finished.
  Future<LazyDatabase> _current() async {
    final pending = _resetting;
    if (pending != null) await pending;
    return _inner;
  }

  /// The current delegate, opened if nothing has opened it yet.
  ///
  /// A statement's `ensureOpen` may have resolved on a delegate that a [reset]
  /// has since replaced. Its run step lands here, and drift's `LazyDatabase`
  /// dereferences an uninitialised delegate — a `LateInitializationError` —
  /// when nothing opened it first.
  Future<LazyDatabase> _ready() async {
    final inner = await _current();
    final user = _user;
    if (_innerOpened || user == null) return inner;
    await _open(inner, user);
    return inner;
  }

  /// Run `ensureOpen` on [inner], discarding it if that fails.
  ///
  /// A cached failure would otherwise be replayed to every later call, so the
  /// next one gets a delegate that runs the opener again. Closing is
  /// best-effort, in case the open itself succeeded and only the migration
  /// failed.
  Future<bool> _open(LazyDatabase inner, QueryExecutorUser user) async {
    try {
      final opened = await inner.ensureOpen(user);
      if (identical(_inner, inner)) _innerOpened = true;
      return opened;
    } catch (_) {
      if (identical(_inner, inner) && _resetting == null) {
        _inner = LazyDatabase(_opener, dialect: _dialect);
        _innerOpened = false;
        generation++;
        unawaited(inner.close().catchError((_) {}));
      }
      rethrow;
    }
  }

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    _user = user;
    return _open(await _current(), user);
  }

  @override
  TransactionExecutor beginTransaction() => _inner.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();

  @override
  Future<void> runBatched(BatchedStatements statements) async =>
      (await _ready()).runBatched(statements);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async =>
      (await _ready()).runCustom(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) async =>
      (await _ready()).runDelete(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) async =>
      (await _ready()).runInsert(statement, args);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async => (await _ready()).runSelect(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async =>
      (await _ready()).runUpdate(statement, args);

  @override
  Future<void> close() async {
    final inner = await _current();
    await inner.close();
  }
}
