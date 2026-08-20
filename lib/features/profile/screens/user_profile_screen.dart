import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:share_plus/share_plus.dart';

import '../../../core/router/app_router.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart' show apiOwnerAddress;
import '../../../shared/widgets/animated_tab_content.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/art_menu_tab.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_menu_row.dart';
import '../../../shared/widgets/state_viewer.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tappable.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../../artwork/widgets/artwork_context_menu_actions.dart';
import '../../cast/models/cast_queue.dart';
import '../../cast/services/cast_actions.dart';
import '../../cast/services/cast_bloc.dart';
import '../../cast/widgets/now_casting_bar.dart';
import '../../curations/widgets/verify_private_curations_banner.dart';
import '../../moderation/services/moderation_actions.dart';
import '../../moderation/services/report_context.dart';
import '../../moderation/widgets/blocked_profile_interstitial.dart';
import '../widgets/profile_required_sheet.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/widgets/all_art_detail.dart';
import '../../portfolio/widgets/all_art_grid.dart';
import '../../portfolio/widgets/all_art_masonry.dart';
import '../../../shared/widgets/mallow_artwork_media.dart' show artworkHeroTag;
import '../../portfolio/widgets/art_group_grid_tile.dart';
import '../../portfolio/widgets/art_group_skeleton.dart';
import '../../portfolio/widgets/art_group_tile.dart';
import '../../portfolio/screens/portfolio_group_screen.dart';
import '../../portfolio/widgets/sort_bottom_sheet.dart';
import '../../search/services/recently_viewed_recorder.dart';
import '../screens/collection_screen.dart';
import '../screens/curation_screen.dart';
import '../services/user_profile_bloc.dart';
import '../widgets/profile_banner.dart';
import '../widgets/profile_bio.dart';
import '../widgets/profile_filters_sheet.dart';
import '../widgets/profile_header.dart';
import '../widgets/profile_tab_bar.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/user_display.dart';
import '../widgets/profile_stats.dart';
import '../widgets/profile_wallets.dart';
import '../widgets/profile_you_own_banner.dart';

part 'user_profile_screen/profile_skeleton.dart';
part 'user_profile_screen/filter_sort_bar.dart';
part 'user_profile_screen/artwork_content.dart';

const _sectionLabels = ['About', 'Stats', 'Wallets'];

const _profileTabLabels = <ProfileTab, String>{
  ProfileTab.created: 'Created',
  ProfileTab.listed: 'Listed',
  ProfileTab.collections: 'Collections',
  ProfileTab.curations: 'Curations',
  ProfileTab.owned: 'Owned',
};

/// Display order for filter tabs when present. Listed sits after Created,
/// mirroring the webapp's profile tab order.
const _profileTabOrder = <ProfileTab>[
  ProfileTab.created,
  ProfileTab.listed,
  ProfileTab.collections,
  ProfileTab.curations,
  ProfileTab.owned,
];

/// User profile screen showing a user's profile and artwork.
class UserProfileScreen extends StatelessWidget {
  const UserProfileScreen({this.address, this.username, super.key})
    : assert(address != null || username != null);

  final String? address;
  final String? username;

  @override
  Widget build(BuildContext context) {
    final event = address != null
        ? UserProfileEvent.load(address: address!)
        : UserProfileEvent.loadByUsername(username: username!);
    return BlocProvider(
      create: (_) => sl<UserProfileBloc>()..add(event),
      child: _TransientErrorListener(
        child: _UserProfileView(address: address, username: username),
      ),
    );
  }
}

/// Surfaces [UserProfileBloc.transientErrors] as a snack bar.
///
/// A failed follow/unfollow reverts to a state that is byte-identical to the
/// one before the tap, so there is nothing a `BlocListener` could diff on —
/// without this the only trace is a `debugPrint` and the user sees the button
/// silently spring back.
class _TransientErrorListener extends StatefulWidget {
  const _TransientErrorListener({required this.child});

