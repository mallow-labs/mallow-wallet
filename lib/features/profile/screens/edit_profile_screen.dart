import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/services/twitter_connect_notifier.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/pickers/image_source_picker.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_textarea_field.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../mint/widgets/mint_drop_zone.dart' show DashedBorderPainter;
import '../../mint/widgets/mint_progress_bar.dart';
import '../../portfolio/data/ethereum_token_service.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/data/tezos_token_service.dart';
import '../../portfolio/data/token_repository.dart';
import '../../portfolio/models/token_balance.dart';
import '../../wallets/services/profile_lookup_service.dart';
import '../../wallets/services/wallet_link_service.dart';
import '../data/profile_image_uploader.dart';
import '../data/user_profile_repository.dart';
import '../services/wallet_link_selection.dart';
import '../widgets/email_otp_sheet.dart';
import '../widgets/profile_wallet_picker.dart';

import '../../../shared/utils/chain.dart';

/// Load state for resolving which wallets can back the profile (a network
/// bulk-lookup is required to know what's already attached to a profile).
enum _Eligibility { idle, loading, ready, error }

/// Async availability state for the chosen username.
enum _UsernameStatus { unchanged, invalid, checking, available, taken, error }

/// Edit Profile screen — a stepped wizard mirroring the mint flow:
///   1. Upload banner + profile picture.
///   2. Username, display name, bio.
///   3. Select which wallets are linked to the profile.
///   4. Social accounts, website, email, notification toggles.
///
/// The wallet step lists **every account on the device**, each card offering its
/// signable wallets that aren't already spoken for by another profile (resolved
/// via a fresh backend lookup). A profile may draw wallets from more than one
/// account.
///
/// When the current user has no username yet this becomes a "Create profile"
/// flow: the wallet step's CTA logs in + verifies with the primary wallet (the
/// active wallet when selected, else the first) and links the rest into the new
/// profile, so the optional final step has a backend profile to act on.
///
/// When editing, the step starts with the profile's existing links selected and
/// Save applies the difference — linking what was added, unlinking what was
/// removed. The signing wallet is pinned so the session can't be cut out from
/// under itself.
///
/// The step progress is shown with the same [MintProgressBar] used in the
/// minting flow. Field set and API contract match the the reference web client
/// EditProfileModal.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, this.forceCreate = false});

  /// Opens the wizard in "Create profile" mode even when the active session is
  /// already a profile (the accounts drawer's Profiles-tab "Add" CTA). Without
  /// this the wizard would prefill from — and edit — the active profile.
  final bool forceCreate;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const _imageExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif'];

  /// Cap on an avatar / banner upload. Nothing capped these before, but the
  /// Photos source needs a number to stat against — a camera-roll still is
  /// rejected on `length()` rather than after it has been read into memory.
  static const _maxImageBytes = 20 * 1024 * 1024;
  static const _uploadHint = '20mb max • .jpeg, .gif, .webp, or .png';
  static final _usernamePattern = RegExp(r'^[a-z0-9_]{3,32}$');

  /// Rewards-store perk that unlocks GIF uploads on a profile (`Perk.GifPfp`
  /// server-side). It gates the avatar and the banner — the two files
  /// `updateProfile` accepts — and nothing else: mint and collection uploads
  /// take a GIF from anyone.
  static const _gifPfpPerk = 'gif-pfp';

  /// Shown for both boxes. It names the perk rather than the box, so a user who
  /// hits it on the banner still knows which store item lifts it.
  static const _gifLockedMessage = 'Animated PFP is locked';

  final _repo = sl<UserProfileRepository>();
  final _auth = sl<AuthService>();
  final _session = sl<SessionManager>();
  final _walletRepo = sl<WalletRepository>();
  final _lookup = sl<ProfileLookupService>();
  final _walletLink = sl<WalletLinkService>();
  final _tokenRepo = sl<TokenRepository>();
  final _ethTokens = sl<EthereumTokenService>();
  final _tezosTokens = sl<TezosTokenService>();
  final _portfolioRepo = sl<PortfolioRepository>();
  final _twitterConnect = sl<TwitterConnectNotifier>();
  StreamSubscription<TwitterConnectStatus>? _twitterSub;

  final _displayNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();
  final _websiteController = TextEditingController();

  late String _originalUsername;
  api.SocialAccount? _twitter;
  String? _email;
  bool _marketingUpdates = true;
  bool _disableEmailNotifications = false;

  String _avatarUrl = '';
  String? _bannerUrl;
  PickedImage? _pickedAvatar;
  PickedImage? _pickedBanner;

  _UsernameStatus _usernameStatus = _UsernameStatus.unchanged;
  Timer? _usernameDebounce;

  int _step = 0;
  bool _saving = false;
  bool _connectingTwitter = false;

  /// Whether this screen opened in first-time "Create profile" mode (no
  /// username yet). Captured once so the step structure stays stable even
  /// after the profile is created mid-flow.
  late final bool _isCreate;

  /// Resolution state for the eligibility lookup (which wallets are signable
  /// AND not already attached to a *different* profile).
  _Eligibility _eligibility = _Eligibility.idle;

  /// Every device account with ≥1 offerable wallet, in display order.
  List<LinkableAccount> _linkableAccounts = const [];

  /// IDs of the wallets the user chose to back the profile.
  final Set<String> _selectedWalletIds = {};

  /// IDs of wallets already linked to the profile when the step loaded — the
  /// baseline the edit-mode save diffs against. Derived, so it can't drift from
  /// the cards: [LinkableWallet.linkedToProfile] is set once by
  /// [resolveLinkable] and preserved across enrichment `copyWith`s.
  Set<String> get _initiallyLinkedIds => {
    for (final account in _linkableAccounts)
      for (final wallet in account.wallets)
        if (wallet.linkedToProfile) wallet.id,
  };

  /// The profile's signing wallet, pinned ON: unlinking it would invalidate the
  /// session mid-save, and it guarantees the selection can never be emptied.
  final Set<String> _lockedWalletIds = {};

  /// Linked addresses that aren't on this device (synthetic `view-only:`
  /// placeholders from [ProfileLookupService.buildProfileGroups]). They aren't
  /// selectable but still count toward [kMaxProfileWallets].
  int _offDeviceLinkedCount = 0;

  /// Wallets the profile would have after saving — on-device selection plus the
  /// off-device links that aren't shown.
  int get _plannedWalletCount =>
      _offDeviceLinkedCount + _selectedWalletIds.length;

  bool get _atCapacity => _plannedWalletCount >= kMaxProfileWallets;

  @override
  void initState() {
    super.initState();
    final user = _auth.currentUser;
    final details = _auth.currentUserDetails;
    // forceCreate (Profiles-tab "Add") starts a brand-new profile even while a
    // profile session is active: leave every field blank rather than prefilling
    // from — and editing — the currently active profile.
    if (widget.forceCreate) {
      _originalUsername = '';
      _isCreate = true;
    } else {
      _displayNameController.text = user?.displayName ?? '';
      _originalUsername = user?.username ?? '';
      _bioController.text = details?.bio ?? '';
      _websiteController.text = details?.website ?? '';
      _avatarUrl = user?.imageUrl ?? '';
      _bannerUrl = user?.bannerUrl;
      _twitter = details?.twitter;
      _email = details?.email;
      _marketingUpdates = details?.marketingUpdates ?? true;
      _disableEmailNotifications = details?.disableEmailNotifications ?? false;
      _isCreate = _originalUsername.isEmpty;
    }
    _usernameController.text = _originalUsername;

    // The create-flow wallet eligibility is resolved lazily (it needs a network
    // bulk-lookup to know what's already attached to a profile) when the user
    // leaves the details step — see [_loadEligibility].

    // Resume the X connect flow when the app returns via the app-link callback.
    _twitterSub = _twitterConnect.results.listen(_onTwitterConnectResult);
  }

  @override
  void dispose() {
    _twitterSub?.cancel();
    _usernameDebounce?.cancel();
    _displayNameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    _websiteController.dispose();
    super.dispose();
  }

  // --- Username availability ---

  void _onUsernameChanged(String raw) {
    final value = raw.toLowerCase();
    if (value != raw) {
      _usernameController.value = _usernameController.value.copyWith(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
    _usernameDebounce?.cancel();

    if (value == _originalUsername) {
      setState(() => _usernameStatus = _UsernameStatus.unchanged);
      return;
    }
    if (!_usernamePattern.hasMatch(value)) {
      setState(() => _usernameStatus = _UsernameStatus.invalid);
      return;
    }
    setState(() => _usernameStatus = _UsernameStatus.checking);
    _usernameDebounce = Timer(const Duration(milliseconds: 500), () {
      _checkUsername(value);
    });
  }

  Future<void> _checkUsername(String username) async {
    try {
      final available = await _repo.isUsernameAvailable(username);
      if (!mounted || _usernameController.text != username) return;
      setState(
        () => _usernameStatus = available
            ? _UsernameStatus.available
            : _UsernameStatus.taken,
      );
    } catch (_) {
      if (!mounted || _usernameController.text != username) return;
      setState(() => _usernameStatus = _UsernameStatus.error);
    }
  }

  String? get _usernameError => switch (_usernameStatus) {
    _UsernameStatus.invalid =>
      '3–32 characters, lowercase letters, numbers and underscores',
    _UsernameStatus.taken => 'Username is taken',
    _UsernameStatus.error => 'Couldn\'t check availability',
    _ => null,
  };

  // --- Image picking ---

  Future<PickedImage?> _pickImage() {
    return pickImageFromSource(
      context,
      allowedExtensions: _imageExtensions,
      maxSizeBytes: _maxImageBytes,
      typeSummary: 'a .jpeg, .gif, .webp or .png image',
      onError: (message) {
        if (mounted) {
          AppSnackBar.show(context, message, type: AppSnackBarType.error);
        }
      },
    );
  }

  Future<void> _pickAvatar() async {
    final picked = await _pickImage();
    if (picked == null || !mounted || _rejectsLockedGif(picked)) return;
    setState(() => _pickedAvatar = picked);
  }

  Future<void> _pickBanner() async {
    final picked = await _pickImage();
    if (picked == null || !mounted || _rejectsLockedGif(picked)) return;
    setState(() => _pickedBanner = picked);
  }

  /// Whether [picked] is a GIF this account may not upload — true means the
  /// error has already been shown and the caller must drop the pick.
  ///
  /// Refusing here rather than at save is what keeps the reason legible:
  /// `createProfileUpload` refuses to presign an `image/gif` pfp OR banner with
  /// a flat 400 unless the user holds [_gifPfpPerk]. Matched on extension, not
  /// on whether the frames actually move — the backend gates the format, so a
  /// single-frame GIF is locked too.
  ///
  /// Caller must be mounted: this reports through the screen's context.
  bool _rejectsLockedGif(PickedImage picked) {
    if (!picked.fileName.toLowerCase().endsWith('.gif')) return false;
    if (_auth.currentUser?.perks.contains(_gifPfpPerk) ?? false) return false;
    AppSnackBar.show(context, _gifLockedMessage, type: AppSnackBarType.error);
    return true;
  }

  // --- Email ---

  Future<void> _editEmail() async {
    final verified = await showEmailOtpSheet(context, initialEmail: _email);
    if (verified != null && mounted) {
      setState(() => _email = verified);
      AppSnackBar.show(
        context,
        'Email verified',
        type: AppSnackBarType.success,
      );
    }
  }

  // --- Twitter / X ---
  //
  // Connect launches the X authorize URL in the system browser. The backend
  // `/v2/twitter/callback` finishes the OAuth exchange server-side (PKCE
  // verifier + address are cached against a single-use state token, not the
  // app session) and redirects to the `?twitter=…` app link, which
  // [DeepLinkService] forwards to [TwitterConnectNotifier]. We then refresh the
  // session to pick up the newly linked handle.

  Future<void> _connectTwitter() async {
    setState(() => _connectingTwitter = true);
    try {
      final url = await _repo.getTwitterAuthUrl();
      final launched = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) throw Exception('Could not open browser');
    } catch (_) {
      if (mounted) {
        AppSnackBar.show(
          context,
          'Could not start X connect',
          type: AppSnackBarType.error,
        );
      }
    } finally {
      // Launching only opens the browser; the connect itself completes later
      // via the app-link callback, so clear the busy state now.
      if (mounted) setState(() => _connectingTwitter = false);
    }
  }

  Future<void> _onTwitterConnectResult(TwitterConnectStatus status) async {
    if (!mounted) return;
    switch (status) {
      case TwitterConnectStatus.success:
        try {
          await _auth.refresh();
        } catch (_) {
          // Best-effort — the link still succeeded server-side.
        }
        if (!mounted) return;
        setState(() => _twitter = _auth.currentUserDetails?.twitter);
        AppSnackBar.show(context, 'X connected', type: AppSnackBarType.success);
      case TwitterConnectStatus.userExists:
        AppSnackBar.show(
          context,
          'That X account is already linked to another account',
          type: AppSnackBarType.error,
        );
      case TwitterConnectStatus.error:
        AppSnackBar.show(
          context,
          'Could not connect X',
          type: AppSnackBarType.error,
        );
    }
  }

  Future<void> _disconnectTwitter() async {
    setState(() => _connectingTwitter = true);
    try {
      await _repo.disconnectTwitter();
      if (mounted) setState(() => _twitter = null);
    } catch (_) {
      if (mounted) {
        AppSnackBar.show(
          context,
          'Could not disconnect X',
          type: AppSnackBarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _connectingTwitter = false);
    }
  }

  // --- Step navigation ---
  //
  // 0 upload · 1 details · 2 wallets · 3 social
  //
  // Both modes share the shape. In create mode the profile/User record is
  // established on the wallets step so the optional final step (X connect etc.)
  // has a backend profile to act on; in edit mode the wallet changes are applied
  // together with the profile fields on the final Save, so backing out of the
  // wizard never leaves a half-applied link.

  static const int _stepCount = 4;

  static const int _lastStep = _stepCount - 1;

  /// The wallet-select step index.
  static const int _walletsStepIndex = 2;

  /// Even fill across the steps: reaches 100% on the final step.
  double get _progressFraction => (_step + 1) / _stepCount;

  /// An avatar is set when one is freshly picked or already on file.
  bool get _hasAvatar => _pickedAvatar != null || _avatarUrl.isNotEmpty;

  /// The chosen username is present and has passed (or skipped) the
  /// availability check.
  bool get _usernameValid =>
      _usernameController.text.trim().isNotEmpty &&
      _usernameStatus != _UsernameStatus.checking &&
      _usernameStatus != _UsernameStatus.invalid &&
      _usernameStatus != _UsernameStatus.taken;

  /// A username and an avatar are required before the profile can be saved.
  bool get _canSave => !_saving && _usernameValid && _hasAvatar;

  /// Whether the bottom CTA is enabled for the current step.
  bool get _ctaEnabled {
    if (_step == 0) return _hasAvatar;
    if (_step == 1) return _usernameValid;
    if (_step == _walletsStepIndex) {
      // Creating commits the profile here, so it needs the full save gate — and
      // a profile with no wallet can't exist, so the lookup must have landed.
      if (_isCreate) {
        return _canSave &&
            _eligibility == _Eligibility.ready &&
            _selectedWalletIds.isNotEmpty;
      }
      if (_saving) return false;
      return switch (_eligibility) {
        // Editing: a failed lookup blocks wallet *changes* (the diff comes out
        // empty) but must not strand an offline user midway through their bio.
        _Eligibility.error => true,
        // Never let the profile end up with zero wallets. Off-device links
        // count: they aren't selectable but still keep the profile alive.
        _Eligibility.ready => _plannedWalletCount > 0,
        _Eligibility.idle || _Eligibility.loading => false,
      };
    }
    // Final step: the save step. When editing it gates on username+avatar;
    // when creating the profile already exists, so the optional extras can
    // always be saved.
    return _isCreate ? !_saving : _canSave;
  }

  String get _ctaLabel {
    if (_isCreate && _step == _walletsStepIndex) return 'Create profile';
    if (_step < _lastStep) return 'Next';
    return 'Save Profile';
  }

  void _handleBack() {
    if (_step == 0) {
      context.pop();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _step--);
  }

  void _onCta() {
    if (_isCreate && _step == _walletsStepIndex) {
      _create();
    } else if (_step < _lastStep) {
      FocusScope.of(context).unfocus();
      // Leaving the details step kicks off the (fresh) wallet eligibility
      // lookup that the next step renders. Only when there's nothing to show
      // yet — re-running it on every Back/Next would drop the enriched activity
      // and re-issue the whole lookup + per-wallet fetch fan-out. The error
      // state has its own retry.
      if (_step == 1 && _eligibility == _Eligibility.idle) _loadEligibility();
      setState(() => _step++);
    } else {
      _save();
    }
  }

  // --- Wallet eligibility ---

  /// Resolve which wallets the "Select wallets" step may offer, across every
  /// account on the device.
  ///
  /// A wallet is offered when it is signable AND not attached to a *different*
  /// named profile. The latter needs a fresh backend bulk-lookup, so this drives
  /// the loading / error / empty states. Wallets already linked to the profile
  /// being edited are kept and start selected.
  Future<void> _loadEligibility() async {
    setState(() => _eligibility = _Eligibility.loading);
    try {
      final accounts = await _walletRepo.getAccountViews();
      final owners = await _lookup.namedProfileIdForAddresses(
        accounts
            .expand((a) => a.wallets)
            .where((w) => w.canSign)
            .map((w) => w.address)
            .toList(),
      );

      // Creating has no profile yet, so nothing is ever "already linked" and
      // every offered wallet is fair game.
      final profile = _isCreate ? null : _session.activeProfile;
      // The id [resolveLinkable] compares wallet owners against. In a Profile
      // session it's the active group's userId; in an Account session (where a
      // wallet may still have a named profile) activeProfile is null, so fall
      // back to the signed-in username — which is exactly what the owner map is
      // keyed by (ProfileLookupService._profileIdFor = username ?? first
      // address). Without this fallback every wallet linked to the user's own
      // profile is misread as "someone else's" and dropped, stranding the edit.
      final currentProfileId = profile?.userId ?? _auth.currentUser?.username;
      final linkable = resolveLinkable(
        accounts: accounts,
        profileIdByAddress: owners,
        currentProfileId: currentProfileId,
      );

      final all = linkable.expand((a) => a.wallets).toList();
      final linked = all.where((w) => w.linkedToProfile).toList();
      // The wallet the session actually signs with stays pinned — see
      // [_lockedWalletIds]. Lock the live session address, not the profile's
      // first-Solana [loginAddress]: they can differ (signed in via a second
      // Solana wallet, or the only Solana address is an off-device placeholder),
      // and pinning the wrong one lets the user unlink the wallet the session is
      // signing with — the exact cut-out the lock exists to prevent.
      final loginAddress = _auth.currentAddress;
      final locked = linked.where((w) => w.address == loginAddress);
      // Linked addresses with no local wallet still occupy a profile slot.
      final linkedOnDevice = linked.map((w) => w.address).toSet();
      final offDevice = (profile?.wallets ?? const <WalletInfo>[])
          .where((w) => !linkedOnDevice.contains(w.address))
          .length;

      if (!mounted) return;
      setState(() {
        _linkableAccounts = linkable;
        _offDeviceLinkedCount = offDevice;
        _lockedWalletIds
          ..clear()
          ..addAll(locked.map((w) => w.id));
        _selectedWalletIds
          ..clear()
          // Creating starts with nothing selected — linking a wallet to a
          // profile is a deliberate choice, not a default. Editing selects what
          // is already linked, so an untouched pass is a no-op.
          ..addAll(_isCreate ? const <String>[] : linked.map((w) => w.id));
        _eligibility = _Eligibility.ready;
      });
      unawaited(_enrichActivity());
    } catch (_) {
      if (!mounted) return;
      // Fail loud: block the step with a retry rather than offering an
      // unfiltered list that would fail server-side on link.
      setState(() => _eligibility = _Eligibility.error);
    }
  }

  /// Fill in per-wallet artwork counts and USD balances behind the shimmer.
  Future<void> _enrichActivity() async {
    final snapshot = _linkableAccounts;
    final enriched = await Future.wait(
      snapshot.map(
        (a) async =>
            a.withWallets(await Future.wait(a.wallets.map(_enrichWallet))),
      ),
    );
    if (!mounted) return;
    // A Retry may have replaced the list while this was in flight.
    if (!identical(_linkableAccounts, snapshot)) return;
    setState(() => _linkableAccounts = enriched);
  }

  Future<LinkableWallet> _enrichWallet(LinkableWallet w) async {
    // Independent network calls — run them concurrently. Each falls back to 0
    // when unavailable so the shimmer always terminates.
    final usdFuture = _loadBalanceUsd(w.wallet);
    final artworksFuture = _portfolioRepo
        .artworkCountForOwner(w.address)
        .catchError((_) => 0);
    return w.copyWith(
      balanceUsd: await usdFuture,
      artworkCount: await artworksFuture,
    );
  }

  /// Total USD held by [wallet], routed to the token service that can actually
  /// answer for its chain — the Solana DAS `searchAssets` path returns nothing
  /// for an Ethereum or Tezos address.
  ///
  /// Cache-first: these wallets are already on the device, so their balances
  /// have usually been fetched elsewhere in the app already.
  Future<double> _loadBalanceUsd(WalletInfo wallet) async {
    try {
      final address = wallet.address;
      final tokens = switch (wallet.chainEnum) {
        Chain.ethereum => await _cacheFirst(
          () => _ethTokens.getCachedBalances(address),
          () => _ethTokens.getTokenBalances(address),
        ),
        Chain.tezos => await _cacheFirst(
          () => _tezosTokens.getCachedBalances(address),
          () => _tezosTokens.getTokenBalances(address),
        ),
        Chain.solana => await _cacheFirst(
          () => _tokenRepo.getCachedBalances(address),
          () async {
            final fresh = await _tokenRepo.getTokenBalances(address);
            // Only the Solana repo needs an explicit write-back; the EVM and
            // Tezos services cache inside their own fetch.
            await _tokenRepo.cacheBalances(address, fresh);
            return fresh;
          },
        ),
      };
      return _tokenRepo.calculateTotalValue(tokens);
    } catch (_) {
      return 0;
    }
  }

  Future<List<TokenBalance>> _cacheFirst(
    Future<List<TokenBalance>> Function() cached,
    Future<List<TokenBalance>> Function() fresh,
  ) async {
    final hit = await cached();
    return hit.isNotEmpty ? hit : await fresh();
  }

  // --- Wallet selection ---

  void _toggleWallet(String walletId) {
    setState(() {
      if (_selectedWalletIds.remove(walletId)) return;
      if (_atCapacity) return;
      _selectedWalletIds.add(walletId);
    });
  }

  /// Header "select all": clears the account's wallets when they're all on,
  /// otherwise selects as many as the remaining capacity allows.
  void _toggleAccount(LinkableAccount account) {
    final ids = account.wallets
        .where((w) => !_lockedWalletIds.contains(w.id))
        .map((w) => w.id)
        .toList();
    setState(() {
      if (ids.every(_selectedWalletIds.contains)) {
        _selectedWalletIds.removeAll(ids);
        return;
      }
      for (final id in ids) {
        if (_selectedWalletIds.contains(id)) continue;
        if (_atCapacity) break;
        _selectedWalletIds.add(id);
      }
    });
  }

  // --- Save ---

  Future<void> _save() async {
    if (!_canSave) return;
    FocusScope.of(context).unfocus();

    // Wallet changes only exist in edit mode — the create flow already linked
    // its selection when it established the profile.
    final diff = _isCreate
        ? const WalletDiff(toLink: {}, toUnlink: {})
        : diffSelection(
            currentlyLinked: _linkedAddressesById(_initiallyLinkedIds),
            selected: _linkedAddressesById(_selectedWalletIds),
            locked: _linkedAddressesById(_lockedWalletIds),
          );

    // Unlinking is destructive and irreversible from here, so name the wallets
    // and make the user say yes before anything is written.
    if (diff.toUnlink.isNotEmpty) {
      final confirmed = await showConfirmSheet(
        context,
        title: 'Unlink wallets?',
        message: diff.toUnlink.length == 1
            ? '${truncateAddress(diff.toUnlink.first)} will be removed from '
                  'this profile. Its artworks will no longer appear on it.'
            : '${diff.toUnlink.length} wallets will be removed from this '
                  'profile. Their artworks will no longer appear on it.',
        confirmLabel: 'Unlink',
        destructive: true,
      );
      if (confirmed != true) return;
      if (!mounted) return;
    }

    // Linking needs the profile's anchor wallet. Resolve it before any write
    // so a missing anchor aborts the save up front instead of failing after
    // the profile fields have already committed. Anchor on the live session
    // address — a held, signable wallet with a local DB row — not the profile's
    // first-Solana loginAddress, which can be an off-device `view-only:`
    // placeholder that WalletLinkService.linkWallet rejects ('Profile wallet
    // not found') after the profile fields have already committed.
    final anchor = _auth.currentAddress;
    if (diff.toLink.isNotEmpty && anchor == null) {
      AppSnackBar.show(
        context,
        'Could not save profile. Please try again.',
        type: AppSnackBarType.error,
      );
      return;
    }

    setState(() => _saving = true);

    final username = _usernameController.text.trim();
    final displayName = _displayNameController.text.trim();
    final bio = _bioController.text.trim();
    final website = _websiteController.text.trim();

    try {
      final result = await _repo.updateProfile(
        username: username != _originalUsername ? username : null,
        displayName: displayName,
        bio: bio,
        website: website,
        marketingUpdates: _marketingUpdates,
        disableEmailNotifications: _disableEmailNotifications,
        pfp: _pickedAvatar,
        banner: _pickedBanner,
      );
      _auth.applyProfileUpdate(result.user, result.userDetails);

      // Apply the wallet changes after the (cheap, most-likely-to-succeed)
      // profile write. Unlink BEFORE link: a swap on a profile already at
      // kMaxProfileWallets must free the outgoing slot before the incoming link
      // is created — linking first would transiently push the backend to 6/5 and
      // be rejected mid-save. The signing wallet is locked out of toUnlink, so
      // unlinking first never cuts the session out from under itself.
      if (!diff.isEmpty) {
        for (final address in diff.toUnlink) {
          await _walletLink.unlinkWallet(address);
        }
        for (final address in diff.toLink) {
          await _walletLink.linkWallet(address, anchor!);
        }
        // The group is rebuilt from the backend below; drop the stale lookup
        // first or it would re-derive the pre-change wallet set.
        _lookup.clearCache();
      }

      // Push the fresh identity into the session's ProfileGroup — the home,
      // drawer, and settings headers all read the name/avatar from
      // SessionManager.activeProfile, which is otherwise only rebuilt on a
      // profile switch, so they'd keep showing the pre-edit name. This also
      // rewrites the group's userId to the new username, so it MUST run before
      // refreshActiveProfile below: that lookup matches session groups by userId
      // against the backend group (keyed by the new username), so refreshing
      // first — while the group still carries the old userId — would find no
      // match and drop the refreshed wallet set on the floor.
      await _session.applyProfileEdit(
        username: result.user.username,
        displayName: result.user.displayName,
        imageUrl: result.user.imageUrl,
      );

      // Now that the group's userId matches the new username, re-derive its
      // wallet set from the backend so the link/unlink lands in the session.
      if (!diff.isEmpty) {
        await _session.refreshActiveProfile();
      }
      // The drawer header builds from a backend bulk lookup, not AuthService,
      // so flag it to reload on return — otherwise it shows the old
      // username/display name until the next wallet switch.
      DrawerSignal.reloadDrawerOnReturn = true;
      if (!mounted) return;
      AppSnackBar.show(
        context,
        'Profile updated',
        type: AppSnackBarType.success,
      );
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppSnackBar.show(context, _messageFor(e), type: AppSnackBarType.error);
      // Links and unlinks apply one at a time, so a mid-flight failure leaves
      // the profile partly changed. Re-resolve rather than leaving the picker
      // showing an optimistic state that no longer matches the backend.
      if (!diff.isEmpty) {
        _lookup.clearCache();
        unawaited(_loadEligibility());
      }
    }
  }

  /// Addresses of the wallets in [ids], resolved against the loaded accounts.
  /// Link and unlink are address-keyed; selection is id-keyed.
  Set<String> _linkedAddressesById(Set<String> ids) => {
    for (final account in _linkableAccounts)
      for (final wallet in account.wallets)
        if (ids.contains(wallet.id)) wallet.address,
  };

  /// Create flow (wallets step): log in + verify with the first selected
  /// wallet to establish the profile, link any other selected wallets into it,
  /// write the core profile fields, switch the session into the new profile,
  /// then advance to the optional extras step.
  Future<void> _create() async {
    if (!_canSave || _selectedWalletIds.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);

    final selected = _linkableAccounts
        .expand((a) => a.wallets)
        .where((w) => _selectedWalletIds.contains(w.id))
        .map((w) => w.wallet)
        .toList();
    // Anchor the profile on the session's active wallet when it's in the
    // selection (the natural choice when creating from the account you're
    // already in); otherwise the first selected wallet.
    final active = await _walletRepo.getActiveWallet();
    final primary = selected.firstWhere(
      (w) => w.id == active?.id,
      orElse: () => selected.first,
    );
    final others = selected.where((w) => w.id != primary.id);

    final username = _usernameController.text.trim();
    final displayName = _displayNameController.text.trim();
    final bio = _bioController.text.trim();
    final website = _websiteController.text.trim();

    try {
      // 1. /v0/login + signature verify with the primary wallet — this becomes
      //    the profile's signing wallet and the active session.
      await _auth.switchWallet(primary.address);
      // 2. Link every other selected wallet into the primary's profile.
      for (final wallet in others) {
        await _walletLink.linkWallet(wallet.address, primary.address);
      }
      // 3. Write the profile fields onto the freshly established profile.
      final result = await _repo.updateProfile(
        username: username,
        displayName: displayName,
        bio: bio,
        website: website,
        marketingUpdates: _marketingUpdates,
        disableEmailNotifications: _disableEmailNotifications,
        pfp: _pickedAvatar,
        banner: _pickedBanner,
      );
      _auth.applyProfileUpdate(result.user, result.userDetails);

      // 4. Switch the session into the new profile (best-effort — a switch
      //    hiccup must not mask a successful creation). The username is set, so
      //    the userId here matches what the backend-discovered group will use.
      try {
        await _session.switchToProfile(
          ProfileGroup(
            userId: result.user.username,
            username: result.user.username,
            displayName: result.user.displayName,
            imageUrl: result.user.imageUrl,
            wallets: selected,
            isAnon: false,
          ),
          preferredWalletId: primary.id,
        );
      } catch (e) {
        // Non-fatal — the profile exists; the drawer rebuilds groups on reload.
      }

      if (!mounted) return;
      AppSnackBar.show(
        context,
        'Profile created',
        type: AppSnackBarType.success,
      );

      // The core profile is saved; the images are now on file, so the optional
      // save won't re-upload them. Advance to the optional extras step.
      setState(() {
        _saving = false;
        _originalUsername = username;
        _avatarUrl = result.user.imageUrl ?? _avatarUrl;
        _bannerUrl = result.user.bannerUrl ?? _bannerUrl;
        _pickedAvatar = null;
        _pickedBanner = null;
        _step++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppSnackBar.show(context, _messageFor(e), type: AppSnackBarType.error);
    }
  }

  String _messageFor(Object e) {
    // The image leg talks to S3, not the API, so it has no `message:` envelope
    // to scrape — its text is already written for the user.
    if (e is ProfileImageUploadException) return e.message;
    final match = RegExp(r'message: ([^,)}]+)').firstMatch(e.toString());
    return match?.group(1)?.trim() ??
        'Could not save profile. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MallowHeader(
                title: _isCreate ? 'Create profile' : 'Edit profile',
                onBack: _handleBack,
                actions: [_CloseAction(onPressed: () => context.pop())],
              ),
              const SizedBox(height: MallowTheme.spacing20),
              MintProgressBar(fraction: _progressFraction),
              const SizedBox(height: MallowTheme.spacing20),
              Expanded(
                child: IndexedStack(
                  index: _step,
                  children: [
                    _uploadStep(context),
                    _detailsStep(context),
                    _walletsStep(context),
                    _socialStep(context),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.only(
                  top: MallowTheme.spacingMd,
                  bottom:
                      MediaQuery.of(context).padding.bottom +
                      MallowTheme.spacingMd,
                ),
                child: MallowButton(
                  label: _ctaLabel,
                  isFullWidth: true,
                  isLoading: _saving,
                  enabled: _ctaEnabled,
                  onPressed: _onCta,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Steps ---

  Widget _uploadStep(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
      children: [
        const MallowSectionLabel(label: 'Upload Banner'),
        const SizedBox(height: 12),
        _ProfileUploadBox(
          picked: _pickedBanner,
          existingUrl: _bannerUrl,
          onTap: _pickBanner,
          height: 160,
        ),
        const SizedBox(height: 8),
        _hintText(context),
        const SizedBox(height: 24),
        const MallowSectionLabel(label: 'Upload Profile Picture'),
        const SizedBox(height: 12),
        _ProfileUploadBox(
          picked: _pickedAvatar,
          existingUrl: _avatarUrl.isEmpty ? null : _avatarUrl,
          onTap: _pickAvatar,
          height: 200,
          square: true,
        ),
        const SizedBox(height: 8),
        _hintText(context),
      ],
    );
  }

  Widget _detailsStep(BuildContext context) {
    final colors = context.mallowColors;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
      children: [
        const MallowSectionLabel(label: 'Username'),
        const SizedBox(height: 12),
        MallowPillField(
          controller: _usernameController,
          hintText: 'username',
          errorText: _usernameError,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 32,
          textInputAction: TextInputAction.next,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
          ],
          prefix: Text(
            '@',
            style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
          ),
          suffix: _UsernameStatusIcon(status: _usernameStatus),
          onChanged: _onUsernameChanged,
        ),
        const SizedBox(height: 8),
        _counter(context, _usernameController, 32),
        const SizedBox(height: 16),
        const MallowSectionLabel(label: 'Display Name'),
        const SizedBox(height: 12),
        MallowPillField(
          controller: _displayNameController,
          hintText: 'Name',
          maxLength: 48,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        _counter(context, _displayNameController, 48),
        const SizedBox(height: 16),
        const MallowSectionLabel(label: 'Bio'),
        const SizedBox(height: 12),
        MallowTextareaField(
          controller: _bioController,
          hintText: 'Let people know about you',
          maxLength: 256,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        _counter(context, _bioController, 256),
      ],
    );
  }

  Widget _socialStep(BuildContext context) {
    final connected = _twitter?.username != null;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
      children: [
        const MallowSectionLabel(
          label: 'Connect Social Accounts',
          optional: true,
        ),
        const SizedBox(height: 12),
        MallowButton(
          label: connected ? '@${_twitter!.username}' : 'Connect X',
          variant: MallowButtonVariant.secondary,
          isFullWidth: true,
          svgAsset: 'assets/icons/brand_x.svg',
          isLoading: _connectingTwitter,
          onPressed: connected ? _disconnectTwitter : _connectTwitter,
        ),
        const SizedBox(height: 24),
        const MallowSectionLabel(label: 'Website', optional: true),
        const SizedBox(height: 12),
        MallowPillField(
          controller: _websiteController,
          hintText: 'Enter your website address',
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 24),
        const MallowSectionLabel(label: 'Email', optional: true),
        const SizedBox(height: 12),
        _TappablePill(
          text: _email ?? 'Enter your email address',
          isPlaceholder: _email == null,
          onTap: _editEmail,
        ),
        const SizedBox(height: 24),
        MallowToggle(
          value: !_disableEmailNotifications,
          label: 'Email notifications',
          onChanged: (v) => setState(() => _disableEmailNotifications = !v),
        ),
        const SizedBox(height: 12),
        MallowToggle(
          value: _marketingUpdates,
          label: 'Marketing updates',
          onChanged: (v) => setState(() => _marketingUpdates = v),
        ),
      ],
    );
  }

  Widget _walletsStep(BuildContext context) {
    final colors = context.mallowColors;
    return ListView(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
      children: [
        Text(
          _isCreate
              ? 'Select which wallets to link to your new profile'
              : 'Select which wallets to link to your profile',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: MallowTheme.spacing20),
        switch (_eligibility) {
          _Eligibility.loading || _Eligibility.idle => const Column(
            children: [
              ProfileWalletPickerSkeleton(),
              ProfileWalletPickerSkeleton(),
            ],
          ),
          _Eligibility.error => _StepError(onRetry: _loadEligibility),
          _Eligibility.ready when _linkableAccounts.isEmpty => const _StepEmpty(
            message:
                'None of your wallets are available — they\'re all already '
                'linked to a profile.',
          ),
          _Eligibility.ready => Column(
            children: [
              for (final account in _linkableAccounts)
                ProfileWalletPickerCard(
                  account: account,
                  selectedWalletIds: _selectedWalletIds,
                  lockedWalletIds: _lockedWalletIds,
                  atCapacity: _atCapacity,
                  onToggleWallet: _toggleWallet,
                  onToggleAccount: _toggleAccount,
                ),
            ],
          ),
        },
        // Surface the cap rather than letting the extra toggles read as broken.
        if (_eligibility == _Eligibility.ready && _atCapacity)
          Text(
            'A profile can link up to $kMaxProfileWallets wallets.',
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
      ],
    );
  }

  Widget _hintText(BuildContext context) {
    return Text(
      _uploadHint,
      textAlign: TextAlign.center,
      style: MallowTheme.uiCaption.copyWith(
        color: context.mallowColors.textSecondary,
      ),
    );
  }

  Widget _counter(BuildContext context, TextEditingController c, int max) {
    final remaining = (max - c.text.characters.length).clamp(0, max);
    return Text(
      '$remaining characters remaining',
      style: MallowTheme.uiCaption.copyWith(
        color: context.mallowColors.textSecondary,
      ),
    );
  }
}

/// Dashed-border media upload box (banner / profile picture).
///
/// Empty: a dashed accent border over a muted surface with an upload glyph
/// and hint. Populated: shows the freshly picked image, or the existing
/// avatar/banner already on file, filling the box. Tapping always opens the
/// file picker so the user can pick or replace the image.
class _ProfileUploadBox extends StatelessWidget {
  const _ProfileUploadBox({
    required this.onTap,
    required this.height,
    this.picked,
    this.existingUrl,
    this.square = false,
  });

  final PickedImage? picked;
  final String? existingUrl;
  final VoidCallback onTap;
  final double height;

  /// When true the populated image renders as a centered square with rounded
  /// corners inset by 10px top/bottom, rather than filling the box full-bleed.
  final bool square;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final radius = BorderRadius.circular(MallowTheme.radiusPrimary);
    // Square thumbnails inset 10px top/bottom; full-bleed images fill the box.
    final double imageSide = square ? height - 20 : double.infinity;
    final double imageHeight = square ? height - 20 : height;
    final Widget body;
    if (picked != null) {
      final image = ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          picked!.bytes,
          fit: BoxFit.cover,
          width: imageSide,
          height: imageHeight,
        ),
      );
      body = square ? Center(child: image) : image;
    } else if (existingUrl != null && existingUrl!.isNotEmpty) {
      final image = MallowNetworkImage(
        imageUrl: existingUrl!,
        logicalSize: 400,
        width: imageSide,
        height: imageHeight,
        borderRadius: radius,
      );
      body = square ? Center(child: image) : image;
    } else {
      body = CustomPaint(
        // Foreground so the dashed stroke draws over the opaque fill rather
        // than being covered by it (see MintDropZone).
        foregroundPainter: DashedBorderPainter(color: colors.accent),
        child: ClipRRect(
          borderRadius: radius,
          child: Container(
            color: colors.surfaceMuted,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MallowSvgIcon(
                  'assets/icons/upload_square.svg',
                  width: 24,
                  height: 24,
                  color: colors.textSecondary,
                ),
                const SizedBox(height: 12),
                Text(
                  'Tap to upload your media',
                  style: MallowTheme.uiMeta.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(height: height, width: double.infinity, child: body),
    );
  }
}

/// Fail-loud state for the eligibility lookup: a message plus a Retry that
/// re-runs the (fresh) lookup. We never fall back to an unfiltered list.
class _StepError extends StatelessWidget {
  const _StepError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Text(
            'Couldn\'t check which wallets are available. Check your '
            'connection and try again.',
            textAlign: TextAlign.center,
            style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          MallowButton(
            label: 'Retry',
            variant: MallowButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

/// Empty state when no wallet (or no account) is eligible to back a profile.
class _StepEmpty extends StatelessWidget {
  const _StepEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        message,
        style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

/// A read-only pill styled like [MallowPillField] that opens a flow on tap
/// (used for email, where the value is set via the OTP verification sheet).
class _TappablePill extends StatelessWidget {
  const _TappablePill({
    required this.text,
    required this.isPlaceholder,
    required this.onTap,
  });

  final String text;
  final bool isPlaceholder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
          border: Border.all(color: colors.divider),
          color: colors.bgPrimary,
        ),
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: MallowTheme.uiBody.copyWith(
            color: isPlaceholder ? colors.textSecondary : colors.textPrimary,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// Close (X) action shown in the header — exits the edit flow.
class _CloseAction extends StatelessWidget {
  const _CloseAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: MallowSvgIcon(
            'assets/icons/x.svg',
            width: 20,
            height: 20,
            color: colors.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _UsernameStatusIcon extends StatelessWidget {
  const _UsernameStatusIcon({required this.status});

  final _UsernameStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return switch (status) {
      _UsernameStatus.checking => MallowLoader(
        size: 16,
        color: colors.textTertiary,
      ),
      _UsernameStatus.available => MallowSvgIcon(
        'assets/icons/checkmark.svg',
        width: 16,
        height: 16,
        color: colors.positive,
      ),
      _ => const SizedBox.shrink(),
    };
  }
}
