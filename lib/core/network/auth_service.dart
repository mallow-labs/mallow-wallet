import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import '../analytics/analytics_service.dart';
import '../config/environment.dart';
import '../crypto/exceptions.dart';
import '../crypto/wallet_manager.dart';
import '../observability/app_logger.dart';
import '../security/secure_storage.dart';
import '../services/preferences_service.dart';
import '../services/push_notification_service.dart';
import '../session/session_manager.dart';
import 'ledger_verify_controller.dart';

import '../../shared/utils/chain.dart';

const _tag = 'AuthService';

/// Session state for UI binding.
enum SessionState {
  /// Not yet initialized
  initial,

  /// Login in progress
  loading,

  /// Successfully logged in
  authenticated,

  /// Login failed
  error,
}

/// Service for authenticating with the mallow API.
///
/// Handles wallet-based authentication and session management.
/// Extends ChangeNotifier to allow UI to react to session state changes.
///
/// The `/v0/login` endpoint is called:
/// - On every app startup (after unlock)
/// - After onboarding completion (before showing home)
/// - When switching wallets (multi-wallet support)
///
/// The login token is stored and sent with subsequent API requests,
/// but login is still called every time to ensure fresh data and
/// trigger backend indexing jobs.
@lazySingleton
class AuthService extends ChangeNotifier {
  AuthService(this._api, this._walletManager, this._storage, this._dio) {
    _dio.interceptors.add(_SignatureRetryInterceptor(this, _dio));
  }

  final MallowApiClient _api;
  final WalletManager _walletManager;
  final SecureWalletStorage _storage;
  final Dio _dio;

  // Dedup guard for concurrent switchWallet calls
  String? _pendingSwitchAddress;
  Completer<LoginResult>? _pendingSwitchCompleter;

  /// Bumped by [logout]. A wallet switch that started before the bump must not
  /// complete a login after it — otherwise logging out while a switch is
  /// in-flight or queued silently logs the user straight back in.
  int _sessionGeneration = 0;

  // Wallet-sig cookie cache (address → JWT), used for dual-sig auth flows
  final Map<String, String> _walletSigCookies = {};

  // Session state
  SessionState _sessionState = SessionState.initial;
  String? _currentAddress;

  // Cached user data from last login
  User? _currentUser;
  UserDetails? _currentUserDetails;
  LoginResult? _lastLoginResult;

  /// Whether [_currentUser] came from a PRIVILEGED render.
  ///
  /// The backend withholds `perks`, the full `roles`, `showNsfw` and
  /// `disabledChains` from a render whose request carried no valid `wallet-sig`
  /// for the address, and [User] defaults every one of those to empty/false —
  /// so a public render is indistinguishable from a privileged render for a
  /// user who genuinely has nothing set. Anything that MIRRORS server state
  /// onto the device must gate on this flag, or it writes those defaults over
  /// the user's real settings (see [_hydrateActiveNetworksForProfile]).
  bool _currentUserIsPrivileged = false;

  /// Current session state (for UI binding).
  SessionState get sessionState => _sessionState;

  /// The address currently logged in (the primary / active signing wallet).
  String? get currentAddress => _currentAddress;

  /// Get the currently logged in user.
  User? get currentUser => _currentUser;

  /// Get the current user's details.
  UserDetails? get currentUserDetails => _currentUserDetails;

  /// Get the last login result (includes likes, following, etc.).
  LoginResult? get lastLoginResult => _lastLoginResult;

  /// Apply a fresh user + details snapshot returned by a profile mutation
  /// (e.g. editing the profile) so cached UI like the account drawer and
  /// profile header reflect the change immediately.
  void applyProfileUpdate(User user, UserDetails? details) {
    _currentUser = user;
    if (details != null) _currentUserDetails = details;
    notifyListeners();
  }

  /// Whether there is an active session.
  bool get hasSession => _sessionState == SessionState.authenticated;

  /// True if the active wallet is a Ledger AND we don't have a usable
  /// wallet-sig cookie cached for it — i.e. callers about to perform an
  /// action that implies wallet identity (e.g. casting) should prompt the
  /// user through [LedgerVerifyController] before proceeding.
  Future<bool> currentWalletNeedsLedgerVerification() async {
    final addr = _currentAddress;
    if (addr == null) return false;
    if (!await _walletManager.isLedgerWallet(addr)) return false;
    final cached =
        _walletSigCookies[addr] ?? await _storage.loadWalletSigCookie(addr);
    if (cached == null || cached.isEmpty) return true;
    return _isJwtExpired(cached);
  }

  /// True when at least one of [addresses] holds a non-expired `wallet-sig`
  /// proof — in the in-memory cache OR on disk.
  ///
  /// The Dio interceptor only attaches the *in-memory* snapshot, so a proof that
  /// lives only on disk (e.g. right after an app restart, before any re-login
  /// hydrates it) would otherwise satisfy this gate while the following request
  /// goes out cookieless. To keep the gate's answer consistent with what the
  /// next request will actually carry, a valid disk-only hit is hydrated into
  /// [_walletSigCookies] and the interceptor refreshed before returning true —
  /// mirroring [signAndVerifyForWallet] and [_verifySignatureIfPossible].
  Future<bool> hasValidWalletSigForAny(Iterable<String> addresses) async {
    for (final address in addresses) {
      final result = await _lookupWalletSig(address);
      if (result.valid) {
        // Refresh only when a disk-only hit was hydrated, so the sig the gate
        // just accepted is the sig the next request sends. An in-memory hit is
        // already reflected in the interceptor.
        if (result.hydrated) _refreshAuthInterceptor();
        return true;
      }
    }
    return false;
  }

  /// Look up a single [address]'s `wallet-sig` in the in-memory cache, then on
  /// disk, hydrating a valid disk-only hit into [_walletSigCookies] WITHOUT
  /// refreshing the interceptor. Returns whether a valid sig was found and
  /// whether a disk value was hydrated — so the caller can refresh the
  /// interceptor once (rather than once per hit) after the lookups complete.
  ///
  /// Future.wait-safe: touches only this address's distinct cookie key.
  Future<({bool valid, bool hydrated})> _lookupWalletSig(String address) async {
    if (address.isEmpty) return (valid: false, hydrated: false);
    final cookieAddress = _cookieAddress(address);

    final inMemory = _walletSigCookies[cookieAddress];
    if (inMemory != null && inMemory.isNotEmpty && !_isJwtExpired(inMemory)) {
      return (valid: true, hydrated: false);
    }

    final disk = await _storage.loadWalletSigCookie(cookieAddress);
    if (disk != null && disk.isNotEmpty && !_isJwtExpired(disk)) {
      _walletSigCookies[cookieAddress] = disk;
      return (valid: true, hydrated: true);
    }
    return (valid: false, hydrated: false);
  }

