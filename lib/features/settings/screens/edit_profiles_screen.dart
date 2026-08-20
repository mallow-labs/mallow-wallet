import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../shared/widgets/loading_indicator.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../wallets/services/wallet_drawer_bloc.dart';
import '../widgets/settings_page_scaffold.dart';

/// Profile-level management: reorder (drag), open a profile to edit it, or
/// create a new profile via the "+" action. Reached from the drawer's
/// Profiles-tab "Edit" button.
class EditProfilesScreen extends StatefulWidget {
  const EditProfilesScreen({super.key});

  @override
  State<EditProfilesScreen> createState() => _EditProfilesScreenState();
}

class _EditProfilesScreenState extends State<EditProfilesScreen> {
  // WalletDrawerBloc is a factory: own a dedicated instance and drive its load
  // ourselves. Reading sl<WalletDrawerBloc>().state directly returns a fresh
  // `initial()` instance with no profiles.
  late final WalletDrawerBloc _drawerBloc;

  @override
  void initState() {
    super.initState();
    _drawerBloc = sl<WalletDrawerBloc>()..add(const WalletDrawerEvent.load());
  }

  @override
  void dispose() {
    _drawerBloc.close();
    super.dispose();
  }

  Future<void> _onReorder(
    List<ProfileGroup> groups,
    int oldIndex,
    int newIndex,
  ) async {
    final reordered = List<ProfileGroup>.from(groups);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    final orderedIds = reordered
        .map((g) => g.userId)
        .whereType<String>()
        .toList();
    _drawerBloc.add(WalletDrawerEvent.reorderProfileGroups(orderedIds));
    DrawerSignal.reloadDrawerOnReturn = true;
  }

  Future<void> _onTapAdd() async {
    // Force create-mode so a new profile is started rather than editing the
    // active session's profile.
    await context.push('${AppRoutes.editProfile}?create=true');
    if (!mounted) return;
    // Reflect a newly created profile in the list.
    _drawerBloc.add(const WalletDrawerEvent.load());
  }

  Future<void> _onTapProfile(ProfileGroup group) async {
    // EditProfileScreen edits the active session's profile, so activate this
    // profile before opening the edit flow.
    await sl<SessionManager>().switchToProfile(group);
    // switchToProfile only re-points the signer and emits; the /v0/login that
    // refreshes AuthService.currentUser runs fire-and-forget via the
    // wallet-change listener. EditProfileScreen reads currentUser synchronously
    // in initState to decide edit-vs-create, so await the login here first —
    // otherwise the wizard sees a cleared user and opens in "Create profile".
    //
    // Log in with THIS profile's own address, not WalletManager.getAddress():
    // that returns the global active-Solana selection, and switchToProfile only
    // moves it onto a wallet this profile *holds* — for a profile whose linked
    // Solana address was never imported that is a held sibling, not the address
    // the backend keys the profile by, so the wizard would prefill the wrong
    // identity's avatar/banner/details.
    final address =
        group.loginAddress ?? await sl<WalletManager>().getAddress();
    await sl<AuthService>().switchWallet(address);
    if (!mounted) return;
    await context.push(AppRoutes.editProfile);
    if (!mounted) return;
    // Reflect any rename / avatar change made in the edit flow.
    _drawerBloc.add(const WalletDrawerEvent.load());
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Edit Profiles',
      showDivider: false,
      actions: [
        TapTargetExpander(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTapAdd,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: MallowSvgIcon(
                'assets/icons/plus.svg',
                width: 16,
                height: 16,
                color: context.mallowColors.textPrimary,
              ),
            ),
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Rearrange or rename your profiles',
              style: MallowTheme.uiCaption.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: BlocBuilder<WalletDrawerBloc, WalletDrawerState>(
                bloc: _drawerBloc,
                builder: (context, state) {
                  final groups = state.maybeWhen(
                    loaded: (groups, anon, activeId, expanded, linkingId, _) =>
                        groups,
                    orElse: () => const <ProfileGroup>[],
                  );
                  final isLoading = state.maybeWhen(
                    loading: () => true,
                    initial: () => true,
                    orElse: () => false,
                  );

                  if (groups.isEmpty) {
                    if (isLoading) {
                      return const Center(child: MallowLoader());
                    }
                    return Center(
                      child: Text(
                        'No profiles yet',
                        style: MallowTheme.uiMeta.copyWith(
                          color: context.mallowColors.textSecondary,
                        ),
                      ),
                    );
                  }

                  return ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: EdgeInsets.zero,
                    onReorderItem: (oldIndex, newIndex) =>
                        _onReorder(groups, oldIndex, newIndex),
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      return _ProfileEditRow(
                        key: ValueKey(group.userId ?? 'profile_$index'),
                        group: group,
                        dragIndex: index,
                        onTap: () => _onTapProfile(group),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileEditRow extends StatelessWidget {
  const _ProfileEditRow({
    required this.group,
    required this.dragIndex,
    required this.onTap,
    super.key,
  });

  final ProfileGroup group;
  final int dragIndex;
  final VoidCallback onTap;

  String get _label {
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

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final total = group.wallets.fold<double>(
      0,
      (sum, w) => sum + (w.balanceUsd ?? 0),
    );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ReorderableDelayedDragStartListener(
              index: dragIndex,
              child: SizedBox(
                width: 16,
                child: Center(
                  child: MallowSvgIcon(
                    'assets/icons/dots_line.svg',
                    width: 16,
                    height: 16,
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _avatar(context),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _label,
                style: GoogleFonts.newsreader(
                  fontStyle: FontStyle.italic,
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  color: colors.textPrimary,
                  height: 21.5 / 15,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatUsd(total),
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            MallowSvgIcon(
              'assets/icons/arrow_right.svg',
              width: 16,
              height: 16,
              color: colors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(BuildContext context) {
    final imageUrl = group.imageUrl;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return MallowNetworkImage(
        imageUrl: imageUrl,
        logicalSize: 24,
        width: 24,
        height: 24,
        borderRadius: BorderRadius.circular(12),
        errorBuilder: (_) => _generatedAvatar(),
      );
    }
    return _generatedAvatar();
  }

  Widget _generatedAvatar() => AccountAvatar(
    seed: avatarSeedOf(username: group.username, id: group.userId),
    size: 24,
  );
}
