import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../di.dart';
import '../../../shared/utils/chain.dart' show apiOwnerAddress;
import '../data/moderation_repository.dart';

/// The viewer's block list, cached for the session.
///
/// Blocking is a **one-directional personal view filter**. The authoritative
/// filter is server-side (home feed, search, offers, push), but the app needs
/// the set locally to render the blocked-profile interstitial and to keep the
/// Blocked accounts screen honest right after a block/unblock, without waiting
/// for a refetch.
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
@lazySingleton
class BlockStore {
  BlockStore(this._repo);

  final ModerationRepository _repo;

  /// Canonicalised addresses the viewer has blocked.
  final ValueNotifier<Set<String>> blocked = ValueNotifier(const <String>{});

  Future<List<api.BlockedAccount>>? _inFlight;
  bool _loaded = false;

  /// Bumped by [clear] so a fetch started for the previous viewer can't
  /// publish its rows into the new session's set.
  int _generation = 0;

  bool isBlocked(String address) =>
      blocked.value.contains(apiOwnerAddress(address));

  /// Loads the list once per session. Safe to call from `build` — concurrent
  /// callers share the in-flight future, and a failure just leaves the set
  /// empty (nothing is hidden that shouldn't be).
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      await refresh();
    } catch (_) {
      // Nothing is hidden that shouldn't be; the next call retries.
    }
  }

  /// Re-reads `GET /v2/blocks` and returns the full rows for the management
  /// screen. Failures propagate so the screen can show its error state.
  ///
  /// A response that lands after a [clear] is discarded (the caller still gets
  /// its rows): it belongs to the profile that was signed in when the request
  /// went out, and adopting it would apply one viewer's block list to another.
  Future<List<api.BlockedAccount>> refresh() {
    final generation = _generation;
    return _inFlight ??= _repo
        .listBlocks()
        .then((rows) {
          if (generation != _generation) return rows;
          _loaded = true;
          blocked.value = rows.map((r) => apiOwnerAddress(r.address)).toSet();
          return rows;
        })
        .whenComplete(() {
          if (generation == _generation) _inFlight = null;
        });
  }

  /// Blocks [address] and updates the local set on success. Returns false when
  /// the write threw, so the caller can surface it rather than pretend.
  Future<bool> block(String address) async {
    try {
      await _repo.block(address);
    } catch (_) {
      return false;
    }
    blocked.value = {...blocked.value, apiOwnerAddress(address)};
    return true;
  }

  /// Unblocks [address] and updates the local set on success.
  Future<bool> unblock(String address) async {
    try {
      await _repo.unblock(address);
    } catch (_) {
      return false;
    }
    blocked.value = {...blocked.value}..remove(apiOwnerAddress(address));
    return true;
  }

  /// Drops cached state on sign-out / profile switch — the block list is
  /// per-viewer, and serving one profile's list to another is worse than none.
  void clear() {
    _generation++;
    _inFlight = null;
    _loaded = false;
    blocked.value = const <String>{};
  }

  @disposeMethod
  void dispose() => blocked.dispose();
}

/// True when [address] is on the viewer's block list. No-ops to false when DI
/// isn't configured (unit tests that don't bootstrap GetIt).
bool isAddressBlocked(String address) =>
    sl.isRegistered<BlockStore>() && sl<BlockStore>().isBlocked(address);
