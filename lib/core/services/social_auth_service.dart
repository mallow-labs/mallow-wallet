import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:web3auth_flutter/enums.dart';
import 'package:web3auth_flutter/input.dart';
import 'package:web3auth_flutter/web3auth_flutter.dart';

import '../../shared/utils/chain.dart' show Chain;
import '../config/environment.dart';
import '../crypto/derivation.dart';
import '../crypto/exceptions.dart';
import '../models/account.dart';
import '../observability/app_logger.dart';
import 'wallet_repository.dart';

/// Result of a social sign-in.
///
/// Carries no key material: the keys reach secure storage by direct call into
/// [WalletRepository.addSocialAccount] and never travel on the broadcast
/// stream, whose events are observable app-wide.
class SocialAuthResult {
  SocialAuthResult({
    required this.wallet,
    required this.provider,
    required this.existed,
  });

  /// The account's **Solana** row — the one the app selects and signs with.
  final WalletInfo wallet;

  /// The social provider used: 'google' or 'apple'.
  final String provider;

  /// Whether this identity already had a social account on this device, i.e.
  /// this login completed/refreshed it rather than creating it.
  final bool existed;
}

/// The chain keys and addresses one Web3Auth login yields.
///
/// Hand-written (not freezed) with a redacted [toString]: a generated one
/// prints every field, and `debugPrint` is not stripped from release builds —
/// its output reaches the platform log (logcat / OSLog), where anything
/// printed is readable off the device. So it would put private keys there.
class _SocialKeys {
  const _SocialKeys({
    required this.solanaAddress,
    required this.solanaStoredKey,
    required this.ethereumAddress,
    required this.tezosAddress,
    required this.secpKeyHex,
  });

  final String solanaAddress;

  /// base58 of the 64-byte Ed25519 keypair — the imported-key storage format.
  final String solanaStoredKey;

  final String ethereumAddress;
  final String tezosAddress;

  /// Normalized secp256k1 key hex. Stored as-is for Ethereum, and re-used as
  /// the Tezos Ed25519 seed (Web3Auth's Tezos convention), so a leak of one
  /// exposes both chains.
  final String secpKeyHex;

  @override
  String toString() =>
      '_SocialKeys(solana: $solanaAddress, ethereum: $ethereumAddress, '
      'tezos: $tezosAddress, keys: <redacted>)';
}

/// Social sign-in via Web3Auth (MetaMask Embedded Wallets).
///
/// One OAuth login yields two private keys — secp256k1 and Ed25519 —
/// deterministic per (identity × Web3Auth project × Web3Auth network). From
/// those we derive one Solana, one Ethereum and one Tezos address and hand the
/// set to [WalletRepository.addSocialAccount], which stores each key in the
/// format the imported-key loaders already read. After that the login is over:
/// signing is local, so this service is not involved again unless a stored key
/// goes missing ([recoverKeysForAccount]).
///
/// That is the whole reason the Reown-era session machinery is gone — there is
/// no remote signer to keep aligned with the active wallet.
@lazySingleton
class SocialAuthService {
  static const _tag = 'SocialAuthService';

  /// Redirect the SDK returns to after the OAuth round-trip. The scheme is
  /// already registered on both platforms (AndroidManifest / Info.plist) and
  /// must be whitelisted on the Web3Auth dashboard. It carries a session
  /// handshake, never key material — the key is reconstructed inside the SDK
  /// from the MPC network.
  static const _redirectUrl = 'mallowwallet://auth';

  /// Broadcasts a [SocialAuthResult] the moment an account has been created or
  /// completed. Durable and lifecycle-independent: the OAuth round-trip
  /// backgrounds the app, and the sheet/screen that started the sign-in can be
  /// torn down before it returns. The caller's [signInWithGoogle] future is
  /// best-effort (it stops the in-flight spinner); this stream is the one that
  /// must not be missed. See the top-level listener in `app.dart`.
  final StreamController<SocialAuthResult> _signInController =
      StreamController<SocialAuthResult>.broadcast();

  /// Fires once per successful social sign-in with the account's Solana row.
  /// Key recovery ([recoverKeysForAccount]) deliberately does not publish —
  /// no account was created, and the listener would re-run the add-wallet flow.
  Stream<SocialAuthResult> get onSignInComplete => _signInController.stream;

