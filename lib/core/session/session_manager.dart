import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import '../../features/wallets/services/profile_lookup_service.dart';
import '../../shared/utils/chain.dart' show Chain, apiOwnerAddress;
import '../crypto/wallet_manager.dart';
import '../models/account.dart';
import '../network/auth_service.dart';
import '../observability/app_logger.dart';
import '../security/secure_storage.dart';
import '../services/preferences_service.dart';
import '../services/wallet_repository.dart';

const _tag = 'SessionManager';

/// What the app is "logged in as".
///
/// - [account] — a derivation-index grouping of wallets. Social features are
/// gated; identity shows the Account name in Geist.
/// - [profile] — a backend user identity (username/avatar/social graph) backed
///   by one or more linked wallets. Full social; username in Newsreader italic.
enum LoginMode {
  account,
  profile;

  String toDbString() => name;

  static LoginMode fromDbString(String? value) =>
      value == 'profile' ? LoginMode.profile : LoginMode.account;
}

/// Owns the active **session**: whether the app is logged in as an Account or a
/// Profile, the set of wallets that session spans, and the active signing
/// wallet resolved **per chain**. Replaces the app's "single active wallet"
/// assumption (see spec).
///
/// This is the source of truth the rest of the app reads for "who am I" and
/// "which wallets are in scope". It activates the active signing wallet through
/// [WalletManager] (which keeps the existing per-wallet signing pipeline and
/// drives the `/v0/login` re-login), so it composes with — rather than
/// replaces — that service.
@lazySingleton
class SessionManager extends ChangeNotifier {
  SessionManager(
    this._walletRepo,
    this._walletManager,
    this._storage,
    this._prefs,
    this._profileLookup,
  );

  final WalletRepository _walletRepo;
  final WalletManager _walletManager;
  final SecureWalletStorage _storage;
  final PreferencesService _prefs;
  final ProfileLookupService _profileLookup;

  LoginMode _mode = LoginMode.account;
  Account? _activeAccount;
  ProfileGroup? _activeProfile;

  /// The active login mode.
  LoginMode get mode => _mode;

  /// True when logged in as a Profile (full social features).
  bool get isProfileMode => _mode == LoginMode.profile;

  /// The active Account (the wallet-holding group). Present in both modes — a
  /// Profile session still signs with a held wallet that belongs to an account.
  Account? get activeAccount => _activeAccount;

  /// The active Profile, or null when logged in as a plain Account.
  ProfileGroup? get activeProfile => _activeProfile;

  /// The wallets in scope for the current session (held wallets of the active
  /// account; for a Profile, its linked wallets including view-only ones).
  List<WalletInfo> get sessionWallets => switch (_mode) {
    LoginMode.profile => _activeProfile?.wallets ?? const [],
    LoginMode.account => _activeAccount?.wallets ?? const [],
  };

  /// Every non-empty address in scope for the current session, including
  /// view-only wallets. The canonical set for ownership / identity / eligibility
  /// checks ("is this mine / do I own this / is this my profile") — scoped to
  /// the current Profile or Account, NOT device-wide (contrast
  /// `ArtworkPermissionService.ownedAddresses`, which spans every wallet on the
  /// device and gates only downloads).
  Set<String> get sessionAddresses =>
      sessionWallets.map((w) => w.address).where((a) => a.isNotEmpty).toSet();

  /// [sessionAddresses] normalised for backend owner/address query keys, with
  /// EVM addresses lowercased (see [apiOwnerAddress]). Use this — not the raw
  /// wallet addresses — for every owner-keyed v2 read (portfolio, offers,
  /// activity, transfers, home-recommended); a checksummed EVM address sent
  /// verbatim never matches the backend's lowercased owner index, so holdings
  /// silently drop out. Deduped after normalisation.
  List<String> get apiOwnerAddresses =>
      sessionAddresses.map(apiOwnerAddress).toSet().toList();

  /// The signable subset of [sessionAddresses] — wallets whose key the app can
  /// use to sign (excludes view-only). Gates signing actions before the
  /// auto-switch: an action is directly signable only when its authority is in
  /// this set.
  Set<String> get signableSessionAddresses => sessionWallets
      .where((w) => w.canSign && w.address.isNotEmpty)
      .map((w) => w.address)
      .toSet();

  /// The in-session wallet for [address], or null when [address] isn't in the
  /// current Profile/Account scope. Used to resolve the auto-switch target.
  WalletInfo? sessionWalletForAddress(String address) =>
      sessionWallets.firstWhereOrNull((w) => w.address == address);

