import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/router/app_router.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/tappable.dart';
import '../services/followers_bloc.dart';
import '../widgets/profile_required_sheet.dart';

/// Followers menu: All / Followers / Following lists for a profile, with
/// follow/unfollow per row, Latest/Oldest ordering, and Follow All.
class FollowersScreen extends StatelessWidget {
  const FollowersScreen({
    required this.addresses,
    this.initialTab = FollowersTab.all,
    super.key,
  });

  /// The profile's linked wallet addresses.
  final List<String> addresses;

  /// Tab to select once the lists resolve. The profile header's Following
  /// count lands here on [FollowersTab.following].
  final FollowersTab initialTab;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          sl<FollowersBloc>()..add(FollowersEvent.load(addresses: addresses)),
      child: _FollowersView(initialTab: initialTab),
    );
  }
}

class _FollowersView extends StatefulWidget {
  const _FollowersView({required this.initialTab});

  final FollowersTab initialTab;

  @override
  State<_FollowersView> createState() => _FollowersViewState();
}

class _FollowersViewState extends State<_FollowersView> {
  static const _tabs = [
    FollowersTab.all,
    FollowersTab.followers,
    FollowersTab.following,
  ];
  static const _tabLabels = ['All', 'Followers', 'Following'];

  final _scrollController = ScrollController();

