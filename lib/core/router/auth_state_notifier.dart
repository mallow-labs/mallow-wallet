import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../crypto/wallet_manager.dart';
import '../database/database.dart';
import '../security/secure_storage.dart';
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
  /// Should be called once at app startup.
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
      // Check for wallet graph first (full recovery)
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
      if (hasWallets) {
        final graph = await _storage.loadAccountGraph();
        if (graph == null || graph.isEmpty) {
          await _walletRepo.syncWalletGraph();
        }
      }
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
  Future<void> onLogout() async {
    _hasWallet = false;
    _hasCompletedOnboarding = false;
    await _storage.deleteOnboardingCompleted();
    notifyListeners();
  }

  /// Refresh state from storage.
  ///
  /// Useful after app resume or state uncertainty.
  Future<void> refresh() async {
    final previousHasWallet = _hasWallet;
    final previousCompleted = _hasCompletedOnboarding;

    await initialize();

    // Only notify if state actually changed
    if (_hasWallet != previousHasWallet ||
        _hasCompletedOnboarding != previousCompleted) {
      notifyListeners();
    }
  }
}
