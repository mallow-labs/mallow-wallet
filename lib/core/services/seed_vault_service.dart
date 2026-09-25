import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';
import 'package:ledger_solana/ledger_solana.dart';

import '../observability/app_logger.dart';

const _tag = 'SeedVault';

/// Platform-channel error codes the Android side raises. Only the two the Dart
/// layer branches on are named here; every other code lands in the generic
/// [SeedVaultException] with its string intact.
const _codeUnavailable = 'SEED_VAULT_UNAVAILABLE';
const _codePermissionDenied = 'PERMISSION_DENIED';
const _codeInvalidAuthToken = 'INVALID_AUTH_TOKEN';
const _codeCanceled = 'CANCELED';

// -----------------------------------------------------------------------------
// Exceptions
// -----------------------------------------------------------------------------

/// Seed Vault is not on this device (or not on this platform at all).
///
/// Also covers a missing platform handler: on iOS, on a plain Android phone,
/// and in unit tests there is no channel implementation, and a raw
/// `MissingPluginException` escaping to a caller would read as a crash rather
/// than as "this device has no Seed Vault".
class SeedVaultUnavailableException implements Exception {
  const SeedVaultUnavailableException([
    this.message = 'Seed Vault is not available on this device.',
  ]);

  final String message;

  @override
  String toString() => 'SeedVaultUnavailableException: $message';
}

/// The `ACCESS_SEED_VAULT` runtime permission is not granted.
///
/// It can be denied permanently while Seed Vault itself stays available, so
/// the recovery is an app-settings CTA, not another permission request.
class SeedVaultPermissionDeniedException implements Exception {
  const SeedVaultPermissionDeniedException([
    this.message = 'Seed Vault access has not been granted.',
  ]);

  final String message;

  @override
  String toString() => 'SeedVaultPermissionDeniedException: $message';
}

/// No authorized seed holds [address], so nothing can sign for it.
///
/// Distinct from a cancelled approval and from unavailability because the
/// recovery differs: the user re-authorizes the seed. Carries [address] so the
/// UI can name the wallet it failed for and offer `authorizeSeed` — gated on
/// [SeedVaultService.hasUnauthorizedSeeds], since after a seed deletion there
/// is nothing left to authorize and the copy has to say so.
///
/// The CTA is deliberately not "open Seed Vault settings": that call needs an
/// auth token, which is exactly what we no longer have.
class SeedVaultSeedNotAuthorizedException implements Exception {
  const SeedVaultSeedNotAuthorizedException(this.address);

  /// The wallet address that could not be resolved to an authorized seed.
  final String address;

  @override
  String toString() =>
      'SeedVaultSeedNotAuthorizedException: no authorized Seed Vault seed '
      'holds this account';
}

/// The user dismissed Seed Vault's own approval screen.
///
/// An orphaned result — the process was killed while the approval Activity was
/// up — arrives here too: nothing was broadcast, so the consequence is a retry.
class SeedVaultApprovalCancelledException implements Exception {
  const SeedVaultApprovalCancelledException([
    this.message = 'Seed Vault approval was cancelled.',
  ]);

  final String message;

  @override
  String toString() => 'SeedVaultApprovalCancelledException: $message';
}

/// Any other Seed Vault failure, carrying the platform's own code verbatim.
///
/// `INVALID_AUTH_TOKEN` reaches callers through this type, and only after the
/// single re-resolve and retry in [SeedVaultService.signTransaction] /
/// [SeedVaultService.signMessage] has already failed.
class SeedVaultException implements Exception {
  const SeedVaultException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() =>
      'SeedVaultException($code)${message == null ? '' : ': $message'}';
}

// -----------------------------------------------------------------------------
// Model
// -----------------------------------------------------------------------------

/// One account row as Seed Vault reports it.
@immutable
class SeedVaultAccount {
  const SeedVaultAccount({
    required this.authToken,
    required this.accountId,
    required this.address,
    required this.derivationPath,
    this.name,
    this.isUserWallet = false,
  });

  /// The seed's current authorization token. Not stable across
  /// deauthorize/re-authorize, which is why it is never persisted.
  final int authToken;

  final int accountId;

  /// Base58 address — the `publicKeyEncoded` column verbatim.
  final String address;

