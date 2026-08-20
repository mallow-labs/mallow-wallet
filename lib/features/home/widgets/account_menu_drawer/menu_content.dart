part of '../account_menu_drawer.dart';

class _MenuContent extends StatelessWidget {
  const _MenuContent({this.currentAddress, this.onClose});

  final String? currentAddress;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalletDrawerBloc, WalletDrawerState>(
      builder: (context, drawerState) {
        final isViewOnly = _isActiveWalletViewOnly(drawerState);

        return Padding(
          padding: const EdgeInsets.only(
            left: 12,
            right: 12,
            top: 20,
            bottom: 32,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Top menu items
              Column(
                children: [
                  MenuRow(
                    icon: 'assets/icons/plus.svg',
                    label: 'Add wallet',
                    iconSize: 20,
                    onTap: () => context.push(AppRoutes.addWalletGlobal),
                  ),
                  const SizedBox(height: 8),
                  _NotificationMenuRow(
                    // Notifications is a Profile-only feature: in Account mode
                    // this surfaces the "profile required" sheet.
                    onTap: () async {
                      if (!await requireProfile(context)) return;
                      if (!context.mounted) return;
                      await context.push(AppRoutes.notifications);
                      // The screen acknowledges the feed on open; re-read so
                      // the dot is gone when the drawer comes back.
                      await sl<NotificationsRepository>().refreshUnreadCount();
                    },
                    disabled: isViewOnly,
                  ),
                  const SizedBox(height: 8),
                  MenuRow(
                    icon: 'assets/icons/dollar_chat.svg',
                    label: 'Offers',
                    // Offers is available to Accounts and Profiles alike (not
                    // gated).
                    onTap: () => context.push(AppRoutes.offers),
                  ),
                  const SizedBox(height: 8),
                  MenuRow(
                    icon: 'assets/icons/profile.svg',
                    label: 'Profile',
                    onTap: () async {
                      // Viewing a profile needs a Profile session; an Account
                      // gets the "profile required" sheet instead.
                      if (!await requireProfile(context)) return;
                      if (!context.mounted) return;
                      onClose?.call();
                      if (currentAddress != null) {
                        await context.push(
                          AppRoutes.profilePath(currentAddress!),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  MenuRow(
                    icon: 'assets/icons/followers.svg',
                    label: 'Followers',
                    // Followers is a Profile-only feature: in Account mode this
                    // surfaces the "profile required" sheet instead of a dead
                    // tap.
                    onTap: () async {
                      if (!await requireProfile(context)) return;
                      if (!context.mounted) return;
                      final address = currentAddress;
                      if (address == null) return;
                      onClose?.call();
                      // Resolve the full linked-address set so the lists cover
                      // every wallet on the profile (matches the follower-count
                      // tap on the profile screen); fall back to the active
                      // address if the lookup fails.
                      var addresses = [address];
                      try {
                        final profile = await sl<UserProfileRepository>()
                            .getUserProfile(address);
                        if (profile.linkedAddresses.isNotEmpty) {
                          addresses = profile.linkedAddresses;
                        }
                      } catch (_) {}
                      if (!context.mounted) return;
                      context.goToFollowers(address, addresses: addresses);
                    },
                  ),
                  const SizedBox(height: 8),
                  MenuRow(
                    icon: 'assets/icons/settings.svg',
                    label: 'Settings',
                    onTap: () => context.push(AppRoutes.settings),
                  ),
                ],
              ),
              // Bottom section
              _BottomSection(),
            ],
          ),
        );
      },
    );
  }

  bool _isActiveWalletViewOnly(WalletDrawerState state) {
    return state.maybeWhen(
      loaded: (profileGroups, anonGroup, activeWalletId, _, _, _) {
        if (activeWalletId == null) return false;
        for (final group in [...profileGroups, anonGroup]) {
          for (final w in group.wallets) {
            if (w.id == activeWalletId) {
              return w.walletType == WalletType.viewOnly;
            }
          }
        }
        return false;
      },
      offline: (wallets, activeWalletId, _) {
        if (activeWalletId == null) return false;
        for (final w in wallets) {
          if (w.id == activeWalletId) {
            return w.walletType == WalletType.viewOnly;
          }
        }
        return false;
      },
      orElse: () => false,
    );
  }
}
