import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/network/auth_service.dart';
import '../../../shared/utils/chain.dart' show apiOwnerAddress;
import '../data/moderation_repository.dart';
import 'moderation_cache.dart';

/// The viewer's block list: read from the server when the session can prove
/// itself, and kept on the device in between.
///
/// Blocking is a **one-directional personal view filter**, and the app does
/// not rely on the server to apply it, since a session cannot always prove
/// itself. So the app holds the set too: it renders the
/// blocked-profile interstitial, drops blocked accounts' content from the
/// lists it builds (`ModerationFilter`), and keeps the Blocked accounts screen
/// honest right after a block/unblock, without waiting for a refetch.
///
/// **The device copy.** A Ledger, Keystone or Seed Vault session, or a social
/// wallet whose key is missing, usually holds no proof, and the background
/// load never asks for one. Without a copy the set would stay empty for that
/// whole session: no interstitial, nothing filtered. So the last list the
/// server returned is stored per signed-in address ([ModerationCache]),
/// published as soon as that address is the session's, and rewritten by every
/// signed read and every block or unblock that succeeds. A wallet switch
/// keeps each address's copy apart; a logout deletes the copy of the address
/// that was signed in, and a full reset deletes them all with the database.
///
/// Addresses are canonicalised through [apiOwnerAddress] on both write and
/// read: the backend lowercases Ethereum-style addresses while wallets are held
/// EIP-55 checksummed, so a raw compare silently never matches — the same class
/// of bug already seen in portfolio owner reads.
///
/// [blocked] is a [ValueNotifier] rather than a stream so widgets can gate on it
/// with a plain [ValueListenableBuilder] and get the current value on first
/// build (a missed broadcast event would leave a blocked profile rendering as
/// normal content).
///
/// `GET /v2/blocks` takes a signed login, and [ensureLoaded] runs from every
/// profile view, which the user did not open to sign anything. So the
/// background load never asks for a signature: it waits for a proof the
/// session already holds, and loads when [AuthService.walletSigChanges] says
/// one may have arrived.
///
/// The list belongs to the logged-in address. When that address changes (a
/// wallet switch, a logout) the set is dropped, and reloaded for the new one
/// if it had been asked for.
@lazySingleton
class BlockStore {
  BlockStore(
    this._repo,
    this._auth, {
    // Tests pass a fake. Kept out of the generated construction, which
    // resolves the device cache below.
    @ignoreParam ModerationCache? cache,
  }) : _cacheOverride = cache,
       _sessionAddress = _auth.currentAddress {
    _lastSignedIn = _sessionAddress;
    _auth.addListener(_onSessionChanged);
    _auth.walletSigChanges.addListener(_onProofChanged);
    _startRestore();
  }

  final ModerationRepository _repo;
  final AuthService _auth;
  final ModerationCache? _cacheOverride;

  late final ModerationCache? _cache =
      _cacheOverride ?? DatabaseModerationCache.ofDevice();

  /// Canonicalised addresses the viewer has blocked.
  final ValueNotifier<Set<String>> blocked = ValueNotifier(const <String>{});

  Future<List<api.BlockedAccount>>? _inFlight;
  bool _inFlightIsBackground = false;
  bool _loaded = false;

  /// Set when [ensureLoaded] could not load (no proof yet, or the server
  /// refused the one sent), so the next session change tries again.
  bool _awaitingProof = false;

  /// The logged-in address the cached list belongs to.
  String? _sessionAddress;

  /// The last address that was signed in. A wallet switch clears
  /// [_sessionAddress] on its way to the next wallet, so this is what a
  /// logout that lands in between still has to forget.
  String? _lastSignedIn;

  /// The read of the device copy for [_sessionAddress] while it is in
  /// flight, else null. Awaited before a block or unblock builds on the set,
  /// so a write cannot drop what the copy was about to restore.
  Future<void>? _restoring;

  /// Writes to the device copy, in the order they were asked for.
  Future<void> _writes = Future<void>.value();

  /// Completes when every write to the device copy asked for so far is done.
  @visibleForTesting
  Future<void> get persisted => _writes;

  /// Bumped by [clear] so a fetch started for the previous viewer can't
  /// publish its rows into the new session's set.
  int _generation = 0;

  bool isBlocked(String address) =>
      blocked.value.contains(apiOwnerAddress(address));