  /// The derivation-path URI the vault reported, verbatim. Signing sends this
  /// back unmodified; see [SeedVaultService.signTransaction].
  final String derivationPath;

  final String? name;

  /// The SDK convention that lets other wallets discover an account as one a
  /// user actually holds.
  final bool isUserWallet;
}

// -----------------------------------------------------------------------------
// Service
// -----------------------------------------------------------------------------

/// Solana Mobile Seed Vault, as a hardware signer.
///
/// The peer of `LedgerService`: a `Uint8List payload -> Uint8List signature`
/// round trip that an external secure environment performs after an explicit
/// user approval. mallow never sees key material.
///
/// 🛑 Every signing call raises a full-screen OS Activity. Call one only from a
/// code path a user tap started, in a flow that is on screen waiting for it —
/// an unprompted approval screen reads as a system-level security event.
///
/// Only [isAvailable] is fail-soft (it is the gate that decides whether
/// Seed Vault UI renders at all, so it must never throw). Every other method
/// raises one of the typed exceptions above; a raw `PlatformException` or
/// `MissingPluginException` never escapes.
@lazySingleton
class SeedVaultService {
  SeedVaultService();

  static const _channel = MethodChannel('com.mallow.wallet/seed_vault');

  /// address -> the account row that can sign for it.
  ///
  /// Process-lifetime only, never persisted: an auth token changes on
  /// deauthorize/re-authorize, so a stored one is a stale token waiting to
  /// fail. Resolving live instead is self-healing and needs no DB migration.
  final Map<String, SeedVaultAccount> _cache = {};

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // ---------------------------------------------------------------------------
  // Availability, permission, authorization
  // ---------------------------------------------------------------------------

