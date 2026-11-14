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
import '../models/account.dart';
import '../observability/app_logger.dart';
import '../security/secure_storage.dart';
import '../services/preferences_service.dart';
import '../session/session_manager.dart';
import 'hardware_verify_controller.dart';

import '../../shared/utils/chain.dart';

const _tag = 'AuthService';

/// Dio request `extra` key: set it to `true` on a request that must never
/// re-sign on a 401 "Signature required" / "Signature expired".
///
/// For background reads — a fetch the user did not ask for, such as the block
/// list a profile view loads. The re-sign on a hardware wallet opens the verify
/// sheet, so a background read without this would ask for a signature every
/// time it ran. The 401 reaches the caller instead. The "Please log in" refresh
/// still runs, because it prompts nobody.
const String kSkipSignatureRetryExtra = 'skipSignatureRetry';

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
/// A session is started with `POST /v2/session` and the user read from
/// `GET /v0/currentUser`:
/// - On every app startup (after unlock)
/// - After onboarding completion (before showing home)
/// - When switching wallets (multi-wallet support)
///
/// `/v2/session` is not a login and proves nothing: it sets the `login-token`
/// cookie for an address and returns only `{address, expiresAt}`. The user
/// comes from `/v0/currentUser`, privileged (with following, likes and gumball
/// invites) only when the request carries a valid `wallet-sig` for the address;
/// otherwise it is the public render and those fields are empty — the
/// anonymous view, never a signature prompt just to fill them. The session is
/// started every time to ensure fresh data and trigger backend indexing jobs.
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

  /// Bumped every time the session is cleared, which is what a wallet switch
  /// and a logout both start with. A login captures it when it starts and
  /// stops the moment it differs: a login is two requests with state assigned
  /// after the second, so one that was overtaken (a resume refresh for the
  /// previous wallet, still on the wire when the user switched) would
  /// otherwise finish last and put its own address and login token over the
  /// newer session's.
  int _loginGeneration = 0;

  /// The `wallet-sig` proofs the auth interceptor sends on every API request
  /// (cookie address → JWT), least recently used first.
  ///
  /// 🛑 Bounded, by [maxSharedWalletProofs] and [maxSharedWalletProofBytes],
  /// because the whole map is one `Cookie` header and servers refuse a header
  /// that grows too large: unbounded, a device with a few dozen wallets fails
  /// every request it makes. Write it only through [_rememberWalletSig], which
  /// keeps the bound. What it holds, in order of claim:
  ///
  /// 1. the logged-in wallet's proof, and the link flow's — always;
  /// 2. proofs a caller asked for or signed this run, most recent first;
  /// 3. the rest of the session's wallets, in the session's own order, while
  ///    there is room ([_hydrateSessionWalletSigs]).
  ///
  /// A proof left out is still on disk: [hasValidWalletSigForAny] brings it
  /// back, at the cost of the least recently used one.
  final Map<String, String> _walletSigCookies = {};

  /// How many proofs the shared cookies carry at most. With the byte cap below
  /// this leaves room in the header for the login token and for the
  /// proofs a single request adds for itself (a push sync carries eight).
  @visibleForTesting
  static const maxSharedWalletProofs = 8;

  /// The most bytes of `Cookie` header the shared proofs may take, names and
  /// separators included. A proof is about 300 bytes; this holds if they grow.
  @visibleForTesting
  static const maxSharedWalletProofBytes = 3072;

  final ValueNotifier<int> _walletSigRevision = ValueNotifier(0);

  /// Fires each time the auth interceptor is rebuilt, which is when the set
  /// of `wallet-sig` cookies the next request carries may have changed: a
  /// fresh signature, a proof pulled in from disk, or a new login token.
  ///
  /// A background read that waits for a proof listens to this, then asks
  /// [canSendBackgroundSignedRead] again. The event does not say a proof
  /// exists.
  Listenable get walletSigChanges => _walletSigRevision;

  /// Set while [loginForLinkFlow] has the login token of an address other than
  /// [currentAddress] installed. A read sent then would run as that profile.
  String? _linkFlowAddress;

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

  /// True if the active wallet signs on external hardware (Ledger or
  /// Seed Vault) AND we don't have a usable wallet-sig cookie cached for it
  /// — i.e. callers about to perform an action that implies wallet identity
  /// (e.g. casting) should prompt the user through [HardwareVerifyController]
  /// before proceeding.
  ///
  /// Hardware-generic because the answer is the same for both devices: the
  /// signature needs an approval outside this process, so it cannot be
  /// conjured mid-action.
  Future<bool> currentWalletNeedsHardwareVerification() async {
    final addr = _currentAddress;
    if (addr == null) return false;
    if (!await _walletManager.isHardwareWallet(addr)) return false;
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

  /// Whether a signed read the user did not ask for (the block list behind a
  /// profile view, the drawer's unread badge) may go out now without any
  /// chance of a signature prompt.
  ///
  /// True only when there is a logged-in address, it holds a valid
  /// `wallet-sig` (memory or disk, see [hasValidWalletSigForAny]), and the
  /// installed login token is that address's own — not the one
  /// [loginForLinkFlow] swaps in for the profile being linked into. Such a read
  /// also sends [kSkipSignatureRetryExtra], so a proof the server no longer
  /// accepts is a quiet 401 rather than a prompt.
  Future<bool> canSendBackgroundSignedRead() async {
    final address = _currentAddress;
    if (address == null || _linkFlowAddress != null) return false;
    final valid = await hasValidWalletSigForAny([address]);
    // Re-read after the await: a switch or a link flow may have started.
    return valid && _currentAddress == address && _linkFlowAddress == null;
  }

  /// Look up a single [address]'s `wallet-sig` in the in-memory cache, then on
  /// disk, hydrating a valid disk-only hit into [_walletSigCookies] WITHOUT
  /// refreshing the interceptor. Returns whether a valid sig was found and
  /// whether a disk value was hydrated — so the caller can refresh the
  /// interceptor once (rather than once per hit) after the lookups complete.
  ///
  /// Either hit counts as a use: the proof becomes the most recently used one,
  /// and a hydrated one may push the least recently used out
  /// ([_rememberWalletSig]).
  Future<({bool valid, bool hydrated})> _lookupWalletSig(String address) async {
    if (address.isEmpty) return (valid: false, hydrated: false);
    final cookieAddress = _cookieAddress(address);

    final inMemory = _walletSigCookies[cookieAddress];
    if (inMemory != null && inMemory.isNotEmpty && !_isJwtExpired(inMemory)) {
      _rememberWalletSig(cookieAddress, inMemory);
      return (valid: true, hydrated: false);
    }

    final disk = await _storage.loadWalletSigCookie(cookieAddress);
    if (disk != null && disk.isNotEmpty && !_isJwtExpired(disk)) {
      _rememberWalletSig(cookieAddress, disk);
      return (valid: true, hydrated: true);
    }
    return (valid: false, hydrated: false);
  }

  /// Put [jwt] in the shared cookies as [cookieAddress]'s proof and the most
  /// recently used one, then drop the least recently used proofs that no
  /// longer fit. Never drops the one just added, the logged-in wallet's, or
  /// the link flow's.
  void _rememberWalletSig(String cookieAddress, String jwt) {
    _walletSigCookies.remove(cookieAddress);
    _walletSigCookies[cookieAddress] = jwt;

    final pinned = {
      cookieAddress,
      if (_currentAddress case final active?) _cookieAddress(active),
      if (_linkFlowAddress case final linked?) _cookieAddress(linked),
    };
    for (final candidate in _walletSigCookies.keys.toList()) {
      if (_sharedWalletSigsFit(_walletSigCookies)) break;
      if (!pinned.contains(candidate)) _walletSigCookies.remove(candidate);
    }
  }

  /// Whether [proofs] is within both caps on the shared cookies.
  static bool _sharedWalletSigsFit(Map<String, String> proofs) {
    if (proofs.length > maxSharedWalletProofs) return false;
    var bytes = 0;
    for (final MapEntry(key: address, value: jwt) in proofs.entries) {
      bytes += _walletSigCookie(address, jwt).length + 2; // "; "
    }
    return bytes <= maxSharedWalletProofBytes;
  }

  /// One proof as it is written in a `Cookie` header.
  static String _walletSigCookie(String cookieAddress, String jwt) =>
      'wallet-sig-$cookieAddress=$jwt';

  /// [address]'s `wallet-sig` proof from disk as a `Cookie` header fragment, for
  /// one request that needs it, or null when it has none.
  ///
  /// Read-only. 🛑 This must not put the proof in [_walletSigCookies]: the
  /// interceptor sends that map on every API request, and it has room for a
  /// few proofs only. One for every wallet on a device with many of them would
  /// push out the proofs the session's own reads need.
  Future<String?> storedWalletProofCookie(String address) async {
    final cookieAddress = _cookieAddress(address);
    final jwt = await _storage.loadWalletSigCookie(cookieAddress);
    if (jwt == null || jwt.isEmpty || _isJwtExpired(jwt)) return null;
    return _walletSigCookie(cookieAddress, jwt);
  }

  /// Sign for [address]'s proof without prompting and return it as
  /// [storedWalletProofCookie] does. Kept out of [_walletSigCookies] too, unless
  /// [address] is the logged-in wallet.
  ///
  /// Null when the wallet cannot sign without the user: a hardware wallet, or a
  /// social wallet whose key needs an interactive re-login. Throws when the
  /// handshake fails.
  Future<String?> signWalletProofCookie(String address) async {
    if (await _walletManager.isHardwareWallet(address) ||
        await _walletManager.needsSocialKeyRecovery(address)) {
      return null;
    }
    // The logged-in wallet's proof belongs in the shared cookies: the session's
    // own reads need it, and one wallet cannot outgrow the header limit.
    final active = _currentAddress;
    final jwt = await _signAndCacheWalletSig(
      address,
      keepInSharedCookies:
          active != null && _cookieAddress(active) == _cookieAddress(address),
    );
    return jwt == null ? null : _walletSigCookie(_cookieAddress(address), jwt);
  }

  /// Delete [address]'s stored proof after the backend refused it, so the next
  /// sign makes a fresh one. Its local expiry says nothing about a proof the
  /// backend no longer accepts for reasons of its own.
  ///
  /// Only if it is still the one [sentCookie] carried: a re-sign that finished
  /// while the request was out has stored a good proof, which on a hardware
  /// wallet took an approval.
  Future<void> discardWalletProof(String address, String sentCookie) async {
    final cookieAddress = _cookieAddress(address);
    final stored = await _storage.loadWalletSigCookie(cookieAddress);
    if (stored == null ||
        _walletSigCookie(cookieAddress, stored) != sentCookie) {
      return;
    }
    await _storage.deleteWalletSigCookie(cookieAddress);
    if (_walletSigCookies.remove(cookieAddress) != null) {
      _refreshAuthInterceptor();
    }
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
  /// active signer. HD, imported and social wallets sign immediately; hardware
  /// (Ledger, Seed Vault), view-only and key-less social wallets are
  /// deferred/skipped (see [_verifySignatureIfPossible]).
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
    return _loginOrJoinNewer(address);
  }

  /// [_loginWithAddress] for a caller that wants a session, not this one
  /// login: the startup login and the resume refresh.
  ///
  /// If a wallet switch overtakes the login, the session it asked for exists
  /// all the same — the switch's. So the caller gets that login's result
  /// rather than an error for a session that is, in fact, up: the startup
  /// screen would otherwise offer "retry" over a logged-in app. Overtaken by a
  /// logout there is no session to hand over, and the error stands.
  ///
  /// Not for [switchWallet]'s own login: a switch that was overtaken must
  /// fail, not adopt a later one's session and then tear it down.
  Future<LoginResult> _loginOrJoinNewer(String address) async {
    try {
      return await _loginWithAddress(address);
    } on _SupersededLogin {
      final switching = _pendingSwitchCompleter;
      if (switching != null && !switching.isCompleted) return switching.future;
      final current = _lastLoginResult;
      if (hasSession && current != null) return current;
      rethrow;
    }
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
      _pruneWalletSigsToSession(newAddress);
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
  ///
  /// 🛑 A no-op while [loginForLinkFlow] has another profile's login token
  /// installed. The link flow signs on hardware (a Seed Vault approval
  /// backgrounds the app), so the resume refresh lands in the middle of it,
  /// and re-logging the active wallet in there would put ITS token on
  /// `approveLinkRequestV2`, linking the new wallet to the wrong profile. The
  /// flow's own restore call puts the active wallet's token back.
  ///
  /// While a wallet switch is in flight or queued this returns that switch's
  /// login instead of starting one: the switch is already fetching fresh data,
  /// and a second login beside it could be for a different address (the
  /// session is cleared mid-switch, so this would fall back to whatever wallet
  /// is selected) and finish after it. A refresh that started BEFORE the
  /// switch is stopped by [_loginGeneration], and answers with the switch's
  /// login too ([_loginOrJoinNewer]).
  Future<LoginResult> refresh() async {
    final last = _lastLoginResult;
    if (_linkFlowAddress != null && last != null) return last;
    final switching = _pendingSwitchCompleter;
    if (switching != null && !switching.isCompleted) return switching.future;
    if (_currentAddress == null) {
      return initializeSession();
    }
    return _loginOrJoinNewer(_currentAddress!);
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

    // Push is deliberately NOT unregistered here. The device's token is mapped
    // to the wallets held on this device, not to a session: those wallets are
    // still present after a logout, so their notifications should keep
    // arriving. A wipe removes the wallets, and the resulting
    // `WalletRepository` mutation re-syncs an empty set on its own.

    await _clearSession();
    // The per-address ownership proofs go with the session. Not inside
    // _clearSession: the wallet-switch path clears the session too, and there
    // the proofs of the session being switched to must survive — multi-wallet
    // reads legitimately widen across its wallets
    // ([_pruneWalletSigsToSession]).
    _walletSigCookies.clear();
    notifyListeners();
  }

  /// Forget the in-memory wallet-sig proof for [address] — called when a
  /// wallet is removed from the device, so a later re-import of the same
  /// address cannot ride on the removed wallet's proof. The on-disk copy is
  /// the repository's to delete.
  void forgetWalletSig(String address) {
    _walletSigCookies.remove(_cookieAddress(address));
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
    final response = await _postSession(address);
    // A swap is flagged before the token goes in: installing it notifies
    // [walletSigChanges], and a background read must not run as the profile
    // being linked into. The flow's second call, back to the active address,
    // clears the flag only once that address's own token is installed — until
    // then the swapped one is still what requests carry.
    final active = _currentAddress;
    final ownToken =
        active != null && _cookieAddress(active) == _cookieAddress(address);
    if (!ownToken) _linkFlowAddress = address;
    await _extractAndStoreLoginToken(response.headers);
    if (ownToken) _endLinkFlowToken();
    // Also run signature verification for this address so the wallet-sig
    // cookie is fresh for the subsequent approveLinkRequestV2 call.
    await _verifySignatureIfPossible(address);
  }

  /// True while [loginForLinkFlow] has another profile's login token
  /// installed.
  bool get linkFlowActive => _linkFlowAddress != null;

  /// Whether the installed login token is [address]'s: the profile
  /// [loginForLinkFlow] swapped in, or else the logged-in address's own. The
  /// link flow checks it before `approveLinkRequestV2`, which acts on whoever
  /// the login token names — a wallet switch mid-flow would make that someone
  /// else.
  bool loginTokenIsFor(String address) {
    final installed = _linkFlowAddress ?? _currentAddress;
    return installed != null &&
        _cookieAddress(installed) == _cookieAddress(address);
  }

  /// Drops the login token [loginForLinkFlow] swapped in, when the flow could
  /// not put the active wallet's back (its `/v2/session` failed, or there is no
  /// logged-in address to restore). Left in place, the flag would keep the
  /// resume refresh and the background reads off and send every "Please log
  /// in" retry to the linked profile until a switch or logout.
  ///
  /// Like a logout of that profile only: the session, the user and every
  /// `wallet-sig` proof stay. With no login token the next request answers
  /// "Please log in", and the ordinary retry logs the active wallet in.
  Future<void> abandonLinkFlowToken() async {
    if (_linkFlowAddress == null) return;
    _dio.interceptors.removeWhere((i) => i is _AuthInterceptor);
    try {
      await _storage.deleteLoginToken();
    } catch (e) {
      AppLogger.warn(_tag, 'dropping the link-flow login token failed: $e');
    }
    _endLinkFlowToken();
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
        _rememberWalletSig(cookieAddress, cached);
        _refreshAuthInterceptor();
        AppLogger.debug(_tag, 'Wallet-sig already cached for $cookieAddress');
        return;
      }
    }

    // Ledger proves ownership by signing a memo *transaction* over BLE — a
    // shape only [LedgerAuthService], inside the verify sheet, produces, and
    // one the ordinary handshake below cannot. Seed Vault and Keystone sign
    // the challenge verbatim, so they fall through to that handshake and the
    // OS approval screen or the QR exchange appears there: this method only
    // ever runs from a user action, so an approval is what the user just
    // asked for.
    if (await _walletManager.isHardwareWallet(address) &&
        await hardwareVerifyDeviceFor(address) == WalletType.ledger) {
      AppLogger.debug(
        _tag,
        'Ledger wallet — routing to interactive verification',
      );
      final controller = GetIt.instance<HardwareVerifyController>();
      final success = await controller.requestVerification(
        address,
        walletType: WalletType.ledger,
      );
      if (!success) {
        throw HardwareVerificationCancelledException();
      }
      return; // JWT already cached by HardwareVerifySheet
    }

    // Step 1: Request the complete SIWS message for Solana, or a legacy nonce.
    final isSolana = Chain.fromAddress(address) == Chain.solana;
    final challengeResponse = await _api.getAuthToken(
      AuthTokenRequest(
        address: cookieAddress,
        format: isSolana ? 'siws' : null,
      ),
    );
    final challenge = challengeResponse.result;

    // Step 2: Sign the chain-specific login challenge
    final signature = await _walletManager.signLoginChallenge(
      walletId,
      message: isSolana ? challenge : _loginMessagePrefix,
      token: isSolana ? null : challenge,
    );

    // Step 3: Verify with backend via raw Dio to capture Set-Cookie header
    final response = await _dio.post<Map<String, dynamic>>(
      '${Config.apiBaseUrl}/v0/authToken/verify',
      data: _verifyBody(
        cookieAddress,
        signature,
        message: isSolana ? challenge : null,
      ),
    );

    // Step 4: Extract and cache the wallet-sig JWT from Set-Cookie
    final jwt = _extractWalletSigCookie(response.headers, cookieAddress);
    if (jwt != null) {
      await _storage.storeWalletSigCookie(cookieAddress, jwt);
      _rememberWalletSig(cookieAddress, jwt);
      _refreshAuthInterceptor();
      AppLogger.debug(_tag, 'Wallet-sig JWT cached for $cookieAddress');
    }

    await _adoptPrivilegedUser(response.data, cookieAddress);
    // Not awaited: this runs inside the 401 re-sign, and the original
    // request's replay must not wait on a second read.
    unawaited(_reloadPersonalData(cookieAddress));
  }

  /// Legacy Ethereum and Tezos challenge prefix.
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
    LoginChallengeSignature signature, {
    String? message,
  }) => {
    'address': address,
    'message': message ?? _loginMessagePrefix,
    if (signature.chain == Chain.solana) 'format': 'siws',
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
      _rememberWalletSig(address, jwt);
      _refreshAuthInterceptor();
      AppLogger.debug(_tag, 'Wallet-sig JWT cached for $address (Ledger)');
      unawaited(_reloadPersonalData(address));
    }

    // Store session expiry if present — not available from headers alone,
    // but callers may pass response data separately.
  }

  // ---------------------------------------------------------------------------
  // Private Methods
  // ---------------------------------------------------------------------------

  /// `POST /v2/session` for [address] — the active signing wallet, the one
  /// that produces the `wallet-sig` and acts on its behalf across the backend.
  ///
  /// Sets the `login-token` cookie (scraped by [_extractAndStoreLoginToken])
  /// and answers `{result: {address, expiresAt}}`, nothing else. Raw Dio, not
  /// a retrofit client, because the token is read off `Set-Cookie`.
  Future<Response<Map<String, dynamic>>> _postSession(String address) =>
      _dio.post<Map<String, dynamic>>(
        '${Config.apiV2BaseUrl}/session',
        data: {'address': address},
      );

  /// `GET /v0/currentUser` — the user behind the installed login token, and
  /// its `result` map.
  ///
  /// Privileged (the private user fields, plus `following`,
  /// `likesByContentType`, `subscriptions` and `invitedGumballCount`) only when
  /// the request carries a valid `wallet-sig` for the address, which the auth
  /// interceptor attaches from [_walletSigCookies] (see
  /// [_primeWalletSigCookie]); the public render otherwise.
  Future<Map<String, dynamic>> _getCurrentUser() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '${Config.apiBaseUrl}/v0/currentUser',
    );
    final result = response.data?['result'];
    if (result is! Map<String, dynamic> || result['user'] is! Map) {
      throw AuthException('Invalid currentUser response');
    }
    return result;
  }

  /// After a proof was obtained for the active wallet, re-read the signed
  /// `/v0/currentUser` for the personal fields — `following`, likes, gumball
  /// invites — which the session start left empty when it had no proof yet.
  /// Best-effort and fire-and-forget at every call site (it logs its own
  /// failure): the user and details were already adopted, and a re-sign's
  /// replay of the original request must not wait on it.
  Future<void> _reloadPersonalData(String cookieAddress) async {
    final address = _currentAddress;
    if (address == null || _cookieAddress(address) != cookieAddress) return;
    // Mid link flow the installed token is the linked profile's: the read
    // would answer for that account.
    if (_linkFlowAddress != null) return;
    try {
      final result = await _getCurrentUser();
      if (_currentAddress != address) return;
      if (!_isPrivilegedUserJson(result['user'] as Map<String, dynamic>?)) {
        return;
      }
      final signed = LoginResult.fromJson(result);
      final last = _lastLoginResult;
      _lastLoginResult = (last ?? signed).copyWith(
        following: signed.following,
        likesByContentType: signed.likesByContentType,
        invitedGumballCount: signed.invitedGumballCount,
      );
      notifyListeners();
    } catch (e) {
      AppLogger.warn(_tag, 'personal data reload failed: $e');
    }
  }

  /// Pull [address]'s valid on-disk `wallet-sig` into the in-memory cookie cache
  /// BEFORE the session starts, so the interceptor the session installs sends
  /// it and the `/v0/currentUser` read that follows is the signed render.
  ///
  /// `/v0/currentUser` renders the user privileged only when the request
  /// carries that sig. Historically a returning launch never did: the request
  /// went out first, and the signature handshake that follows it short-circuits on
  /// exactly this cached sig ([_verifySignatureIfPossible]) — so
  /// `/v0/authToken/verify` never ran and nothing ever upgraded the public
  /// render. `currentUser.perks` then stayed empty for the whole session and an
  /// owned perk read as unowned. Priming costs one disk read and no extra round
  /// trip, and it covers the wallets that skip the handshake entirely —
  /// hardware wallets, and a social row whose key needs an interactive
  /// re-login — for which this read is the only route to a privileged render.
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

  /// Log [address] in: start the session, read its user, and only then assign
  /// the session state.
  ///
  /// 🛑 Every step after an `await` is behind `ensureCurrent()`. A login that
  /// was overtaken by a wallet switch or a logout ([_loginGeneration]) must
  /// install no login token, assign no address or user, and report no state —
  /// not even `error`, which would land on top of the newer session. However
  /// it ends, it ends with a [_SupersededLogin] and leaves everything as the
  /// newer one set it.
  Future<LoginResult> _loginWithAddress(String address) async {
    final generation = _loginGeneration;
    bool isCurrent() => generation == _loginGeneration;
    void ensureCurrent() {
      if (!isCurrent()) throw _SupersededLogin();
    }

    _sessionState = SessionState.loading;
    notifyListeners();

    try {
      // Sign the login request with a sig we already hold, so the response is
      // the privileged render rather than one nothing later upgrades.
      await _primeWalletSigCookie(address);
      ensureCurrent();

      // Raw Dio, for the Set-Cookie header.
      final response = await _postSession(address);
      ensureCurrent();

      AppLogger.debug(_tag, 'Session started, extracting token...');
      await _extractAndStoreLoginToken(response.headers, isCurrent: isCurrent);
      ensureCurrent();

      final data = response.data;
      if (data == null) {
        throw AuthException('Empty response from session');
      }
      // The legacy `{err}` envelope on a 200; the Rust route answers errors
      // with a status and `{error}`, which Dio throws (handled below).
      final err = data['err'] ?? data['error'];
      if (err != null) {
        final message =
            (err is Map ? err['message'] as String? : null) ?? 'Login failed';
        _sessionState = SessionState.error;
        notifyListeners();
        throw AuthException(message);
      }
      final session = data['result'] as Map<String, dynamic>?;
      if (session == null) {
        throw AuthException('Invalid session response');
      }

      // The user, from the route that renders it privileged only for a caller
      // holding this address's proof (primed above).
      final resultData = await _getCurrentUser();
      ensureCurrent();
      final result = LoginResult.fromJson({
        ...resultData,
        'expiresAt': session['expiresAt'],
      });

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
      ensureCurrent();

      // Likewise mirror the profile's server-side NSFW visibility into the
      // device preference the blur overlays read.
      await _hydrateShowNsfwForProfile();
      ensureCurrent();

      // Store session expiry
      if (result.expiresAt != null) {
        AppLogger.debug(_tag, 'Storing session expiry...');
        await _storage.storeSessionExpiry(result.expiresAt!);
        ensureCurrent();
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
      ensureCurrent();

      // Cold-start hydration: pull the other session wallets' valid on-disk
      // sigs into the in-memory cookie cache the interceptor sends, as far as
      // it has room.
      await _hydrateSessionWalletSigs();
      ensureCurrent();

      return result;
    } on _SupersededLogin {
      AppLogger.debug(_tag, 'Login superseded by a wallet switch or logout');
      rethrow;
    } on DioException catch (e, stack) {
      // The state belongs to whichever login is current: a superseded one
      // failing late must not mark the newer session as failed, and its
      // failure is of no interest to anyone.
      if (!isCurrent()) throw _SupersededLogin();
      AppLogger.warn(_tag, 'DioException during login: $e');
      AppLogger.warn(_tag, 'Stack: $stack');
      _sessionState = SessionState.error;
      notifyListeners();

      final body = e.response?.data;
      final envelope = body is Map ? (body['error'] ?? body['err']) : null;
      final message =
          (envelope is Map ? envelope['message'] as String? : null) ??
          e.message ??
          'Network error';
      throw AuthException(message);
    } catch (e, stack) {
      if (!isCurrent()) throw _SupersededLogin();
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

  /// Hydrate the in-memory `wallet-sig` cookie cache from disk for the wallets
  /// in the current session — not just the active one
  /// [_verifySignatureIfPossible] covers.
  ///
  /// The Dio interceptor attaches only the in-memory snapshot, so after a cold
  /// start a non-active session wallet's proof would sit on disk while the
  /// reads that widen across the session's wallets — a profile's private
  /// curations, hidden artworks — go out without it. This runs one disk pass at
  /// login: the reads are independent and run in parallel, and the interceptor
  /// is refreshed once at the end if anything was hydrated.
  ///
  /// 🛑 It only fills the room the shared cookies have left
  /// ([maxSharedWalletProofs]), in the session's own wallet order, and never
  /// pushes out a proof that is already there: push sync stores a proof for
  /// every wallet the app holds a key for, so "every proof on disk" can be
  /// more than one `Cookie` header may carry. A proof that was used this run
  /// outranks one that was merely found. A wallet left out here still gets its
  /// proof when a caller asks for it ([hasValidWalletSigForAny]).
  ///
  /// Best-effort: [SessionManager] is looked up lazily via [GetIt] (like the
  /// other login-time hydration helpers) and any failure must not break login.
  Future<void> _hydrateSessionWalletSigs() async {
    try {
      final session = GetIt.instance<SessionManager>();
      final missing = session.sessionAddresses
          .map(_cookieAddress)
          .where((a) => a.isNotEmpty && !_walletSigCookies.containsKey(a))
          .toSet()
          .toList();
      final stored = await Future.wait(
        missing.map(_storage.loadWalletSigCookie),
      );

      // Taken in the session's order while they fit.
      final found = <String, String>{};
      for (final (i, cookieAddress) in missing.indexed) {
        final jwt = stored[i];
        if (jwt == null || jwt.isEmpty || _isJwtExpired(jwt)) continue;
        if (_walletSigCookies.containsKey(cookieAddress)) continue;
        final withIt = {...found, cookieAddress: jwt, ..._walletSigCookies};
        if (!_sharedWalletSigsFit(withIt)) break;
        found[cookieAddress] = jwt;
      }
      if (found.isEmpty) return;

      // Found, not used: they go in front of the proofs already there, last
      // one first, because the front is the end an eviction takes from. So a
      // later use gives up the session's last wallet before its first, and
      // any of these before a proof a caller asked for.
      final used = Map.of(_walletSigCookies);
      _walletSigCookies
        ..clear()
        ..addEntries(found.entries.toList().reversed)
        ..addAll(used);
      _refreshAuthInterceptor();
    } catch (e) {
      AppLogger.warn(_tag, 'session wallet-sig hydrate failed: $e');
    }
  }

  /// On a wallet or account switch, drop the shared proofs that belong to
  /// neither [newAddress] nor a wallet of the session being switched to, and
  /// any that expired.
  ///
  /// The proofs widen reads across the wallets of ONE session. Kept across
  /// switches they pile up for the whole run — every account the user visited
  /// — and each request to the API then carries proofs for wallets the session
  /// it is made in has nothing to do with. [SessionManager] already describes
  /// the new session when the switch reaches here; with none to ask, only the
  /// wallet being logged in keeps its proof.
  void _pruneWalletSigsToSession(String newAddress) {
    final keep = {_cookieAddress(newAddress)};
    if (GetIt.instance.isRegistered<SessionManager>()) {
      keep.addAll(
        GetIt.instance<SessionManager>().sessionAddresses.map(_cookieAddress),
      );
    }
    _walletSigCookies.removeWhere(
      (address, jwt) => !keep.contains(address) || _isJwtExpired(jwt),
    );
  }

  /// Extract login token from Set-Cookie response header and store it.
  ///
  /// [isCurrent], when given, is asked again after the write: a session cleared
  /// while the token was being stored has removed the interceptor and deleted
  /// the token, and installing this one now would put the previous wallet's
  /// login back on every request.
  Future<void> _extractAndStoreLoginToken(
    Headers headers, {
    bool Function()? isCurrent,
  }) async {
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
          if (isCurrent != null && !isCurrent()) return;
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
    _walletSigRevision.value++;
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
      _walletSigRevision.value++;
    }
  }

  /// Request an auth token, sign it, and verify with the backend.
  ///
  /// Wallets that cannot sign silently are skipped: view-only ones hold no key,
  /// hardware wallets need an approval outside this process, and a social
  /// wallet whose stored key is missing needs an interactive re-login.
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
            _rememberWalletSig(cookieAddress, cached);
            _refreshAuthInterceptor();
            AppLogger.debug(
              _tag,
              'Wallet-sig already cached for $cookieAddress',
            );
            return;
          }
        }
      }

      // 🛑 Hardware wallets are deferred, both of them. Ledger needs a BLE
      // connect and an on-device confirmation; Seed Vault raises a full-screen
      // OS approval Activity. Every caller of this method reaches it without a
      // user action — the post-login warm-up, a resume, [verifySessionWallet]
      // — so a prompt here has nothing behind it. On Seed Vault that is worse
      // than a stray bottom sheet: an approval screen the user did not ask for
      // reads as a system-level security event, on every cold start and every
      // resume. Defer until the user does something that actually needs it
      // (see [signAndVerifyForWallet], and the 401 retry below, which takes
      // consent on a sheet of ours first).
      if (await _walletManager.isHardwareWallet(address)) {
        AppLogger.debug(
          _tag,
          'Skipping background signature verification for hardware '
          'wallet $address — will sign on demand',
        );
        return;
      }

      // A social wallet signs locally and silently from the key stored on this
      // device, so it falls through and signs like any imported-key wallet.
      // Only the restore case defers: a social row whose key is missing (a
      // wiped keystore, or a restored DB) sends every signing entry point
      // into a key recovery ([SocialAuthService.recoverKeysForAccount]),
      // which can show a sign-in sheet or a passkey prompt.
      //
      // 🛑 Every caller of this method signs unprompted — the post-login
      // warm-up, [verifySessionWallet], [loginForLinkFlow], and the 401 retry
      // interceptor ([_handleSignatureRetry]) — so it must NEVER go
      // interactive. Hence the
      // presence probe before the sign, not a try/catch around it: the catch
      // would run only after the sign-in sheet had already opened. The deferred
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

      await _signAndCacheWalletSig(address);

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

  /// The wallet-sig handshake itself: request a challenge token, sign it with
  /// the wallet matching [address], verify with the backend and cache the JWT
  /// the response sets.
  ///
  /// Split out of [_verifySignatureIfPossible] so the 401 retry can run it for
  /// a Seed Vault wallet *after* the user has consented on a sheet — the gates
  /// [_verifySignatureIfPossible] applies before calling this exist to keep
  /// background callers from prompting, and must not be reachable with an
  /// "except this once" flag.
  ///
  /// Throws on failure (including [ViewOnlyWalletException] from the signer);
  /// [_verifySignatureIfPossible] is what makes a background attempt non-fatal.
  ///
  /// With [keepInSharedCookies] false the proof goes to disk only, so it does not
  /// join the cookies sent on every request ([signWalletProofCookie]). Returns
  /// the proof, or null when the response set none.
  Future<String?> _signAndCacheWalletSig(
    String address, {
    bool keepInSharedCookies = true,
  }) async {
    final cookieAddress = _cookieAddress(address);
    final isSolana = Chain.fromAddress(address) == Chain.solana;

    // Step 1: Request the chain-specific challenge
    AppLogger.debug(_tag, 'Requesting challenge for signature verification...');
    final challengeResponse = await _api.getAuthToken(
      AuthTokenRequest(
        address: cookieAddress,
        format: isSolana ? 'siws' : null,
      ),
    );
    final challenge = challengeResponse.result;

    // Step 2: Sign the chain-specific login challenge with the wallet matching
    // this address (not the active wallet, which may differ after
    // switchWallet). Throws ViewOnlyWalletException for view-only wallets;
    // social wallets sign locally from their stored key.
    final signature = await _walletManager.signLoginChallengeForAddress(
      address,
      message: isSolana ? challenge : _loginMessagePrefix,
      token: isSolana ? null : challenge,
    );

    // Step 3: Verify with backend via raw Dio to capture Set-Cookie header
    final response = await _dio.post<Map<String, dynamic>>(
      '${Config.apiBaseUrl}/v0/authToken/verify',
      data: _verifyBody(
        cookieAddress,
        signature,
        message: isSolana ? challenge : null,
      ),
    );

    // Step 4: Extract and cache the wallet-sig JWT from Set-Cookie
    final jwt = _extractWalletSigCookie(response.headers, cookieAddress);
    if (jwt != null) {
      await _storage.storeWalletSigCookie(cookieAddress, jwt);
      if (keepInSharedCookies) {
        _rememberWalletSig(cookieAddress, jwt);
        _refreshAuthInterceptor();
      }
      AppLogger.debug(_tag, 'Wallet-sig JWT cached for $cookieAddress');
    }

    // Store session expiry if present
    final resultData = response.data?['result'] as Map<String, dynamic>?;
    final expiresAt = resultData?['expiresAt'] as String?;
    if (expiresAt != null) {
      await _storage.storeSessionExpiry(expiresAt);
    }

    await _adoptPrivilegedUser(response.data, cookieAddress);
    // Not awaited: this runs inside the 401 re-sign, and the original
    // request's replay must not wait on a second read.
    unawaited(_reloadPersonalData(cookieAddress));
    return jwt;
  }

  /// Replace the cached user with the privileged render `/v0/authToken/verify`
  /// returns for [cookieAddress], if it carries one.
  ///
  /// `/v0/currentUser` withholds the private fields — `perks`, the full
  /// `roles`, `showNsfw`, `disabledChains`, and the following/likes/invites —
  /// unless the request already carries a valid `wallet-sig` cookie for the
  /// address. [_primeWalletSigCookie] supplies one
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
  ///
  /// The token is dropped if a wallet switch or logout cleared the session
  /// while the request was out: it is [address]'s, and installing it would put
  /// that wallet's login on the requests of whoever is logged in now.
  Future<void> _refreshLoginToken(String address) async {
    final generation = _loginGeneration;
    bool isCurrent() => generation == _loginGeneration;
    final response = await _postSession(address);
    if (!isCurrent()) return;
    await _extractAndStoreLoginToken(response.headers, isCurrent: isCurrent);
  }

  /// The installed login token is the current address's own again: the link
  /// flow's restore call. A switch or logout clears the flag in
  /// [_clearSession]; [refresh] does not run mid-flow, and the "Please log in"
  /// refresh re-logs the linked profile in, not the active wallet. Lets the
  /// background reads that waited out the swap run, by notifying
  /// [walletSigChanges] after the flag is down.
  void _endLinkFlowToken() {
    if (_linkFlowAddress == null) return;
    _linkFlowAddress = null;
    _walletSigRevision.value++;
  }

  Future<void> _clearSession() async {
    // First, before any await: every login still on the wire is now stale.
    _loginGeneration++;
    _currentAddress = null;
    _linkFlowAddress = null;
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

/// Whether [uri] is a route on the API hosts that is no part of the wallet
/// session: the social-vault routes, which authenticate by the provider's
/// identity token or by a vault-key signature and by nothing else.
///
/// Such a request gets no session cookies. A vault is opened before any wallet
/// is logged in and belongs to an identity, not to a wallet; sending the login
/// token and the `wallet-sig` proofs with it would tell the server which
/// wallets were logged in on the device that opened which vault, for no
/// purpose. It is also never retried as a session failure: a `401` from these
/// routes is about the identity token or the vault signature, and re-signing
/// a wallet proof (on a hardware wallet, a prompt) cannot mend either.
///
/// Matched on the path segment, not a full prefix: the `/v2` base path is
/// configurable. The build-identifying headers and the API key are other
/// interceptors' and are unaffected.
@visibleForTesting
bool isSessionlessRoute(Uri uri) => uri.pathSegments.contains('social-vault');

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
///
/// On those hosts, the routes [isSessionlessRoute] names get none either.
///
/// The header this adds is bounded: one login token and at most
/// [AuthService.maxSharedWalletProofs] proofs, because servers refuse a
/// header that grows too large (see [AuthService._walletSigCookies]).
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
    if (!mallowHosts.contains(options.uri.host) ||
        isSessionlessRoute(options.uri)) {
      return handler.next(options);
    }

    final parts = <String>['login-token=$token'];
    for (final entry in walletSigCookies.entries) {
      parts.add(AuthService._walletSigCookie(entry.key, entry.value));
    }

    final existing = options.headers['Cookie'] as String? ?? '';
    final combined = [if (existing.isNotEmpty) existing, ...parts].join('; ');
    options.headers['Cookie'] = combined;

    handler.next(options);
  }
}

