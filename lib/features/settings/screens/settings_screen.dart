import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/wallet_type_badge.dart';

import 'package:go_router/go_router.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/security/reauth_gate.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/push_notification_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../widgets/settings_menu_item.dart';

/// Top-level Settings screen.
///
/// Shows the active account profile row and links to all settings sub-screens.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  /// Whether the session is a Profile (vs a plain Account). Drives the header
  /// identity (profile username/pfp vs account name/dicebear avatar), the
  /// "Edit Profile"/"Edit Account" label, and the destination route.
  bool _isProfile = false;
  String? _accountId;
  String? _accountName;
  WalletBadge? _accountBadge;
  String? _walletAddress;
  String _avatarSeed = '';

  /// Profile-mode identity, sourced from the active profile (falling back to the
  /// authenticated user). Null in Account mode.
  String? _profileName;
  String? _profileImageUrl;
  String _networksBadge = 'All';
  bool _pushEnabled = true;
  StreamSubscription<String>? _walletChangeSub;

  /// Set when the push toggle sent the user to the OS settings app, so the
  /// grant they make there completes the enable when they come back.
  bool _awaitingOsPushGrant = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
    _walletChangeSub = sl<WalletManager>().onWalletChanged.listen(
      (_) => _loadData(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _walletChangeSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS permission can change while we're backgrounded — most obviously
    // when the toggle just sent the user to the settings app.
    if (state == AppLifecycleState.resumed) unawaited(_syncPushToggle());
  }

  Future<void> _loadData() async {
    final walletRepo = sl<WalletRepository>();
    final selection = await walletRepo.getActiveSelection();
    final storage = sl<SecureWalletStorage>();
    // Scope the badge to the current session so it reflects this profile's (or
    // the account's) own Active Networks setting.
    final networksScope = await sl<SessionManager>().settingsScopeId();
    final tezos = await storage.loadNetworkEnabled(
      Chain.tezos,
      scope: networksScope,
    );
    final ethereum = await storage.loadNetworkEnabled(
      Chain.ethereum,
      scope: networksScope,
    );
    // The toggle reflects what will actually be delivered, not just the stored
    // preference — the OS permission can be missing or revoked underneath it.
    final pushEnabled =
        sl<PreferencesService>().pushNotificationsEnabled &&
        await sl<PushNotificationService>().isAuthorized();
    if (!mounted) return;

    // Find active wallet
    WalletInfo? activeWallet;
    Account? activeAccount;
    if (selection != null) {
      activeAccount = selection.$1;
      activeWallet = selection.$2;
    }

    // The session is the source of truth for whether we're a Profile or a plain
    // Account, matching the drawer header (drawer_header.dart).
    final session = sl<SessionManager>();
    final isProfile = session.isProfileMode;
    final profile = session.activeProfile;
    final authUser = sl<AuthService>().currentUser;

    setState(() {
      _isProfile = isProfile;
      _accountId = activeAccount?.id;
      _accountName = activeAccount?.name;
      _accountBadge = activeAccount?.typeBadge;
      _walletAddress = activeWallet?.address;
      _pushEnabled = pushEnabled;
      _avatarSeed = activeAccount?.avatarSeed ?? '';
      _profileName = isProfile
          ? (profile?.username ?? profile?.displayName ?? authUser?.username)
          : null;
      _profileImageUrl = isProfile
          ? (profile?.imageUrl ?? authUser?.imageUrl)
          : null;
      if (tezos && ethereum) {
        _networksBadge = 'All';
      } else {
        final active = ['Solana'];
        if (tezos) active.add('Tezos');
        if (ethereum) active.add('Ethereum');
        _networksBadge = active.join(', ');
      }
    });
  }

  /// Tap target for the header row: a Profile session opens the Edit Profile
  /// flow; an Account session opens that account's edit screen. Disabled when
  /// there is no editable identity yet.
  VoidCallback? _onTapHeader() {
    if (_isProfile) {
      return () async {
        await context.push(AppRoutes.editProfile);
        await _loadData();
      };
    }
    final accountId = _accountId;
    if (accountId == null) return null;
    return () async {
      await context.push(AppRoutes.editAccountPath(accountId));
      await _loadData();
    };
  }

  Future<void> _togglePush(bool value) async {
    if (!value) {
      setState(() => _pushEnabled = false);
      await sl<PreferencesService>().setPushNotificationsEnabled(false);
      await sl<PushNotificationService>().unregister();
      return;
    }

    // Enabling has to clear the OS permission first. Persisting the preference
    // and calling register() (which only fetches a token) leaves the toggle on
    // while nothing can be delivered and nothing explains why.
    final outcome = await enablePushFromUserAction(context);
    if (!mounted) return;
    setState(() {
      _pushEnabled = outcome == PushEnableOutcome.granted;
      _awaitingOsPushGrant = outcome == PushEnableOutcome.sentToSettings;
    });
  }

  /// Re-reads the OS permission and reconciles the toggle with it.
  ///
  /// Runs on resume: the user may have granted (or revoked) notifications in
  /// the settings app. A grant that follows our own "Open Settings" hand-off
  /// finishes the enable the user started, but a grant made for unrelated
  /// reasons must not silently re-enable a preference they turned off in-app.
  Future<void> _syncPushToggle() async {
    final prefs = sl<PreferencesService>();
    final pushService = sl<PushNotificationService>();
    final authorized = await pushService.isAuthorized();
    if (!mounted) return;

    if (authorized && _awaitingOsPushGrant) {
      _awaitingOsPushGrant = false;
      if (!prefs.pushNotificationsEnabled) {
        await prefs.setPushNotificationsEnabled(true);
        await pushService.register();
      }
      if (!mounted) return;
      setState(() => _pushEnabled = true);
      return;
    }

    final enabled = authorized && prefs.pushNotificationsEnabled;
    if (enabled != _pushEnabled) setState(() => _pushEnabled = enabled);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const MallowHeader(title: 'Settings'),
              const SizedBox(height: 20),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onTapHeader(),
                child: _ProfileRow(
                  isProfile: _isProfile,
                  name: _isProfile ? _profileName : _accountName,
                  badge: _isProfile ? null : _accountBadge,
                  walletAddress: _walletAddress,
                  avatarSeed: _avatarSeed,
                  profileImageUrl: _profileImageUrl,
                ),
              ),
              const SizedBox(height: 12),
              Divider(
                height: 1,
                thickness: 1,
                color: context.mallowColors.dividerLight,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    SettingsMenuItem(
                      iconAsset: 'assets/icons/globe_dots.svg',
                      label: 'Active Networks',
                      badge: _networksBadge,
                      onTap: () async {
                        await context.push(AppRoutes.activeNetworks);
                        await _loadData();
                      },
                    ),
                    const SizedBox(height: 8),
                    _PushNotificationRow(
                      enabled: _pushEnabled,
                      onChanged: _togglePush,
                    ),
                    const SizedBox(height: 8),
                    SettingsMenuItem(
                      iconAsset: 'assets/icons/sliders.svg',
                      label: 'Preferences',
                      onTap: () => context.push(AppRoutes.preferences),
                    ),
                    const SizedBox(height: 8),
                    SettingsMenuItem(
                      iconAsset: 'assets/icons/shield_2.svg',
                      label: 'Security & Privacy',
                      onTap: () async {
                        // Gate the whole Security & Privacy area (Show secrets,
                        // Require auth over, etc.) behind biometric/PIN here so
                        // each sub-screen doesn't have to gate individually.
                        if (await requireReauth(context) && context.mounted) {
                          unawaited(context.push(AppRoutes.securityPrivacy));
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    SettingsMenuItem(
                      iconAsset: 'assets/icons/mallow_icon.svg',
                      label: 'About mallow',
                      onTap: () => context.push(AppRoutes.aboutMallow),
                    ),
                    const SizedBox(height: 8),
                    SettingsMenuItem(
                      iconAsset: 'assets/icons/bug_2.svg',
                      label: 'Report a bug',
                      onTap: () => context.push(AppRoutes.reportBug),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Profile row at the top of the settings screen.
///
/// In a Profile session it shows the profile username + uploaded picture and
/// links to Edit Profile; in an Account session it shows the account name +
/// generated avatar and links to Edit Account — mirroring the drawer header.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.isProfile,
    this.name,
    this.badge,
    this.walletAddress,
    this.avatarSeed,
    this.profileImageUrl,
  });

  final bool isProfile;
  final String? name;
  final WalletBadge? badge;
  final String? walletAddress;
  final String? avatarSeed;
  final String? profileImageUrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 47,
      child: Row(
        children: [
          _avatar(context),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name ?? '—',
                        style: GoogleFonts.newsreader(
                          fontStyle: FontStyle.italic,
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          color: context.mallowColors.textPrimary,
                          height: 22.9 / 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    WalletTypeBadge(badge),
                  ],
                ),
                if (isProfile && walletAddress != null)
                  Text(
                    truncateAddress(walletAddress!),
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            isProfile ? 'Edit profile' : 'Edit account',
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
          SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: Transform.rotate(
                angle: -3.14159 / 2, // -90° to point right
                child: const MallowSvgIcon(
                  'assets/icons/arrow_down.svg',
                  width: 6,
                  height: 6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Profile pfp (uploaded image, generated-identicon fallback) in a Profile
  /// session; the account's generated dicebear avatar otherwise — matching the
  /// drawer.
  Widget _avatar(BuildContext context) {
    if (isProfile) {
      if (profileImageUrl != null && profileImageUrl!.isNotEmpty) {
        return MallowNetworkImage(
          imageUrl: profileImageUrl!,
          logicalSize: 32,
          width: 32,
          height: 32,
          borderRadius: BorderRadius.circular(16),
          errorBuilder: (_) => _generatedAvatar(),
        );
      }
      return _generatedAvatar();
    }
    return AccountAvatar(seed: avatarSeed ?? '', size: 32);
  }

  Widget _generatedAvatar() => AccountAvatar(
    seed: avatarSeedOf(address: walletAddress, username: name),
    size: 32,
  );
}

/// Push notification toggle row matching the SettingsMenuItem visual style.
class _PushNotificationRow extends StatelessWidget {
  const _PushNotificationRow({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!enabled),
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              const MallowSvgIcon(
                'assets/icons/notif_badge.svg',
                width: 24,
                height: 24,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Push Notifications', style: MallowTheme.uiBody),
              ),
              MallowToggle(value: enabled, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}