  /// Whether this device has a Seed Vault implementation.
  ///
  /// Gate every Seed Vault entry point on this, never on the device model —
  /// `Build.MODEL` is spoofable, this checks signature protection on the
  /// implementation's permission.
  ///
  /// Fail-soft by design: any failure answers `false`, so a broken probe hides
  /// the feature rather than breaking the screen that asked.
  Future<bool> isAvailable() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      AppLogger.error(_tag, 'isAvailable probe failed', e.code);
      return false;
    }
  }

  /// Whether `ACCESS_SEED_VAULT` is granted.
  Future<bool> hasPermission() async =>
      await _invoke<bool>('hasPermission') ?? false;

  /// Request `ACCESS_SEED_VAULT`. Returns whether it ended up granted.
  ///
  /// A permanent denial answers `false` without a dialog, so the caller needs
  /// an app-settings CTA rather than a second request.
  Future<bool> requestPermission() async =>
      await _invoke<bool>('requestPermission') ?? false;

  /// Whether the device holds a seed this app has not been authorized for.
  ///
  /// Gates the "authorize another seed" affordance, and the recovery CTA on a
  /// [SeedVaultSeedNotAuthorizedException] — when this is false there is
  /// nothing left to authorize and the copy has to say so.
  Future<bool> hasUnauthorizedSeeds() async =>
      await _invoke<bool>('hasUnauthorizedSeeds') ?? false;

  /// Ask the user to authorize a seed. Raises Seed Vault's own UI.
  ///
  /// Returns the new auth token. Hold it only for the duration of the import
  /// flow — signing resolves its own token per call.
  Future<int> authorizeSeed() async {
    final token = await _invoke<int>('authorizeSeed');
    if (token == null) {
      throw const SeedVaultException(
        'UNKNOWN_ERROR',
        'authorizeSeed returned no token',
      );
    }
    return token;
  }

  /// Drop this app's authorization for a seed.
  ///
  /// Invalidates the whole cache: every cached row carries an auth token, and
  /// the ones for this seed are now dead.
  Future<void> deauthorizeSeed(int authToken) async {
    await _invoke<void>('deauthorizeSeed', {'authToken': authToken});
    invalidateCache();
  }

  // ---------------------------------------------------------------------------
  // Enumeration
  // ---------------------------------------------------------------------------

  /// Every account across every authorized seed. Raises no Seed Vault UI.
  ///
  /// Reads the content provider, so it costs no password prompt and can be
  /// called during import to build the account picker. Also refills the
  /// resolution cache.
  Future<List<SeedVaultAccount>> listAccounts() => _enumerate();

  /// Derive and cache addresses for [paths] the vault has not pre-derived.
  ///
  /// MAY raise a Seed Vault prompt — call only from a user-initiated flow.
  /// Returns base58 addresses in the order of [paths].
  Future<List<String>> requestPublicKeys(
    int authToken,
    List<String> paths,
  ) async {
    final result = await _invoke<List<Object?>>('requestPublicKeys', {
      'authToken': authToken,
      'derivationPaths': paths,
    });
    return (result ?? const []).cast<String>();
  }

  /// Mark an account as one the user actually holds — the SDK convention that
  /// lets other wallets on the device discover it.
  Future<void> markAsUserWallet({
    required int authToken,
    required int accountId,
  }) async {
    await _invoke<void>('setAccountIsUserWallet', {
      'authToken': authToken,
      'accountId': accountId,
      'isUserWallet': true,
    });
  }

  /// Open Seed Vault's own settings screen for a seed.
  ///
  /// Needs a live auth token, so it is reachable only while a seed is
  /// authorized — never as the recovery from a resolution miss.
  Future<void> showSeedSettings(int authToken) async {
    await _invoke<void>('showSeedSettings', {'authToken': authToken});
  }

  // ---------------------------------------------------------------------------
  // Signing
  // ---------------------------------------------------------------------------

  /// Detached 64-byte ed25519 signature over [payload] verbatim.
  ///
  /// [payload] is the compiled message, not a signed envelope — the same
  /// contract the Ledger path satisfies, so the returned signature slots
  /// straight into the transaction's signatures array.
  Future<Uint8List> signTransaction(
    Uint8List payload, {
    required String address,
  }) => _signOne('signTransactions', payload, address);

  /// Detached 64-byte ed25519 signature over [payload] verbatim.
  ///
  /// Unlike the Ledger app, Seed Vault does NOT wrap the payload in an
  /// off-chain-message envelope, so the login challenge goes through the
  /// ordinary `{address, message, signature}` verify body with no bespoke
  /// memo-transaction shape.
  Future<Uint8List> signMessage(Uint8List payload, {required String address}) =>
      _signOne('signMessages', payload, address);

  /// Drop the in-memory (address -> authToken/path/accountId) cache.
  void invalidateCache() => _cache.clear();

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  Future<Uint8List> _signOne(
    String method,
    Uint8List payload,
    String address,
  ) async {
    final account = await _resolve(address);
    try {
      return await _signWith(method, account, payload, address);
    } on SeedVaultException catch (e) {
      if (e.code != _codeInvalidAuthToken) rethrow;
      // The token died between resolution and use (the user deauthorized, or
      // this one was resolved before a re-authorization). Re-resolve exactly
      // once and retry exactly once: a token that is invalid twice in a row is
      // a real failure, and retrying in a loop would spin the approval screen.
      AppLogger.warn(_tag, 'auth token rejected — re-resolving once');
      invalidateCache();
      final fresh = await _resolve(address);
      return _signWith(method, fresh, payload, address);
    }
  }

  Future<Uint8List> _signWith(
    String method,
    SeedVaultAccount account,
    Uint8List payload,
    String address,
  ) async {
    assertResolvedAccountMatches(address, account);

    final result = await _invoke<List<Object?>>(method, {
      'authToken': account.authToken,
      // Verbatim, never reconstructed — see [assertResolvedAccountMatches].
      'derivationPath': account.derivationPath,
      'payloads': <Uint8List>[payload],
    });
    final signatures = (result ?? const []).cast<Uint8List>();
    if (signatures.length != 1 || signatures.first.length != 64) {
      throw const SeedVaultException(
        'INVALID_PAYLOAD',
        'Seed Vault returned a malformed signature',
      );
    }
    return signatures.first;
  }

  /// Resolve [address] to the account row that can sign for it.
  ///
  /// Walks every authorized seed's accounts and matches on the vault's own
  /// `publicKeyEncoded`. Cached for the process lifetime; a miss is never
  /// cached, so a freshly authorized seed is picked up on the next call.
  Future<SeedVaultAccount> _resolve(String address) async {
    final cached = _cache[address];
    if (cached != null) return cached;

    await _enumerate();
    final resolved = _cache[address];
    if (resolved == null) {
      throw SeedVaultSeedNotAuthorizedException(address);
    }
    return resolved;
  }

  Future<List<SeedVaultAccount>> _enumerate() async {
    final seeds =
        await _invoke<List<Object?>>('getAuthorizedSeeds') ?? const [];

    final accounts = <SeedVaultAccount>[];
    for (final seed in seeds) {
      final authToken = (seed! as Map)['authToken'] as int;
      final rows =
          await _invoke<List<Object?>>('getAccounts', {
            'authToken': authToken,
          }) ??
          const [];
      for (final row in rows) {
        final map = row! as Map;
        accounts.add(
          SeedVaultAccount(
            authToken: authToken,
            accountId: map['accountId'] as int,
            address: map['publicKeyEncoded'] as String,
            derivationPath: map['derivationPath'] as String,
            name: map['name'] as String?,
            isUserWallet: map['isUserWallet'] as bool? ?? false,
          ),
        );
      }
    }

    // Replace rather than merge, so a row that has gone away stops resolving.
    // First seed wins a duplicate address: that only happens when the same
    // seed was imported twice, and either token signs correctly.
    _cache.clear();
    for (final account in accounts) {
      _cache.putIfAbsent(account.address, () => account);
    }
    AppLogger.debug(
      _tag,
      'enumerated ${accounts.length} account(s) across ${seeds.length} seed(s)',
    );
    return accounts;
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    if (!_isAndroid) throw const SeedVaultUnavailableException();
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const SeedVaultUnavailableException();
    } on PlatformException catch (e) {
      throw _mapPlatformException(e);
    }
  }

  Exception _mapPlatformException(PlatformException e) => switch (e.code) {
    _codeUnavailable => SeedVaultUnavailableException(
      e.message ?? 'Seed Vault is not available on this device.',
    ),
    _codePermissionDenied => SeedVaultPermissionDeniedException(
      e.message ?? 'Seed Vault access has not been granted.',
    ),
    _codeCanceled => SeedVaultApprovalCancelledException(
      e.message ?? 'Seed Vault approval was cancelled.',
    ),
    _ => SeedVaultException(e.code, e.message),
  };

  /// Refuse to sign when the resolved row is not the account that was asked
  /// for.
  ///
  /// This is the guard against the classic hardware failure: signing under a
  /// path that belongs to a different key produces a *valid* signature from
  /// the wrong address, which fails silently downstream instead of erroring.
  /// It cannot fire while resolution matches strictly on the vault's own
  /// `publicKeyEncoded` — which is the point. The day someone adds a
  /// well-meaning "they only have one seed, just use the first account"
  /// fallback, this stops it at the boundary instead of on-chain.
  @visibleForTesting
  static void assertResolvedAccountMatches(
    String requestedAddress,
    SeedVaultAccount account,
  ) {
    if (account.address != requestedAddress) {
      AppLogger.error(
        _tag,
        'resolved account address does not match the requested address — refusing to sign',
      );
      throw StateError(
        'Seed Vault resolved a different account than requested — '
        'refusing to sign.',
      );
    }
  }
}