  /// Loads the list once per session, in the background. Safe to call from
  /// `build` — concurrent callers share the in-flight future, and a failure
  /// leaves the set as the device copy had it (empty on a first run).
  ///
  /// 🛑 Never prompts. It fetches only when
  /// [AuthService.canSendBackgroundSignedRead] says the logged-in wallet
  /// already holds a valid `wallet-sig`, and the fetch opts out of the 401
  /// re-sign. Without a proof it does nothing and waits for one: a Ledger,
  /// Seed Vault or Keystone session usually has none, and asking for a
  /// signature on every profile open, and again after each cancel, is the bug
  /// this guards against. A refusal (`requireProof=true` makes a rejected proof a 401
  /// rather than an empty list) latches nothing either. Until a proof arrives
  /// the set is the device copy, which needs none.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _awaitingProof = true;
    final restoring = _restoring;
    if (restoring != null) {
      await restoring;
      if (_loaded) {
        _awaitingProof = false;
        return;
      }
    }
    if (!await _auth.canSendBackgroundSignedRead()) return;
    // Another caller may have loaded it while the gate was checked.
    if (_loaded) {
      _awaitingProof = false;
      return;
    }
    try {
      await refresh(background: true);
      _awaitingProof = !_loaded;
    } catch (_) {
      // The device copy stays in force. The next profile view, or the next
      // proof, retries.
    }
  }

  void _onSessionChanged() {
    _followSession();
    if (sessionEnded(_auth)) _forgetSignedOut();
    if (_awaitingProof && !_loaded) unawaited(ensureLoaded());
  }

  /// A proof arrived or went. It says nothing about the session ending, so
  /// unlike [_onSessionChanged] it never deletes a device copy.
  void _onProofChanged() {
    _followSession();
    if (_awaitingProof && !_loaded) unawaited(ensureLoaded());
  }

  /// Moves to the logged-in address when it changed: drops the previous
  /// account's set and reads the new one's device copy.
  void _followSession() {
    final address = _auth.currentAddress;
    if (address == _sessionAddress) return;
    _sessionAddress = address;
    final wanted = _loaded || _awaitingProof;
    clear();
    _awaitingProof = wanted;
    if (address != null) _lastSignedIn = address;
    _startRestore();
  }

  static String _accountKey(String address) => apiOwnerAddress(address);

  /// Starts reading the device copy for the signed-in address, when there is
  /// an address and a cache to read it from.
  void _startRestore() {
    final address = _sessionAddress;
    final cache = _cache;
    if (address == null || cache == null) {
      _restoring = null;
      return;
    }
    late final Future<void> read;
    read = _restore(address, cache).whenComplete(() {
      if (identical(_restoring, read)) _restoring = null;
    });
    _restoring = read;
  }

  /// Publishes the device copy for [address], unless something newer got
  /// there first: a server answer, a block or unblock, or another session.
  Future<void> _restore(String address, ModerationCache cache) async {
    final generation = _generation;
    Set<String>? stored;
    try {
      stored = _decode(
        await cache.read(ModerationCacheSection.blocks, _accountKey(address)),
      );
    } catch (_) {
      // Unreadable is the same as absent: the next signed read rewrites it.
      return;
    }
    if (stored == null || generation != _generation || _loaded) return;
    _publish(stored);
  }

  /// Sets [blocked] to [next] when it differs. Every list on screen filters
  /// itself again when [blocked] notifies, and a set with the same addresses
  /// in a new object would notify for nothing: each signed read builds one.
  void _publish(Set<String> next) {
    if (!setEquals(blocked.value, next)) blocked.value = next;
  }

  static Set<String>? _decode(String? json) {
    if (json == null) return null;
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    return decoded.whereType<String>().map(apiOwnerAddress).toSet();
  }

  /// Stores the current set as the signed-in address's device copy.
  void _persist() {
    final address = _sessionAddress;
    final cache = _cache;
    if (address == null || cache == null) return;
    final json = jsonEncode(blocked.value.toList()..sort());
    _enqueue(
      () => cache.write(
        ModerationCacheSection.blocks,
        _accountKey(address),
        json,
      ),
    );
  }

  /// Applies [change] to the device copy of [account], which is no longer the
  /// session's: a block or unblock it sent landed after a switch.
  void _amendCopy(String? account, void Function(Set<String> set) change) {
    final cache = _cache;
    if (account == null || cache == null) return;
    final key = _accountKey(account);
    _enqueue(() async {
      final set =
          _decode(await cache.read(ModerationCacheSection.blocks, key)) ??
          <String>{};
      change(set);
      await cache.write(
        ModerationCacheSection.blocks,
        key,
        jsonEncode(set.toList()..sort()),
      );
    });
  }

  /// Deletes the device copy of the address whose session just ended.
  void _forgetSignedOut() {
    final address = _lastSignedIn;
    final cache = _cache;
    _lastSignedIn = null;
    if (address == null || cache == null) return;
    _enqueue(
      () => cache.remove(ModerationCacheSection.blocks, _accountKey(address)),
    );
  }

  /// A failed write costs only the copy: the set in memory is already right,
  /// and the next signed read stores it again.
  void _enqueue(Future<void> Function() write) {
    _writes = _writes.then((_) => write()).catchError((Object _) {});
  }

  /// Re-reads `GET /v2/blocks` and returns the full rows for the management
  /// screen. Failures propagate so the screen can show its error state.
  ///
  /// [background] is for [ensureLoaded]: its 401 fails instead of re-signing.
  /// The management screen leaves it false, so opening it may ask to sign.
  ///
  /// A response that lands after a [clear] is discarded (the caller still gets
  /// its rows): it belongs to the profile that was signed in when the request
  /// went out, and adopting it would apply one viewer's block list to another.
  /// So is one that lands after a block or unblock: it predates the write.
  Future<List<api.BlockedAccount>> refresh({bool background = false}) {
    final generation = _generation;
    // The screen's read must not ride a background one: that one cannot
    // re-sign, so its 401 would become the screen's error.
    final pending = _inFlight;
    if (pending != null && (background || !_inFlightIsBackground)) {
      return pending;
    }
    _inFlightIsBackground = background;
    late final Future<List<api.BlockedAccount>> request;
    request = _repo
        .listBlocks(background: background)
        .then((rows) {
          if (generation != _generation) return rows;
          _loaded = true;
          _publish(rows.map((r) => apiOwnerAddress(r.address)).toSet());
          _persist();
          return rows;
        })
        .whenComplete(() {
          if (identical(_inFlight, request)) _inFlight = null;
        });
    return _inFlight = request;
  }

  /// Blocks [address] and updates the local set on success. Returns false when
  /// the write threw, so the caller can surface it rather than pretend.
  Future<bool> block(String address) async {
    final account = _sessionAddress;
    final restoring = _restoring;
    if (restoring != null) await restoring;
    try {
      await _repo.block(address);
    } catch (_) {
      return false;
    }
    // The write belongs to the address that sent it. After a switch the set
    // in memory is another account's and must not gain this block; only the
    // sender's device copy does.
    if (account != _sessionAddress) {
      _amendCopy(account, (set) => set.add(apiOwnerAddress(address)));
      return true;
    }
    _afterWrite({...blocked.value, apiOwnerAddress(address)});
    return true;
  }

  /// Unblocks [address] and updates the local set on success.
  Future<bool> unblock(String address) async {
    final account = _sessionAddress;
    final restoring = _restoring;
    if (restoring != null) await restoring;
    try {
      await _repo.unblock(address);
    } catch (_) {
      return false;
    }
    if (account != _sessionAddress) {
      _amendCopy(account, (set) => set.remove(apiOwnerAddress(address)));
      return true;
    }
    _afterWrite({...blocked.value}..remove(apiOwnerAddress(address)));
    return true;
  }

  /// Publishes [next] after a block or unblock landed, and re-reads the list.
  ///
  /// A read that went out before the write answers with the list as it was,
  /// so it would undo the write. Bumping the generation makes [refresh] drop
  /// that answer, and the re-read (still the never-prompting background load)
  /// fetches the list the write produced.
  void _afterWrite(Set<String> next) {
    final reload = _inFlight != null || _loaded || _awaitingProof;
    _generation++;
    _inFlight = null;
    _loaded = false;
    _publish(next);
    _persist();
    if (reload) {
      _awaitingProof = true;
      unawaited(ensureLoaded());
    }
  }

  /// Drops the state in memory on sign-out / profile switch — the block list
  /// is per-viewer, and serving one profile's list to another is worse than
  /// none. The device copies are untouched: each is keyed by its own address.
  void clear() {
    _generation++;
    _inFlight = null;
    _loaded = false;
    _awaitingProof = false;
    _publish(const <String>{});
  }

  @disposeMethod
  void dispose() {
    _auth.removeListener(_onSessionChanged);
    _auth.walletSigChanges.removeListener(_onProofChanged);
    blocked.dispose();
  }
}