  /// Case-insensitive variant of [sessionWalletForAddress]: matches [address]
  /// against the session wallets ignoring case, so an EVM hex holder resolves
  /// regardless of its EIP-55 checksum casing (the session may store one
  /// casing while a caller passes another). Returns null for an empty
  /// [address] or one outside the current Profile/Account scope. The single
  /// lookup used by both the signer gate (`ensureSigner`) and the EVM transfer
  /// service to resolve a holder to the session wallet that can sign for it.
  WalletInfo? sessionWalletForAddressCaseInsensitive(String address) {
    if (address.isEmpty) return null;
    final lower = address.toLowerCase();
    return sessionWallets.firstWhereOrNull(
      (w) => w.address.toLowerCase() == lower,
    );
  }

  /// True when [address] belongs to the current session — the active signing
  /// identity ([AuthService.currentAddress]) **or** any wallet in
  /// [sessionAddresses]. Compared on the normalised owner key
  /// ([apiOwnerAddress]) so an EIP-55 checksummed EVM address matches the
  /// API's lowercased form. Null/empty → false.
  ///
  /// The single ownership/eligibility predicate ("is this mine"). Do **not**
  /// use it for gates whose backend write matches `owner == req.loginAddress`
  /// — hide/download ([ensureActiveWalletVerified]), curation edit, profile
  /// edit. Those stay active-wallet-only; widening them surfaces controls that
  /// 404.
  ///
  /// The active signer is unioned in deliberately: it is **not** guaranteed to
  /// be in [sessionAddresses]. A Profile session cold-starts with
  /// [activeProfile] null until [restoreActiveProfile] rebuilds the group (and
  /// it stays null when that lookup fails offline), so [sessionWallets] is empty
  /// there — a sessionAddresses-only predicate would deny every gate on launch.
  /// It is unioned **through [scopedToSession]**, so a Profile session never
  /// claims ownership via a wallet outside its linked set.
  bool ownsAddress(String? address) {
    if (address == null || address.isEmpty) return false;
    final key = apiOwnerAddress(address);
    final active = scopedToSession(
      GetIt.instance<AuthService>().currentAddress ?? '',
    );
    if (active != null && apiOwnerAddress(active) == key) return true;
    return sessionAddresses.any((a) => apiOwnerAddress(a) == key);
  }

  /// [address] narrowed to the current session's sourcing scope, or null when
  /// the session may not source from it.
  ///
  /// 🛑 A **Profile** session sources from its linked wallets and nothing else.
  /// The active selection is not automatically one of them: the active account
  /// (anchored to the signer for per-chain resolution) carries Ethereum/Tezos
  /// siblings the profile never linked. Any address that reaches a balance read,
  /// a receive QR, a signer pick, or an ownership gate must come through here
  /// first.
  ///
  /// Account sessions pass through — an Account's scope *is* its wallets. So
  /// does a session whose wallets aren't loaded yet (pre-restore), because
  /// blanking the active address there would deny every gate on launch.
  ///
  /// Exempt by design: the download and cast gates (local-only actions that
  /// deliberately span every on-device wallet — see
  /// `ArtworkPermissionService.ownedAddresses`) and
  /// [resolveWalletForAddress] (restores an already-active signer rather than
  /// choosing a source).
  String? scopedToSession(String address) {
    if (address.isEmpty) return null;
    if (!isProfileMode || sessionWallets.isEmpty) return address;
    return sessionWalletForAddressCaseInsensitive(address) != null
        ? address
        : null;
  }

  /// Display name for the session header (Account name, or Profile username).
  String? get displayName => switch (_mode) {
    LoginMode.profile =>
      _activeProfile?.username ?? _activeProfile?.displayName,
    LoginMode.account => _activeAccount?.name,
  };

  /// Storage scope for per-session preferences that must stay isolated between
  /// sessions — currently the Active Networks setting. Returns the active
  /// profile's id in a Profile session (so each profile, and the account scope,
  /// keep their own setting), or null for an Account session (the shared
  /// device-local scope).
  ///
  /// Resolves from the rebuilt [activeProfile] when present, else the persisted
  /// active-profile id — so it is correct during early cold start, before
  /// [restoreActiveProfile] has rebuilt the group but after [restore] has set
  /// the mode.
  Future<String?> settingsScopeId() async {
    if (_mode != LoginMode.profile) return null;
    return _activeProfile?.userId ?? await _storage.loadActiveProfileId();
  }

  // ---------------------------------------------------------------------------
  // Restore (cold start)
  // ---------------------------------------------------------------------------