  /// True when any of [addresses] currently holds a non-expired `wallet-sig`
  /// proof in the in-memory cookie cache — i.e. a proof the Dio interceptor
  /// will attach to the next request.
  ///
  /// Purely local and synchronous (no storage/network). It reads exactly the
  /// map [_AuthInterceptor] sends, so a private, ownership-gated read is
  /// authorized the moment this returns true for any session wallet — even a
  /// non-active one. Unlike [hasValidWalletSigForAny] it never falls back to
  /// [SecureWalletStorage]: a sig that lives only on disk isn't attached to
  /// requests, so it wouldn't authorize the fetch either.
  bool hasAnyVerifiedSession(Iterable<String> addresses) {
    for (final address in addresses) {
      if (address.isEmpty) continue;
      final cached = _walletSigCookies[_cookieAddress(address)];
      if (cached != null && cached.isNotEmpty && !_isJwtExpired(cached)) {
        return true;
      }
    }
    return false;
  }

  /// Silently obtain a `wallet-sig` for [address] in the background — the same
  /// path login runs for the active wallet, exposed so callers can widen the
  /// signature gate to a *non-active* session wallet WITHOUT switching the
  /// active signer. HD, imported and social wallets sign immediately; Ledger,
  /// view-only and key-less social wallets are deferred/skipped (see
  /// [_verifySignatureIfPossible]).
  Future<void> verifySessionWallet(String address) =>
      _verifySignatureIfPossible(address);

  /// Initialize session for the current wallet.
  ///
  /// Call this on app startup after authentication/unlock and
  /// after onboarding completion. Blocks until login completes.
  ///
  /// Returns the LoginResult on success, throws AuthException on failure.
  Future<LoginResult> initializeSession() async {
    AppLogger.debug(_tag, 'initializeSession called');
    final address = await _walletManager.getAddress();
    AppLogger.debug(_tag, 'Got address: $address');
    return _loginWithAddress(address);
  }

  /// Switch to a different wallet address and re-login.
  ///
  /// Clears current session and logs in with the new address.
  /// Uses a Completer guard to deduplicate concurrent calls for the same
  /// address (e.g. BLoC + app-level listener both calling switchWallet).
  ///
  /// Switches to *different* addresses are **serialized**, not interleaved: an
  /// overlapping switch queues behind the in-flight one instead of racing it.
  /// Without that, a cancel-during-switch fires a second `_clearSession` +
  /// login concurrently, last-login-wins, and the logged-in identity can end up
  /// diverging from the persisted wallet selection.
  Future<LoginResult> switchWallet(String newAddress) async {
    // If a switch to the same address is already in-flight, piggyback on it.
    if (_pendingSwitchAddress == newAddress &&
        _pendingSwitchCompleter != null &&
        !_pendingSwitchCompleter!.isCompleted) {
      AppLogger.debug(
        _tag,
        'switchWallet dedup — already switching to $newAddress',
      );
      return _pendingSwitchCompleter!.future;
    }

    // Publish this switch SYNCHRONOUSLY before awaiting the in-flight one.
    // Order matters: if we awaited first and registered after, the dedup check
    // above would still see the *old* pending address for the whole wait, so a
    // concurrent caller for `newAddress` would open a second `_clearSession()`
    // + login whose clear lands after the first caller already resolved —
    // re-creating the null-`currentAddress`-at-dispatch race that serializing
    // exists to kill.
    final inFlight = _pendingSwitchCompleter;
    final completer = Completer<LoginResult>();
    final generation = _sessionGeneration;
    _pendingSwitchAddress = newAddress;
    _pendingSwitchCompleter = completer;
    // Mark the completer's error as observed so a switch nobody piggybacked on
    // does not surface as an unhandled async error; awaiting callers still
    // receive it, and this call rethrows below either way.
    unawaited(completer.future.then((_) {}, onError: (_, _) {}));

    try {
      if (inFlight != null && !inFlight.isCompleted) {
        AppLogger.debug(_tag, 'switchWallet queued behind in-flight switch');
        // Its outcome is irrelevant — we are replacing that identity anyway.
        await inFlight.future.then((_) {}, onError: (_, _) {});
      }
      // A logout while we were queued ends the session outright. Clearing the
      // pending-switch fields alone would not stop us: `inFlight` is a local
      // reference, so we would still fall through and log the user back in.
      if (_sessionGeneration != generation) {
        throw AuthException('Wallet switch abandoned — session was ended');
      }
      await _clearSession();
      final result = await _loginWithAddress(newAddress);
      // ...and a logout that lands *during* the login must win too, or the
      // completed login re-populates the session it just tore down.
      if (_sessionGeneration != generation) {
        await _clearSession();
        notifyListeners();
        throw AuthException('Wallet switch abandoned — session was ended');
      }
      completer.complete(result);
      return result;
    } catch (e, stack) {
      completer.completeError(e, stack);
      rethrow;
    } finally {
      // Only clear if this is still the active switch (not replaced by a newer
      // one). Compared on completer **identity**, not on the address: with
      // three overlapping switches whose 1st and 3rd target the same address
      // (B → C → B), an address comparison lets the first switch's `finally`
      // see its own address re-registered by the third and free the guard while
      // C and B#2 are still queued. A subsequent switch would then see no
      // in-flight switch and run its `_clearSession()` + login concurrently —
      // the last-login-wins interleaving this guard exists to forbid.
      if (identical(_pendingSwitchCompleter, completer)) {
        _pendingSwitchAddress = null;
        _pendingSwitchCompleter = null;
      }
    }
  }

  /// Refresh the current session.
  ///
  /// Re-calls login to get fresh data. Use after returning from
  /// background or when session might be stale.
  Future<LoginResult> refresh() async {
    if (_currentAddress == null) {
      return initializeSession();
    }
    return _loginWithAddress(_currentAddress!);
  }

