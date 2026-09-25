import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../crypto/wallet_manager.dart';
import '../database/database.dart';
import '../security/secure_storage.dart';
import '../services/sentry_service.dart';
import '../services/wallet_repository.dart';

/// Notifies GoRouter when auth state changes, triggering route reevaluation.
///
/// This enables the router to react to:
/// - Wallet creation/import completion
/// - PIN setup completion
/// - Logout/wallet deletion
///
/// Usage:
/// ```dart
/// GoRouter(
///   refreshListenable: authStateNotifier,
///   redirect: (context, state) { ... },
/// )
/// ```
@lazySingleton
class AuthStateNotifier extends ChangeNotifier {
  AuthStateNotifier(
    this._walletManager,
    this._storage,
    this._db,
    this._walletRepo,
  );

  final WalletManager _walletManager;
  final SecureWalletStorage _storage;
  final MallowDatabase _db;
  final WalletRepository _walletRepo;

  bool _hasWallet = false;
  bool _hasCompletedOnboarding = false;
  bool _hasStaleKeychain = false;

  /// Whether user has created/imported a wallet.
  bool get hasWallet => _hasWallet;

  /// Whether user has completed full onboarding (wallet + PIN).
  bool get hasCompletedOnboarding => _hasCompletedOnboarding;

  /// Whether Keychain has a mnemonic but DB has no wallets.
  ///
  /// This happens on iOS when the app is uninstalled and reinstalled —
  /// Keychain data persists but the Drift database is wiped.
  bool get hasStaleKeychain => _hasStaleKeychain;

  /// Initialize state by checking storage and DB.
  ///
  /// Called once at app startup, and never on resume: the `!hasWallets` arm
  /// clears the wallet session keys and the `hasWallets` arm writes the
  /// recovery graph, so a foregrounding app would repeat both against live
  /// wallet state. Boot is the only moment nothing else is touching them.
  Future<void> initialize() async {
    // Check DB for wallets, then fallback to legacy storage check
    final hasWallets = await _db.hasAnyWallets();
    _hasWallet = hasWallets || await _walletManager.hasWallet();
    final onboardingCompleted = await _storage.loadOnboardingCompleted();
    _hasCompletedOnboarding = _hasWallet && onboardingCompleted;

    // Detect iOS Keychain/DB mismatch: Keychain thinks a wallet exists but
    // DB is empty. This happens after uninstall+reinstall on iOS (Keychain
    // persists, DB doesn't).
    if (!hasWallets && await _storage.hasWallet()) {
      // Check for wallet graph first (full recovery). The read throws rather
      // than answering "absent" when the keystore cannot be seen; that fails
      // the launch onto the boot error screen, whose Retry re-runs this — the
      // same outcome the DB key read already has on the same condition, and
      // far better than the else branch below acting on a false "nothing here".
      final graph = await _storage.loadAccountGraph();
      if (graph != null && graph.isNotEmpty) {
        _hasStaleKeychain = true;
      } else {
        // Fall back to legacy mnemonic check
        final mnemonic = await _storage.loadMnemonic();
        if (mnemonic != null && mnemonic.isNotEmpty) {
          _hasStaleKeychain = true;
        } else {
          // Nothing recoverable behind the wallet flag — clear only the
          // non-secret session keys so hasWallet() stops reporting one, and
          // send the user to onboarding. Never wipe secrets here: this
          // branch can also be reached through a transient Keychain misread
          // (graph and mnemonic both reading as absent for one launch), and
          // deleting the account graph would orphan the per-seed mnemonics
          // that are still in the vault.
          await _storage.clearWalletSessionKeys();
          _hasWallet = false;
          _hasCompletedOnboarding = false;
          _hasStaleKeychain = false;
        }
      }
    } else {
      _hasStaleKeychain = false;

      // Eager backfill: if DB has wallets but no graph in Keychain yet,
      // sync it now so existing users get recovery support on next reinstall.
      //
      // Only an absent graph is backfilled, never an unreadable one: the read
      // throws when the keystore cannot be seen, and "unknown" is not "none".
      // Skipping the backfill for this launch costs nothing — the next wallet
      // mutation syncs the graph anyway — while failing the launch here would
      // strand an install whose database already opened successfully.
      if (hasWallets) {
        String? graph;
        try {
          graph = await _storage.loadAccountGraph();
          if (graph == null || graph.isEmpty) {
            await _walletRepo.syncWalletGraph();
          }
        } catch (e) {
          debugPrint('[AuthStateNotifier] graph backfill check failed: $e');
        }
        // The restore reads the same blob, so it is handed this one rather
        // than repeating the read and its protected-data probe. A read that
        // threw leaves `graph` null — "unknown", not "none" — and handing that
        // over as an absent graph would have it conclude nothing is dormant;
        // an absent graph has nothing dormant in it either. Both skip.
        if (graph != null && graph.isNotEmpty) {
          await _restoreDormantOnce(graph);
        }
      }
    }
  }