// -----------------------------------------------------------------------------
// Derivation paths
// -----------------------------------------------------------------------------

/// The Seed Vault derivation-path URI for account [index] under [scheme].
///
/// `bip32:/m'/44'/501'/$index'/0'` for standard, `bip32:/m'/44'/501'/$index'`
/// for legacy — the same two paths `MultiChainDerivation.solanaHdPath`
/// produces, in the URI form the vault takes.
///
/// Use this to *offer* paths at import. Signing never reconstructs a path: it
/// sends back the one the vault itself reported for the account.
///
/// Throws [ArgumentError] for [SolanaDerivationScheme.root]. Seed Vault
/// pre-derives the common Solana paths on first authorization, but not the
/// index-less depth-2 root path — offering it would cost the user a password
/// prompt for an account almost nobody has.
String seedVaultDerivationPath(
  int index,
  SolanaDerivationScheme scheme,
) => switch (scheme) {
  SolanaDerivationScheme.standard => "bip32:/m'/44'/501'/$index'/0'",
  SolanaDerivationScheme.legacy => "bip32:/m'/44'/501'/$index'",
  SolanaDerivationScheme.root => throw ArgumentError.value(
    scheme,
    'scheme',
    'Seed Vault does not pre-derive the root path; offer standard or legacy',
  ),
};