  /// Logout - clear cached user and session.
  Future<void> logout() async {
    // Invalidate any in-flight or queued wallet switch FIRST, before the awaits
    // below give one a chance to run. A switch that has already passed its own
    // generation check will still complete its login, but the post-login check
    // in [switchWallet] tears that session back down. Without this, logging out
    // while a switch is pending logs the user straight back in.
    _sessionGeneration++;
    _pendingSwitchAddress = null;
    _pendingSwitchCompleter = null;

    // Unregister push token before clearing session
    try {
      await GetIt.instance<PushNotificationService>().unregister();
    } catch (e) {
      AppLogger.warn(_tag, 'Failed to unregister push token: $e');
    }

    await _clearSession();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // User Data Accessors
  // ---------------------------------------------------------------------------

  /// Check if the current user is Twitter verified.
  bool get isTwitterVerified => _currentUser?.isTwitterVerified ?? false;

  /// Get the list of addresses the user is following.
  List<String> get following => _lastLoginResult?.following ?? [];

  /// Get likes organized by content type.
  Map<ContentType, List<String>> get likesByContentType =>
      _lastLoginResult?.likesByContentType ?? {};

  /// Number of gumball invites available.
  int get invitedGumballCount => _lastLoginResult?.invitedGumballCount ?? 0;

  /// Check if a content item is liked.
  bool isLiked(String contentId, ContentType type) {
    return likesByContentType[type]?.contains(contentId) ?? false;
  }

  /// Check if an address is being followed.
  bool isFollowing(String address) {
    return following.contains(address);
  }

  // ---------------------------------------------------------------------------
  // Dual-Signature Auth (for wallet linking)
  // ---------------------------------------------------------------------------

  /// Lightweight login that only sets the login-token for [address].
  ///
  /// Unlike [switchWallet], this does NOT update session state, cached user
  /// data, or notify listeners. Used by the wallet link flow to ensure the
  /// login-token identifies the target profile without side effects.
  Future<void> loginForLinkFlow(String address) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '${Config.apiBaseUrl}/v0/login',
      data: {'address': address},
    );
    await _extractAndStoreLoginToken(response.headers);
    // Also run signature verification for this address so the wallet-sig
    // cookie is fresh for the subsequent approveLinkRequestV2 call.
    await _verifySignatureIfPossible(address);
  }

  /// Request an auth token, sign it with [walletId], and verify with the
  /// backend. On success the backend sets a `wallet-sig-{address}` JWT cookie.
  ///
  /// The JWT is cached in [SecureWalletStorage] and added to subsequent
  /// requests via the Dio interceptor so callers can skip re-signing.
  ///
  /// - [walletId] — ID of the wallet to sign with (must be HD or importedKey)
  /// - [address] — on-chain address matching [walletId] (used in the auth
  ///   token request and as the cookie key)
  ///
  /// Throws [ViewOnlyWalletException] if the wallet cannot sign.
  Future<void> signAndVerifyForWallet(String walletId, String address) async {
    // The backend keys the wallet-sig cookie by the normalized address
    // (Ethereum lowercased; Solana/Tezos unchanged), so cache/store/extract all
    // use the cookie form while signing uses the wallet's own address.
    final cookieAddress = _cookieAddress(address);

    // Skip if we already have a non-expired cached JWT for this address
    final cached = await _storage.loadWalletSigCookie(cookieAddress);
    if (cached != null && cached.isNotEmpty) {
      if (_isJwtExpired(cached)) {
        AppLogger.debug(
          _tag,
          'Wallet-sig expired for $cookieAddress — requesting new signature',
        );
        await _storage.deleteWalletSigCookie(cookieAddress);
        _walletSigCookies.remove(cookieAddress);
      } else {
        _walletSigCookies[cookieAddress] = cached;
        _refreshAuthInterceptor();
        AppLogger.debug(_tag, 'Wallet-sig already cached for $cookieAddress');
        return;
      }
    }

    // Ledger wallets require interactive BLE verification via bottom sheet
    final isLedger = await _walletManager.isLedgerWallet(address);
    if (isLedger) {
      AppLogger.debug(
        _tag,
        'Ledger wallet — routing to interactive verification',
      );
      final controller = GetIt.instance<LedgerVerifyController>();
      final success = await controller.requestVerification(address);
      if (!success) {
        throw LedgerVerificationCancelledException();
      }
      return; // JWT already cached by LedgerVerifySheet
    }

    // Step 1: Request auth token
    final tokenResponse = await _api.getAuthToken(
      AuthTokenRequest(address: cookieAddress),
    );
    final token = tokenResponse.result;

    // Step 2: Sign the chain-specific login challenge
    final signature = await _walletManager.signLoginChallenge(
      walletId,
      message: _loginMessagePrefix,
      token: token,
    );

    // Step 3: Verify with backend via raw Dio to capture Set-Cookie header
    final response = await _dio.post<Map<String, dynamic>>(
      '${Config.apiBaseUrl}/v0/authToken/verify',
      data: _verifyBody(cookieAddress, signature),
    );

    // Step 4: Extract and cache the wallet-sig JWT from Set-Cookie
    final jwt = _extractWalletSigCookie(response.headers, cookieAddress);
    if (jwt != null) {
      await _storage.storeWalletSigCookie(cookieAddress, jwt);
      _walletSigCookies[cookieAddress] = jwt;
      _refreshAuthInterceptor();
      AppLogger.debug(_tag, 'Wallet-sig JWT cached for $cookieAddress');
    }

    await _adoptPrivilegedUser(response.data, cookieAddress);
  }

  /// The login challenge message prefix the backend reconstructs and verifies
  /// (signed content is `<prefix>\n\ntoken:<token>`).
  static const _loginMessagePrefix = 'mallow Login';

  /// Backend cookie/lookup form of an address: Ethereum (`0x…`) is
  /// case-insensitive and keyed lowercase server-side (see `normalizeAddress`);
  /// Solana and Tezos are case-significant and pass through unchanged.
  String _cookieAddress(String address) =>
      address.startsWith('0x') ? address.toLowerCase() : address;

  /// Build the `/authToken/verify` body for [signature].
  ///
  /// Non-Solana chains add the `chain` discriminator the backend switches on;
  /// Tezos additionally sends the `publicKey` and `timestamp` it needs to
  /// rebuild and verify the Micheline payload.
  Map<String, dynamic> _verifyBody(
    String address,
    LoginChallengeSignature signature,
  ) => {
    'address': address,
    'message': _loginMessagePrefix,
    'signature': signature.signature,
    if (signature.chain != Chain.solana) 'chain': signature.chain.toDbString(),
    if (signature.publicKey != null) 'publicKey': signature.publicKey,
    if (signature.timestamp != null) 'timestamp': signature.timestamp,
  };

  /// Extract wallet-sig-{address} JWT from Set-Cookie response headers.
  String? _extractWalletSigCookie(Headers headers, String address) {
    final cookieKey = 'wallet-sig-$address=';
    final cookies = headers['set-cookie'];
    if (cookies == null) return null;
    for (final cookie in cookies) {
      if (cookie.startsWith(cookieKey)) {
        final cookiePart = cookie.split(';').first;
        final eqIndex = cookiePart.indexOf('=');
        if (eqIndex < 0) continue;
        return cookiePart.substring(eqIndex + 1);
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Ledger Verification Support
  // ---------------------------------------------------------------------------

  /// Called after external verification (e.g. Ledger transaction signing)
  /// succeeds. Extracts and caches the wallet-sig JWT from the response headers.
  Future<void> handleVerifyResponse(Headers headers, String address) async {
    final jwt = _extractWalletSigCookie(headers, address);
    if (jwt != null) {
      await _storage.storeWalletSigCookie(address, jwt);
      _walletSigCookies[address] = jwt;
      _refreshAuthInterceptor();
      AppLogger.debug(_tag, 'Wallet-sig JWT cached for $address (Ledger)');
    }

    // Store session expiry if present — not available from headers alone,
    // but callers may pass response data separately.
  }

  // ---------------------------------------------------------------------------
  // Private Methods
  // ---------------------------------------------------------------------------

  /// POST the `/v0/login` request for [address] — the active signing wallet,
  /// the one that produces the `wallet-sig` and acts on its behalf across the
  /// backend.
  ///
  /// The backend renders the user privileged only when the request already
  /// carries a valid `wallet-sig` cookie for [address] (see
  /// [_primeWalletSigCookie]). The [_AuthInterceptor] that normally attaches it
  /// is installed from a login's own Set-Cookie and removed again by
  /// [_clearSession], so on a cold start — and on every [switchWallet] — there
  /// is no interceptor to send a primed sig. Attach it here in exactly that
  /// case; when the interceptor IS installed it already sends the same map, and
  /// adding the pair again would only duplicate it.
  Future<Response<Map<String, dynamic>>> _postLogin(String address) {
    final cookieAddress = _cookieAddress(address);
    final sig = _dio.interceptors.whereType<_AuthInterceptor>().isEmpty
        ? _walletSigCookies[cookieAddress]
        : null;
    return _dio.post<Map<String, dynamic>>(
      '${Config.apiBaseUrl}/v0/login',
      data: {'address': address},
      options: sig == null
          ? null
          : Options(headers: {'Cookie': 'wallet-sig-$cookieAddress=$sig'}),
    );
  }

  /// Pull [address]'s valid on-disk `wallet-sig` into the in-memory cookie cache
  /// BEFORE the `/v0/login` POST, so the login itself is signed.
  ///
  /// `/v0/login` renders the user privileged only when the request already
  /// carries that sig. Historically a returning launch never did: the POST went
  /// out first, and the signature handshake that follows it short-circuits on
  /// exactly this cached sig ([_verifySignatureIfPossible]) — so
  /// `/v0/authToken/verify` never ran and nothing ever upgraded the public
  /// render. `currentUser.perks` then stayed empty for the whole session and an
  /// owned perk read as unowned. Priming costs one disk read and no extra round
  /// trip, and it covers the wallets that skip the handshake entirely — Ledger,
  /// and a social row whose key needs an interactive re-login — for which the
  /// login response is the only route to a privileged render.
  ///
  /// Best-effort: a storage failure must not break login.
  Future<void> _primeWalletSigCookie(String address) async {
    try {
      final result = await _lookupWalletSig(address);
      if (result.hydrated) _refreshAuthInterceptor();
    } catch (e) {
      AppLogger.warn(_tag, 'wallet-sig prime failed: $e');
    }
  }

  /// Whether a `user` render carries the privileged field block.
  ///
  /// The privileged render always emits `showNsfw` and `disabledChains` (the
  /// backend defaults them to `false` / `[]`), while the public one omits both
  /// keys outright — so their presence is the discriminator. `perks` and `roles`
  /// are not: the backend passes those through unset, so a privileged render for
  /// a user with neither omits them too.
  bool _isPrivilegedUserJson(Map<String, dynamic>? userJson) =>
      userJson != null &&
      (userJson.containsKey('showNsfw') ||
          userJson.containsKey('disabledChains'));

  Future<LoginResult> _loginWithAddress(String address) async {
    _sessionState = SessionState.loading;
    notifyListeners();

    try {
      // Sign the login request with a sig we already hold, so the response is
      // the privileged render rather than one nothing later upgrades.
      await _primeWalletSigCookie(address);

      // Use raw Dio to access response headers for cookie extraction.
      final response = await _postLogin(address);

      AppLogger.debug(_tag, 'Response received, extracting token...');
      // Extract login token from Set-Cookie header
      await _extractAndStoreLoginToken(response.headers);

      AppLogger.debug(_tag, 'Parsing response body...');
      // Parse response body
      final data = response.data;
      if (data == null) {
        throw AuthException('Empty response from login');
      }

      // Check for API error
      final err = data['err'];
      if (err != null) {
        final message = err['message'] as String? ?? 'Login failed';
        _sessionState = SessionState.error;
        notifyListeners();
        throw AuthException(message);
      }

      // Parse result
      final resultData = data['result'] as Map<String, dynamic>?;
      if (resultData == null) {
        throw AuthException('Invalid login response');
      }

      AppLogger.debug(_tag, 'Parsing LoginResult from: $resultData');
      final result = LoginResult.fromJson(resultData);
      AppLogger.debug(_tag, 'LoginResult parsed successfully');

      // Cache everything
      _currentAddress = address;
      _currentUser = result.user;
      _currentUserDetails = result.userDetails;
      _lastLoginResult = result;
      _currentUserIsPrivileged = _isPrivilegedUserJson(
        resultData['user'] as Map<String, dynamic>?,
      );

      // In a Profile session, mirror the user's server-side disabled chains
      // into the local Active Networks preference so the toggles and the
      // seed-import chain filter reflect the profile. See
      // [_hydrateActiveNetworksForProfile].
      await _hydrateActiveNetworksForProfile();

      // Likewise mirror the profile's server-side NSFW visibility into the
      // device preference the blur overlays read.
      await _hydrateShowNsfwForProfile();

      // Store session expiry
      if (result.expiresAt != null) {
        AppLogger.debug(_tag, 'Storing session expiry...');
        await _storage.storeSessionExpiry(result.expiresAt!);
      }

      _sessionState = SessionState.authenticated;
      notifyListeners();
      AppLogger.debug(_tag, 'Login complete!');

      // Record the successful backend authentication. Throttled inside the
      // service (30 min) — this path also runs on every cold start, wallet
      // switch and session refresh. Guarded on registration so unit tests that
      // drive login without a DI container skip it.
      if (GetIt.instance.isRegistered<AnalyticsService>()) {
        unawaited(GetIt.instance<AnalyticsService>().trackLogin());
      }

      // Attempt signature-based verification (every wallet that signs silently)
      await _verifySignatureIfPossible(address);

      // Cold-start hydration: pull EVERY other session wallet's valid on-disk
      // sig into the in-memory cookie cache the interceptor sends.
      await _hydrateSessionWalletSigs();

      return result;
    } on DioException catch (e, stack) {
      AppLogger.warn(_tag, 'DioException during login: $e');
      AppLogger.warn(_tag, 'Stack: $stack');
      _sessionState = SessionState.error;
      notifyListeners();

      final message =
          e.response?.data?['err']?['message'] as String? ??
          e.message ??
          'Network error';
      throw AuthException(message);
    } catch (e, stack) {
      AppLogger.warn(_tag, 'login error: $e');
      AppLogger.warn(_tag, 'Stack: $stack');
      _sessionState = SessionState.error;
      notifyListeners();

      if (e is AuthException) rethrow;
      throw AuthException(e.toString());
    }
  }

  /// Mirror the logged-in user's server-side [User.disabledChains] into the
  /// profile-scoped Active Networks preference — but only for a Profile session.
  /// Account sessions keep the setting device-local and never write it back, so
  /// hydrating from their (empty) server value would wrongly re-enable a
  /// locally-disabled chain; a null scope (Account session) is the gate that
  /// skips them. Each profile writes under its own scope, so profiles and the
  /// account scope stay isolated. Solana is always active and never written.
  ///
  /// A public render is skipped for the same reason: it omits `disabledChains`
  /// entirely, which parses to the empty default and is therefore
  /// indistinguishable from "nothing disabled" — mirroring it re-enables every
  /// chain the user turned off server-side. [_adoptPrivilegedUser] re-runs this
  /// once the privileged render arrives.
  ///
  /// Best-effort: a storage failure must not break login. [SessionManager] is
  /// looked up lazily via [GetIt] (rather than constructor-injected) to avoid a
  /// DI cycle with this service's pipeline.
  Future<void> _hydrateActiveNetworksForProfile() async {
    if (!_currentUserIsPrivileged) return;
    try {
      final scope = await GetIt.instance<SessionManager>().settingsScopeId();
      if (scope == null) return;
      final disabled = _currentUser?.disabledChains ?? const <String>[];
      await _storage.storeNetworkEnabled(
        Chain.tezos,
        !disabled.contains(Chain.tezos.toDbString()),
        scope: scope,
      );
      await _storage.storeNetworkEnabled(
        Chain.ethereum,
        !disabled.contains(Chain.ethereum.toDbString()),
        scope: scope,
      );
    } catch (e) {
      AppLogger.warn(_tag, 'active-networks hydrate failed: $e');
    }
  }

  /// Mirror the logged-in user's server-side [User.showNsfw] into the device
  /// preference the blur overlays read — but only for a Profile session.
  /// Account sessions keep the setting device-local and never write it back,
  /// so hydrating from their (default-false) server value would wrongly
  /// re-blur for a user who opted in locally. A public render is skipped for
  /// the same reason — it omits `showNsfw`, which parses to the same
  /// default-false. Best-effort, like [_hydrateActiveNetworksForProfile].
  Future<void> _hydrateShowNsfwForProfile() async {
    if (!_currentUserIsPrivileged) return;
    try {
      final scope = await GetIt.instance<SessionManager>().settingsScopeId();
      if (scope == null) return;
      final user = _currentUser;
      if (user == null) return;
      await GetIt.instance<PreferencesService>().setShowNsfw(user.showNsfw);
    } catch (e) {
      AppLogger.warn(_tag, 'showNsfw hydrate failed: $e');
    }
  }

  /// Hydrate the in-memory `wallet-sig` cookie cache from disk for every wallet
  /// in the current session — not just the active one [_verifySignatureIfPossible]
  /// covers.
  ///
  /// The Dio interceptor attaches only the in-memory snapshot, so after a cold
  /// start a non-active session wallet's proof would sit on disk while its
  /// hidden-state / sig-gated reads go out cookieless. This runs one cheap disk
  /// pass at login via [_lookupWalletSig] per address so every valid sig is
  /// hydrated — not just the first. The per-address lookups touch distinct
  /// cookie keys and are independent, so they run in parallel via [Future.wait],
  /// and the interceptor is refreshed once at the end (rather than per hit) if
  /// anything was hydrated.
  ///
  /// Best-effort: [SessionManager] is looked up lazily via [GetIt] (like the
  /// other login-time hydration helpers) and any failure must not break login.
  Future<void> _hydrateSessionWalletSigs() async {
    try {
      final session = GetIt.instance<SessionManager>();
      final results = await Future.wait(
        session.sessionAddresses.map(_lookupWalletSig),
      );
      if (results.any((r) => r.hydrated)) {
        _refreshAuthInterceptor();
      }
    } catch (e) {
      AppLogger.warn(_tag, 'session wallet-sig hydrate failed: $e');
    }
  }

  /// Extract login token from Set-Cookie response header and store it.
  Future<void> _extractAndStoreLoginToken(Headers headers) async {
    final cookies = headers['set-cookie'];
    if (cookies == null) return;

    for (final cookie in cookies) {
      if (cookie.startsWith('login-token=')) {
        // Extract token value (before the first semicolon)
        final tokenPart = cookie.split(';').first;
        final eqIndex = tokenPart.indexOf('=');
        if (eqIndex < 0) continue;
        final token = tokenPart.substring(eqIndex + 1);
        if (token.isNotEmpty) {
          await _storage.storeLoginToken(token);
          // Update Dio interceptor with new token
          _setupAuthInterceptor(token);
        }
        break;
      }
    }
  }

  /// Set up Dio interceptor to send login token with requests.
  void _setupAuthInterceptor(String token) {
    _dio.interceptors.removeWhere((i) => i is _AuthInterceptor);
    _dio.interceptors.add(
      _AuthInterceptor(
        token,
        Map.from(_walletSigCookies),
        mallowHosts: Config.sessionHosts,
      ),
    );
  }

  /// Refresh the auth interceptor with latest wallet-sig cookies.
  void _refreshAuthInterceptor() {
    // Find the existing interceptor's token (if any) and rebuild it
    final existing = _dio.interceptors
        .whereType<_AuthInterceptor>()
        .firstOrNull;
    if (existing != null) {
      _dio.interceptors.removeWhere((i) => i is _AuthInterceptor);
      _dio.interceptors.add(
        _AuthInterceptor(
          existing.token,
          Map.from(_walletSigCookies),
          mallowHosts: Config.sessionHosts,
        ),
      );
    }
  }

  /// Request an auth token, sign it, and verify with the backend.
  ///
  /// Wallets that cannot sign silently are skipped: view-only ones hold no key,
  /// Ledger needs an on-device confirmation, and a social wallet whose stored
  /// key is missing needs an interactive re-login.
  ///
  /// When [forceRefresh] is true, the cache check is skipped (used by the
  /// retry interceptor after a 401).
  Future<void> _verifySignatureIfPossible(
    String address, {
    bool forceRefresh = false,
  }) async {
    // The backend keys the wallet-sig cookie by the normalized address
    // (Ethereum lowercased; Solana/Tezos unchanged).
    final cookieAddress = _cookieAddress(address);
    try {
      // Cache check — skip re-sign if we already have a non-expired wallet-sig JWT
      if (!forceRefresh) {
        final cached = await _storage.loadWalletSigCookie(cookieAddress);
        if (cached != null && cached.isNotEmpty) {
          if (_isJwtExpired(cached)) {
            AppLogger.debug(
              _tag,
              'Wallet-sig expired for $cookieAddress — requesting new signature',
            );
            await _storage.deleteWalletSigCookie(cookieAddress);
            _walletSigCookies.remove(cookieAddress);
          } else {
            _walletSigCookies[cookieAddress] = cached;
            _refreshAuthInterceptor();
            AppLogger.debug(
              _tag,
              'Wallet-sig already cached for $cookieAddress',
            );
            return;
          }
        }
      }

      // Ledger wallets require interactive BLE confirmation — popping the
      // connect/verify sheet during a background login is jarring. Defer the
      // wallet-sig handshake until the user takes an action that actually
      // needs it (see [signAndVerifyForWallet], which routes through
      // [LedgerVerifyController]).
      if (await _walletManager.isLedgerWallet(address)) {
        AppLogger.debug(
          _tag,
          'Skipping background signature verification for Ledger '
          'wallet $address — will sign on demand',
        );
        return;
      }

      // A social wallet signs locally and silently from the key stored on this
      // device, so it falls through and signs like any imported-key wallet.
      // Only the restore case defers: a social row whose key is missing (wiped
      // keystore, restored DB, or a pre-migration row whose key never existed
      // here) sends every signing entry point into an interactive Web3Auth
      // re-login ([SocialAuthService.recoverKeysForAccount]).
      //
      // 🛑 Every caller of this method signs unprompted — the post-login
      // warm-up, [verifySessionWallet], [loginForLinkFlow], and the 401 retry
      // interceptor ([_handleSignatureRetry]) — so it must NEVER go
      // interactive. Hence the
      // presence probe before the sign, not a try/catch around it: the catch
      // would run only after the OAuth tab had already opened. The deferred
      // case is repaired by [signAndVerifyForWallet], which runs from a user
      // action where a login prompt is expected.
      if (await _walletManager.needsSocialKeyRecovery(address)) {
        AppLogger.debug(
          _tag,
          'Skipping background signature verification for social '
          'wallet $address — its key needs an interactive re-login',
        );
        return;
      }

      // Step 1: Request auth token
      AppLogger.debug(
        _tag,
        'Requesting auth token for signature verification...',
      );
      final tokenResponse = await _api.getAuthToken(
        AuthTokenRequest(address: cookieAddress),
      );
      final token = tokenResponse.result;

      // Step 2: Sign the chain-specific login challenge with the wallet matching
      // this address (not the active wallet, which may differ after
      // switchWallet). Throws ViewOnlyWalletException for view-only wallets;
      // social wallets sign locally from their stored key.
      final signature = await _walletManager.signLoginChallengeForAddress(
        address,
        message: _loginMessagePrefix,
        token: token,
      );

      // Step 3: Verify with backend via raw Dio to capture Set-Cookie header
      final response = await _dio.post<Map<String, dynamic>>(
        '${Config.apiBaseUrl}/v0/authToken/verify',
        data: _verifyBody(cookieAddress, signature),
      );

      // Step 4: Extract and cache the wallet-sig JWT from Set-Cookie
      final jwt = _extractWalletSigCookie(response.headers, cookieAddress);
      if (jwt != null) {
        await _storage.storeWalletSigCookie(cookieAddress, jwt);
        _walletSigCookies[cookieAddress] = jwt;
        _refreshAuthInterceptor();
        AppLogger.debug(_tag, 'Wallet-sig JWT cached for $cookieAddress');
      }

      // Store session expiry if present
      final resultData = response.data?['result'] as Map<String, dynamic>?;
      final expiresAt = resultData?['expiresAt'] as String?;
      if (expiresAt != null) {
        await _storage.storeSessionExpiry(expiresAt);
      }

      await _adoptPrivilegedUser(response.data, cookieAddress);

      AppLogger.debug(_tag, 'Signature verification succeeded');
    } on ViewOnlyWalletException {
      // View-only wallets hold no key to sign with — skip silently
      AppLogger.debug(
        _tag,
        'Skipping signature verification (view-only wallet)',
      );
    } catch (e) {
      // Non-fatal: basic login already succeeded
      AppLogger.warn(_tag, 'Signature verification failed (non-fatal): $e');
    }
  }

  /// Replace the cached user with the privileged render `/v0/authToken/verify`
  /// returns for [cookieAddress], if it carries one.
  ///
  /// `/v0/login` withholds the private fields — `perks`, the full `roles`,
  /// `showNsfw`, `disabledChains` — unless the request already carries a valid
  /// `wallet-sig` cookie for the address. [_primeWalletSigCookie] supplies one
  /// whenever a valid sig is already on disk, but the first login for a wallet
  /// (and any login after the 30-day sig lapses) has none, so that response is
  /// the public render and a perk the account owns reads as absent. Verify is
  /// where ownership is proven, and its response repeats the user privileged —
  /// adopting it here is what makes [currentUser] agree with what the backend
  /// will enforce.
  ///
  /// The two settings hydrations are re-run because they ran against that public
  /// render, which omits the exact fields they read: they would otherwise have
  /// mirrored "no chains disabled" and "NSFW off" over the user's real
  /// server-side settings. Both are idempotent writes derived from
  /// [_currentUser], and both no-op until this point via
  /// [_currentUserIsPrivileged].
  ///
  /// Guarded on the active address because [verifySessionWallet] runs the same
  /// handshake for *non-active* session wallets, and in an Account session
  /// those resolve to a different user entirely.
  Future<void> _adoptPrivilegedUser(
    Map<String, dynamic>? responseData,
    String cookieAddress,
  ) async {
    final address = _currentAddress;
    if (address == null || _cookieAddress(address) != cookieAddress) return;

    final result = responseData?['result'] as Map<String, dynamic>?;
    final userJson = result?['user'] as Map<String, dynamic>?;
    if (userJson == null) return;

    _currentUser = User.fromJson(userJson);
    _currentUserIsPrivileged = true;
    final detailsJson = result?['userDetails'] as Map<String, dynamic>?;
    if (detailsJson != null) {
      _currentUserDetails = UserDetails.fromJson(detailsJson);
    }

    await _hydrateActiveNetworksForProfile();
    await _hydrateShowNsfwForProfile();

    notifyListeners();
  }

  /// Decode a JWT and check whether it has expired.
  ///
  /// Returns `true` if the token is expired or cannot be decoded.
  /// Uses a 30-second buffer so we refresh slightly before actual expiry.
  bool _isJwtExpired(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return true;
      // JWT payload is base64url-encoded — normalize padding
      final payload = parts[1];
      final normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final data = jsonDecode(decoded) as Map<String, dynamic>;
      final exp = data['exp'] as num?;
      if (exp == null) return true;
      // Expired if current time is past exp (with 30s buffer)
      final expiryTime = DateTime.fromMillisecondsSinceEpoch(
        (exp.toInt()) * 1000,
      );
      return DateTime.now().isAfter(
        expiryTime.subtract(const Duration(seconds: 30)),
      );
    } catch (e) {
      AppLogger.warn(_tag, 'Failed to decode JWT for expiry check: $e');
      return true; // Treat decode failures as expired — will re-sign
    }
  }

  /// Silently refresh the login token without updating session state.
  ///
  /// Used by the retry interceptor when a 401 "Please log in" is received.
  /// Unlike [_loginWithAddress], this does not touch [_sessionState], cached
  /// user data, or notify listeners — it only refreshes the login-token cookie
  /// so the failed request can be retried transparently.
  Future<void> _refreshLoginToken(String address) async {
    final response = await _postLogin(address);
    await _extractAndStoreLoginToken(response.headers);
  }

  Future<void> _clearSession() async {
    _currentAddress = null;
    _currentUser = null;
    _currentUserDetails = null;
    _currentUserIsPrivileged = false;
    _lastLoginResult = null;
    _sessionState = SessionState.initial;

    await Future.wait([
      _storage.deleteLoginToken(),
      _storage.deleteSessionExpiry(),
      _storage.deleteAuthToken(),
    ]);

    // Remove auth interceptor
    _dio.interceptors.removeWhere((i) => i is _AuthInterceptor);
  }
}

/// Dio interceptor that adds the login token and any wallet-sig cookies.
///
/// 🛑 Host-guarded. These cookies are the session itself — `login-token` is the
/// bearer of the logged-in account and each `wallet-sig-<addr>` is a signed
/// proof of wallet ownership — and the Dio they ride on is the app's one shared
/// client, which also fetches Jupiter's public token search and the rewards
/// CDN. Attaching them unconditionally handed the user's live session to hosts
/// that have no part in it, and a third party is under no obligation to keep
/// what its logs capture. They go only to [mallowHosts] — [Config.sessionHosts],
/// which is the derived API hosts and nothing else.
///
/// 🛑 Deliberately NOT [Config.firstPartyHosts]. That set is configurable via
/// `FIRST_PARTY_HOSTS` and is wider; it carries headers that identify the
/// build. These cookies identify the *user*, so no build configuration may
/// widen where they travel.
class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(
    this.token,
    this.walletSigCookies, {
    required this.mallowHosts,
  });

  final String token;

  /// Per-address wallet-sig JWTs (address → JWT value).
  final Map<String, String> walletSigCookies;

  /// Hosts the session cookies may be sent to. Any other host is left
  /// untouched.
  final Set<String> mallowHosts;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!mallowHosts.contains(options.uri.host)) {
      return handler.next(options);
    }

    final parts = <String>['login-token=$token'];
    for (final entry in walletSigCookies.entries) {
      parts.add('wallet-sig-${entry.key}=${entry.value}');
    }

    final existing = options.headers['Cookie'] as String? ?? '';
    final combined = [if (existing.isNotEmpty) existing, ...parts].join('; ');
    options.headers['Cookie'] = combined;

    handler.next(options);
  }
}

