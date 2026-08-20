import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../di.dart';
import '../../../shared/pagination/pagination_scroll_listener.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/art_menu_tab.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/state_viewer.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/tappable.dart';
import '../../artwork/widgets/artwork_context_menu_actions.dart';
import '../../cast/widgets/now_casting_bar.dart';
import '../../curations/widgets/verify_private_curations_banner.dart';
import '../../profile/screens/curation_screen.dart';
import '../../profile/widgets/profile_filters_sheet.dart';
import '../services/portfolio_bloc.dart';
import '../widgets/all_art_grid.dart';
import '../widgets/all_art_detail.dart';
import '../widgets/all_art_masonry.dart';
import '../widgets/all_art_skeleton.dart';
import '../widgets/art_group_grid_tile.dart';
import '../widgets/art_group_skeleton.dart';
import '../widgets/art_group_tile.dart';
import '../widgets/sort_bottom_sheet.dart';
import 'portfolio_group_screen.dart';
import '../../../shared/widgets/mallow_artwork_media.dart' show artworkHeroTag;

/// Shared-element source for the "Your art" grid tiles, keeping their Hero tags
/// unique to this screen (see [artworkHeroTag]).
const _kYourArtHeroSource = 'your-art';

/// Portfolio screen showing user's owned artworks.
///
/// Features:
/// - 4 pill-style tabs: All art, Artists, Collections, Curations
/// - Masonry grid for "All art" tab
/// - List/grid toggle for group tabs
/// - Sort bottom sheet
class YourArtScreen extends StatefulWidget {
  const YourArtScreen({super.key});

  @override
  State<YourArtScreen> createState() => _YourArtScreenState();
}

class _YourArtScreenState extends State<YourArtScreen> {
  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<PortfolioBloc>()..add(const PortfolioEvent.load()),
      child: const _YourArtView(),
    );
  }
}

