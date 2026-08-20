import 'dart:async';

import 'package:injectable/injectable.dart';

import '../security/secure_storage.dart';
import '../session/session_manager.dart';

import '../../shared/utils/chain.dart';

/// The user's **Active Networks** preference: which non-Solana chains are
/// switched on for the current session scope (this Profile, or the Account).
///
/// The preference lives in [SecureWalletStorage] keyed by
/// [SessionManager.settingsScopeId], so each profile — and the account scope —
/// stay isolated. This wraps that read so every surface that has to honour it
/// (tokens tab, NFT portfolio request, import picker) resolves the scope the
/// same way, and so a toggle can announce itself: switching a chain off has to
/// drop its rows from a portfolio that is already on screen.
///
/// Solana is never togglable — it is the transactional chain the session's
/// identity is built on.
@lazySingleton
class ActiveNetworks {
  ActiveNetworks(this._storage, this._session);

  final SecureWalletStorage _storage;
  final SessionManager _session;

  /// The chains the user may switch off, in settings order.
  static const togglable = [Chain.tezos, Chain.ethereum];

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Fires after [setEnabled] writes. Listeners re-read the preference and
  /// reload — the toggle screen sits on top of a live portfolio, so nothing
  /// re-queries on its own when the user flips a chain and backs out.
  Stream<void> get changes => _changes.stream;

  /// Whether [chain] is switched on for the current scope. Unset defaults to
  /// enabled, so an untouched install has every chain active.
  Future<bool> isEnabled(Chain chain) async {
    if (!togglable.contains(chain)) return true;
    return _storage.loadNetworkEnabled(
      chain,
      scope: await _session.settingsScopeId(),
    );
  }

  /// The chains switched **off** for the current scope.
  Future<Set<Chain>> disabled() async {
    final scope = await _session.settingsScopeId();
    final off = <Chain>{};
    for (final chain in togglable) {
      if (!await _storage.loadNetworkEnabled(chain, scope: scope)) {
        off.add(chain);
      }
    }
    return off;
  }

  /// Switch [chain] on or off for the current scope and notify [changes].
  /// Ignores Solana rather than writing a preference nothing reads.
  Future<void> setEnabled(Chain chain, bool enabled) async {
    if (!togglable.contains(chain)) return;
    await _storage.storeNetworkEnabled(
      chain,
      enabled,
      scope: await _session.settingsScopeId(),
    );
    if (!_changes.isClosed) _changes.add(null);
  }
}