  /// Rebuild the persisted session before the startup login runs.
  ///
  /// Loads the persisted mode + account/profile id and reconstructs the active
  /// account from the DB so the subsequent [AuthService.initializeSession] logs
  /// in as its active signing wallet. Safe to call when nothing is persisted
  /// (no-op session).
  Future<void> restore() async {
    _mode = LoginMode.fromDbString(await _storage.loadLoginMode());

    final accounts = await _walletRepo.getAccountViews();
    if (accounts.isEmpty) {
      _activeAccount = null;
      _activeProfile = null;
      return;
    }

    // Resolve the active account from the already-loaded list: the one holding
    // the selected Solana wallet, else the persisted account id, else the first.
    // (Resolved in-memory to avoid getActiveSelection()'s second reconcile +
    // per-account query on this cold-start path.)
    final selectedWalletId = await _storage.loadSelectedWalletId();
    final persistedId = await _storage.loadSelectedAccountId();
    _activeAccount =
        (selectedWalletId == null
            ? null
            : accounts.firstWhereOrNull(
                (a) => a.wallets.any((w) => w.id == selectedWalletId),
              )) ??
        accounts.firstWhereOrNull((a) => a.id == persistedId) ??
        accounts.first;

    // Profile-mode reconstruction (full ProfileGroup) is handled by the
    // switcher (Task 06) when profile discovery reloads; on cold start we
    // restore the active account and let that refresh re-attach identity.
    if (_mode == LoginMode.profile &&
        (await _storage.loadActiveProfileId()) == null) {
      _mode = LoginMode.account;
    }

    AppLogger.debug(
      _tag,
      'restored session mode=$_mode account=${_activeAccount?.id}',
    );
  }

  /// Reconstruct the active [ProfileGroup] for a restored Profile session.
  ///
  /// [restore] runs before the startup login and only re-establishes the
  /// account, so a cold start leaves a Profile session with a null
  /// [activeProfile] — and [sessionWallets] then falls back to the active
  /// account's single wallet instead of the profile's full linked set (the
  /// reported receive-sheet bug). This runs *after* the startup login (so the
  /// authenticated bulk lookup succeeds), re-derives the profile groups from
  /// the held wallets, and re-attaches the one whose userId was persisted.
  ///
  /// Best-effort: a no-op outside Profile mode or with no persisted profile,
  /// and offline / lookup failure leaves the session on its account wallets.
  Future<void> restoreActiveProfile() async {
    if (_mode != LoginMode.profile || _activeProfile != null) return;
    final profileId = await _storage.loadActiveProfileId();
    if (profileId == null) return;
    await _attachProfileGroup(profileId, 'restoreActiveProfile');
  }

  /// Re-derive the active [ProfileGroup] from the backend after its **wallet
  /// set** changed (a link or unlink).
  ///
  /// [applyProfileEdit] deliberately only touches the identity fields, and
  /// [restoreActiveProfile] bails when a profile is already attached, so neither
  /// can pick up a new or removed link — without this the session (and every
  /// header reading `activeProfile.wallets`) keeps the pre-link set.
  ///
  /// Best-effort: a no-op outside Profile mode, and a lookup failure leaves the
  /// existing group in place rather than dropping the session.
  Future<void> refreshActiveProfile() async {
    final profileId = _activeProfile?.userId;
    if (_mode != LoginMode.profile || profileId == null) return;
    await _attachProfileGroup(profileId, 'refreshActiveProfile');
  }

  /// Re-derive the profile groups from the held wallets and attach the one
  /// matching [profileId]. Shared body of [restoreActiveProfile] and
  /// [refreshActiveProfile]; [op] only tags the failure logs.
  ///
  /// Best-effort: any failure (offline, lookup error, profile gone) leaves
  /// [activeProfile] as it was rather than dropping the session.
  Future<void> _attachProfileGroup(String profileId, String op) async {
    try {
      final wallets = await _walletRepo.getAllWallets();
      if (wallets.isEmpty) return;
      await _profileLookup.bulkLookup(wallets.map((w) => w.address).toList());
      final response = _profileLookup.lastResponse;
      if (response == null) return;
      final (groups, _) = _profileLookup.buildProfileGroups(wallets, response);
      final group = groups.firstWhereOrNull((g) => g.userId == profileId);
      if (group == null) {
        AppLogger.warn(_tag, '$op: $profileId no longer found');
        return;
      }
      _activeProfile = group;
      notifyListeners();
    } on Object catch (e) {
      AppLogger.warn(_tag, '$op failed: $e');
    }
  }