class _YourArtView extends StatelessWidget {
  const _YourArtView();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PortfolioBloc, PortfolioState>(
      builder: (context, state) {
        // The pre-load skeleton is group-tile shaped, so it follows the group
        // layout rather than the artwork one.
        final viewMode = state.maybeMap(
          initial: (s) => s.groupViewMode,
          loading: (s) => s.groupViewMode,
          orElse: () => PortfolioViewMode.grid,
        );
        return StateViewer(
          isLoading: state.maybeMap(
            initial: (_) => true,
            loading: (_) => true,
            orElse: () => false,
          ),
          loadingBuilder: (_) => _SkeletonContent(viewMode: viewMode),
          error: state.mapOrNull(error: (e) => e.message),
          onRetry: () =>
              context.read<PortfolioBloc>().add(const PortfolioEvent.load()),
          child: state.maybeMap(
            loaded: (s) => _LoadedContent(state: s),
            orElse: () => const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

/// Display order for the tab pills. Canonical — the pill index is this list's
/// index, so inserting a tab here is the only change needed.
const _tabOrder = <PortfolioTab>[
  PortfolioTab.allArt,
  PortfolioTab.listed,
  PortfolioTab.artists,
  PortfolioTab.collections,
  PortfolioTab.curations,
];

const _tabNames = <PortfolioTab, String>{
  PortfolioTab.allArt: 'Artworks',
  PortfolioTab.listed: 'Listed',
  PortfolioTab.artists: 'Artists',
  PortfolioTab.collections: 'Collections',
  PortfolioTab.curations: 'Curations',
};

final _tabLabels = [for (final tab in _tabOrder) _tabNames[tab]!];

class _SkeletonContent extends StatelessWidget {
  const _SkeletonContent({required this.viewMode});

  final PortfolioViewMode viewMode;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: MallowTheme.spacingMd),
        // Tab pills with filter button (mirrors loaded layout)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Row(
            children: [
              SvgPicture.asset(
                'assets/icons/sliders.svg',
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  context.mallowColors.textPrimary,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: ArtMenuTab(
                  labels: _tabLabels,
                  selectedIndex: null,
                  onChanged: (_) {},
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: MallowTheme.spacing20),
        // Sort row placeholder
        _SortRow(
          label: 'Recent',
          onTap: () {},
          trailing: _IconButton(assetPath: viewMode.iconAsset, onTap: () {}),
        ),
        const SizedBox(height: 12),
        // Skeleton items based on view mode
        Expanded(
          child: CustomScrollView(
            slivers: [
              if (viewMode == PortfolioViewMode.list)
                const PortfolioSkeletonList()
              else
                const PortfolioSkeletonGrid(),
              // Bottom reserve for nav bar (grows when cast bar is active).
              const SliverToBoxAdapter(child: NavBarBottomReserve(base: 120)),
            ],
          ),
        ),
      ],
    );
  }
}

class _LoadedContent extends StatefulWidget {
  const _LoadedContent({required this.state});

  final PortfolioLoaded state;

  @override
  State<_LoadedContent> createState() => _LoadedContentState();
}

class _LoadedContentState extends State<_LoadedContent> {
  final _scrollController = ScrollController();
  late final PaginationScrollListener _paginationListener;

  @override
  void initState() {
    super.initState();
    _paginationListener = PaginationScrollListener(
      controller: _scrollController,
      onLoadMore: () {
        final bloc = context.read<PortfolioBloc>();
        final s = bloc.state;
        final isListed =
            s is PortfolioLoaded && s.activeTab == PortfolioTab.listed;
        bloc.add(
          isListed
              ? const PortfolioEvent.loadMoreListedArtworks()
              : const PortfolioEvent.loadMoreAllArtworks(),
        );
      },
      // Only paginate on the flat artwork tabs; group tabs render fixed lists,
      // and PortfolioBloc itself ignores the event when it isn't
      // loading-eligible.
      canLoadMore: () {
        final s = context.read<PortfolioBloc>().state;
        if (s is! PortfolioLoaded) return false;
        if (s.activeTab == PortfolioTab.listed) {
          return s.listedArtworks != null &&
              s.hasMoreListed &&
              !s.isLoadingMoreListed;
        }
        if (s.activeTab != PortfolioTab.allArt) return false;
        // A filter refetch collapses the list mid-flight; don't paginate
        // against the stale cursor until it settles.
        if (s.isRefreshing) return false;
        return s.hasMoreAllArt && !s.isLoadingMoreAllArt;
      },
    )..attach();
  }

  @override
  void dispose() {
    _paginationListener.detach();
    _scrollController.dispose();
    super.dispose();
  }

  PortfolioLoaded get state => widget.state;

  int? _tabToIndex(PortfolioTab? tab) =>
      tab == null ? null : _tabOrder.indexOf(tab);

  PortfolioTab _indexToTab(int index) => index >= 0 && index < _tabOrder.length
      ? _tabOrder[index]
      : PortfolioTab.allArt;

  /// True when the active tab renders a flat artwork list rather than groups.
  bool get _isArtworkTab =>
      state.activeTab == PortfolioTab.allArt ||
      state.activeTab == PortfolioTab.listed;

  /// True when showing groups (null = all groups, or a specific group tab)
  bool get _isGroupTab => !_isArtworkTab;

  String get _viewModeIcon => _isGroupTab
      ? state.groupViewMode.iconAsset
      : state.artworkViewMode.iconAsset;

  String get _sortLabel {
    switch (state.activeSort) {
      case PortfolioSortOption.count:
        return 'Count';
      case PortfolioSortOption.name:
        return 'Name';
      case PortfolioSortOption.recent:
        return 'Recent';
    }
  }

  /// Open the filters sheet for the active tab: the full artwork filters on
  /// the "Artworks" tab (shared with the profile screen), or a tab-specific
  /// name search on the group tabs.
  Future<void> _openFiltersSheet(BuildContext context) async {
    if (_isArtworkTab) {
      final result = await showProfileFiltersSheet(
        context,
        initial: state.artworkFilter ?? const api.ExploreFilter(),
        // The Listed tab is listed-only, so an 'unlisted' filter makes no sense.
        showUnlistedOption: state.activeTab != PortfolioTab.listed,
      );
      if (result == null || !context.mounted) return;
      context.read<PortfolioBloc>().add(
        PortfolioEvent.setArtworkFilter(filter: result),
      );
      return;
    }
    final result = await showGroupSearchSheet(
      context,
      hint: _groupSearchHint,
      initial: state.groupSearch,
    );
    if (result == null || !context.mounted) return;
    context.read<PortfolioBloc>().add(
      PortfolioEvent.setGroupSearch(query: result),
    );
  }

  String get _groupSearchHint => switch (state.activeTab) {
    PortfolioTab.artists => 'Artist name or address...',
    PortfolioTab.collections => 'Collection name...',
    PortfolioTab.curations => 'Curation name...',
    // No tab selected — all group types are showing, so search all names.
    _ => 'Search by name...',
  };

  /// Badge count on the filters button: the artwork filter's constraint count
  /// on the Artworks tab, the active name search (0 or 1) on group tabs.
  int get _filterCount => _isArtworkTab
      ? activeFilterCount(state.artworkFilter)
      : (state.groupSearch != null ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: MallowTheme.spacingMd),
        // Tab pills
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Row(
            children: [
              Tappable(
                onTap: () => _openFiltersSheet(context),
                child: FilterBadgeIcon(count: _filterCount),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: ArtMenuTab(
                  labels: _tabLabels,
                  selectedIndex: _tabToIndex(state.activeTab),
                  onChanged: (index) {
                    context.read<PortfolioBloc>().add(
                      PortfolioEvent.changeTab(
                        tab: index != null ? _indexToTab(index) : null,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: MallowTheme.spacing20),
        // Sort row
        _SortRow(
          label: _sortLabel,
          onTap: () async {
            final result = await showSortBottomSheet(
              context,
              currentSort: state.activeSort,
              // Count sorts groups by item count — the artwork tabs render a
              // flat artwork list, so there is nothing to count.
              options: _isArtworkTab
                  ? const [PortfolioSortOption.name, PortfolioSortOption.recent]
                  : PortfolioSortOption.values,
            );
            if (result != null && context.mounted) {
              context.read<PortfolioBloc>().add(
                PortfolioEvent.setSort(sort: result),
              );
            }
          },
          trailing: _IconButton(
            assetPath: _viewModeIcon,
            onTap: () {
              context.read<PortfolioBloc>().add(
                const PortfolioEvent.toggleViewMode(),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        // Scrollable content
        Expanded(
          child: MallowRefreshIndicator(
            onRefresh: () async {
              final bloc = context.read<PortfolioBloc>();
              bloc.add(const PortfolioEvent.refresh());
              // Hold the indicator until the refetch completes (isRefreshing
              // clears) rather than dropping it instantly.
              await bloc.stream.firstWhere(
                (state) => state is! PortfolioLoaded || !state.isRefreshing,
              );
            },
            child: CustomScrollView(
              scrollCacheExtent: ScrollCacheExtent.pixels(
                MediaQuery.sizeOf(context).height,
              ),
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (_isArtworkTab) ...[
                  ..._artworkSlivers(context),
                ] else ...[
                  // null tab (all groups) or specific group tab
                  if (state.activeTab == PortfolioTab.curations &&
                      state.showVerifyPrivateCurationsCta)
                    SliverToBoxAdapter(
                      child: VerifyPrivateCurationsBanner(
                        isVerifying: state.isVerifyingCurations,
                        onVerify: () => context.read<PortfolioBloc>().add(
                          const PortfolioEvent.verifyForPrivateCurations(),
                        ),
                      ),
                    ),
                  if (state.groups.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyState(
                        tab: state.activeTab ?? PortfolioTab.allArt,
                        searchActive: state.groupSearch != null,
                      ),
                    )
                  else if (state.groupViewMode == PortfolioViewMode.list)
                    _buildGroupList(context)
                  else
                    _buildGroupGrid(context),
                ],
                // Bottom reserve for nav bar (grows when cast bar is active).
                const SliverToBoxAdapter(child: NavBarBottomReserve(base: 120)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Slivers for a flat artwork tab (Artworks or Listed): shimmer while the
  /// page is in flight, an empty state, otherwise the masonry/detail/grid view
  /// plus the pagination footer.
  List<Widget> _artworkSlivers(BuildContext context) {
    final isListed = state.activeTab == PortfolioTab.listed;
    // Listed is lazily fetched: null means "not loaded yet" (shimmer). The
    // Artworks tab reuses its refetch flag for the same purpose.
    final artworks = isListed
        ? (state.listedArtworks ?? const <PortfolioArtwork>[])
        : state.allArtworks;
    final isLoading = isListed
        ? state.listedArtworks == null
        : state.isRefreshing;
    final isLoadingMore = isListed
        ? state.isLoadingMoreListed
        : state.isLoadingMoreAllArt;

    if (artworks.isEmpty && isLoading) {
      // Fetch in flight with nothing to show — shimmer tiles in the active
      // layout instead of a blank tab.
      return [
        switch (state.artworkViewMode) {
          ArtworkViewMode.masonry => const AllArtSkeletonMasonry(),
          ArtworkViewMode.detail => const AllArtSkeletonDetail(),
          ArtworkViewMode.grid => const AllArtSkeletonGrid(),
        },
      ];
    }
    if (artworks.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(tab: state.activeTab ?? PortfolioTab.allArt),
        ),
      ];
    }

    void onTap(PortfolioArtwork artwork) => _openArtwork(context, artwork);
    Future<void> onLongPress(PortfolioArtwork artwork) =>
        showAndHandleArtworkContextMenu(context, artwork: artwork);

    final content = switch (state.artworkViewMode) {
      ArtworkViewMode.masonry => AllArtMasonry(
        artworks: artworks,
        heroSource: _kYourArtHeroSource,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
      ArtworkViewMode.detail => AllArtDetail(
        artworks: artworks,
        heroSource: _kYourArtHeroSource,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
      ArtworkViewMode.grid => AllArtGrid(
        artworks: artworks,
        heroSource: _kYourArtHeroSource,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    };

    return [
      content,
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingMd),
          child: isLoadingMore
              ? const Center(child: MallowLoadingIndicator())
              : const SizedBox.shrink(),
        ),
      ),
    ];
  }

  Widget _buildGroupList(BuildContext context) {
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        // Alternating items and dividers
        final itemIndex = index ~/ 2;
        final isDivider = index.isOdd;

        if (isDivider) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
              vertical: MallowTheme.spacingMd,
            ),
            child: Divider(height: 1, color: context.mallowColors.dividerLight),
          );
        }

        final group = state.groups[itemIndex];
        return ArtGroupTile(
          name: group.name,
          imageUrls: group.thumbnailUrl != null ? [group.thumbnailUrl!] : [],
          count: group.artworkCount,
          displayType: _mapGroupType(group.type),
          collectionName: group.creatorName,
          onTap: () => _openGroup(context, group),
        );
      }, childCount: state.groups.length * 2 - 1),
    );
  }

  Widget _buildGroupGrid(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 40,
          crossAxisSpacing: 12,
          childAspectRatio: 170.5 / 222,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final group = state.groups[index];
          return ArtGroupGridTile(
            name: group.name,
            imageUrls: group.thumbnailUrl != null ? [group.thumbnailUrl!] : [],
            count: group.artworkCount,
            displayType: _mapGridGroupType(group.type),
            collectionName: group.creatorName,
            onTap: () => _openGroup(context, group),
          );
        }, childCount: state.groups.length),
      ),
    );
  }

  void _openArtwork(BuildContext context, PortfolioArtwork artwork) {
    // Pass the tile's shared-element tag so the detail image flies in from it.
    context.push(
      AppRoutes.artworkDetailPath(artwork.mintAccount),
      extra: artworkHeroTag(_kYourArtHeroSource, artwork.mintAccount),
    );
  }

  void _openGroup(BuildContext context, ArtGroup group) {
    // Curations are the user's *created* curations — open the full curation
    // detail (same surface the profile uses), not the held-art drilldown.
    if (group.type == ArtGroupType.curation) {
      final ownerAddress = sl<AuthService>().currentAddress ?? '';
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              CurationScreen(group: group, ownerAddress: ownerAddress),
        ),
      );
      return;
    }
    // Artist / collection groups drill into the held artworks matching that
    // group — collections no longer open the public CollectionScreen here.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PortfolioGroupScreen(group: group),
      ),
    );
  }

  ArtGroupDisplayType _mapGroupType(ArtGroupType type) {
    switch (type) {
      case ArtGroupType.artist:
        return ArtGroupDisplayType.artist;
      case ArtGroupType.collection:
        return ArtGroupDisplayType.collection;
      case ArtGroupType.curation:
        return ArtGroupDisplayType.curation;
    }
  }

  ArtGroupGridDisplayType _mapGridGroupType(ArtGroupType type) {
    switch (type) {
      case ArtGroupType.artist:
        return ArtGroupGridDisplayType.artist;
      case ArtGroupType.collection:
        return ArtGroupGridDisplayType.collection;
      case ArtGroupType.curation:
        return ArtGroupGridDisplayType.curation;
    }
  }
}

class _SortRow extends StatelessWidget {
  const _SortRow({required this.label, required this.onTap, this.trailing});

  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Row(
        children: [
          TapTargetExpander(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset(
                    'assets/icons/arrows-sort.svg',
                    width: 16,
                    height: 16,
                    colorFilter: ColorFilter.mode(
                      context.mallowColors.textPrimary,
                      BlendMode.srcIn,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.tab, this.searchActive = false});

  final PortfolioTab tab;

  /// True when a group-tab name search filtered everything out — the copy
  /// then points at the search instead of claiming there's nothing collected.
  final bool searchActive;

  @override
  Widget build(BuildContext context) {
    final (icon, title, subtitle) = _getEmptyStateContent(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MallowTheme.spacingXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              title,
              style: MallowTheme.editorialSubhead,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              subtitle,
              style: MallowTheme.uiMeta.copyWith(
                color: context.mallowColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  (Widget, String, String) _getEmptyStateContent(BuildContext context) {
    final inactive = context.mallowColors.textTertiary;
    if (searchActive) {
      return (
        MallowSvgIcon(
          'assets/icons/my_art.svg',
          width: 64,
          height: 64,
          color: inactive,
        ),
        'No results',
        'Try a different search',
      );
    }
    switch (tab) {
      case PortfolioTab.allArt:
        return (
          MallowSvgIcon(
            'assets/icons/my_art.svg',
            width: 64,
            height: 64,
            color: inactive,
          ),
          'No art yet',
          'Start collecting art to see it here',
        );
      case PortfolioTab.listed:
        return (
          MallowSvgIcon(
            'assets/icons/my_art.svg',
            width: 64,
            height: 64,
            color: inactive,
          ),
          'Nothing listed',
          'Art you list for sale will appear here',
        );
      case PortfolioTab.artists:
        return (
          MallowSvgIcon(
            'assets/icons/my_art.svg',
            width: 64,
            height: 64,
            color: inactive,
          ),
          'No artists yet',
          'Start collecting art to see artists here',
        );
      case PortfolioTab.collections:
        return (
          MallowSvgIcon(
            'assets/icons/my_curations.svg',
            width: 64,
            height: 64,
            color: inactive,
          ),
          'No collections yet',
          'Collected artworks will be grouped by collection here',
        );
      case PortfolioTab.curations:
        return (
          MallowSvgIcon(
            'assets/icons/curations.svg',
            width: 64,
            height: 64,
            color: inactive,
          ),
          'No curations yet',
          'Create curations to organize your art',
        );
    }
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({required this.onTap, this.assetPath, this.icon});

  final String? assetPath;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: assetPath != null
            ? SvgPicture.asset(
                assetPath!,
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  context.mallowColors.textPrimary,
                  BlendMode.srcIn,
                ),
              )
            : Icon(icon, size: 24, color: context.mallowColors.textPrimary),
      ),
    );
  }
}