  /// `FollowersEvent.changeTab` is dropped while the bloc is still on its
  /// `initial` state, and `load` only emits `loaded` once both lists have
  /// resolved — so the requested tab has to be applied on that first emission
  /// rather than dispatched alongside `load`.
  bool _appliedInitialTab = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Already loaded (a bloc handed in ready-made) — the listener below only
    // sees later emissions, never the state that is current at mount.
    if (context.read<FollowersBloc>().state is FollowersLoaded) {
      _applyInitialTab();
    }
  }

  void _applyInitialTab() {
    if (_appliedInitialTab) return;
    _appliedInitialTab = true;
    if (widget.initialTab == FollowersTab.all) return;
    context.read<FollowersBloc>().add(
      FollowersEvent.changeTab(tab: widget.initialTab),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      context.read<FollowersBloc>().add(const FollowersEvent.loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: BlocListener<FollowersBloc, FollowersState>(
        listenWhen: (_, curr) => curr is FollowersLoaded && !_appliedInitialTab,
        listener: (_, _) => _applyInitialTab(),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- Header: back arrow + title ---
              Padding(
                padding: const EdgeInsets.only(
                  left: MallowTheme.spacing20,
                  right: MallowTheme.spacing20,
                  top: MallowTheme.spacingMd,
                  bottom: MallowTheme.spacingSm,
                ),
                child: Row(
                  children: [
                    Tappable(
                      onTap: () => Navigator.of(context).pop(),
                      child: SvgPicture.asset(
                        'assets/icons/arrow_left.svg',
                        width: 24,
                        height: 24,
                        colorFilter: ColorFilter.mode(
                          colors.textPrimary,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                    const SizedBox(width: MallowTheme.spacingSm),
                    Expanded(
                      child: Text(
                        'Followers',
                        style: MallowTheme.editorialSection.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: BlocBuilder<FollowersBloc, FollowersState>(
                  builder: (context, state) => switch (state) {
                    FollowersInitial() => Center(
                      child: MallowLoader(color: colors.textPrimary),
                    ),
                    FollowersError(:final message) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(MallowTheme.spacing20),
                        child: Text(
                          message,
                          style: MallowTheme.uiBody.copyWith(
                            color: colors.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    FollowersLoaded() => _buildLoaded(context, state),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoaded(BuildContext context, FollowersLoaded state) {
    final colors = context.mallowColors;
    final bloc = context.read<FollowersBloc>();
    final users = visibleFollowUsers(state);
    // Self spans every wallet in the session, not just the active signer: a
    // follow row for a linked-but-inactive session wallet is still the viewer,
    // and offering Follow/Unfollow there would let the user follow themselves.
    // [SessionManager.ownsAddress] also normalises the owner key, so an EVM
    // address the API returns lowercased matches a checksummed session wallet.
    final session = sl<SessionManager>();
    bool isSelf(api.FollowUser u) => u.addresses.any(session.ownsAddress);
    final canFollowAll =
        !state.isFollowingAll && users.any((u) => !u.isFollowing && !isSelf(u));
    final listLoading =
        (state.activeTab != FollowersTab.following &&
            state.followers == null) ||
        (state.activeTab != FollowersTab.followers && state.following == null);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Sort toggle + Follow All ---
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: Row(
              children: [
                Tappable(
                  onTap: () => bloc.add(const FollowersEvent.toggleSort()),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset(
                        'assets/icons/arrows-sort.svg',
                        width: 16,
                        height: 16,
                        colorFilter: ColorFilter.mode(
                          colors.textPrimary,
                          BlendMode.srcIn,
                        ),
                      ),
                      const SizedBox(width: MallowTheme.spacingXs),
                      Text(
                        state.latestFirst ? 'Latest' : 'Oldest',
                        style: MallowTheme.uiCaption.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (canFollowAll)
                  Tappable(
                    onTap: () async {
                      if (!await requireProfile(context)) return;
                      bloc.add(const FollowersEvent.followAll());
                    },
                    child: Text(
                      'Follow All',
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: MallowTheme.spacing20),
          // --- Tab bar ---
          _FollowersTabBar(
            labels: _tabLabels,
            selectedIndex: _tabs.indexOf(state.activeTab),
            onTabSelected: (i) =>
                bloc.add(FollowersEvent.changeTab(tab: _tabs[i])),
          ),
          // --- User list ---
          Expanded(
            child: listLoading
                ? Center(child: MallowLoader(color: colors.textPrimary))
                : users.isEmpty
                ? Center(
                    child: Text(
                      switch (state.activeTab) {
                        FollowersTab.followers => 'No followers yet',
                        FollowersTab.following => 'Not following anyone yet',
                        FollowersTab.all => 'No followers yet',
                      },
                      style: MallowTheme.uiBody.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: MallowTheme.spacing20,
                      vertical: MallowTheme.spacing20,
                    ),
                    itemCount: users.length + (state.isLoadingMore ? 1 : 0),
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: MallowTheme.spacing12),
                    itemBuilder: (context, index) {
                      if (index >= users.length) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(
                              MallowTheme.spacingSm,
                            ),
                            child: MallowLoader(
                              size: 16,
                              color: colors.textSecondary,
                            ),
                          ),
                        );
                      }
                      final user = users[index];
                      return _FollowUserRow(
                        user: user,
                        showButton: !isSelf(user),
                        onToggleFollow: () async {
                          if (!await requireProfile(context)) return;
                          bloc.add(FollowersEvent.toggleFollow(user: user));
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Underlined tab row (All / Followers / Following), matching the profile
/// screen's tab bar but as a plain (non-sliver) widget.
class _FollowersTabBar extends StatelessWidget {
  const _FollowersTabBar({
    required this.labels,
    required this.selectedIndex,
    required this.onTabSelected,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...List.generate(labels.length, (i) {
              final isActive = i == selectedIndex;
              return Tappable(
                onTap: () => onTabSelected(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: isActive
                            ? colors.textPrimary
                            : colors.dividerLight,
                        width: isActive ? 2.0 : 1.0,
                      ),
                    ),
                  ),
                  child: Text(
                    labels[i],
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              );
            }),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: colors.dividerLight),
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

/// Single row: 24px avatar + @username + Follow/Unfollow pill.
class _FollowUserRow extends StatelessWidget {
  const _FollowUserRow({
    required this.user,
    required this.showButton,
    required this.onToggleFollow,
  });

  final api.FollowUser user;
  final bool showButton;
  final VoidCallback onToggleFollow;

  Widget _generatedAvatar(String? address) => AccountAvatar(
    seed: avatarSeedOf(address: address, username: user.username),
    size: 24,
    borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final address = user.addresses.firstOrNull;
    final label = user.username != null
        ? '@${user.username}'
        : (address != null ? truncateAddress(address) : 'Unknown');

    return Tappable(
      onTap: address != null ? () => context.goToProfile(address) : null,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: user.imageUrl != null
                ? MallowNetworkImage(
                    imageUrl: user.imageUrl!,
                    logicalSize: 24,
                    width: 24,
                    height: 24,
                    borderRadius: BorderRadius.circular(
                      MallowTheme.radiusPrimary,
                    ),
                    errorBuilder: (_) => _generatedAvatar(address),
                  )
                : _generatedAvatar(address),
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: Text(
              label,
              style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showButton) ...[
            const SizedBox(width: MallowTheme.spacingSm),
            Tappable(
              onTap: onToggleFollow,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: MallowTheme.spacing12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  border: Border.all(
                    // Per design: Follow gets the stronger outline.
                    color: user.isFollowing
                        ? colors.dividerLight
                        : colors.textPrimary,
                  ),
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusCircular,
                  ),
                ),
                child: Text(
                  user.isFollowing ? 'Unfollow' : 'Follow',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
