import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/pin_hasher.dart';

import '../../shared/utils/chain.dart';
import '../observability/app_logger.dart';

/// Secure storage for sensitive wallet data.
///
/// Mnemonic and private-key paths are routed through [MnemonicVault], which
/// stores them in an OS keychain/keystore entry at the device-unlock tier —
/// the same protection as the DB encryption key. Reads/writes do NOT surface
/// an OS biometric/passcode prompt; the user-facing gate is the app's own
/// dual-lock (PIN and/or biometric app-lock), see AppLockBloc.
///
/// All other fields use [FlutterSecureStorage]: the iOS Keychain, or on
/// Android AES-GCM ciphertext under an RSA-OAEP-wrapped Keystore key — see
/// [_androidOptions]. `EncryptedSharedPreferences` is not used.
///
/// SECURITY: Never log or expose the values stored here.
@lazySingleton
class SecureWalletStorage {
  SecureWalletStorage(this._storage, this._vault)
    : _pinHasher = const PinHasher();

  /// Test-only constructor that injects a [PinHasher] (e.g. one with a
  /// deterministic RNG running the KDF inline) so PIN tests stay fast and
  /// reproducible.
  @visibleForTesting
  SecureWalletStorage.withHasher(this._storage, this._vault, this._pinHasher);

  final FlutterSecureStorage _storage;
  final MnemonicVault _vault;
  final PinHasher _pinHasher;

  // Storage keys
  static const _mnemonicKey = 'mallow_mnemonic';
  static const _authTokenKey = 'mallow_auth_token';
  static const _pinKey = 'mallow_pin';
  static const _biometricEnabledKey = 'mallow_biometric_enabled';
  static const _loginTokenKey = 'mallow_login_token';
  static const _sessionExpiryKey = 'mallow_session_expiry';
  static const _selectedWalletKey = 'mallow_selected_wallet';
  static const _selectedAccountKey = 'mallow_selected_account';
  static const _selectedWalletIdKey = 'mallow_selected_wallet_id';
  static const _loginModeKey = 'mallow_login_mode';
  static const _activeProfileIdKey = 'mallow_active_profile_id';
  static const _onboardingCompletedKey = 'mallow_onboarding_completed';
  static const _accountGraphKey = 'mallow_account_graph';
  static const _failedPinAttemptsKey = 'mallow_failed_pin_attempts';
  static const _pinCooldownUntilKey = 'mallow_pin_cooldown_until';
  static const _txAuthThresholdUsdKey = 'mallow_tx_auth_threshold_usd';
  static const _txAuthEnabledKey = 'mallow_tx_auth_enabled';