/// Dio interceptor that catches 401 responses and automatically retries:
///
/// - **"Please log in"** — login token expired; silently re-calls `/v0/login`
///   to get a fresh token, then retries the original request.
/// - **"Signature required" / "Signature expired"** — wallet-sig JWT expired;
///   re-signs and verifies, then retries.
///
/// Uses a [Completer] guard to coalesce concurrent 401s into a single re-auth
/// flow. Marks retried requests with extra flags to prevent infinite loops.
class _SignatureRetryInterceptor extends Interceptor {
  _SignatureRetryInterceptor(this._authService, this._dio);

  final AuthService _authService;
  final Dio _dio;

  // Coalescing guard: only one re-auth at a time per address.
  final Map<String, Completer<void>> _pending = {};

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    if (response == null || response.statusCode != 401) {
      return handler.next(err);
    }

    final message = _extractErrorMessage(response.data);
    if (message == null) {
      return handler.next(err);
    }

    // Handle expired login token ("Please log in")
    if (message.contains('Please log in')) {
      return _handleLoginRetry(err, handler, message);
    }

    // Handle expired/missing wallet signature
    if (message.contains('Signature required') ||
        message.contains('Signature expired')) {
      return _handleSignatureRetry(err, handler, message);
    }

    return handler.next(err);
  }

  /// Make [options] safe to re-send. Dio's [FormData] is single-use — its byte
  /// stream is finalized on the first send, so retrying a multipart request
  /// (e.g. an `uploadUnlockableContent` asset) with the same instance throws
  /// "FormData has already been finalized". Swap in a fresh clone before any
  /// login/signature-refresh retry. Non-multipart bodies (JSON maps, strings)
  /// are re-readable and left untouched.
  void _rewindFormData(RequestOptions options) {
    final data = options.data;
    if (data is FormData) {
      options.data = data.clone();
    }
  }

  /// Re-login silently and retry the request when the login token has expired.
  Future<void> _handleLoginRetry(
    DioException err,
    ErrorInterceptorHandler handler,
    String message,
  ) async {
    // Prevent infinite retry loop
    if (err.requestOptions.extra['_loginRetry'] == true) {
      return handler.next(err);
    }

    final address = _authService._currentAddress;
    if (address == null) {
      return handler.next(err);
    }

    AppLogger.warn(
      _tag,
      '401 "$message" — refreshing login token for $address',
    );

    try {
      // Coalesce concurrent login refreshes
      const loginKey = '_login';
      if (_pending.containsKey(loginKey) && !_pending[loginKey]!.isCompleted) {
        await _pending[loginKey]!.future;
      } else {
        final completer = Completer<void>();
        _pending[loginKey] = completer;
        try {
          await _authService._refreshLoginToken(address);
          completer.complete();
        } catch (e) {
          completer.completeError(e);
          rethrow;
        }
      }

      // Retry the original request with fresh cookies
      final options = err.requestOptions;
      options.extra['_loginRetry'] = true;
      options.headers.remove('Cookie');
      _rewindFormData(options);

      final retryResponse = await _dio.fetch<dynamic>(options);
      return handler.resolve(retryResponse);
    } catch (e) {
      AppLogger.warn(_tag, 'Login token refresh failed: $e');
      return handler.next(err);
    }
  }

  /// Re-sign and retry the request when the wallet signature has expired.
  ///
  /// For Ledger wallets, routes through [LedgerVerifyController] to show an
  /// interactive bottom sheet (the user must connect and confirm on device).
  /// For all other wallets, signs silently in the background.
  Future<void> _handleSignatureRetry(
    DioException err,
    ErrorInterceptorHandler handler,
    String message,
  ) async {
    // Prevent infinite retry loop
    if (err.requestOptions.extra['_signatureRetry'] == true) {
      return handler.next(err);
    }

    final address = _authService._currentAddress;
    if (address == null) {
      return handler.next(err);
    }

    AppLogger.warn(
      _tag,
      '401 "$message" — attempting signature refresh for $address',
    );

    try {
      // Check if this is a Ledger wallet — requires interactive UI
      final isLedger = await _authService._walletManager.isLedgerWallet(
        address,
      );

      if (isLedger) {
        AppLogger.debug(
          _tag,
          'Ledger wallet detected — routing to interactive verification',
        );
        final controller = GetIt.instance<LedgerVerifyController>();
        final success = await controller.requestVerification(address);
        if (!success) {
          AppLogger.warn(_tag, 'Ledger verification cancelled or failed');
          return handler.next(err);
        }
      } else {
        // Existing silent signing flow for HD / importedKey / social wallets
        if (_pending.containsKey(address) && !_pending[address]!.isCompleted) {
          await _pending[address]!.future;
        } else {
          final completer = Completer<void>();
          _pending[address] = completer;
          try {
            await _authService._verifySignatureIfPossible(
              address,
              forceRefresh: true,
            );
            completer.complete();
          } catch (e) {
            completer.completeError(e);
            rethrow;
          }
        }
      }

      // Retry the original request with fresh cookies
      final options = err.requestOptions;
      options.extra['_signatureRetry'] = true;
      // Strip stale Cookie header so _AuthInterceptor rebuilds it
      options.headers.remove('Cookie');
      _rewindFormData(options);

      final retryResponse = await _dio.fetch<dynamic>(options);
      return handler.resolve(retryResponse);
    } on ViewOnlyWalletException {
      AppLogger.warn(
        _tag,
        'Cannot re-sign for view-only wallet — surfacing SignatureRequiredException',
      );
      final sigErr = DioException(
        requestOptions: err.requestOptions,
        response: err.response,
        error: SignatureRequiredException(message),
      );
      return handler.next(sigErr);
    } catch (e) {
      AppLogger.warn(_tag, 'Signature retry failed: $e');
      return handler.next(err);
    }
  }

  /// Extract error message from response data.
  ///
  /// Checks both `data['error']['message']` (current API format) and
  /// `data['err']['message']` (legacy format).
  String? _extractErrorMessage(dynamic data) {
    if (data is! Map<String, dynamic>) return null;
    // Current format: { "error": { "message": "..." } }
    final error = data['error'];
    if (error is Map<String, dynamic>) {
      final msg = error['message'];
      if (msg is String) return msg;
    }
    // Legacy format: { "err": { "message": "..." } }
    final err = data['err'];
    if (err is Map<String, dynamic>) {
      final msg = err['message'];
      if (msg is String) return msg;
    }
    return null;
  }
}

/// Exception thrown when authentication fails.
class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => 'AuthException: $message';
}

/// Exception thrown when a 401 "Signature required" cannot be resolved
/// because the wallet is view-only, social, or hardware (cannot sign).
///
/// UI can catch this to show appropriate messaging (e.g. "Switch to an HD
/// wallet to access this feature").
class SignatureRequiredException implements Exception {
  SignatureRequiredException(this.message);

  final String message;

  @override
  String toString() => 'SignatureRequiredException: $message';
}

/// Thrown when the interactive Ledger connect + verify sheet does not produce a
/// wallet-sig — the user dismissed it, or the BLE/APDU exchange failed. The
/// sheet itself already shows the specific reason, so a caller catching this
/// only needs to abort with its own short copy.
///
/// Typed on purpose: without it a caller cannot tell a dismissed sheet from a
/// storage/database failure on the same wallet, and ends up guessing from
/// `walletType.isHardware`.
class LedgerVerificationCancelledException implements Exception {
  LedgerVerificationCancelledException([
    this.message = 'Ledger verification cancelled',
  ]);

  final String message;

  @override
  String toString() => 'LedgerVerificationCancelledException: $message';
}
