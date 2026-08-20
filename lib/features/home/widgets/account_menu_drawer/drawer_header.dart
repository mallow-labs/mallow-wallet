part of '../account_menu_drawer.dart';

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({
    required this.currentAddress,
    required this.totalUsdValue,
    required this.showingAccounts,
    required this.onToggleMode,
  });

  final String? currentAddress;
  final double totalUsdValue;
  final bool showingAccounts;
  final VoidCallback onToggleMode;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalletDrawerBloc, WalletDrawerState>(
      builder: (context, state) {
        String? profileImageUrl;
        String? displayName;
        String? displayAddress;
        String? walletName;

        state.maybeWhen(
          loaded:
              (
                profileGroups,
                anonGroup,
                activeWalletId,
                expandedGroupIds,
                linkingWalletId,
                _,
              ) {
                WalletInfo? activeWallet;
                for (final group in [...profileGroups, anonGroup]) {
                  for (final w in group.wallets) {
                    if (w.id == activeWalletId) {
                      activeWallet = w;
                      break;
                    }
                  }
                  if (activeWallet != null) break;
                }

                displayAddress = activeWallet?.address ?? currentAddress;
                walletName = activeWallet?.name;

                if (activeWallet != null) {
                  for (final group in profileGroups) {
                    if (group.wallets.any((w) => w.id == activeWalletId)) {
                      profileImageUrl = group.imageUrl;
                      // Always surface the profile's username; fall back to its
                      // display name, then the local wallet name takes over
                      // below if both are missing.
                      displayName = (group.username?.isNotEmpty ?? false)
                          ? group.username
                          : group.displayName;
                      break;
                    }
                  }
                }
              },
          offline: (wallets, activeWalletId, _) {
            final activeWallet = wallets.cast<WalletInfo?>().firstWhere(
              (w) => w?.id == activeWalletId,
              orElse: () => null,
            );
            displayAddress = activeWallet?.address ?? currentAddress;
            walletName = activeWallet?.name;
          },
          orElse: () {
            displayAddress = currentAddress;
          },
        );

        // The session — not the active wallet's profile group — is the source
        // of truth for identity. In Account mode show the Account itself
        // (dicebear avatar + name in Geist); only a Profile session surfaces
        // the linked profile's username/avatar. Without this, tapping
        // an Account whose signing wallet is linked to a profile renders that
        // profile, making it look like a profile login.
        final session = sl<SessionManager>();
        final isProfile = session.isProfileMode;
        final activeAccount = session.activeAccount;
        final activeProfile = session.activeProfile;
        if (isProfile && activeProfile != null) {
          // Take profile identity straight from the session — it updates
          // synchronously on switch, whereas the bloc's activeWalletId lags a
          // frame and would otherwise flash the anon avatar + wallet address
          // mid-switch.
          profileImageUrl = activeProfile.imageUrl;
          displayName = (activeProfile.username?.isNotEmpty ?? false)
              ? activeProfile.username
              : activeProfile.displayName;
        } else if (!isProfile && activeAccount != null) {
          displayName = activeAccount.name;
          profileImageUrl = null; // render the dicebear account avatar below
        }

        if (displayName == null || displayName!.isEmpty) {
          displayName = (walletName != null && walletName!.isNotEmpty)
              ? walletName
              : truncateAddress(displayAddress ?? '');
        }

        // Generated-identicon seed for the missing-image fallback. A profile
        // seeds by its own identity (username → userId) so the avatar stays
        // stable across wallet switches; otherwise the wallet address seeds.
        final fallbackSeed = isProfile && activeProfile != null
            ? avatarSeedOf(
                username: activeProfile.username,
                id: activeProfile.userId,
              )
            : avatarSeedOf(address: displayAddress);

        return Padding(
          padding: const EdgeInsets.only(top: 68, left: 12, right: 12),
          child: Row(
            children: [
              // Avatar + name/balance — tapping toggles the account list.
              Expanded(
                child: GestureDetector(
                  onTap: onToggleMode,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      // Avatar
                      if (!isProfile && activeAccount != null)
                        AccountAvatar(seed: activeAccount.avatarSeed, size: 44)
                      else if (profileImageUrl != null)
                        MallowNetworkImage(
                          imageUrl: profileImageUrl!,
                          logicalSize: 44,
                          width: 44,
                          height: 44,
                          borderRadius: BorderRadius.circular(22),
                          errorBuilder: (_) =>
                              AccountAvatar(seed: fallbackSeed, size: 44),
                        )
                      else
                        AccountAvatar(seed: fallbackSeed, size: 44),
                      const SizedBox(width: 12),
                      // Name + balance
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Builder(
                              builder: (context) {
                                // Profile identity → Newsreader italic; a plain
                                // Account → Geist uiBody. The session
                                // is the source of truth for which mode is
                                // active.
                                final style = isProfile
                                    ? GoogleFonts.newsreader(
                                        fontStyle: FontStyle.italic,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w400,
                                        color: context.mallowColors.textPrimary,
                                        height: 24 / 17,
                                      )
                                    : MallowTheme.uiBody.copyWith(
                                        color: context.mallowColors.textPrimary,
                                      );
                                final nameText = Text(
                                  displayName!,
                                  style: style,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                );
                                final badge = isProfile
                                    ? null
                                    : activeAccount?.typeBadge;
                                if (badge != null) {
                                  return Row(
                                    children: [
                                      Flexible(child: nameText),
                                      WalletTypeBadge(badge),
                                    ],
                                  );
                                }
                                return nameText;
                              },
                            ),
                            Text(
                              formatUsd(totalUsdValue),
                              style: MallowTheme.uiCaption.copyWith(
                                color: context.mallowColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // QR — opens the active account's multi-chain receive sheet.
              TapTargetExpander(
                child: GestureDetector(
                  onTap: () => _openReceive(context),
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: MallowSvgIcon('assets/icons/qr.svg', width: 20),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Switch — toggles the Wallets/Profiles account list. Reads
              // "Close" while that list is showing.
              _SwitchPill(
                onTap: onToggleMode,
                showingAccounts: showingAccounts,
              ),
            ],
          ),
        );
      },
    );
  }

  void _openReceive(BuildContext context) {
    showSessionReceiveSheet(context);
  }
}

/// Outlined pill that toggles the account switcher list.
class _SwitchPill extends StatelessWidget {
  const _SwitchPill({required this.onTap, required this.showingAccounts});

  final VoidCallback onTap;
  final bool showingAccounts;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: colors.bgSurface,
            border: Border.all(color: colors.accent),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Text(
            showingAccounts ? 'Close' : 'Switch',
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ),
    );
  }
}