  // iOS options: Only accessible when device is unlocked, doesn't migrate to new device
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
    accountName: 'mallow_wallet',
  );

  // Android options: AES-GCM data encryption under an RSA-OAEP-wrapped Keystore
  // key (the v10 default). The old `encryptedSharedPreferences: true` is gone —
  // Google deprecated Jetpack Security, so v10 dropped the flag (it is now
  // ignored) and reads legacy EncryptedSharedPreferences entries through
  // migrateOnAlgorithmChange instead.
  //
  // migrateOnAlgorithmChange is the load-bearing one here: pre-vault installs
  // still hold their mnemonic in this store (see _vaultReadWithMigration), so
  // it is what re-encrypts those entries to the new ciphers rather than losing
  // them. It defaults to true; pinned explicitly so a future default flip can't
  // silently strand a seed.
  //
  // resetOnError recreates the store if its Keystore master key gets
  // invalidated/corrupted, instead of throwing PlatformException(write_failed).
  static const _androidOptions = AndroidOptions(
    migrateOnAlgorithmChange: true,
    resetOnError: true,
  );

  /// Store the wallet mnemonic securely.
  ///
  /// SECURITY: Written to the OS keychain/keystore at the device-unlock tier.
  Future<void> storeMnemonic(String mnemonic) async {
    await _vault.write(_mnemonicKey, mnemonic);
  }

  /// Load the wallet mnemonic.
  ///
  /// Returns null if no mnemonic is stored. Lazily migrates legacy
  /// [FlutterSecureStorage] items on first call after an app update. Does not
  /// surface an OS authentication prompt — the app-lock is the gate.
  Future<String?> loadMnemonic() async {
    return _vaultReadWithMigration(_mnemonicKey);
  }

  /// Delete the stored mnemonic from both vault and legacy storage.
  Future<void> deleteMnemonic() async {
    await Future.wait([
      _vault.delete(_mnemonicKey),
      _storage.delete(
        key: _mnemonicKey,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      ),
    ]);
  }

  /// Store the authentication token.
  Future<void> storeAuthToken(String token) async {
    await _storage.write(
      key: _authTokenKey,
      value: token,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Load the authentication token.
  Future<String?> loadAuthToken() async {
    return _storage.read(
      key: _authTokenKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Delete the authentication token.
  Future<void> deleteAuthToken() async {
    await _storage.delete(
      key: _authTokenKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Store the app lock PIN as an Argon2id hash (`v1$salt$hash`).
  ///
  /// SECURITY: The plaintext PIN is never written to disk — only its salted,
  /// memory-hard hash. See [PinHasher].
  Future<void> storePinHash(String pin) async {
    final encoded = await _pinHasher.hash(pin);
    await _storage.write(
      key: _pinKey,
      value: encoded,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Load the raw stored PIN value (an encoded `v1$...` hash, or a legacy
  /// plaintext PIN that predates hashing). Prefer [verifyPin] / [hasPin] —
  /// this is exposed only for callers that need to detect presence.
  Future<String?> loadPin() async {
    return _storage.read(
      key: _pinKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Verify [pin] against the stored PIN.
  ///
  /// Returns false when no PIN is set. Legacy plaintext PINs (written before
  /// hashing shipped) are transparently re-hashed on the first correct entry,
  /// so existing users are upgraded without being re-prompted.
  Future<bool> verifyPin(String pin) async {
    final stored = await loadPin();
    if (stored == null || stored.isEmpty) return false;

    if (PinHasher.isEncoded(stored)) {
      return _pinHasher.verify(pin, stored);
    }

    // Legacy plaintext PIN — verify by equality, then migrate to a hash.
    if (stored == pin) {
      await storePinHash(pin);
      return true;
    }
    return false;
  }

  /// Delete the app lock PIN.
  Future<void> deletePin() async {
    await _storage.delete(
      key: _pinKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Check if a PIN has been set.
  Future<bool> hasPin() async {
    final pin = await loadPin();
    return pin != null && pin.isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // Failed-PIN lockout (counter + cooldown)
  // ---------------------------------------------------------------------------

  /// Persist the running failed-PIN attempt counter so a force-close does not
  /// reset progression through the cooldown ladder.
  Future<void> storeFailedPinAttempts(int attempts) =>
      _write(_failedPinAttemptsKey, attempts.toString());

  /// Load the persisted failed-PIN counter. Returns 0 if absent or malformed.
  Future<int> loadFailedPinAttempts() async {
    final value = await _read(_failedPinAttemptsKey);
    if (value == null) return 0;
    return int.tryParse(value) ?? 0;
  }

  /// Persist the active cooldown deadline as a UTC ISO-8601 string.
  Future<void> storePinCooldownUntil(DateTime until) =>
      _write(_pinCooldownUntilKey, until.toUtc().toIso8601String());

  /// Load the persisted cooldown deadline (UTC). Returns null if absent or
  /// malformed.
  Future<DateTime?> loadPinCooldownUntil() async {
    final value = await _read(_pinCooldownUntilKey);
    if (value == null) return null;
    return DateTime.tryParse(value);
  }

  /// Delete only the persisted cooldown deadline (leaving the counter intact).
  /// Used at startup when the persisted cooldown has already elapsed.
  Future<void> deletePinCooldownUntil() => _delete(_pinCooldownUntilKey);

  /// Delete only the persisted failed-PIN counter.
  Future<void> deleteFailedPinAttempts() => _delete(_failedPinAttemptsKey);

  /// Clear both the failed-PIN counter and any active cooldown deadline.
  Future<void> clearPinLockout() async {
    await Future.wait([deleteFailedPinAttempts(), deletePinCooldownUntil()]);
  }

  /// Store that onboarding has been completed.
  Future<void> storeOnboardingCompleted() =>
      _write(_onboardingCompletedKey, 'true');

  /// Check if onboarding has been completed.
  Future<bool> loadOnboardingCompleted() async {
    final value = await _read(_onboardingCompletedKey);
    return value == 'true';
  }

  /// Delete the onboarding completed flag.
  Future<void> deleteOnboardingCompleted() => _delete(_onboardingCompletedKey);

  /// Store biometric enabled preference.
  Future<void> storeBiometricEnabled(bool enabled) async {
    await _storage.write(
      key: _biometricEnabledKey,
      value: enabled.toString(),
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Load biometric enabled preference.
  Future<bool> loadBiometricEnabled() async {
    final value = await _storage.read(
      key: _biometricEnabledKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
    return value == 'true';
  }

  /// Check if a wallet exists (account graph, mnemonic, or social wallet address).
  Future<bool> hasWallet() async {
    final graph = await loadAccountGraph();
    if (graph != null && graph.isNotEmpty) return true;

    final mnemonic = await loadMnemonic();
    if (mnemonic != null && mnemonic.isNotEmpty) return true;

    // Social wallets have no mnemonic — check for a stored address instead.
    final selected = await loadSelectedWallet();
    return selected != null && selected.isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // Account Graph (full account/wallet structure for recovery)
  // ---------------------------------------------------------------------------

  /// Store the account graph JSON blob for recovery after reinstall.
  Future<void> storeAccountGraph(String json) => _write(_accountGraphKey, json);

  /// Load the account graph JSON blob.
  Future<String?> loadAccountGraph() => _read(_accountGraphKey);

  /// Delete the account graph.
  Future<void> deleteAccountGraph() => _delete(_accountGraphKey);

  // ---------------------------------------------------------------------------
  // Login Token Methods
  // ---------------------------------------------------------------------------

  /// Store the login token received from API login response.
  ///
  /// This token is sent with subsequent API requests for authentication.
  /// Handles iOS Keychain `-25299` (duplicate item) by deleting first then
  /// retrying — this can happen when concurrent login flows race.
  Future<void> storeLoginToken(String token) async {
    try {
      await _storage.write(
        key: _loginTokenKey,
        value: token,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
    } on PlatformException catch (e) {
      if (e.code == '-25299') {
        AppLogger.warn(
          'SecureStorage',
          'Keychain duplicate item — deleting and retrying',
        );
        await _storage.delete(
          key: _loginTokenKey,
          iOptions: _iosOptions,
          aOptions: _androidOptions,
        );
        await _storage.write(
          key: _loginTokenKey,
          value: token,
          iOptions: _iosOptions,
          aOptions: _androidOptions,
        );
      } else {
        rethrow;
      }
    }
  }

  /// Load the login token.
  Future<String?> loadLoginToken() async {
    return _storage.read(
      key: _loginTokenKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Delete the login token.
  Future<void> deleteLoginToken() async {
    await _storage.delete(
      key: _loginTokenKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  // ---------------------------------------------------------------------------
  // Session Expiry Methods
  // ---------------------------------------------------------------------------

  /// Store the session expiry timestamp (ISO 8601 string).
  Future<void> storeSessionExpiry(String expiresAt) async {
    await _storage.write(
      key: _sessionExpiryKey,
      value: expiresAt,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Load the session expiry timestamp.
  Future<String?> loadSessionExpiry() async {
    return _storage.read(
      key: _sessionExpiryKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Delete the session expiry.
  Future<void> deleteSessionExpiry() async {
    await _storage.delete(
      key: _sessionExpiryKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  // ---------------------------------------------------------------------------
  // Selected Wallet Methods (Multi-Wallet Support)
  // ---------------------------------------------------------------------------

  /// Store the selected wallet address.
  ///
  /// Used when user has multiple wallets and selects one as active.
  Future<void> storeSelectedWallet(String address) async {
    await _storage.write(
      key: _selectedWalletKey,
      value: address,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Load the selected wallet address.
  Future<String?> loadSelectedWallet() async {
    return _storage.read(
      key: _selectedWalletKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Delete the selected wallet preference.
  Future<void> deleteSelectedWallet() async {
    await _storage.delete(
      key: _selectedWalletKey,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
  }

  // ---------------------------------------------------------------------------
  // Per-SeedPhrase Mnemonic Methods
  // ---------------------------------------------------------------------------

  /// Store a mnemonic for a specific seed phrase.
  Future<void> storeMnemonicForSeedPhrase(
    String seedPhraseId,
    String mnemonic,
  ) => _vault.write('mallow_mnemonic_seed_$seedPhraseId', mnemonic);

  /// Load the mnemonic for a specific seed phrase.
  ///
  /// Lazily migrates legacy items. Does not surface an OS authentication
  /// prompt — the app-lock is the gate.
  Future<String?> loadMnemonicForSeedPhrase(String seedPhraseId) =>
      _vaultReadWithMigration('mallow_mnemonic_seed_$seedPhraseId');

  /// Delete the mnemonic for a specific seed phrase.
  Future<void> deleteMnemonicForSeedPhrase(String seedPhraseId) async {
    final k = 'mallow_mnemonic_seed_$seedPhraseId';
    await Future.wait([
      _vault.delete(k),
      _storage.delete(key: k, iOptions: _iosOptions, aOptions: _androidOptions),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Per-Account Mnemonic Methods (Legacy — kept for recovery migration)
  // ---------------------------------------------------------------------------

  /// Load the mnemonic for a specific account (legacy key format).
  Future<String?> loadMnemonicForAccount(String accountId) =>
      _read('mallow_mnemonic_$accountId');

  // ---------------------------------------------------------------------------
  // Per-Wallet Private Key Methods (Imported Keys)
  // ---------------------------------------------------------------------------

  /// Store a private key for an imported wallet.
  Future<void> storePrivateKey(String walletId, String key) =>
      _vault.write('mallow_pk_$walletId', key);

  /// Load a private key for an imported wallet.
  ///
  /// Lazily migrates legacy items. Does not surface an OS authentication
  /// prompt — the app-lock is the gate.
  Future<String?> loadPrivateKey(String walletId) =>
      _vaultReadWithMigration('mallow_pk_$walletId');

  /// Delete a private key for an imported wallet.
  Future<void> deletePrivateKey(String walletId) async {
    final k = 'mallow_pk_$walletId';
    await Future.wait([
      _vault.delete(k),
      _storage.delete(key: k, iOptions: _iosOptions, aOptions: _androidOptions),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Wallet-Sig Cookie Cache (Per-Address JWT)
  // ---------------------------------------------------------------------------

  /// Store the wallet-sig JWT cookie for a wallet address.
  ///
  /// Used by dual-signature auth flow to skip re-signing if a valid JWT
  /// already exists for this address (key: wallet-sig-{address}).
  Future<void> storeWalletSigCookie(String address, String jwt) =>
      _write('mallow_wallet_sig_$address', jwt);

  /// Load the cached wallet-sig JWT for a wallet address.
  ///
  /// Returns null if no JWT is cached for this address.
  Future<String?> loadWalletSigCookie(String address) =>
      _read('mallow_wallet_sig_$address');

  /// Delete the wallet-sig JWT cache for a wallet address.
  Future<void> deleteWalletSigCookie(String address) =>
      _delete('mallow_wallet_sig_$address');

  /// Delete every cached `mallow_wallet_sig_*` JWT, regardless of address.
  ///
  /// Used on logout so a subsequent re-login cannot reuse stale wallet-sig
  /// JWTs from a prior session.
  Future<void> deleteAllWalletSigCookies() async {
    const prefix = 'mallow_wallet_sig_';
    final all = await _storage.readAll(
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
    final keys = all.keys.where((k) => k.startsWith(prefix)).toList();
    await Future.wait(keys.map(_delete));
  }

  // ---------------------------------------------------------------------------
  // Selected Account/Wallet ID Methods (Multi-Account)
  // ---------------------------------------------------------------------------

  /// Store the currently selected account ID.
  Future<void> storeSelectedAccountId(String id) =>
      _write(_selectedAccountKey, id);

  /// Load the currently selected account ID.
  Future<String?> loadSelectedAccountId() => _read(_selectedAccountKey);

  /// Delete the selected account ID.
  Future<void> deleteSelectedAccountId() => _delete(_selectedAccountKey);

  /// Store the active login mode (`account` | `profile`).
  Future<void> storeLoginMode(String mode) => _write(_loginModeKey, mode);

  /// Load the active login mode. Returns null when no session has been
  /// established yet (caller defaults to account mode).
  Future<String?> loadLoginMode() => _read(_loginModeKey);

  /// Delete the active login mode.
  Future<void> deleteLoginMode() => _delete(_loginModeKey);

  /// Store the active profile id (set only when logged in as a Profile).
  Future<void> storeActiveProfileId(String id) =>
      _write(_activeProfileIdKey, id);

  /// Load the active profile id. Null when logged in as an Account.
  Future<String?> loadActiveProfileId() => _read(_activeProfileIdKey);

  /// Delete the active profile id.
  Future<void> deleteActiveProfileId() => _delete(_activeProfileIdKey);

  /// Store the currently selected wallet ID (UUID).
  Future<void> storeSelectedWalletId(String id) =>
      _write(_selectedWalletIdKey, id);

  /// Load the currently selected wallet ID (UUID).
  Future<String?> loadSelectedWalletId() => _read(_selectedWalletIdKey);

  /// Delete the selected wallet ID.
  Future<void> deleteSelectedWalletId() => _delete(_selectedWalletIdKey);

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Read from the biometric vault, falling back to legacy [FlutterSecureStorage]
  /// on a cache miss and migrating the value on first access.
  Future<String?> _vaultReadWithMigration(String key) async {
    final vaultValue = await _vault.read(key);
    if (vaultValue != null) return vaultValue;

    // Legacy item present from before the vault was introduced.
    final legacy = await _storage.read(
      key: key,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
    if (legacy == null) return null;

    // Migrate: write to vault and delete from legacy storage.
    await _vault.write(key, legacy);
    await _storage.delete(
      key: key,
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
    return legacy;
  }

  Future<void> _write(String key, String value) => _storage.write(
    key: key,
    value: value,
    iOptions: _iosOptions,
    aOptions: _androidOptions,
  );

  Future<String?> _read(String key) =>
      _storage.read(key: key, iOptions: _iosOptions, aOptions: _androidOptions);

  Future<void> _delete(String key) => _storage.delete(
    key: key,
    iOptions: _iosOptions,
    aOptions: _androidOptions,
  );

  // ---------------------------------------------------------------------------
  // Transaction Step-Up Auth Threshold
  // ---------------------------------------------------------------------------

  /// Store the USD threshold above which transaction signing demands step-up
  /// auth (biometric / PIN). See [TransactionAuthGate].
  Future<void> storeTransactionAuthThresholdUsd(double usd) =>
      _write(_txAuthThresholdUsdKey, usd.toString());

  /// Load the configured step-up-auth USD threshold. Returns null when the
  /// user has never changed it — callers fall back to the built-in default
  /// (`kTransactionAuthThresholdUsd`).
  Future<double?> loadTransactionAuthThresholdUsd() async {
    final value = await _read(_txAuthThresholdUsdKey);
    if (value == null) return null;
    return double.tryParse(value);
  }

  /// Store whether transaction step-up auth is enabled at all. When false,
  /// [TransactionAuthGate] never prompts regardless of the threshold.
  Future<void> storeTransactionAuthEnabled(bool enabled) =>
      _write(_txAuthEnabledKey, enabled.toString());

  /// Load whether transaction step-up auth is enabled. Defaults to `false`
  /// (off) until the user opts in via Settings → Security & Privacy.
  Future<bool> loadTransactionAuthEnabled() async {
    final value = await _read(_txAuthEnabledKey);
    return value == 'true';
  }

  // ---------------------------------------------------------------------------
  // Network Preferences
  // ---------------------------------------------------------------------------

  /// Key for a per-[scope] network-enabled flag. The key embeds the chain's
  /// wire value ([Chain.toDbString]), which is the format already on device —
  /// changing it would orphan every stored preference. A null [scope] (Account
  /// session) keeps the original unscoped key so existing device-local settings
  /// survive the upgrade; a Profile session scopes by its id so each profile —
  /// and the account scope — stay isolated.
  String _networkEnabledKey(Chain chain, String? scope) {
    final network = chain.toDbString();
    return scope == null
        ? 'mallow_network_enabled_$network'
        : 'mallow_network_enabled_${scope}_$network';
  }

  /// Store whether [chain] is enabled for [scope]. Only Tezos and Ethereum are
  /// togglable — Solana is always active.
  Future<void> storeNetworkEnabled(
    Chain chain,
    bool enabled, {
    String? scope,
  }) => _write(_networkEnabledKey(chain, scope), enabled.toString());

  /// Load whether [chain] is enabled for [scope]. Defaults to true if unset.
  Future<bool> loadNetworkEnabled(Chain chain, {String? scope}) async {
    final value = await _read(_networkEnabledKey(chain, scope));
    return value == null || value == 'true';
  }

  // ---------------------------------------------------------------------------
  // Database Encryption Key
  // ---------------------------------------------------------------------------

  static const _dbEncryptionKeyKey = 'mallow_db_encryption_key';

  /// Read attempts before concluding the key is really absent while a
  /// database file exists on disk. iOS can transiently report an existing
  /// Keychain item as "not found" (locked-state and prewarming glitches), and
  /// wrongly concluding "absent" re-keys — and thereby loses — the DB.
  static const _dbKeyReadAttempts = 3;
  static const _dbKeyReadRetryDelay = Duration(milliseconds: 200);

  /// Attempts to see iOS/macOS protected data become available before giving
  /// up on the launch. Kept short: on a locked-device background launch it
  /// will not become available, and a foreground launch implies unlocked.
  static const _protectedDataAttempts = 4;
  static const _protectedDataRetryDelay = Duration(milliseconds: 250);

  /// Store the database encryption key.
  Future<void> storeDbEncryptionKey(String hexKey) =>
      _write(_dbEncryptionKeyKey, hexKey);

  /// Load the database encryption key.
  Future<String?> loadDbEncryptionKey() => _read(_dbEncryptionKeyKey);

  /// In-flight bootstrap, so concurrent cold-start callers share one result
  /// instead of racing to generate/store separate keys.
  Completer<String>? _dbEncryptionKeyBootstrap;

  /// Resolve the DB encryption key, generating and persisting one only when
  /// this is genuinely the first run.
  ///
  /// [dbFileExists] is the safety interlock: when an encrypted database is
  /// already on disk, a key must have existed, so a null read is treated as a
  /// transient keystore fault (retried) rather than "first run". Minting a
  /// fresh key against an existing file makes that file undecryptable — the
  /// bug that silently destroyed wallet metadata and forced users through the
  /// Restore screen.
  ///
  /// Concurrent callers receive the same key — the first call wins and any
  /// callers that arrive while it is in flight await the same future.
  Future<String> getOrCreateDbEncryptionKey({required bool dbFileExists}) {
    final inFlight = _dbEncryptionKeyBootstrap;
    if (inFlight != null) return inFlight.future;
    final completer = Completer<String>();
    _dbEncryptionKeyBootstrap = completer;
    () async {
      try {
        completer.complete(await _resolveDbEncryptionKey(dbFileExists));
      } catch (e, st) {
        _dbEncryptionKeyBootstrap = null;
        completer.completeError(e, st);
      }
    }();
    return completer.future;
  }

  Future<String> _resolveDbEncryptionKey(bool dbFileExists) async {
    await _requireProtectedData();

    var hexKey = await _readDbKeyAnySource();

    // An encrypted DB exists, so a key must have existed. Retry before
    // concluding it is gone — a transient "not found" must never re-key.
    for (
      var attempt = 1;
      hexKey == null && dbFileExists && attempt < _dbKeyReadAttempts;
      attempt++
    ) {
      await Future<void>.delayed(_dbKeyReadRetryDelay);
      hexKey = await _readDbKeyAnySource();
    }
    if (hexKey != null) return hexKey;

    if (dbFileExists) {
      // Genuine loss (e.g. Android resetOnError wiped the store and the
      // vault backup predates this build). Mint a replacement so the app
      // stays usable; the open path quarantines — never deletes — the old
      // file, and the recovery screen restores wallets from the Keychain
      // account graph.
      AppLogger.warn(
        'SecureStorage',
        'DB encryption key missing from both stores while a database file '
            'exists; minting a replacement. The old file will be quarantined.',
      );
    }

    final random = Random.secure();
    final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
    final minted = keyBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    // The primary write must succeed — handing out a key that exists only in
    // memory would create a database no later launch can decrypt.
    await storeDbEncryptionKey(minted);
    await _backfillDbKeyBackup(minted);
    return minted;
  }

  /// Read the key from the primary store, falling back to the vault backup.
  /// Heals whichever copy is missing when the other is present.
  ///
  /// A [MnemonicVault] read error propagates when the primary came back empty:
  /// with the
  /// primary unreadable, failing the launch is safer than concluding "no key"
  /// and re-keying an existing database.
  Future<String?> _readDbKeyAnySource() async {
    final primary = await loadDbEncryptionKey();
    if (primary != null) {
      await _backfillDbKeyBackup(primary);
      return primary;
    }
    final backup = await _vault.read(_dbEncryptionKeyKey);
    if (backup == null) return null;
    try {
      await storeDbEncryptionKey(backup);
    } catch (e) {
      // The key itself is usable; a failed heal just means the next launch
      // reads the backup again.
      AppLogger.warn(
        'SecureStorage',
        'Failed to re-write the DB key to the primary store: $e',
      );
    }
    return backup;
  }

  /// Write the vault backup copy of the DB key if it is absent. Best-effort:
  /// the vault write is delete-then-add on iOS, so this only runs when no
  /// backup exists — never as a replacement — and failures are swallowed.
  Future<void> _backfillDbKeyBackup(String hexKey) async {
    try {
      final existing = await _vault.read(_dbEncryptionKeyKey);
      if (existing == null) {
        await _vault.write(_dbEncryptionKeyKey, hexKey);
      }
    } catch (e) {
      AppLogger.warn('SecureStorage', 'DB key backup maintenance failed: $e');
    }
  }

  /// Block until iOS/macOS protected data is available, or fail the launch.
  ///
  /// Every Keychain item here uses the when-unlocked tier, and iOS can report
  /// an existing-but-inaccessible item as *not found* — which reads as "no
  /// key". Never read (or mint) while the keystore is in that state. Failing
  /// is fatal for this launch (drift's LazyDatabase caches a failed open):
  /// headless background launches while locked die here harmlessly, and a
  /// foreground launch implies an unlocked device.
  Future<void> _requireProtectedData() async {
    if (kIsWeb) return;
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.iOS && platform != TargetPlatform.macOS) {
      return;
    }
    for (var attempt = 0; attempt < _protectedDataAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_protectedDataRetryDelay);
      }
      final available = await _storage.isCupertinoProtectedDataAvailable();
      if (available ?? true) return;
    }
    throw const DbEncryptionKeyUnavailable();
  }

  // ---------------------------------------------------------------------------
  // Maintenance
  // ---------------------------------------------------------------------------

  /// Clear all stored data (logout/reset).
  ///
  /// Pass [seedPhraseIds], [walletIds], and [walletAddresses] to also delete
  /// their dynamic keys.
  ///
  /// SECURITY: This permanently deletes mnemonics and private keys.
  /// Ensure the user has backed up their seed phrase before calling this.
  // ---------------------------------------------------------------------------
  // Ledger Device IDs
  // ---------------------------------------------------------------------------

  static const _ledgerDevicePrefix = 'mallow_ledger_device_';

  /// Store the BLE device ID for a Ledger hardware wallet (for reconnection).
  Future<void> storeLedgerDeviceId(String walletId, String deviceId) =>
      _write('$_ledgerDevicePrefix$walletId', deviceId);

  /// Load the stored BLE device ID for a Ledger hardware wallet.
  Future<String?> loadLedgerDeviceId(String walletId) =>
      _read('$_ledgerDevicePrefix$walletId');

  /// Delete the stored BLE device ID for a Ledger hardware wallet.
  Future<void> deleteLedgerDeviceId(String walletId) =>
      _delete('$_ledgerDevicePrefix$walletId');

  // ---------------------------------------------------------------------------
  // Clear All
  // ---------------------------------------------------------------------------

  Future<void> clearAll({
    List<String> seedPhraseIds = const [],
    List<String> walletIds = const [],
  }) async {
    await Future.wait([
      // Legacy single-mnemonic key
      deleteMnemonic(),
      deleteAuthToken(),
      deletePin(),
      deleteLoginToken(),
      deleteSessionExpiry(),
      deleteSelectedWallet(),
      deleteSelectedAccountId(),
      deleteSelectedWalletId(),
      deleteLoginMode(),
      deleteActiveProfileId(),
      deleteOnboardingCompleted(),
      deleteAccountGraph(),
      _delete(_biometricEnabledKey),
      _delete(_txAuthThresholdUsdKey),
      _delete(_txAuthEnabledKey),
      clearPinLockout(),
      // Per-seed-phrase mnemonics
      ...seedPhraseIds.map(deleteMnemonicForSeedPhrase),
      // Per-wallet private keys
      ...walletIds.map(deletePrivateKey),
      // Per-wallet sig cookies (catches orphan keys for addresses that
      // were already removed before reset).
      deleteAllWalletSigCookies(),
      // Per-wallet Ledger device IDs
      ...walletIds.map(deleteLedgerDeviceId),
      // Per-session Active Networks flags. Swept by prefix rather than by a
      // fixed key list because Profile sessions scope the key by profile id
      // (`mallow_network_enabled_${scope}_$network`), so the set is unbounded.
      // Without this, "Reset app" leaves the previous identity's enabled
      // chains applied to the wallet the user re-onboards with.
      deleteAllNetworkEnabledFlags(),
    ]);
  }

  /// Deletes every `mallow_network_enabled_*` flag across all session scopes.
  ///
  /// Used on reset — see [clearAll]. Modelled on
  /// [deleteAllWalletSigCookies]: the scoped key space cannot be enumerated
  /// without reading the store, since the scope is a profile id.
  Future<void> deleteAllNetworkEnabledFlags() async {
    const prefix = 'mallow_network_enabled_';
    final all = await _storage.readAll(
      iOptions: _iosOptions,
      aOptions: _androidOptions,
    );
    final keys = all.keys.where((k) => k.startsWith(prefix)).toList();
    await Future.wait(keys.map(_delete));
  }

  /// Delete only the non-secret session/selection keys that make [hasWallet]
  /// report a wallet: selected wallet/account pointers, login session, and
  /// the onboarding flag.
  ///
  /// Used when boot finds Keychain wallet flags with nothing recoverable
  /// behind them. Deliberately does NOT touch mnemonics, private keys, the
  /// account graph, the PIN, or the DB key — that state of affairs can also
  /// be produced by a transient Keychain misread, and destroying secrets on a
  /// misread is unrecoverable. Everything deleted here is re-creatable by a
  /// fresh onboarding or login.
  Future<void> clearWalletSessionKeys() async {
    await Future.wait([
      deleteSelectedWallet(),
      deleteSelectedAccountId(),
      deleteSelectedWalletId(),
      deleteLoginMode(),
      deleteActiveProfileId(),
      deleteOnboardingCompleted(),
      deleteLoginToken(),
      deleteSessionExpiry(),
      deleteAllWalletSigCookies(),
    ]);
  }
}

/// Thrown when the DB encryption key cannot be read because the OS keystore
/// is not available (iOS/macOS protected data unavailable — the device has
/// not been unlocked). Fatal for this launch: drift's LazyDatabase caches a
/// failed open, so recovery is a relaunch. Users should never see this — a
/// foreground launch implies an unlocked device; locked background launches
/// die on it harmlessly instead of corrupting the key.
class DbEncryptionKeyUnavailable implements Exception {
  const DbEncryptionKeyUnavailable();

  @override
  String toString() =>
      'Secure storage is locked. Unlock your device, then close and reopen '
      'the app.';
}
