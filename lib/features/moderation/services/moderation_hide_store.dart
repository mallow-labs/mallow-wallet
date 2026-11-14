import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/network/auth_service.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart' show apiOwnerAddress;
import 'moderation_cache.dart';

/// Viewer-side suppression of content the viewer has reported.
///
/// 🛑 This is **not** `/v0/hide`. That endpoint is *owner*-scoped — it hides an
/// artwork you own from your own public profile and is gated by a `wallet-sig`
/// cookie proving ownership (`artwork_hide_actions.dart`), so calling it on
/// someone else's artwork 403s. Reporting must hide the content from the
/// *reporter's* view only, with no signature prompt and no server write beyond
/// the report itself. Nothing in this file talks to the network.
///
/// The app never reads its own reports back from the server, and does not
/// rely on a route to leave them out. So this store is what keeps a
/// reported artwork, curation or user out of the lists the app builds
/// (`ModerationFilter`), and it has to outlive the session: the three sets
/// are stored on the device per signed-in address ([ModerationCache]) and
/// reloaded when that address signs in again. One account's reports never
/// hide anything for another; a logout deletes the copy of the address that
/// was signed in, and a full reset deletes them all with the database.
///
/// Without a signed-in address (or without a cache, as in unit tests that do
/// not bootstrap the service locator) the sets live in memory only.
@lazySingleton
class ModerationHideStore {
  ModerationHideStore({
    // Tests pass fakes. Both are kept out of the generated construction,
    // which resolves the device cache and the session below.
    @ignoreParam ModerationCache? cache,
    @ignoreParam AuthService? auth,
  }) : _cacheOverride = cache,
       _auth =
           auth ?? (sl.isRegistered<AuthService>() ? sl<AuthService>() : null) {
    _account = _auth?.currentAddress;
    _lastSignedIn = _account;
    _auth?.addListener(_onSessionChanged);
    _startRestore();
  }

  final ModerationCache? _cacheOverride;
  final AuthService? _auth;

  late final ModerationCache? _cache =
      _cacheOverride ?? DatabaseModerationCache.ofDevice();

  final Set<String> _artworks = <String>{};
  final Set<String> _curations = <String>{};
  final Set<String> _users = <String>{};

  /// The signed-in address the sets belong to.
  String? _account;

  /// The last address that was signed in: what a logout has to forget even
  /// when a wallet switch had already cleared [_account].
  String? _lastSignedIn;

  /// Bumped by every session change, so a device copy read for the previous
  /// address is not merged into the next one's sets.
  int _generation = 0;

  /// The read of the device copy for [_account] while it is in flight, else
  /// null.
  Future<void>? _restoring;
  Future<void> _writes = Future<void>.value();

  /// Completes once the device copy for the current address has been read.
  @visibleForTesting
  Future<void> get restored => _restoring ?? Future<void>.value();

  /// Completes when every write to the device copy asked for so far is done.
  @visibleForTesting
  Future<void> get persisted => _writes;

  /// Bumped whenever the sets change — a report, a device copy read, a session
  /// change — so `ValueListenableBuilder` rebuilds and lists re-filter. The
  /// value itself carries no meaning.
  final ValueNotifier<int> revision = ValueNotifier(0);

  bool isArtworkHidden(String mintAccount) => _artworks.contains(mintAccount);

  /// True when the curation was reported. [curation] may be the exhibition
  /// slug — the identifier the report carries as its `targetId` — or the
  /// curation id, which is all most lists have (see [hide]).
  bool isCurationHidden(String curation) => _curations.contains(curation);

  bool isUserHidden(String address) =>
      _users.contains(apiOwnerAddress(address));

  /// Records [targetId] as suppressed for the signed-in address.
  ///
  /// [alias] is a second identifier the same target goes by. A curation is
  /// reported by its slug, while the lists that show it (search, home, a
  /// profile's Curations tab) carry only its id, so the screen filing the
  /// report passes the id here and both are matched.
  void hide(api.ReportTargetType targetType, String targetId, {String? alias}) {
    if (targetId.isEmpty) return;
    final added = switch (targetType) {
      api.ReportTargetType.artwork => _artworks.add(targetId),
      api.ReportTargetType.curation => _addCuration(targetId, alias),
      api.ReportTargetType.user => _users.add(apiOwnerAddress(targetId)),
      // Inbound-only placeholder for a target type the spec doesn't list, so
      // there is no bucket to hide it in. Unreachable in practice — every
      // caller passes a literal from `moderation_actions.dart`.
      api.ReportTargetType.swaggerGeneratedUnknown => false,
    };
    if (!added) return;
    revision.value++;
    _persist();
  }

