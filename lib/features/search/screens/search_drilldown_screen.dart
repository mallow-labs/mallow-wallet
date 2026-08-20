import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/tappable.dart';
import '../../cast/widgets/now_casting_bar.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/widgets/all_art_detail.dart';
import '../../portfolio/widgets/all_art_grid.dart';
import '../../portfolio/widgets/all_art_masonry.dart';
import '../../portfolio/widgets/sort_bottom_sheet.dart';
import '../../profile/widgets/profile_filters_sheet.dart';
import '../models/search_models.dart';
import '../services/search_bloc.dart';

/// Opens the drilldown screen for [filterType].
///
/// Pushed on the caller's navigator — the one hosting the search sheet — so the
/// sheet stays alive underneath and back returns to the search landing page
/// with its recent searches intact.
void openSearchDrilldown(BuildContext context, SearchFilterType filterType) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SearchDrilldownScreen(filterType: filterType),
    ),
  );
}

/// A full-screen artwork drilldown pushed from the search landing page: the
/// listing-type, browse and category buttons whose results are artworks (see
/// [SearchFilterType.isArtworkBrowse]).
///
/// Laid out like [PortfolioGroupScreen] minus the parts a filter has no
/// identity for: a back / label header bar with no kebab, then the filter /
/// sort / view-mode bar over the artworks. Owns its own [SearchBloc] so the
/// fetch, paging and filter/sort knobs are the sheet's, without the sheet's
/// state being disturbed while drilled in.
class SearchDrilldownScreen extends StatelessWidget {
  const SearchDrilldownScreen({required this.filterType, super.key});

  final SearchFilterType filterType;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          sl<SearchBloc>()..add(SearchEvent.filterSelected(filterType)),
      child: _DrilldownView(filterType: filterType),
    );
  }
}

class _DrilldownView extends StatelessWidget {
  const _DrilldownView({required this.filterType});