  Future<void>? _dormantRestore;

  /// Bring back wallets the recovery graph lists but the database lacks —
  /// once per process, before routing, never blocking boot on a failure.
  /// Silent to the user; counts go to Sentry so a "wallets came back" report
  /// can be explained. [graphJson] is the blob the caller has already read, so
  /// this costs no second Keychain read.
  /// See [WalletRepository.restoreDormantFromGraph].
  ///
  /// A second [initialize] joins the in-flight future rather than skipping it.
  /// A skip returns while the first restore is still writing rows, pruning the
  /// graph and deleting vault entries, so routing would resume over a
  /// half-finished restore.
  Future<void> _restoreDormantOnce(String graphJson) =>
      _dormantRestore ??= _runDormantRestore(graphJson);

  Future<void> _runDormantRestore(String graphJson) async {
    try {
      final result = await _walletRepo.restoreDormantFromGraph(
        graphJson: graphJson,
      );
      if (!result.isEmpty) {
        // Not awaited: this runs inside boot, before the first route is
        // resolved, and the report is a platform-channel round trip. Blocking
        // routing on telemetry delays the splash for no user-visible gain.
        unawaited(
          SentryService.captureMessage(
            'dormant restore: ${result.seedPhrasesRestored} seeds, '
            '${result.walletsRestored} wallets restored, '
            '${result.duplicatesDropped} duplicates dropped, '
            '${result.skipped} skipped'
            // Why it matters on its own: this skip is correct for one launch
            // and permanent if that live seed never reads again — every
            // dormant seed then waits forever with nothing to say why.
            '${result.liveSeedUnreadable ? ', live seed unreadable' : ''}',
          ),
        );
      }
    } catch (e) {
      debugPrint('[AuthStateNotifier] dormant restore failed: $e');
    }
  }

  /// Called when wallet creation/import completes.
  void onWalletCreated() {
    _hasWallet = true;
    notifyListeners();
  }

  /// Called when onboarding completes (PIN set or skipped).
  Future<void> onOnboardingCompleted() async {
    await _storage.storeOnboardingCompleted();
    _hasCompletedOnboarding = true;
    notifyListeners();
  }

  /// Clear stale keychain flag after recovery completes.
  void clearStaleKeychain() {
    _hasStaleKeychain = false;
  }

  /// Called when user logs out or deletes wallet.
  ///
  /// Best-effort by design: the in-memory flags go first and listeners are
  /// notified whatever the storage delete does. The delete is a raw Keychain
  /// call, and an unguarded throw used to skip [notifyListeners] — leaving the
  /// router on a signed-in route and the caller's spinner running on a device
  /// whose wallets are already gone.
  Future<void> onLogout() async {
    _hasWallet = false;
    _hasCompletedOnboarding = false;
    try {
      await _storage.deleteOnboardingCompleted();
    } catch (e) {
      debugPrint('[AuthStateNotifier] onboarding flag delete failed: $e');
    }
    notifyListeners();
  }
}
