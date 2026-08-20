import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../wallets/services/profile_lookup_service.dart';

/// Gate a social action behind a Profile.
///
/// Returns `true` when the session is already in Profile mode (the caller
/// proceeds) — or when the user switches into a Profile from the sheet, so the
/// gated action runs in the newly active Profile without losing their spot. In
/// Account mode it returns `false` after presenting the "Profile required"
/// sheet, which offers to switch to or create a Profile — so social controls
/// stay visible and explain themselves on tap rather than silently failing.
///
/// Usage:
/// ```dart
/// if (!await requireProfile(context)) return;
/// // ... perform the gated action (like / follow / comment / curate)
/// ```
Future<bool> requireProfile(BuildContext context) async {
  if (sl<SessionManager>().isProfileMode) return true;
  if (!context.mounted) return false;
  final switched = await showProfileRequiredSheet(context);
  return switched ?? false;
}

/// Shows the "Profile required" sheet directly (without the mode check).
///
/// Resolves to `true` when the user switched into an existing profile from the
/// sheet (so callers can proceed with the gated action in the now-active
/// profile), and `null` otherwise.
Future<bool?> showProfileRequiredSheet(BuildContext context) {
  return showMallowSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ProfileRequiredSheet(
      canSwitchProfile: _hasSwitchableProfiles(),
      currentAccountProfile: _currentAccountProfile(),
    ),
  );
}

/// The profile already linked to a wallet in the active session [Account], or
/// `null` when none of the account's wallets belong to a named profile.
///
/// When this is non-null the sheet drops the "Create a new profile" action: the
/// account already has a profile, so the right move is to switch into it rather
/// than claim a second one. Resolved synchronously from the drawer's cached bulk
/// lookup — [ProfileLookupService.buildProfileGroups] only emits a group when
/// one of the passed wallets is actually held, so feeding it just the active
/// account's wallets yields exactly that account's profiles.
ProfileGroup? _currentAccountProfile() {
  final account = sl<SessionManager>().activeAccount;
  if (account == null || account.wallets.isEmpty) return null;
  final lookup = sl<ProfileLookupService>();
  final response = lookup.lastResponse;
  if (response == null) return null;
  final groups = lookup.buildProfileGroups(account.wallets, response).$1;
  for (final group in groups) {
    if (group.username != null && group.username!.isNotEmpty) return group;
  }
  return null;
}

/// Whether the device has at least one named profile to switch to.
///
/// Read from the wallet drawer's cached bulk lookup: a "profile" is a
/// looked-up user with a username or display name (the same definition the
/// account switcher uses). When the lookup hasn't run yet we report `false`
/// so the sheet hides the switch action rather than offering a switch to
/// nothing.
bool _hasSwitchableProfiles() {
  final response = sl<ProfileLookupService>().lastResponse;
  if (response == null) return false;
  return response.result.users.any(
    (e) => e.user.username != null || e.user.displayName != null,
  );
}

/// Resolves a profile group's display label: username → display name →
/// truncated primary address.
String _profileLabel(ProfileGroup group) {
  if (group.username != null && group.username!.isNotEmpty) {
    return group.username!;
  }
  if (group.displayName != null && group.displayName!.isNotEmpty) {
    return group.displayName!;
  }
  if (group.wallets.isNotEmpty) {
    return truncateAddress(group.wallets.first.address);
  }
  return 'Profile';
}

class _ProfileRequiredSheet extends StatefulWidget {
  const _ProfileRequiredSheet({
    required this.canSwitchProfile,
    this.currentAccountProfile,
  });

  /// Shows the "Switch to an existing profile" action only when the device
  /// actually has a profile to switch to.
  final bool canSwitchProfile;

  /// The profile already linked to the active account's wallets. When set, the
  /// sheet offers "Switch to @username" + "Switch to another profile" instead of
  /// the create flow — the account already owns a profile.
  final ProfileGroup? currentAccountProfile;

  @override
  State<_ProfileRequiredSheet> createState() => _ProfileRequiredSheetState();
}

class _ProfileRequiredSheetState extends State<_ProfileRequiredSheet> {
  bool _showProfiles = false;
  bool _loading = false;
  bool _switching = false;
  List<ProfileGroup> _groups = const [];