  final SearchFilterType filterType;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(context),
            const SizedBox(height: MallowTheme.spacing20),
            Expanded(
              child: BlocBuilder<SearchBloc, SearchState>(
                builder: (context, state) => switch (state) {
                  SearchArtworkResults() => _ArtworkDrilldown(state: state),
                  SearchError(:final message) => Center(
                    child: Text(
                      message,
                      style: TextStyle(
                        fontSize: 14,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  // The bloc is created for this one drilldown and the fetch is
                  // dispatched with it, so every other state is the first page
                  // still loading.
                  _ => const Center(child: MallowLoadingIndicator()),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Header bar: back arrow · filter label · empty slot. The group screen's
  /// kebab has no counterpart on a filter, so the right slot only balances the
  /// back arrow to keep the label centred.
  Widget _buildHeader(BuildContext context) {
    final colors = context.mallowColors;

    return Padding(
      padding: const EdgeInsets.only(
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
        top: MallowTheme.spacingMd,
      ),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            TapTargetExpander(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: SizedBox(
                  width: 24,
                  height: 40,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SvgPicture.asset(
                      'assets/icons/arrow_left.svg',
                      width: 16,
                      height: 16,
                      colorFilter: ColorFilter.mode(
                        colors.textPrimary,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Text(
                filterType.label,
                textAlign: TextAlign.center,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 24, height: 40),
          ],
        ),
      ),
    );
  }
}

/// The drilldown content: the filter / sort / view-mode row, then the artworks
/// in the portfolio's masonry, detail or grid layout.
///
/// The three view widgets are the portfolio's own, so a drilldown looks and
/// paginates exactly like the "Artworks" tab. Tiles carry no Hero tag and no
/// long-press menu: nothing on this screen is flown into the detail route, and
/// the context menu is for art the viewer owns.
class _ArtworkDrilldown extends StatelessWidget {
  const _ArtworkDrilldown({required this.state});

  final SearchArtworkResults state;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DrilldownBar(state: state),
        const SizedBox(height: MallowTheme.spacing12),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if ((notification is ScrollUpdateNotification ||
                      notification is ScrollEndNotification) &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension &&
                  state.hasMore &&
                  !state.isLoadingMore) {
                context.read<SearchBloc>().add(
                  const SearchEvent.loadMoreFilterResults(),
                );
              }
              return false;
            },
            child: CustomScrollView(
              slivers: [
                ..._contentSlivers(context),
                const SliverToBoxAdapter(child: NavBarBottomReserve(base: 120)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _contentSlivers(BuildContext context) {
    if (state.artworks.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: state.isRefetching
                ? const MallowLoadingIndicator()
                : Text(
                    'No results found',
                    style: TextStyle(
                      fontSize: 14,
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
          ),
        ),
      ];
    }

    void onTap(PortfolioArtwork artwork) =>
        _openArtwork(context, artwork.mintAccount);

    final content = switch (state.artworkViewMode) {
      ArtworkViewMode.masonry => AllArtMasonry(
        artworks: state.artworks,
        onTap: onTap,
      ),
      ArtworkViewMode.detail => AllArtDetail(
        artworks: state.artworks,
        onTap: onTap,
      ),
      ArtworkViewMode.grid => AllArtGrid(
        artworks: state.artworks,
        onTap: onTap,
      ),
    };

    return [
      content,
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingMd),
          child: state.isLoadingMore
              ? const Center(child: MallowLoadingIndicator())
              : const SizedBox.shrink(),
        ),
      ),
    ];
  }

  /// Push the detail on top of this screen — back returns to the drilldown,
  /// then to the search sheet still open beneath it.
  void _openArtwork(BuildContext context, String mintAccount) {
    if (mintAccount.isEmpty) return;
    context.push(AppRoutes.artworkDetailPath(mintAccount));
  }
}

/// Single row above a drilldown's content: filters on the left, then sort,
/// with the view-mode toggle pushed to the right edge.
class _DrilldownBar extends StatelessWidget {
  const _DrilldownBar({required this.state});

  final SearchArtworkResults state;

  String get _sortLabel => state.sort.label;

  String get _viewModeIcon => state.artworkViewMode.iconAsset;

  Future<void> _openFilters(BuildContext context) async {
    final bloc = context.read<SearchBloc>();
    final result = await showProfileFiltersSheet(
      context,
      initial: state.filter,
      // The drilldown pins one facet and would override anything picked in
      // it — hide it rather than offer a control with no effect.
      showListingTypeSection: !state.filterType.pinsListingType,
      showSupplyTypeSection: !state.filterType.pinsSupplyType,
      showCategoriesSection: !state.filterType.pinsCategory,
    );
    if (result == null) return;
    bloc.add(SearchEvent.setDrilldownFilter(result));
  }

  Future<void> _openSort(BuildContext context) async {
    final bloc = context.read<SearchBloc>();
    final result = await showSortBottomSheet(
      context,
      currentSort: state.sort,
      // Count sorts groups by item count — a drilldown is a flat artwork
      // list, so there is nothing to count.
      options: const [PortfolioSortOption.name, PortfolioSortOption.recent],
    );
    if (result == null) return;
    bloc.add(SearchEvent.setDrilldownSort(result));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Row(
        children: [
          Tappable(
            onTap: () => _openFilters(context),
            child: FilterBadgeIcon(count: activeFilterCount(state.filter)),
          ),
          const SizedBox(width: MallowTheme.spacingMd),
          TapTargetExpander(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openSort(context),
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
                  const SizedBox(width: 6),
                  Text(
                    _sortLabel,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          TapTargetExpander(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => context.read<SearchBloc>().add(
                const SearchEvent.toggleDrilldownViewMode(),
              ),
              child: SvgPicture.asset(
                _viewModeIcon,
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  colors.textPrimary,
                  BlendMode.srcIn,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