  bool _initialized = false;

  /// In-flight init, shared by concurrent callers, so two racing sign-ins
  /// cannot each run `Web3AuthFlutter.init` and leave the native SDK holding a
  /// half-built second instance.
  Future<void>? _initFuture;

  /// Configure the native SDK. Deduplicated; lazy, so a user who never signs
  /// in socially never pays for it.
  ///
  /// 🛑 Exactly **once per process**, and [_initialized] is never cleared once
  /// set. `Web3AuthFlutter.init` constructs a new native `Web3Auth`, whose
  /// constructor builds a Segment analytics client keyed by a fixed write key.
  /// A successful `Web3Auth.logout()` — which every sign-in ends with — clears
  /// that manager's own init flag *without* shutting the Segment client down,
  /// so a second `init` builds a duplicate and the SDK throws
  /// `Duplicate analytics client created with tag: …`, failing the sign-in
  /// before the browser ever opens. Re-initializing gains nothing anyway: the
  /// options come from compile-time [Config], and `connectTo` works fine on an
  /// instance that has been logged out.
  ///
  /// [Web3AuthFlutter.initialize] is deliberately **not** called. It exists to
  /// restore a previous session, which we never want: we log out immediately
  /// after capturing keys, and on Android it throws when no session exists —
  /// which is our normal state. (On iOS it is a no-op; session restore there
  /// happens inside `init` itself.)
  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final pending = _initFuture;
    if (pending != null) {
      // Shares the outcome: a failure propagates to this caller too, and the
      // next call (with _initFuture cleared) starts a fresh attempt.
      await pending;
      if (_initialized) return;
    }
    final future = _doInitialize();
    _initFuture = future;
    try {
      await future;
    } finally {
      _initFuture = null;
    }
  }

  Future<void> _doInitialize() async {
    final clientId = Config.web3AuthClientId;
    if (clientId.isEmpty) {
      // Fail loud at the first login attempt rather than letting the native
      // SDK fail with an opaque error: without a client id there is no
      // Web3Auth project, so no key can be derived at all.
      throw StateError(
        'WEB3AUTH_CLIENT_ID is not configured — social sign-in cannot start. '
        'Set it in .env / --dart-define-from-file.',
      );
    }
    await Web3AuthFlutter.init(
      Web3AuthOptions(
        clientId: clientId,
        redirectUrl: _redirectUrl,
        web3AuthNetwork: web3AuthNetworkFor(Config.web3AuthNetwork),
      ),
    );
    _initialized = true;
    AppLogger.info(_tag, 'Web3Auth initialized on ${Config.web3AuthNetwork}');
  }

  /// Map [Config.web3AuthNetwork] onto the SDK enum.
  ///
  /// Pure and exhaustive on purpose: the network is part of the key
  /// derivation, so a silent fallback to the wrong one would hand every user a
  /// different address than the one their assets are on. `environment.dart`
  /// stays SDK-free by keeping the value a string, and this is where the two
  /// vocabularies meet.
  @visibleForTesting
  static Web3AuthNetwork web3AuthNetworkFor(String name) => switch (name) {
    'sapphire_devnet' => Web3AuthNetwork.sapphire_devnet,
    'sapphire_mainnet' => Web3AuthNetwork.sapphire_mainnet,
    _ => throw StateError(
      'Unsupported Web3Auth network "$name" — expected sapphire_devnet or '
      'sapphire_mainnet.',
    ),
  };

  static final _hexPattern = RegExp(r'^[0-9a-f]+$');

  /// Canonicalize the secp256k1 key hex the SDK returns: `0x` stripped,
  /// lowercase, left-padded with zeros to exactly 64 characters.
  ///
  /// 🛑 The padding is the point. The key is a 256-bit scalar, and the SDK
  /// hands it back as a big-integer hex string — so a key whose leading
  /// bytes/nibbles are zero comes back **shorter than 64 characters**.
  /// Storing that as-is is a silent wrong-key bug on two chains at once:
  ///  * `MultiChainDerivation.privateKeyBytesFromHex` decodes hex pairwise, so
  ///    an odd-length string is truncated rather than rejected;
  ///  * a short-but-even string decodes to fewer than 32 bytes, and both the
  ///    Ethereum key and the Tezos seed would then be a *different* key than
  ///    the one Web3Auth derived — valid signatures from the wrong address.
  /// Short input is therefore padded, never rejected: rejecting it would lock
  /// the user out of their own account on exactly the logins this fixes.
  ///
  /// Only genuinely unusable input throws — empty, non-hex, or longer than 64
  /// characters (which cannot be a 32-byte key at all). The thrown message
  /// carries the length only; embedding the value would put a private key into
  /// logs and crash reports.
  @visibleForTesting
  static String normalizedSecpKeyHex(String hex) {
    var body = hex.trim();
    if (body.startsWith('0x') || body.startsWith('0X')) {
      body = body.substring(2);
    }
    body = body.toLowerCase();
    if (body.isEmpty || body.length > 64 || !_hexPattern.hasMatch(body)) {
      throw ArgumentError(
        'Web3Auth returned a secp256k1 key that is not 1-64 hex characters '
        '(length ${body.length})',
      );
    }
    return body.padLeft(64, '0');
  }

  /// The provider and Solana address a key recovery for one account must
  /// reproduce, or [LegacySocialWalletException] when the account cannot be
  /// recovered at all.
  ///
  /// Unrecoverable means: no social row (nothing to recover), no usable
  /// `socialProvider` (we cannot know which identity to authenticate as), or
  /// no social Solana row (the address a login is verified against). All three
  /// describe a pre-migration Reown row, whose key never left Reown's hosted
  /// wallet — see [LegacySocialWalletException].
  ///
  /// Pure so the policy is pinned without a live SDK.
  @visibleForTesting
  static ({String provider, String solanaAddress}) recoveryTargetFor(
    List<WalletInfo> wallets,
  ) {
    final social = wallets
        .where((w) => w.walletType == WalletType.social)
        .toList();
    if (social.isEmpty) {
      throw LegacySocialWalletException(
        'This account has no social wallet to sign in for.',
      );
    }
    final provider = social
        .map((w) => w.socialProvider)
        .firstWhere((p) => p == 'google' || p == 'apple', orElse: () => null);
    if (provider == null) {
      throw LegacySocialWalletException();
    }
    final solana = social.cast<WalletInfo?>().firstWhere(
      (w) => w!.chain == Chain.solana.toDbString(),
      orElse: () => null,
    );
    if (solana == null) {
      throw LegacySocialWalletException();
    }
    return (provider: provider, solanaAddress: solana.address);
  }

  /// Gate a recovery on the re-login deriving the address the account already
  /// holds.
  ///
  /// A mismatch is the pre-migration case, not a transient error: Web3Auth
  /// derives a *different* address than Reown did for the same Google/Apple
  /// identity. Storing the new key against the old row would produce valid
  /// signatures from an address the row does not represent, which fails
  /// silently downstream — so this throws instead.
  ///
  /// Pure so the hard cutover is pinned without a live SDK.
  @visibleForTesting
  static void requireDerivedAddressMatches({
    required String expected,
    required String derived,
  }) {
    if (expected == derived) return;
    throw LegacySocialWalletException();
  }

  /// Sign in with Google. Returns null when the user cancels.
  Future<SocialAuthResult?> signInWithGoogle() =>
      _signIn(AuthConnection.google, 'google');

  /// Sign in with Apple. Returns null when the user cancels.
  Future<SocialAuthResult?> signInWithApple() =>
      _signIn(AuthConnection.apple, 'apple');

  /// Run the OAuth round-trip, then create or complete the account behind the
  /// identity that came back.
  ///
  /// Returns null only for cancellation — the user's own abort, which every
  /// caller treats as "nothing happened". Every other failure is logged and
  /// rethrown so the sheet can show a reason; swallowing them (as the Reown
  /// implementation did) left the user staring at a screen that silently did
  /// nothing.
  Future<SocialAuthResult?> _signIn(
    AuthConnection connection,
    String provider,
  ) async {
    try {
      final keys = await _connectAndDerive(connection);
      final repository = GetIt.instance<WalletRepository>();
      final outcome = await _storeSocialAccount(repository, provider, keys);
      final result = SocialAuthResult(
        wallet: _solanaRowOf(outcome.wallets),
        provider: provider,
        existed: outcome.existed,
      );
      AppLogger.info(
        _tag,
        '$provider sign-in complete for ${result.wallet.address} '
        '(existed=${result.existed})',
      );
      // Publish on the durable stream FIRST so account creation is observed
      // even if the awaiting sheet was disposed by the OAuth round-trip's
      // background/resume cycle.
      _signInController.add(result);
      return result;
    } on UserCancelledException {
      AppLogger.info(_tag, '$provider sign-in cancelled in the browser');
      return null;
    } on TransactionAuthCancelledException {
      AppLogger.info(_tag, '$provider sign-in cancelled from the app');
      return null;
    } catch (e) {
      // Never interpolate the SDK response: Web3AuthResponse.toString() prints
      // both private keys. Only the thrown error reaches the log.
      AppLogger.error(_tag, '$provider sign-in failed', e);
      rethrow;
    }
  }

  /// Re-derive and re-store the keys for the social account [accountId].
  ///
  /// Called when a social row's stored key is missing — a wiped keystore, a
  /// restored database, or a row that predates this migration. The interactive
  /// login is the only way back: keys are obtainable during a login session
  /// and nowhere else.
  ///
  /// Publishes nothing on [onSignInComplete]: no account was created, and the
  /// listener would re-run the add-wallet flow and yank navigation home.
  ///
  /// Throws [LegacySocialWalletException] when the account cannot be recovered
  /// (see [recoveryTargetFor] and [requireDerivedAddressMatches]), and
  /// [TransactionAuthCancelledException] when the user backs out — the caller
  /// is mid-signature, so a cancel must unwind the whole flow rather than
  /// return quietly.
  ///
  /// Concurrent calls for the same [accountId] share one login and one
  /// outcome — see [_recoveriesInFlight].
  Future<void> recoverKeysForAccount(String accountId) {
    final pending = _recoveriesInFlight[accountId];
    if (pending != null) return pending;
    // Registered before the first suspension inside [_runKeyRecovery], so no
    // second entrant can slip past the lookup above.
    final started = _runKeyRecovery(accountId);
    _recoveriesInFlight[accountId] = started;
    return started;
  }

  /// In-flight recoveries, keyed by account id, so concurrent callers share
  /// one OAuth round-trip instead of each opening a browser tab.
  ///
  /// Mirrors [_initFuture], and for the same reason: `WalletManager` wires
  /// recovery into every social key load, so a multi-chain sign or a
  /// `Future.wait` over two rows of one account can enter here at once.
  /// Un-coalesced, the second entrant starts a second login and installs its
  /// own cancel signal, so the sheet's Cancel unwinds one caller and leaves
  /// the other waiting on a browser tab that is never coming back.
  ///
  /// Every caller gets the *same* future, so all of them see the same
  /// outcome — success, [LegacySocialWalletException], or the cancellation.
  /// The entry is dropped before that future completes, so the next call is
  /// always a fresh attempt rather than a replay of this one's result.
  final Map<String, Future<void>> _recoveriesInFlight =
      <String, Future<void>>{};

  Future<void> _runKeyRecovery(String accountId) async {
    try {
      await _recoverKeysForAccount(accountId);
    } finally {
      // Discarded rather than awaited: `remove` hands back the evicted
      // future, which is the one we are running inside.
      final _ = _recoveriesInFlight.remove(accountId);
    }
  }

  Future<void> _recoverKeysForAccount(String accountId) async {
    final repository = GetIt.instance<WalletRepository>();
    try {
      final target = recoveryTargetFor(
        await repository.getWalletsForAccount(accountId),
      );
      final keys = await _connectAndDerive(_connectionFor(target.provider));
      requireDerivedAddressMatches(
        expected: target.solanaAddress,
        derived: keys.solanaAddress,
      );
      // Idempotent: re-stores all three keys and backfills any chain row the
      // account is missing (a pre-Accounts-model row had Solana only).
      await _storeSocialAccount(repository, target.provider, keys);
      AppLogger.info(_tag, 'recovered keys for ${target.solanaAddress}');
    } on UserCancelledException {
      AppLogger.info(_tag, 'key recovery cancelled in the browser');
      throw TransactionAuthCancelledException(
        'Sign-in was cancelled. Transaction aborted.',
      );
    } on TransactionAuthCancelledException {
      rethrow;
    } catch (e) {
      AppLogger.error(_tag, 'key recovery failed', e);
      rethrow;
    }
  }

  /// The storage half both entry points share: map one login's derived keys
  /// onto the three chain rows and hand them to secure storage.
  ///
  /// 🛑 Stated exactly once on purpose. [_SocialKeys.secpKeyHex] is BOTH the
  /// Ethereum stored key and the Tezos one (Web3Auth's Tezos convention feeds
  /// the secp256k1 bytes in as an Ed25519 seed), and only sign-in derived the
  /// addresses that mapping is checked against. A second copy of it could
  /// drift, and then recovery would store different key material than sign-in
  /// derived for the same rows — valid signatures from the wrong address,
  /// which fails silently rather than erroring.
  Future<({List<WalletInfo> wallets, bool existed})> _storeSocialAccount(
    WalletRepository repository,
    String provider,
    _SocialKeys keys,
  ) => repository.addSocialAccount(
    provider: provider,
    name: '${_providerLabel(provider)} Wallet',
    solana: SocialChainCredential(
      address: keys.solanaAddress,
      storedKey: keys.solanaStoredKey,
    ),
    ethereum: SocialChainCredential(
      address: keys.ethereumAddress,
      storedKey: keys.secpKeyHex,
    ),
    tezos: SocialChainCredential(
      address: keys.tezosAddress,
      storedKey: keys.secpKeyHex,
    ),
  );

  /// The interactive half both entry points share: OAuth, capture both keys,
  /// end the Web3Auth session, derive the three addresses.
  Future<_SocialKeys> _connectAndDerive(AuthConnection connection) async {
    await _ensureInitialized();

    // Raced against [cancelPendingRequest]: this blocks on the user finishing
    // a browser round-trip, and nothing else times it out.
    final response = await _cancellable(
      Web3AuthFlutter.connectTo(
        LoginParams(authConnection: connection, mfaLevel: MFALevel.NONE),
      ),
    );

    final ed25519Hex = await _capturedKey(
      response.ed25519PrivateKey,
      Web3AuthFlutter.getEd25519PrivateKey,
      'Ed25519',
    );
    final rawSecpHex = await _capturedKey(
      response.privateKey,
      Web3AuthFlutter.getPrivateKey,
      'secp256k1',
    );

    // The stored keys are our source of truth from here on, so end the session
    // immediately — that is what makes "add another Google wallet" show a
    // fresh account chooser instead of silently reusing this identity. Done
    // before any validation so an unusable key still leaves no session behind.
    await _logoutQuietly();

    final secpHex = normalizedSecpKeyHex(rawSecpHex);

    // Fails loud on anything but exactly 64 bytes; seed-first byte order is
    // pinned by derivation_test.dart, the one place a silent wrong-key bug
    // could hide.
    final solanaAddress = MultiChainDerivation.solanaAddressFromEd25519KeyHex(
      ed25519Hex,
    );
    return _SocialKeys(
      solanaAddress: solanaAddress,
      solanaStoredKey: MultiChainDerivation.solanaStoredKeyFromEd25519KeyHex(
        ed25519Hex,
      ),
      ethereumAddress: MultiChainDerivation.ethereumAddressFromPrivateKeyHex(
        secpHex,
      ),
      // Web3Auth's canonical Tezos convention: the secp256k1 key bytes fed in
      // as an Ed25519 seed. Same bytes as the Ethereum key by design.
      tezosAddress: await MultiChainDerivation.tezosAddressFromSeedHex(secpHex),
      secpKeyHex: secpHex,
    );
  }

  /// The key from the login response, falling back to the SDK getter.
  ///
  /// `connectTo` normally carries both keys, but the field is nullable on the
  /// wire and the getters read the same session — so the fallback costs one
  /// channel call and removes a class of "logged in but no key" failures.
  Future<String> _capturedKey(
    String? fromResponse,
    Future<String> Function() fallback,
    String label,
  ) async {
    final direct = fromResponse?.trim() ?? '';
    if (direct.isNotEmpty) return direct;
    final recovered = (await fallback()).trim();
    if (recovered.isEmpty) {
      throw StateError(
        'Web3Auth returned no $label private key for this login.',
      );
    }
    return recovered;
  }

  /// End the Web3Auth session. Best effort: the keys are already captured, and
  /// a failed logout must not fail a sign-in that otherwise succeeded.
  Future<void> _logoutQuietly() async {
    try {
      await Web3AuthFlutter.logout();
    } catch (e) {
      AppLogger.warn(_tag, 'logout failed (session may persist): $e');
    }
  }

  static String _providerLabel(String provider) =>
      provider == 'apple' ? 'Apple' : 'Google';

  static AuthConnection _connectionFor(String provider) =>
      provider == 'apple' ? AuthConnection.apple : AuthConnection.google;

  /// The Solana row of a freshly created/completed social account. Absent only
  /// if [WalletRepository.addSocialAccount] changed shape, which would break
  /// the wallet the app selects and signs with — so it throws rather than
  /// guessing at another chain's row.
  static WalletInfo _solanaRowOf(List<WalletInfo> wallets) =>
      wallets.firstWhere(
        (w) => w.chain == Chain.solana.toDbString(),
        orElse: () => throw StateError(
          'Social account was created without a Solana wallet',
        ),
      );

  /// Race [operation] against a signal [cancelPendingRequest] can complete,
  /// publishing on [requestPending] that something cancellable is in flight so
  /// the UI can offer a way out.
  ///
  /// Wraps the OAuth round-trip — the one step that blocks on the user leaving
  /// the app. Unraced, an abandoned browser tab would strand the caller (the
  /// transaction sheet's approval step) forever.
  Future<T> _cancellable<T>(Future<T> operation) async {
    final cancelSignal = Completer<Never>();
    _cancelSignals.add(cancelSignal);
    _requestPending.value = true;
    try {
      return await Future.any<T>([operation, cancelSignal.future]);
    } finally {
      _cancelSignals.remove(cancelSignal);
      // Only the last one out clears the flag, so an operation that overlaps
      // this one keeps the Cancel affordance up instead of losing it when
      // this one unwinds.
      if (_cancelSignals.isEmpty) _requestPending.value = false;
    }
  }

  /// Whether an interactive sign-in is in flight and can still be cancelled.
  ///
  /// Drives the Cancel affordance on the approval step of
  /// `TransactionPipelineSheet`, which is reachable when a social row's key
  /// must be recovered mid-signature.
  ValueListenable<bool> get requestPending => _requestPending;
  final ValueNotifier<bool> _requestPending = ValueNotifier<bool>(false);

  /// Completed by [cancelPendingRequest] to break the waits in [_cancellable].
  /// Empty when nothing is in flight.
  ///
  /// A set rather than a single field: recovery is reachable from every social
  /// key load, so it can overlap a sign-in or a recovery for another account.
  /// With one field the later entrant overwrote the earlier one's signal, and
  /// a Cancel then unwound only the last caller while the rest waited forever
  /// on a browser tab nobody was going to come back to.
  final Set<Completer<Never>> _cancelSignals = <Completer<Never>>{};

  /// Stop waiting on the in-flight sign-in.
  ///
  /// The browser tab stays open — we cannot close it — and the SDK's future
  /// may still complete later, onto a future nobody listens to. All this does
  /// is stop *us* waiting, which is the part that strands the user.
  ///
  /// Reuses [TransactionAuthCancelledException] rather than inventing a
  /// cancellation type: `AppFailure.fromError` already maps it to
  /// `AppFailure.cancelled`, so every flow's existing `isCancelled` branch
  /// treats this as the clean abort it is. No-op when nothing is in flight.
  void cancelPendingRequest() {
    // Signals are left in the set for [_cancellable]'s `finally` to remove —
    // it owns both the set and the in-flight flag, and removing here would
    // strand the flag on and leave the Cancel button up after the flow has
    // unwound. Iterated over a copy for the same reason.
    for (final signal in _cancelSignals.toList()) {
      if (signal.isCompleted) continue;
      signal.completeError(
        TransactionAuthCancelledException(
          'Sign-in was cancelled. Transaction aborted.',
        ),
      );
    }
  }

  /// Drop any Web3Auth session, so the next sign-in starts from a fresh
  /// account chooser.
  ///
  /// Best effort. Deleting stored private keys is **not** this method's job —
  /// wallet removal owns that, because a key belongs to a wallet row, not to
  /// the SDK session this clears.
  ///
  /// 🛑 Deliberately leaves [_initialized] set. The logout is what ends the
  /// session; re-initializing buys nothing (the options are compile-time
  /// config) and on Android it *crashes* — see [_ensureInitialized].
  Future<void> reset() => _logoutQuietly();
}