/// Dio interceptor that catches 401 responses and automatically retries:
///
/// - **"Please log in"** — login token expired; silently re-calls `/v2/session`
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
    // Not a session failure, whatever its message says.
    if (isSessionlessRoute(err.requestOptions.uri)) {
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

    // Mid link flow the installed token is the target profile's, and the
    // request being retried (`approveLinkRequestV2`) must keep it: logging the
    // active wallet in instead would link to the wrong profile.
    final address =
        _authService._linkFlowAddress ?? _authService._currentAddress;
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
  /// A 401 is trigger-blind: it can arrive from a background refresh as easily
  /// as from a tap. So hardware wallets go through [HardwareVerifyController]
  /// first, and nothing reaches the device until the user has agreed to it on
  /// a sheet of ours. All other wallets sign silently in the background.
  Future<void> _handleSignatureRetry(
    DioException err,
    ErrorInterceptorHandler handler,
    String message,
  ) async {
    // Prevent infinite retry loop
    if (err.requestOptions.extra['_signatureRetry'] == true) {
      return handler.next(err);
    }

    // A background read opted out: on a hardware wallet the re-sign below is a
    // verify sheet the user never asked for (see [kSkipSignatureRetryExtra]).
    if (err.requestOptions.extra[kSkipSignatureRetryExtra] == true) {
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
      // Hardware wallets cannot re-sign in the background: Ledger needs a BLE
      // connect plus an on-device confirmation, and Seed Vault raises a
      // full-screen OS approval Activity. Both get our own sheet first, so the
      // user has a deliberate tap behind whatever the device then shows.
      if (await _authService._walletManager.isHardwareWallet(address)) {
        final device = await hardwareVerifyDeviceFor(address);
        AppLogger.debug(
          _tag,
          'Hardware wallet detected — routing to interactive verification',
        );
        final controller = GetIt.instance<HardwareVerifyController>();
        final consented = await controller.requestVerification(
          address,
          walletType: device,
        );
        if (!consented) {
          AppLogger.warn(_tag, 'Hardware verification cancelled or failed');
          return handler.next(err);
        }
        // The Ledger sheet performs the whole handshake itself and has already
        // cached the JWT. Seed Vault's and Keystone's sheets only collect
        // consent, so the signature — and with it the OS approval screen or
        // the QR exchange — happens here, now that the user has asked for it.
        //
        // Exhaustive on purpose: written as `device == seedVault` this site
        // compiled clean when Keystone was added, and a Keystone user would
        // have consented and then never been asked to sign.
        switch (device) {
          case WalletType.seedVault:
          case WalletType.keystone:
            await _authService._signAndCacheWalletSig(address);
          case WalletType.ledger:
            break;
          case WalletType.hd:
          case WalletType.importedKey:
          case WalletType.viewOnly:
          case WalletType.social:
            // Unreachable: [hardwareVerifyDeviceFor] answers only hardware
            // types.
            break;
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

/// A login that a wallet switch or logout overtook. Thrown to unwind it without
/// touching the session state, which belongs to whatever replaced it.
class _SupersededLogin extends AuthException {
  _SupersededLogin() : super('Login superseded by a wallet switch or logout');
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

/// Thrown when the interactive hardware verify sheet does not produce a
/// wallet-sig — the user dismissed it, or the exchange with the device failed.
/// The sheet itself already shows the specific reason, so a caller catching
/// this only needs to abort with its own short copy.
///
/// One type for both devices: a caller can do nothing with the distinction
/// (either way the user backed out of an approval), and an exception hierarchy
/// for a single catch site buys nothing.
///
/// Typed on purpose: without it a caller cannot tell a dismissed sheet from a
/// storage/database failure on the same wallet, and ends up guessing from
/// `walletType.isHardware`.
class HardwareVerificationCancelledException implements Exception {
  HardwareVerificationCancelledException([
    this.message = 'Hardware wallet verification cancelled',
  ]);

  final String message;

  @override
  String toString() => 'HardwareVerificationCancelledException: $message';
}