  bool _addCuration(String slug, String? alias) {
    final added = _curations.add(slug);
    final aliased = alias != null && alias.isNotEmpty && _curations.add(alias);
    return added || aliased;
  }

  void _onSessionChanged() {
    final auth = _auth;
    if (auth == null) return;
    final address = auth.currentAddress;
    if (address != _account) {
      _account = address;
      _generation++;
      final hadAny =
          _artworks.isNotEmpty || _curations.isNotEmpty || _users.isNotEmpty;
      _artworks.clear();
      _curations.clear();
      _users.clear();
      if (hadAny) revision.value++;
      if (address != null) _lastSignedIn = address;
      _startRestore();
    }
    if (sessionEnded(auth)) _forgetSignedOut();
  }

  static String _accountKey(String address) => apiOwnerAddress(address);

  /// Starts reading the device copy for the signed-in address, when there is
  /// an address and a cache to read it from.
  void _startRestore() {
    final account = _account;
    final cache = _cache;
    if (account == null || cache == null) {
      _restoring = null;
      return;
    }
    late final Future<void> read;
    read = _restore(account, cache).whenComplete(() {
      if (identical(_restoring, read)) _restoring = null;
    });
    _restoring = read;
  }

  /// Merges the device copy for [account] into the sets. Merged, not
  /// assigned: a report filed while the read was in flight stays.
  Future<void> _restore(String account, ModerationCache cache) async {
    final generation = _generation;
    Map<String, dynamic>? stored;
    try {
      final json = await cache.read(
        ModerationCacheSection.reports,
        _accountKey(account),
      );
      final decoded = json == null ? null : jsonDecode(json);
      stored = decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      // Unreadable is the same as absent.
      return;
    }
    if (stored == null || generation != _generation) return;
    Iterable<String> strings(String key) =>
        (stored![key] as List<dynamic>? ?? const []).whereType<String>();
    final before = _artworks.length + _curations.length + _users.length;
    _artworks.addAll(strings(_artworksKey));
    _curations.addAll(strings(_curationsKey));
    _users.addAll(strings(_usersKey).map(apiOwnerAddress));
    final after = _artworks.length + _curations.length + _users.length;
    if (after != before) revision.value++;
  }

  static const _artworksKey = 'artworks';
  static const _curationsKey = 'curations';
  static const _usersKey = 'users';

  void _persist() {
    final account = _account;
    final cache = _cache;
    if (account == null || cache == null) return;
    final key = _accountKey(account);
    // The read must land first, or this write would replace what it had not
    // merged yet. The sets are encoded after it, so they include it.
    final restoring = _restoring;
    final generation = _generation;
    _enqueue(() async {
      if (restoring != null) await restoring;
      if (generation != _generation) return;
      await cache.write(
        ModerationCacheSection.reports,
        key,
        jsonEncode({
          _artworksKey: _artworks.toList()..sort(),
          _curationsKey: _curations.toList()..sort(),
          _usersKey: _users.toList()..sort(),
        }),
      );
    });
  }

  /// Deletes the device copy of the address whose session just ended.
  void _forgetSignedOut() {
    final account = _lastSignedIn;
    final cache = _cache;
    _lastSignedIn = null;
    if (account == null || cache == null) return;
    _enqueue(
      () => cache.remove(ModerationCacheSection.reports, _accountKey(account)),
    );
  }

  /// A failed write costs only the copy; the sets in memory are already right.
  void _enqueue(Future<void> Function() write) {
    _writes = _writes.then((_) => write()).catchError((Object _) {});
  }

  @disposeMethod
  void dispose() {
    _auth?.removeListener(_onSessionChanged);
    revision.dispose();
  }
}
