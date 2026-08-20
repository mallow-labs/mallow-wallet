part of '../account_menu_drawer.dart';

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

/// Profiles tab: the linked profiles, each as a single row (avatar + italic
/// name + aggregate balance + QR). Tapping a row activates that profile. The
/// anon (unlinked) group is intentionally not shown here.
class _ProfileGroupListContent extends StatelessWidget {
  const _ProfileGroupListContent({this.onClose, this.onSwitched});

  final VoidCallback? onClose;

  /// Collapses the account list back to the menu after switching, leaving the
  /// surrounding drawer open.
  final VoidCallback? onSwitched;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalletDrawerBloc, WalletDrawerState>(
      builder: (context, state) {
        return state.maybeWhen(
          loaded:
              (
                profileGroups,
                anonGroup,
                activeWalletId,
                expandedGroupIds,
                linkingWalletId,
                _,
              ) {
                return Column(
                  children: [
                    Expanded(
                      child: profileGroups.isEmpty
                          ? _emptyState(context)
                          : MallowRefreshIndicator(
                              onRefresh: () => _refresh(context),
                              child: ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  8,
                                  12,
                                  16,
                                ),
                                children: [
                                  for (final group in profileGroups)
                                    _ProfileRow(
                                      group: group,
                                      // Switch the active profile, then collapse
                                      // the account list back to the menu — the
                                      // surrounding drawer stays open.
                                      onTap: () {
                                        sl<SessionManager>().switchToProfile(
                                          group,
                                        );
                                        onSwitched?.call();
                                      },
                                    ),
                                ],
                              ),
                            ),
                    ),
                    _EditProfilesButtons(onClose: onClose),
                  ],
                );
              },
          offline: (wallets, activeWalletId, _) =>
              const MallowNetworkErrorView(),
          orElse: () => const Center(child: MallowLoader()),
        );
      },
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Text(
        'No profiles yet',
        style: MallowTheme.uiMeta.copyWith(
          color: context.mallowColors.textSecondary,
        ),
      ),
    );
  }

  Future<void> _refresh(BuildContext context) async {
    context.read<WalletDrawerBloc>().add(
      const WalletDrawerEvent.refreshProfiles(),
    );
    await context.read<WalletDrawerBloc>().stream.firstWhere(
      (s) => s is WalletDrawerLoaded || s is WalletDrawerOffline,
    );
  }
}

/// One profile: avatar + italic name + aggregate balance + QR (opens the
/// profile's multi-chain receive sheet). Tapping the row activates the profile.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.group, required this.onTap});

  final ProfileGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    // A balance is "known" once balanceUsd is non-null — even a genuine $0. No
    // known balance for any wallet means this profile's aggregate is still on
    // its first load: show a shimmer, not $0.00. (This row only renders in the
    // loaded state, where cached-then-fresh balances stream in.)
    final hasKnownBalance = group.wallets.any((w) => w.balanceUsd != null);
    final total = group.wallets.fold<double>(
      0,
      (sum, w) => sum + (w.balanceUsd ?? 0),
    );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
        ),
        child: Row(
          children: [
            _ProfileAvatar(
              imageUrl: group.imageUrl,
              size: 24,
              seed: avatarSeedOf(username: group.username, id: group.userId),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _profileLabel(group),
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
            if (!hasKnownBalance)
              const ShimmerBox(width: 48, height: 12)
            else
              Text(
                formatUsd(total),
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            const SizedBox(width: 8),
            TapTargetExpander(
              child: GestureDetector(
                onTap: () =>
                    showWalletsReceiveSheet(context, wallets: group.wallets),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: MallowSvgIcon(
                      'assets/icons/qr.svg',
                      width: 20,
                      height: 20,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom CTAs — Edit (manage/reorder profiles) + Create (create a new profile).
class _EditProfilesButtons extends StatelessWidget {
  const _EditProfilesButtons({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: MallowButton(
              label: 'Edit',
              variant: MallowButtonVariant.secondary,
              // Keep the drawer open behind the pushed screen so popping back
              // from the edit flow returns to the still-visible drawer.
              onPressed: () => context.push(AppRoutes.editProfiles),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: MallowButton(
              label: 'Create',
              // Force create-mode so a new profile is started even when the
              // active session is already a profile (else the wizard would edit
              // the current one).
              onPressed: () {
                onClose?.call();
                context.push('${AppRoutes.editProfile}?create=true');
              },
            ),
          ),
        ],
      ),
    );
  }
}