  /// Warm [ProfileLookupService]'s in-memory bulk-lookup cache for every local
  /// wallet at startup, so profile membership (including linked wallets the
  /// user hasn't imported) is resolvable in any session mode — not just after
  /// [restoreActiveProfile] runs for a Profile session or the drawer opens.
  ///
  /// Best-effort and cheap: skips when the cache is already warm (e.g.
  /// [restoreActiveProfile] just populated it) and swallows offline failures.
  Future<void> warmProfileLookup() async {
    if (_profileLookup.lastResponse != null) return;
    try {
      final wallets = await _walletRepo.getAllWallets();
      if (wallets.isEmpty) return;
      await _profileLookup.bulkLookup(wallets.map((w) => w.address).toList());
    } on Object catch (e) {
      AppLogger.warn(_tag, 'warmProfileLookup failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Switching
  // ---------------------------------------------------------------------------

  /// Switch the session to the Account [accountId]. Resolves the account's
  /// default Solana signing wallet (remembered per account, else the first),
  /// persists, and triggers a re-login via the existing wallet-switch pipeline.
  ///
  /// [preferredWalletId] honors a direct wallet tap in the switcher: a tapped
  /// Solana wallet becomes the signer and is remembered for this account (so the
  /// picker isn't shown for an explicit choice); for a Solana-less account it
  /// becomes the preferred target of the no-signer fallback below.
  Future<void> switchToAccount(
    String accountId, {
    String? preferredWalletId,
  }) async {
    final accounts = await _walletRepo.getAccountViews();
    final account = accounts.firstWhereOrNull((a) => a.id == accountId);
    if (account == null) {
      AppLogger.warn(_tag, 'switchToAccount: unknown account $accountId');
      return;
    }

    _mode = LoginMode.account;
    _activeAccount = account;
    _activeProfile = null;
    await _storage.deleteActiveProfileId();

    // A direct tap on a Solana wallet row wins: remember it so the resolution
    // below returns it without prompting. Guarded to this account's Solana
    // wallets, so a non-Solana preferred id is never persisted as the Solana
    // default (it still steers the no-signer fallback below).
    if (preferredWalletId != null &&
        account.solanaWallets.any((w) => w.id == preferredWalletId)) {
      await _prefs.setLastSolanaWalletId(account.id, preferredWalletId);
    }

    // Resolve the Solana signer ONCE per switch so a multi-Solana account
    // prompts the picker at most once (not again when scoping + activating).
    final signer = await resolveSolanaSigner();
    await _persistSession();
    if (signer != null) {
      await _walletManager.switchWalletById(signer.id);
    } else {
      // No Solana wallet (e.g. an ETH/Tezos-only Ledger import). Still re-point
      // the active wallet to one of this account's wallets — preferring the
      // explicitly chosen wallet, then a signable one — so the active-wallet
      // pointer doesn't stay on the previously-active wallet. Leaving it stale
      // keeps the active wallet (and view-only-gated UI like the Notifications
      // row) stuck on the prior wallet's state instead of reflecting the
      // account just switched to.
      final fallback =
          account.wallets.firstWhereOrNull((w) => w.id == preferredWalletId) ??
          account.wallets.firstWhereOrNull((w) => w.canSign) ??
          account.wallets.firstOrNull;
      if (fallback != null) {
        await _walletManager.switchWalletById(fallback.id);
      } else {
        AppLogger.warn(_tag, 'account ${account.id} has no wallets');
      }
    }
    notifyListeners();
  }

  /// Switch the session so [walletId] becomes the active wallet, taking its
  /// whole account along — the single entry point for post-import/"make this
  /// wallet active" flows (watch, private-key import, ledger).
  ///
  /// Routing only the active *wallet* (`WalletManager.switchWalletById`) leaves
  /// [activeAccount] stale, so headers fall back to the wallet's chain-label /
  /// local name and the session identity desyncs. This re-points to the
  /// wallet's account via [switchToAccount], passing this wallet as the
  /// preferred one so it becomes the active signer (Solana) — or, for an
  /// account with no Solana wallet (Eth/Tezos-only, e.g. a Ledger import), the
  /// preferred target of `switchToAccount`'s no-signer fallback, which re-logins
  /// auth onto it. A wallet with no account (legacy/orphan) falls back to a bare
  /// wallet switch.
  Future<void> switchToWallet(String walletId) async {
    final wallet = await _walletRepo.getWalletById(walletId);
    final accountId = wallet?.accountId;
    if (accountId == null) {
      await _walletManager.switchWalletById(walletId);
      return;
    }
    await switchToAccount(accountId, preferredWalletId: walletId);
  }

  /// True when the active session is a **Profile** that already links one of
  /// [addresses] — including a read-only placeholder for an address the user
  /// hasn't imported locally yet.
  ///
  /// Import flows consult this before their post-import auto-switch: importing
  /// a wallet the active Profile already contains (e.g. importing the real key
  /// for a read-only linked wallet) should keep the user on their Profile
  /// rather than jump the session to the freshly imported Account. Always false
  /// in Account mode — an Account session has no Profile to stay on, so imports
  /// switch as before.
  bool activeProfileContainsAnyAddress(Iterable<String> addresses) {
    final profile = _activeProfile;
    if (_mode != LoginMode.profile || profile == null) return false;
    // Normalise both sides: profile-linked EVM addresses come back lowercased
    // from the API, but callers pass EIP-55 checksummed addresses (e.g. after
    // ENS resolution in the watch flow) — a raw string compare misses and the
    // post-import auto-switch wrongly fires. Solana/Tezos pass through.
    final linked = profile.wallets
        .map((w) => apiOwnerAddress(w.address))
        .toSet();
    return addresses.map(apiOwnerAddress).any(linked.contains);
  }

  /// Switch the session to a discovered [profile]. Signs with [preferredWalletId]
  /// when it names a held signable wallet in the profile (honors a direct tap),
  /// else the profile's first held signable Solana wallet. If none is held the
  /// profile is browse-only and social actions prompt (Task 09) — but the active
  /// wallet still moves onto one of the profile's own held (watch-only) wallets,
  /// so nothing downstream keeps signing or authenticating as the previous
  /// profile.
  Future<void> switchToProfile(
    ProfileGroup profile, {
    String? preferredWalletId,
  }) async {
    _mode = LoginMode.profile;
    _activeProfile = profile;

    // Prefer a held Solana signer (the transactional chain for most actions);
    // fall back to any held signable wallet so a Tezos/Eth-only profile still
    // re-points the active wallet (below) instead of staying browse-only.
    final signer =
        profile.wallets.firstWhereOrNull(
          (w) =>
              w.id == preferredWalletId &&
              w.canSign &&
              w.chainEnum == Chain.solana,
        ) ??
        profile.wallets.firstWhereOrNull(
          (w) => w.canSign && w.chainEnum == Chain.solana,
        ) ??
        profile.wallets.firstWhereOrNull(
          (w) => w.id == preferredWalletId && w.canSign,
        ) ??
        profile.wallets.firstWhereOrNull((w) => w.canSign);

    // 🛑 A browse-only profile (every linked wallet watch-only) still re-points
    // the active wallet — onto one of ITS OWN wallets. Leaving the previous
    // profile's wallet selected leaves `WalletManager.getAddress()` answering
    // with that wallet, and it is read straight through by Solana's signing
    // path (`SolanaRpcService.buildSolTransferTx`, `TransactionExecutor`'s
    // keypair lookup) and by the callers that re-login off it
    // (`profile_required_sheet`) — so the session keeps signing and
    // authenticating as the profile the user just left. Same reason
    // [switchToAccount] re-points a Solana-less account.
    //
    // Held wallets only ([isViewOnlyPlaceholder]): the synthetic entries minted
    // for linked-but-not-imported addresses have no DB row, so
    // `switchWalletById` throws on one. Solana first — `getAddress()` returns
    // the selected row's address whatever chain it is on, so selecting an ETH
    // watch-only wallet would answer a Solana read with a `0x` address.
    //
    // ⚠️ Resolved from [profile] as given, which is not always the profile's
    // full set: `WalletDrawerBloc.groupsOnActiveNetworks` hands the switcher a
    // group with the wallets on disabled chains already dropped. A profile
    // whose every held wallet sits on a disabled chain therefore still falls
    // through to the browse-only warning below — and, more broadly, its
    // truncated set becomes [sessionWallets] for the whole session.
    final activeWallet =
        signer ??
        profile.wallets.firstWhereOrNull(
          (w) => !isViewOnlyPlaceholder(w) && w.chainEnum == Chain.solana,
        ) ??
        profile.wallets.firstWhereOrNull((w) => !isViewOnlyPlaceholder(w));

    // Anchor the active account to the active wallet's account so per-chain
    // resolution and the avatar/name fall back correctly.
    if (activeWallet?.accountId != null) {
      final accounts = await _walletRepo.getAccountViews();
      _activeAccount =
          accounts.firstWhereOrNull((a) => a.id == activeWallet!.accountId) ??
          _activeAccount;
    }

    if (profile.userId != null) {
      await _storage.storeActiveProfileId(profile.userId!);
    }

    await _persistSession();
    if (activeWallet != null) {
      // Re-point the active wallet — the Solana signer, the fallback held
      // wallet on another chain, or (browse-only) a held watch-only wallet.
      // This persists the selection and emits onWalletChanged, so the balance
      // blocs reload and the app re-logins for the profile just switched to;
      // without it the session keeps the previous profile's active wallet, its
      // stale token balances, and its signing key.
      await _walletManager.switchWalletById(activeWallet.id);
    } else {
      // Nothing with a DB row to point at. `buildProfileGroups` never emits
      // such a group, but a network-filtered one (see above) can be.
      AppLogger.warn(
        _tag,
        'switchToProfile: no held wallet — active selection left unchanged',
      );
    }
    notifyListeners();
  }

  /// Reconcile the active session after an account (and its wallets) were
  /// removed. Call this only when the deleted account held the active
  /// **signing** wallet — when it didn't, the session is unaffected and nothing
  /// should change (and we avoid a needless re-login).
  ///
  /// A Profile session survives as long as the profile still holds a signable
  /// wallet on the device: it re-anchors to a surviving signer and prunes the
  /// removed wallet(s) from its in-memory set. Once the profile's last held
  /// wallet is gone — the reported failure mode — it drops back to Account mode
  /// on the account that owns [replacementWalletId], clearing the now-orphaned
  /// profile identity from the drawer header. An Account session likewise moves
  /// to the replacement wallet's account.
  Future<void> reconcileAfterRemoval(String? replacementWalletId) async {
    // No wallets remain — the caller handles logout / onboarding redirect.
    if (replacementWalletId == null) return;

    final accounts = await _walletRepo.getAccountViews();
    final allWallets = accounts.expand((a) => a.wallets).toList();

    if (_mode == LoginMode.profile && _activeProfile != null) {
      final profileAddresses = _activeProfile!.wallets
          .map((w) => w.address)
          .toSet();
      final survivingSigner = allWallets.firstWhereOrNull(
        (w) =>
            profileAddresses.contains(w.address) &&
            w.canSign &&
            w.chainEnum == Chain.solana,
      );
      if (survivingSigner != null) {
        // Profile still holds a signer: keep the Profile session, drop the
        // removed wallet(s) from its in-memory set (placeholders stay), and
        // re-anchor the active account + signer.
        final liveAddresses = allWallets.map((w) => w.address).toSet();
        final prunedWallets = _activeProfile!.wallets
            .where(
              (w) =>
                  liveAddresses.contains(w.address) ||
                  w.walletType == WalletType.viewOnly,
            )
            .toList();
        _activeProfile = _activeProfile!.copyWith(wallets: prunedWallets);
        _activeAccount =
            accounts.firstWhereOrNull(
              (a) => a.id == survivingSigner.accountId,
            ) ??
            _activeAccount;
        await _persistSession();
        await _walletManager.switchWalletById(survivingSigner.id);
        notifyListeners();
        return;
      }
      // Profile lost its last held wallet — fall through to Account mode.
    }

    // Account session, or a profile with no held wallets left: switch to the
    // account that owns the replacement wallet (clears any profile identity).
    final replacementAccount = accounts.firstWhereOrNull(
      (a) => a.wallets.any((w) => w.id == replacementWalletId),
    );
    if (replacementAccount != null) {
      await switchToAccount(replacementAccount.id);
    } else {
      await _walletManager.switchWalletById(replacementWalletId);
    }
  }

  /// Apply an in-place profile edit (username / display name / avatar) to the
  /// active [ProfileGroup] — the Profile-mode counterpart of
  /// [refreshActiveAccount]. The session-backed headers (home header, drawer
  /// header, settings profile row) all read identity from [activeProfile],
  /// which is otherwise rebuilt only on switch/restore — so an Edit Profile
  /// save that updates the backend and [AuthService] would leave every header
  /// painting the stale name until the next profile switch.
  ///
  /// A username change also changes the group's userId (it *is* the username
  /// in [ProfileLookupService.buildProfileGroups]), so the persisted
  /// active-profile id is re-stored to keep cold-start restore working.
  /// No-op outside Profile mode.
  Future<void> applyProfileEdit({
    String? username,
    String? displayName,
    String? imageUrl,
  }) async {
    final current = _activeProfile;
    if (_mode != LoginMode.profile || current == null) return;
    _activeProfile = current.copyWith(
      userId: username ?? current.userId,
      username: username ?? current.username,
      displayName: displayName,
      imageUrl: imageUrl ?? current.imageUrl,
    );
    if (username != null && username != current.userId) {
      await _storage.storeActiveProfileId(username);
    }
    notifyListeners();
  }

  /// Re-read the active account from the DB so an in-place edit to its name or
  /// avatar seed — which doesn't change the active selection — propagates to the
  /// session-backed headers (home header, drawer header) that read identity from
  /// [activeAccount]/[displayName]. No-op when there is no active account or it
  /// no longer exists.
  Future<void> refreshActiveAccount() async {
    final current = _activeAccount;
    if (current == null) return;
    final accounts = await _walletRepo.getAccountViews();
    final updated = accounts.firstWhereOrNull((a) => a.id == current.id);
    if (updated == null) return;
    _activeAccount = updated;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Send-flow source selection
  // ---------------------------------------------------------------------------

  /// Re-point the active **signing** wallet to [wallet] for the send flow's
  /// source-wallet picker (send-wallet-select spec). Remembers it as the
  /// owning account's default ([PreferencesService.setLastSolanaWalletId]) and
  /// re-anchors the active account to that wallet's account so per-chain
  /// resolution stays correct.
  ///
  /// In Profile mode the Profile identity (drawer header) is untouched — only
  /// the signer and the internal account anchor move. Re-points via the
  /// existing wallet-switch pipeline; rethrows if [WalletManager.switchWalletById]
  /// fails so the caller can keep the previous source and surface the error.
  ///
  /// **The switch is atomic: this resolves only once the `/v0/login` for
  /// [wallet] has landed**, so [AuthService.currentAddress] equals the target
  /// the moment it returns. That matters because the two "active wallet"
  /// mechanisms diverge in the gap: [WalletManager.getAddress] reads the DB and
  /// is correct immediately, but [AuthService.currentAddress] is synchronously
  /// nulled by `_clearSession` before the network login begins. Callers that
  /// dispatch a `currentAddress`-derived authority (marketplace accept/cancel/
  /// settle, offers inbox, burn) would otherwise fail "No wallet connected".
  ///
  /// On login failure the wallet selection and account anchor are rolled back
  /// and the error rethrown, so the selection never points at the target after
  /// a failed switch. The terminal state is: previous wallet selected, previous
  /// account anchored, and the session either re-authenticated as the previous
  /// wallet (network recovered) or unauthenticated with retry available.
  ///
  /// [AuthService] is looked up lazily via [GetIt] rather than
  /// constructor-injected, mirroring the existing reverse edge, to avoid a DI
  /// cycle with this service's login pipeline.
  Future<void> selectSourceWallet(WalletInfo wallet) async {
    // Snapshot for rollback. The `lastSolanaWalletId` pref is deliberately
    // excluded: [PreferencesService] has set-only accessors with no removal, so
    // a previously-*unset* value cannot be restored. A previously-set one can,
    // and is restored below — leaving it pointing at the failed target would
    // make the next `switchToAccount` or cold start silently adopt the wallet
    // the switch never reached, contradicting this method's own postcondition.
    final previousWallet = await _walletRepo.getActiveWallet();
    final previousAccount = _activeAccount;
    final previousSolanaWalletId = wallet.accountId == null
        ? null
        : _prefs.lastSolanaWalletId(wallet.accountId!);

    final accountId = wallet.accountId;
    if (accountId != null) {
      // Solana-only, mirroring the guard in [switchToAccount]. The pref is read
      // back by [resolveSolanaSigner] against `account.solanaWallets`, so
      // recording an ETH/Tezos wallet id there silently destroys the account's
      // remembered Solana choice and re-points every later Solana resolution to
      // `solWallets.first`. Reachable today via send's non-Solana adopt path.
      if (wallet.chainEnum == Chain.solana) {
        await _prefs.setLastSolanaWalletId(accountId, wallet.id);
      }
      final accounts = await _walletRepo.getAccountViews();
      _activeAccount =
          accounts.firstWhereOrNull((a) => a.id == accountId) ?? _activeAccount;
      await _persistSession();
    }
    await _walletManager.switchWalletById(wallet.id);
    // Notify BEFORE the await, not after: the drawer and session header repaint
    // off the new selection, and deferring this until the login lands would lag
    // every switch tap by the full round trip.
    notifyListeners();

    try {
      // Coalesces with the concurrent call from the `onWalletChanged` listener
      // in app.dart via AuthService's per-address dedup, so only one login runs
      // regardless of which side opens the completer.
      await GetIt.instance<AuthService>().switchWallet(wallet.address);
    } catch (_) {
      if (previousWallet != null && previousWallet.id != wallet.id) {
        try {
          // Deliberately NOT awaiting the rollback's own re-login: this
          // re-emits `onWalletChanged`, so the retained app.dart listener
          // re-logs-in as the previous wallet in the background. Awaiting it
          // would throw a second time while the network is still down.
          await _walletManager.switchWalletById(previousWallet.id);
        } catch (e) {
          AppLogger.warn(_tag, 'selectSourceWallet rollback failed: $e');
        }
      }
      _activeAccount = previousAccount;
      if (accountId != null) {
        // Only restorable when it was already set — [PreferencesService] has no
        // removal accessor, so a previously-unset pref keeps the target id as
        // residue. That narrow case stays a documented tie-breaker leak.
        if (previousSolanaWalletId != null) {
          await _prefs.setLastSolanaWalletId(accountId, previousSolanaWalletId);
        }
        await _persistSession();
      }
      notifyListeners();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Chain-aware address resolution
  // ---------------------------------------------------------------------------

  /// The active account's wallets, but **only when the session may source from
  /// them** — i.e. never in Profile mode.
  ///
  /// The active account is anchored to the signer's account so per-chain
  /// resolution and the avatar/name work (see [switchToProfile]), but its
  /// Ethereum/Tezos siblings are auto-derived at account creation and are not
  /// part of a Profile unless the user linked them. Sourcing from them would
  /// sign, receive, and report balances on wallets the profile doesn't own.
  List<WalletInfo> get _accountSourcingFallback =>
      isProfileMode ? const [] : (_activeAccount?.wallets ?? const []);

  /// The session's active **signable** wallet on [chain] — the wallet the app
  /// signs with for that chain from anywhere. Each chain has its own active
  /// wallet so a Tezos/Ethereum action doesn't fall back to the Solana signer.
  ///
  /// Resolves from the in-scope [sessionWallets] first, then (Account sessions
  /// only) the active account's sibling on that chain. Null when the session
  /// holds no signable wallet on [chain] — a Solana-only Profile has no Tezos
  /// signer, and the caller should disable/error the chain-specific action
  /// rather than reach outside the profile.
  WalletInfo? sessionWalletForChain(Chain chain) {
    bool matches(WalletInfo w) => w.chainEnum == chain && w.canSign;
    return sessionWallets.firstWhereOrNull(matches) ??
        _accountSourcingFallback.firstWhereOrNull(matches);
  }

  /// The wallet for [address] from the current session, falling back to the
  /// active account's wallets when the session itself doesn't hold it.
  ///
  /// Exists because the **active signer is not guaranteed to be in
  /// [sessionWallets]** (see [ownsAddress]): in Profile mode the session spans
  /// the profile's linked wallets only, and [sessionWallets] is empty for the
  /// whole window between cold start and [restoreActiveProfile] rebuilding the
  /// group. [sessionWalletForAddress] returns null there, which would make a
  /// snapshot-and-restore of the active signer a silent no-op — so an abandoned
  /// confirm sheet would permanently move the user's wallet. Matched
  /// case-insensitively so an EVM holder resolves regardless of checksum.
  ///
  /// Deliberately exempt from [scopedToSession]: this **restores a wallet that
  /// was already active**, it never picks a source. Do not copy the fallback
  /// into a resolver that chooses what to sign, receive, or read with.
  WalletInfo? resolveWalletForAddress(String address) {
    if (address.isEmpty) return null;
    final lower = address.toLowerCase();
    bool matches(WalletInfo w) => w.address.toLowerCase() == lower;
    return sessionWallets.firstWhereOrNull(matches) ??
        _activeAccount?.wallets.firstWhereOrNull(matches);
  }

  /// Every session wallet that has an address on [chain], in session order and
  /// deduped by address.
  ///
  /// Unlike [sessionWalletForChain] this **includes view-only wallets** and is
  /// plural: it backs display-only pickers (receive) where an address is all
  /// that is needed and no signing is implied. Do not use it to resolve a
  /// signer — [sessionWalletForChain] is the `canSign`-gated lookup for that.
  ///
  /// Falls back to the active account's sibling on [chain] **in Account mode
  /// only**. A Profile that links no wallet on [chain] returns empty: the
  /// receive sheet must not hand out an address the profile doesn't own, and
  /// the chain's row/tab is hidden instead (see `chainSupported`).
  List<WalletInfo> sessionWalletsForChain(Chain chain) {
    final seen = <String>{};
    final result = <WalletInfo>[];
    for (final w in sessionWallets) {
      if (w.chainEnum != chain || w.address.isEmpty) continue;
      if (seen.add(w.address)) result.add(w);
    }
    if (result.isEmpty) {
      final fallback = _accountSourcingFallback.firstWhereOrNull(
        (w) => w.chainEnum == chain && w.address.isNotEmpty,
      );
      if (fallback != null) result.add(fallback);
    }
    return result;
  }

  /// The active signing/display address for [chain] in the current session.
  ///
  /// Solana resolves the active signing wallet (disambiguating multi-Solana
  /// accounts via [resolveSolanaSigner]); Ethereum/Tezos resolve the active
  /// account's sibling wallet (display only this pass).
  ///
  /// The per-chain resolution in [WalletManager.getAddress] is account-scoped
  /// and profile-blind, so its answer is filtered through [scopedToSession] and
  /// falls back to the session's own wallet on [chain] (including view-only
  /// linked ones) rather than the account's unlinked sibling.
  Future<String?> activeAddress(Chain chain) async {
    if (chain == Chain.solana) {
      final signer = await resolveSolanaSigner();
      return scopedToSession(signer?.address ?? '') ??
          sessionWalletsForChain(chain).firstOrNull?.address;
    }
    try {
      final address = await _walletManager.getAddress(chain: chain);
      final scoped = scopedToSession(address);
      if (scoped != null) return scoped;
    } on Object {
      // Account holds no wallet on this chain — fall through to the session.
    }
    return sessionWalletsForChain(chain).firstOrNull?.address;
  }

  /// Resolve the default Solana wallet for the active account.
  ///
  /// - 0 Solana wallets → null.
  /// - 1 Solana wallet → that wallet.
  /// - >1 → the remembered choice for this account if still valid, else the
  ///   first wallet. A multi-Solana account never prompts here; where a signing
  ///   flow genuinely needs the user to choose, the wallet selection lives in
  ///   that flow.
  Future<WalletInfo?> resolveSolanaSigner() async {
    final account = _activeAccount;
    if (account == null) return null;

    final solWallets = account.solanaWallets;
    if (solWallets.isEmpty) return null;
    if (solWallets.length == 1) return solWallets.first;

    // Remembered choice (still present in the account) wins; else the first.
    final rememberedId = _prefs.lastSolanaWalletId(account.id);
    return solWallets.firstWhereOrNull((w) => w.id == rememberedId) ??
        solWallets.first;
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  /// Persist the active session's mode + account id so the next cold start
  /// restores it.
  Future<void> _persistSession() async {
    final account = _activeAccount;
    await _storage.storeLoginMode(_mode.toDbString());
    if (account != null) {
      await _storage.storeSelectedAccountId(account.id);
    }
  }
}