  /// Reveal the in-context profile list, building the same profile groups the
  /// drawer uses from the cached bulk lookup + the device's wallets.
  Future<void> _openProfilesView() async {
    setState(() {
      _showProfiles = true;
      _loading = true;
    });
    var groups = const <ProfileGroup>[];
    try {
      final lookup = sl<ProfileLookupService>();
      final response = lookup.lastResponse;
      if (response != null) {
        final accounts = await sl<WalletRepository>().getAccountViews();
        final wallets = accounts.expand((a) => a.wallets).toList();
        groups = lookup.buildProfileGroups(wallets, response).$1;
      }
    } catch (_) {
      // Best-effort — fall through to an empty list.
    }
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  /// Switch the session into [group] and close, signalling the caller to
  /// proceed with the originally-gated action in the new profile context.
  ///
  /// [SessionManager.switchToProfile] only re-points the signer and emits the
  /// wallet-change event — the re-login and signature verification it triggers
  /// run fire-and-forget in `MallowApp._setupWalletChangeListener`. We block on
  /// that here (coalesced via [AuthService.switchWallet]'s in-flight dedup) so
  /// the gated action runs against the new profile's authenticated session
  /// rather than the previous one. Only signal `true` once we're actually
  /// signed in; on login failure we close gated rather than acting unsigned.
  Future<void> _switchTo(ProfileGroup group) async {
    if (_switching) return;
    setState(() => _switching = true);
    var ready = false;
    try {
      await sl<SessionManager>().switchToProfile(group);
      final address = await sl<WalletManager>().getAddress();
      await sl<AuthService>().switchWallet(address);
      ready = sl<AuthService>().hasSession;
    } catch (_) {
      // Login failed — leave the caller gated rather than acting unsigned.
    }
    if (!mounted) return;
    Navigator.of(context).pop(ready);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacing20,
                MallowTheme.spacing20,
              ),
              child: _showProfiles
                  ? _profilesView(context)
                  : _actionsView(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionsView(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(MallowTheme.spacingMd),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          child: Text(
            'You need to be signed into a profile to perform this action',
            textAlign: TextAlign.center,
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        if (widget.currentAccountProfile case final linked?) ...[
          // The active account already owns a profile — switch into it rather
          // than offering to claim a second one.
          MallowButton(
            label: 'Switch to @${linked.username}',
            isFullWidth: true,
            onPressed: () => _switchTo(linked),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          MallowButton(
            label: 'Switch to another profile',
            variant: MallowButtonVariant.secondary,
            isFullWidth: true,
            onPressed: _openProfilesView,
          ),
        ] else ...[
          MallowButton(
            label: 'Create a new profile',
            isFullWidth: true,
            onPressed: () {
              Navigator.of(context).pop();
              // Lands in the edit-profile flow in create mode (username claim +
              // avatar + wallet selection). create=true forces a blank form: in
              // Account mode AuthService.currentUser can still hold the profile
              // we switched away from (its re-login is fire-and-forget), so
              // without this the wizard would prefill — and edit — that stale
              // profile.
              context.push('${AppRoutes.editProfile}?create=true');
            },
          ),
          if (widget.canSwitchProfile) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            MallowButton(
              label: 'Switch to an existing profile',
              variant: MallowButtonVariant.secondary,
              isFullWidth: true,
              onPressed: _openProfilesView,
            ),
          ],
        ],
      ],
    );
  }

  Widget _profilesView(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            GestureDetector(
              onTap: () => setState(() => _showProfiles = false),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: MallowSvgIcon(
                    'assets/icons/arrow_left.svg',
                    width: 16,
                    height: 16,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Text(
                'Switch profile',
                textAlign: TextAlign.center,
                style: MallowTheme.editorialSection.copyWith(fontSize: 18),
              ),
            ),
            const SizedBox(width: 40),
          ],
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: MallowLoader()),
          )
        else if (_groups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No profiles available',
              textAlign: TextAlign.center,
              style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
            ),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final group in _groups)
                  _ProfileSwitchRow(
                    group: group,
                    onTap: () => _switchTo(group),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One switchable profile: avatar + italic name on a 48px row with a hairline
/// bottom divider. Tapping activates the profile.
class _ProfileSwitchRow extends StatelessWidget {
  const _ProfileSwitchRow({required this.group, required this.onTap});

  final ProfileGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
        ),
        child: Row(
          children: [
            _SheetProfileAvatar(
              imageUrl: group.imageUrl,
              size: 28,
              seed: avatarSeedOf(username: group.username, id: group.userId),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _profileLabel(group),
                style: MallowTheme.editorialSection.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Circular profile avatar — the image when present, else the generated
/// identicon for [seed].
class _SheetProfileAvatar extends StatelessWidget {
  const _SheetProfileAvatar({
    required this.size,
    this.imageUrl,
    this.seed = '',
  });

  final String? imageUrl;
  final double size;
  final String seed;

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return MallowNetworkImage(
        imageUrl: imageUrl!,
        logicalSize: size,
        width: size,
        height: size,
        borderRadius: BorderRadius.circular(size / 2),
        errorBuilder: (_) => AccountAvatar(seed: seed, size: size),
      );
    }
    return AccountAvatar(seed: seed, size: size);
  }
}