  final Widget child;

  @override
  State<_TransientErrorListener> createState() =>
      _TransientErrorListenerState();
}

class _TransientErrorListenerState extends State<_TransientErrorListener> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = context.read<UserProfileBloc>().transientErrors.listen((message) {
      if (!mounted) return;
      AppSnackBar.show(context, message, type: AppSnackBarType.error);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _UserProfileView extends StatelessWidget {
  const _UserProfileView({this.address, this.username});

  final String? address;
  final String? username;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: BlocBuilder<UserProfileBloc, UserProfileState>(
        builder: (context, state) {
          return StateViewer(
            isLoading: state.maybeMap(
              initial: (_) => true,
              loading: (_) => true,
              orElse: () => false,
            ),
            loadingBuilder: (_) => const _ProfileSkeleton(),
            error: state.mapOrNull(error: (e) => e.message),
            onRetry: () {
              final event = address != null
                  ? UserProfileEvent.load(address: address!)
                  : UserProfileEvent.loadByUsername(username: username!);
              context.read<UserProfileBloc>().add(event);
            },
            child: state.maybeMap(
              // A blocked account's profile must render *as blocked* — not as
              // a 404 and not as normal content. The gate keeps that decision
              // outside the loaded view so nothing below it has to know.
              loaded: (loadedState) => BlockedProfileGate(
                address: loadedState.profile.address,
                label: formatHandleOrAddress(
                  username: loadedState.profile.username,
                  address: loadedState.profile.address,
                ),
                child: _LoadedProfile(state: loadedState),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
          );
        },
      ),
    );
  }
}

class _LoadedProfile extends StatefulWidget {
  const _LoadedProfile({required this.state});

  final UserProfileLoaded state;

  @override
  State<_LoadedProfile> createState() => _LoadedProfileState();
}

class _LoadedProfileState extends State<_LoadedProfile> {
  /// 0 = About, 1 = Stats, 2 = Wallets
  int _activeSection = 0;
  final _scrollController = ScrollController();

  /// Fade-out range above the pinned filter/sort bar. Content above the bar
  /// fades to fully transparent over the last [_topFadeRange] pixels of
  /// scroll before pinning kicks in.
  static const double _topFadeRange = 20;
  final GlobalKey _pinHeaderBoxKey = GlobalKey();
  double _topContentOpacity = 1;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

    final profile = widget.state.profile;
    RecentlyViewedRecorder.recordProfile(
      username: profile.username,
      address: profile.address,
      avatarUrl: profile.avatarUrl,
      isVerified: profile.isVerified,
      isAdmin: profile.roles.contains('admin'),
    );
  }

  @override
  void didUpdateWidget(_LoadedProfile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.activeTab == widget.state.activeTab) return;
    if (!_scrollController.hasClients) return;

    // When the user changes tabs while scrolled past the filter bar, keep the
    // bar pinned at the top instead of snapping to 0 — bouncing them back to
    // the profile header is jarring when they were actively browsing artwork.
    final ctx = _pinHeaderBoxKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return;

    final dy = ro.localToGlobal(Offset.zero).dy;
    final safeAreaTop = MediaQuery.of(context).padding.top;
    final delta = dy - safeAreaTop;
    if (delta < 0) {
      _scrollController.jumpTo(_scrollController.offset + delta);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    _updateTopFade();

    if (!isArtworkListTab(state.activeTab)) return;
    final position = _scrollController.position;
    if (position.pixels >=
        position.maxScrollExtent - position.viewportDimension) {
      context.read<UserProfileBloc>().add(
        const UserProfileEvent.loadMoreArtworks(),
      );
    }
  }

  /// Compute the opacity of profile content above the in-flow filter/sort
  /// bar. Triggers when the in-flow bar's top edge approaches the bottom of
  /// the system safe area (notch). The same value (inverted) drives the
  /// floating overlay's opacity — see [build].
  void _updateTopFade() {
    if (!mounted) return;
    final ctx = _pinHeaderBoxKey.currentContext;
    if (ctx == null) return;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return;
    final dy = ro.localToGlobal(Offset.zero).dy;
    final safeAreaTop = MediaQuery.of(context).padding.top;
    final fade = ((dy - safeAreaTop) / _topFadeRange).clamp(0.0, 1.0);
    if ((fade - _topContentOpacity).abs() > 0.005) {
      setState(() => _topContentOpacity = fade);
    }
  }

  UserProfileLoaded get state => widget.state;

  /// True if the currently authenticated user is viewing their own profile.
  bool get _isOwnProfile {
    // "Own profile" = the viewed profile intersects the current session's
    // wallets (active Profile/Account scope), not just the active signing
    // wallet — viewing your own profile through a secondary / linked wallet
    // must still count as yours (no signing involved here).
    // Both sides go through [apiOwnerAddress]: the profile's addresses come
    // back from the API with EVM hex lowercased while session wallets hold the
    // EIP-55 checksummed form, so a raw compare misses for EVM and your own
    // profile renders with other-user chrome. Solana / Tezos pass through.
    final session = sl<SessionManager>().apiOwnerAddresses;
    if (session.isEmpty) return false;
    if (state.profile.linkedAddresses
        .map(apiOwnerAddress)
        .any(session.contains)) {
      return true;
    }
    return session.contains(apiOwnerAddress(state.profile.address));
  }

  /// Casts the artworks for the currently active tab, respecting the active
  /// sort order. Group tabs (collections/curations) fall back to created
  /// artworks since those tabs surface groups, not individual artworks.
  ///
  /// Dispatches the already-loaded page first so the cast configuration
  /// sheet opens immediately with a populated "View Queue", then paginates
  /// the remaining pages (capped at 1000 items) in the background and
  /// appends them to the pending queue as they arrive.
  Future<void> _castActiveTabArtworks() async {
    final List<PortfolioArtwork> loaded = switch (state.activeTab) {
      ProfileTab.owned => state.ownedArtworks ?? const [],
      ProfileTab.listed => state.listedArtworks ?? const [],
      ProfileTab.created ||
      ProfileTab.collections ||
      ProfileTab.curations => state.artworks ?? const [],
    };
    if (loaded.isEmpty) return;

    // Capture bloc references before any await — the widget's context can
    // be detached by the time pagination resolves.
    final profileBloc = context.read<UserProfileBloc>();
    final castBloc = sl<CastBloc>();
    final activeTab = state.activeTab;
    final loadedCount = loaded.length;

    await castArtworksWithVerify(
      loaded.map(CastQueueItemFromArtwork.fromPortfolioArtwork).toList(),
    );

    // Group tabs cast the user's created artworks; the bloc only paginates
    // the created/owned tabs, so there's nothing further to fetch here.
    if (activeTab == ProfileTab.collections ||
        activeTab == ProfileTab.curations) {
      return;
    }

    final all = await profileBloc.fetchAllArtworksForActiveTab();
    if (all.length <= loadedCount) return;
    for (final artwork in all.skip(loadedCount)) {
      castBloc.add(
        CastEvent.addToQueue(
          CastQueueItemFromArtwork.fromPortfolioArtwork(artwork),
        ),
      );
    }
  }

  Future<void> _showOptionsSheet() async {
    await runGuardedSheet<void>(
      'profileOptions',
      () => showMallowSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) {
          final colors = sheetContext.mallowColors;
          return Container(
            decoration: BoxDecoration(
              color: colors.bgSurface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(MallowTheme.popupRadius),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    width: 60,
                    height: 3,
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(
                        MallowTheme.radiusFull,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Own-profile management. Everything below the divider is
                // available on any profile.
                if (_isOwnProfile) ...[
                  _OptionsMenuItem(
                    assetPath: 'assets/icons/edit.svg',
                    label: 'Edit profile',
                    onTap: () async {
                      // Capture the bloc before navigating — on return from
                      // the edit flow we reload to surface any
                      // name/avatar/bio changes. The load handler is
                      // cache-first, so this refreshes in place without a
                      // skeleton flash.
                      final bloc = context.read<UserProfileBloc>();
                      final address = state.profile.address;
                      Navigator.of(sheetContext).pop();
                      await context.push(AppRoutes.editProfile);
                      bloc.add(UserProfileEvent.load(address: address));
                    },
                  ),
                  _OptionsMenuItem(
                    assetPath: 'assets/icons/cast.svg',
                    label: 'Cast',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_castActiveTabArtworks());
                    },
                  ),
                ],
                _OptionsMenuItem(
                  assetPath: 'assets/icons/export.svg',
                  label: 'Share profile',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_shareProfile());
                  },
                ),
                // Moderation — other people's profiles only. Reporting or
                // blocking yourself is not a thing, and the rows would just
                // add noise to the owner's own menu.
                if (!_isOwnProfile) ...[
                  // [SheetMenuRow] rather than [_OptionsMenuItem]: identical
                  // metrics and typography, and it carries the shared
                  // destructive treatment for Block.
                  SheetMenuRow(
                    assetPath: 'assets/icons/alert_triangle.svg',
                    label: 'Report user',
                    isWarning: true,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_reportProfile());
                    },
                  ),
                  SheetMenuRow(
                    assetPath: 'assets/icons/shield_alert.svg',
                    label: 'Block user',
                    isDestructive: true,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_blockProfile());
                    },
                  ),
                ],
                SizedBox(
                  height: MediaQuery.of(sheetContext).padding.bottom + 16,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Label for the viewed account in report/block copy. Deliberately the
  /// handle (`@username`) rather than the display name: display names are
  /// free-text and not unique, so `Block <display name>?` can name the wrong
  /// account in the one place the user has to be sure who they are blocking.
  String get _profileLabel => formatHandleOrAddress(
    username: state.profile.username,
    address: state.profile.address,
  );

  /// Report the viewed account. On success the flow offers Block as a
  /// follow-up — the two are separate decisions and the sheet says so.
  Future<void> _reportProfile() => runReportUserFlow(
    context,
    address: state.profile.address,
    label: _profileLabel,
    screen: currentScreenName(context),
  );

  /// Block the viewed account. [BlockedProfileGate] swaps this screen for the
  /// interstitial as soon as the block lands — no refetch, no pop.
  Future<void> _blockProfile() => runBlockUserFlow(
    context,
    address: state.profile.address,
    label: _profileLabel,
  );

  /// Share a link to the viewed profile. Prefer the username link
  /// (`/u/<username>`) when the profile has one, otherwise fall back to the
  /// address link (`/a/<address>`) — mirroring mallow.art's canonical URLs.
  Future<void> _shareProfile() async {
    final profile = state.profile;
    final path = profile.username.isNotEmpty
        ? AppRoutes.deepLinkProfileByUsernamePath(profile.username)
        : AppRoutes.deepLinkProfilePath(profile.address);
    final url = 'https://mallow.art$path';
    await SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
  }

  /// Filter tabs to show, in display order, based on which underlying data
  /// the viewed user has. Mirrors the webapp's conditional tab visibility.
  List<ProfileTab> get _visibleTabs {
    final profile = state.profile;
    final groups = state.groups ?? const <ArtGroup>[];
    final hasCollections = groups.any((g) => g.type == ArtGroupType.collection);
    final hasCurations = groups.any((g) => g.type == ArtGroupType.curation);
    // Keep the Curations tab visible when the fetch failed so the error is
    // surfaced (fail loud) rather than the tab silently disappearing.
    final showCurations = hasCurations || state.curationsError != null;

    // The profile counts are denormalized fields on the backend user doc and
    // can lag reality (e.g. a wallet link merges away the doc that held the
    // counts) — never let a stale 0 hide a tab whose artworks were actually
    // fetched.
    final hasCreated =
        profile.createdArtworkCount > 0 ||
        (state.artworks?.isNotEmpty ?? false);
    final hasOwned =
        profile.collectedArtworkCount > 0 ||
        (state.ownedArtworks?.isNotEmpty ?? false);

    return _profileTabOrder.where((tab) {
      switch (tab) {
        case ProfileTab.created:
          return hasCreated;
        case ProfileTab.listed:
          // Webapp rule: any creator or collector can have live listings.
          return hasCreated || hasOwned;
        case ProfileTab.collections:
          return hasCollections;
        case ProfileTab.curations:
          return showCurations;
        case ProfileTab.owned:
          return hasOwned;
      }
    }).toList();
  }

  bool get _isGroupTab => !isArtworkListTab(state.activeTab);

  String get _viewModeIcon => _isGroupTab
      ? state.groupViewMode.iconAsset
      : state.artworkViewMode.iconAsset;

  /// Open the filters sheet for the active tab: the full artwork filters on
  /// Created/Listed/Owned, or a name-search-only sheet on the group tabs.
  Future<void> _showFiltersSheet() async {
    final tab = state.activeTab;
    if (isArtworkListTab(tab)) {
      final result = await showProfileFiltersSheet(
        context,
        initial: state.filter ?? const api.ExploreFilter(),
        // The Listed tab is listed-only, so an 'unlisted' filter makes no sense.
        showUnlistedOption: tab != ProfileTab.listed,
      );
      if (result == null || !mounted) return;
      context.read<UserProfileBloc>().add(
        UserProfileEvent.setFilter(filter: result),
      );
      return;
    }
    final result = await showGroupSearchSheet(
      context,
      hint: tab == ProfileTab.collections
          ? 'Collection name...'
          : 'Curation name...',
      initial: state.groupSearch,
    );
    if (result == null || !mounted) return;
    context.read<UserProfileBloc>().add(
      UserProfileEvent.setGroupSearch(query: result),
    );
  }

  /// Badge count on the filters button: the artwork filter's constraint count
  /// on the artwork tabs, the active name search (0 or 1) on group tabs.
  int get _filterCount {
    final tab = state.activeTab;
    if (isArtworkListTab(tab)) {
      return activeFilterCount(state.filter);
    }
    return state.groupSearch != null ? 1 : 0;
  }

  String get _sortLabel => switch (state.activeSort) {
    PortfolioSortOption.count => 'Count',
    PortfolioSortOption.name => 'Name',
    PortfolioSortOption.recent => 'Recent',
  };

  @override
  Widget build(BuildContext context) {
    final profile = state.profile;
    final safeAreaTop = MediaQuery.of(context).padding.top;

    return Stack(
      children: [
        MallowRefreshIndicator(
          // The banner is full-bleed behind the status bar — keep the
          // spinner below the notch.
          edgeOffset: safeAreaTop,
          onRefresh: () async {
            final bloc = context.read<UserProfileBloc>();
            // The load handler is cache-first + progressive, so this
            // revalidates in place without a skeleton flash.
            bloc.add(UserProfileEvent.load(address: profile.address));
            // Hold the indicator until the revalidation completes
            // (isRefreshing clears) rather than dropping it instantly.
            await bloc.stream.firstWhere(
              (state) => state is! UserProfileLoaded || !state.isRefreshing,
            );
          },
          child: CustomScrollView(
            scrollCacheExtent: ScrollCacheExtent.pixels(
              MediaQuery.sizeOf(context).height,
            ),
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // 1. Full-width banner image
              SliverOpacity(
                opacity: _topContentOpacity,
                sliver: ProfileBanner(
                  bannerUrl: profile.bannerUrl,
                  onBack: () => context.pop(),
                ),
              ),

              // 2. Avatar + name + handle + follow + 3-dot
              SliverOpacity(
                opacity: _topContentOpacity,
                sliver: ProfileHeader(
                  avatarUrl: profile.avatarUrl,
                  avatarSeed: avatarSeedOf(
                    address: profile.address,
                    username: profile.username,
                  ),
                  // The display name reads as the user's real name and goes
                  // up top; the @handle below carries the actual username,
                  // so we never need to surface the same string in both rows.
                  username: (profile.displayName?.isNotEmpty ?? false)
                      ? profile.displayName!
                      : profile.username.isNotEmpty
                      ? profile.username
                      : truncateAddress(profile.address),
                  handle: profile.handle.isNotEmpty ? profile.handle : null,
                  role: profile.role,
                  roles: profile.roles,
                  isVerified: profile.isVerified,
                  isFollowing: state.isFollowing,
                  onFollowTap: () async {
                    // Following is a social action — gated behind a Profile.
                    // In Account mode this prompts switch/create.
                    if (!await requireProfile(context)) return;
                    if (!context.mounted) return;
                    final wallet = await sl<WalletRepository>()
                        .getActiveWallet();
                    if (!context.mounted) return;
                    if (wallet != null && !wallet.canSign) {
                      await showViewOnlyPrompt(context);
                      return;
                    }
                    context.read<UserProfileBloc>().add(
                      const UserProfileEvent.toggleFollow(),
                    );
                  },
                  // The menu is no longer own-profile-only: Report / Block
                  // live behind it on other people's profiles, and an
                  // affordance a reviewer can't find is a rejection.
                  onMenuTap: _showOptionsSheet,
                  showFollowButton: !_isOwnProfile,
                ),
              ),

              // 3. About | Stats | Wallets tab bar
              SliverOpacity(
                opacity: _topContentOpacity,
                sliver: ProfileTabBar(
                  tabs: _sectionLabels,
                  selectedIndex: _activeSection,
                  onTabSelected: (i) => setState(() => _activeSection = i),
                ),
              ),

              // 4. Section content — only the slot directly under the tab
              //    bar swaps between About / Stats / Wallets. Cast pill and
              //    everything below stay visible across tabs, mirroring the
              //    History/Offers fade in [ArtworkDetailScreen]. Height
              //    animates between tabs so the elements below glide rather
              //    than snap.
              SliverOpacity(
                opacity: _topContentOpacity,
                sliver: SliverToBoxAdapter(
                  child: AnimatedTabContent(
                    activeIndex: _activeSection,
                    builder: (_, idx) => _sectionContent(idx),
                  ),
                ),
              ),

              // "You own" card — only show once youOwnArtworks has loaded
              if (state.youOwnArtworks != null &&
                  profile.ownedArtworkCount > 0) ...[
                SliverOpacity(
                  opacity: _topContentOpacity,
                  sliver: const SliverToBoxAdapter(child: SizedBox(height: 8)),
                ),
                SliverOpacity(
                  opacity: _topContentOpacity,
                  sliver: ProfileYouOwnBanner(
                    count: profile.ownedArtworkCount,
                    thumbnailUrls: profile.ownedArtworkThumbnailUrls,
                    onTap: () {
                      final name = (profile.displayName?.isNotEmpty ?? false)
                          ? profile.displayName!
                          : profile.username.isNotEmpty
                          ? profile.username
                          : truncateAddress(profile.address);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PortfolioGroupScreen(
                            group: ArtGroup(
                              id: 'artist:${profile.address}',
                              type: ArtGroupType.artist,
                              name: name,
                              thumbnailUrl: profile.avatarUrl,
                              artworkCount: profile.ownedArtworkCount,
                              artistAddress: profile.address,
                              artistUsername: profile.username,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SliverOpacity(
                  opacity: _topContentOpacity,
                  sliver: const SliverToBoxAdapter(
                    child: SizedBox(height: MallowTheme.spacing20),
                  ),
                ),
              ],

              // In-flow filter chips (Created / Collections / Curations / Owned)
              // and sort/view-mode row. Renders in the natural scroll position,
              // with no safe-area inset. The floating overlay (in the parent
              // Stack) takes over with a safe-area inset as this bar approaches
              // the notch — see `_FilterSortBar` and the cross-fade logic.
              SliverOpacity(
                opacity: _topContentOpacity,
                sliver: SliverToBoxAdapter(
                  child: _FilterSortBar(
                    key: _pinHeaderBoxKey,
                    visibleTabs: _visibleTabs,
                    activeTab: state.activeTab,
                    activeSort: state.activeSort,
                    sortLabel: _sortLabel,
                    viewModeIconAsset: _viewModeIcon,
                    onFilterTap: _showFiltersSheet,
                    filterCount: _filterCount,
                  ),
                ),
              ),

              // Artwork list, owned list, or group views — fade-swapped on
              // tab change to avoid a hard pop between Created/Collections/
              // Curations/Owned. Driven by canonical [_profileTabOrder]
              // index so the visible-vs-active distinction is stable across
              // varying [_visibleTabs] sets.
              SliverAnimatedTabContent(
                activeIndex: _profileTabOrder.indexOf(state.activeTab),
                builder: (_, idx) => _artworkContentSliver(
                  context,
                  state,
                  _profileTabOrder[idx],
                  isOwnProfile: _isOwnProfile,
                ),
              ),

              // Bottom reserve for nav bar (grows when cast bar is active).
              const SliverToBoxAdapter(child: NavBarBottomReserve(base: 120)),
            ],
          ),
        ),

        // Floating filter/sort bar with safe-area inset that fades in as
        // the in-flow bar approaches the notch. Slides 20px into place
        // during the fade so chips stay aligned with the in-flow bar's
        // chips during the cross-fade.
        Positioned(
          top: _topFadeRange * _topContentOpacity,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: _topContentOpacity > 0.5,
            child: Opacity(
              opacity: 1 - _topContentOpacity,
              child: _FilterSortBar(
                visibleTabs: _visibleTabs,
                activeTab: state.activeTab,
                activeSort: state.activeSort,
                sortLabel: _sortLabel,
                viewModeIconAsset: _viewModeIcon,
                onFilterTap: _showFiltersSheet,
                filterCount: _filterCount,
                topInset: safeAreaTop,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Box content for the slot directly under the About/Stats/Wallets tab
  /// bar. Only this slot swaps; Cast pill, You Own, filter/sort, and
  /// artwork content all render below it regardless of which section is
  /// active. Returned as a non-sliver so [AnimatedTabContent] can animate
  /// the height transition between tabs.
  Widget _sectionContent(int section) {
    final profile = state.profile;
    switch (section) {
      case 1:
        return ProfileStats(
          createdCount: profile.createdArtworkCount,
          collectedCount: profile.collectedArtworkCount,
        );
      case 2:
        return ProfileWallets(addresses: profile.linkedAddresses);
      case 0:
      default:
        final followAddresses = profile.linkedAddresses.isNotEmpty
            ? profile.linkedAddresses
            : [profile.address];
        return ProfileBio(
          bio: profile.bio,
          followerCount: profile.followerCount,
          followingCount: profile.followingCount,
          collectorCount: profile.collectorCount,
          onFollowersTap: () => context.goToFollowers(
            profile.address,
            addresses: followAddresses,
          ),
          onFollowingTap: () => context.goToFollowers(
            profile.address,
            addresses: followAddresses,
            showFollowing: true,
          ),
          twitterUrl: profile.twitterUrl,
          instagramUrl: profile.instagramUrl,
          websiteUrl: profile.websiteUrl,
          youtubeUrl: profile.youtubeUrl,
        );
    }
  }
}
