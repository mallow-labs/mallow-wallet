import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/deep_link_service.dart';
import '../../../core/services/preferences_service.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/full_screen_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_artwork_media.dart';
import '../../../shared/widgets/tappable.dart';
import '../../../shared/widgets/user_handle_text.dart';
import '../../curations/screens/exhibition_screen.dart';
import '../models/recently_viewed_item.dart';
import '../models/search_models.dart';
import '../services/search_bloc.dart';
import '../widgets/category_button_grid.dart';
import '../widgets/filter_button_grid.dart';
import '../widgets/filter_results_header.dart';
import '../widgets/recent_searches_section.dart';
import '../widgets/recently_viewed_section.dart';
import '../widgets/search_artwork_item.dart';
import '../widgets/search_curation_item.dart';
import '../widgets/search_input.dart';
import '../widgets/search_result_actions.dart';
import '../widgets/search_token_item.dart';
import '../widgets/search_user_item.dart';
import 'search_drilldown_screen.dart';

/// Opens the search sheet as a full-screen modal bottom sheet.
Future<void> showSearchSheet(BuildContext context) async {
  await showFullScreenSheet<void>(
    context: context,
    child: BlocProvider(
      create: (_) => sl<SearchBloc>(),
      child: const _SearchSheet(),
    ),
  );
}

class _SearchSheet extends StatefulWidget {
  const _SearchSheet();

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Intercepts pasted mallow.art links: a URL the app can deep-link
  /// (artwork / collection / profile) navigates straight there; any other
  /// mallow.art URL falls back to searching its last path segment. Returns
  /// false for non-URL input so the caller runs the normal search path.
  bool _maybeHandlePastedLink(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host != 'mallow.art' && uri.host != 'www.mallow.art') {
      return false;
    }

    final location = DeepLinkService.mapToLocation(uri);
    if (location != null) {
      // Surface the jumped-to identifier (asset/collection mint, or profile
      // username/address) in recent searches so the destination stays
      // reachable, mirroring the normal search path. The bloc is disposed
      // when this sheet pops, so persist directly rather than dispatching an
      // event that may never run.
      unawaited(sl<PreferencesService>().saveRecentSearch(uri.pathSegments[1]));
      Navigator.of(context).pop();
      context.push(location);
      return true;
    }

    // No in-app route — search the last meaningful path segment instead of
    // the raw URL (which would never match anything).
    final lastSegment = uri.pathSegments.lastWhere(
      (s) => s.isNotEmpty,
      orElse: () => '',
    );
    if (lastSegment.isEmpty) return false;
    _searchController.text = lastSegment;
    _searchController.selection = TextSelection.collapsed(
      offset: lastSegment.length,
    );
    context.read<SearchBloc>().add(SearchEvent.queryChanged(lastSegment));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SearchBloc, SearchState>(
      listener: (context, state) {
        // When returning to initial state (back from filter), clear the input
        if (state is SearchInitial) {
          _searchController.clear();
        }
      },
      builder: (context, state) {
        return Column(
          children: [
            // Pinned header: search bar OR filter back header
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacing20,
              ),
              child: _buildHeader(context, state),
            ),
            const SizedBox(height: 16),
            // Body
            Expanded(child: _buildBody(context, state)),
          ],
        );
      },
    );
  }

  /// The drilldown being viewed, or null when the sheet is showing the
  /// landing page or text results. Only the item drilldowns (Curations,
  /// Exhibitions) reach this — the artwork ones are their own pushed screen.
  static SearchFilterType? _drilldownType(SearchState state) => switch (state) {
    SearchFilterLoading(:final filterType) => filterType,
    SearchFilterResults(:final filterType) => filterType,
    _ => null,
  };

  Widget _buildHeader(BuildContext context, SearchState state) {
    final drilldown = _drilldownType(state);

    if (drilldown != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Search',
            style: GoogleFonts.newsreader(
              fontSize: 15,
              fontStyle: FontStyle.italic,
              color: context.mallowColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          FilterResultsHeader(
            label: drilldown.label,
            onBack: () {
              context.read<SearchBloc>().add(const SearchEvent.filterBack());
            },
          ),
        ],
      );
    }

    // Default: search label + input
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Search',
          style: GoogleFonts.newsreader(
            fontSize: 15,
            fontStyle: FontStyle.italic,
            color: context.mallowColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        SearchInput(
          controller: _searchController,
          onChanged: (query) {
            if (_maybeHandlePastedLink(query)) return;
            context.read<SearchBloc>().add(SearchEvent.queryChanged(query));
          },
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, SearchState state) => switch (state) {
    SearchInitial(:final recentSearches, :final recentlyViewed) =>
      _LandingContent(
        recentSearches: recentSearches,
        recentlyViewed: recentlyViewed,
        onRecentSearchTapped: (query) {
          _searchController.text = query;
          context.read<SearchBloc>().add(SearchEvent.recentSearchTapped(query));
        },
      ),
    SearchLoading() ||
    SearchFilterLoading() => const Center(child: MallowLoadingIndicator()),
    SearchLoaded(:final results, :final query) =>
      results.isEmpty
          ? _NoResults(query: query)
          : _ResultsList(results: results),
    SearchError(:final message) => _ErrorView(message: message),
    SearchFilterResults(
      :final filterType,
      :final items,
      :final hasMore,
      :final isLoadingMore,
    ) =>
      _FilterResultsList(
        filterType: filterType,
        items: items,
        hasMore: hasMore,
        isLoadingMore: isLoadingMore,
      ),
    // Artwork drilldowns run on their own bloc inside the pushed
    // [SearchDrilldownScreen], so the sheet's bloc never enters this state.
    SearchArtworkResults() => const SizedBox.shrink(),
  };
}

// =============================================================================
// Landing content (initial state)
// =============================================================================

class _LandingContent extends StatelessWidget {
  const _LandingContent({
    required this.recentSearches,
    required this.recentlyViewed,
    required this.onRecentSearchTapped,
  });

  final List<String> recentSearches;
  final List<RecentlyViewedItem> recentlyViewed;
  final ValueChanged<String> onRecentSearchTapped;

  /// Routes a filter tap. An artwork-backed filter opens the pushed
  /// [SearchDrilldownScreen] above the sheet, which the sheet's landing page
  /// survives underneath; Curations and Exhibitions have no artwork views and
  /// stay in the sheet as plain rows.
  void _onFilterTap(BuildContext context, SearchFilterType filter) {
    if (filter.isArtworkBrowse) {
      openSearchDrilldown(context, filter);
      return;
    }
    context.read<SearchBloc>().add(SearchEvent.filterSelected(filter));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
        bottom: sheetBottomInset(context, gap: 40),
      ),
      children: [
        // Recent searches
        if (recentSearches.isNotEmpty) ...[
          RecentSearchesSection(
            searches: recentSearches,
            onTap: onRecentSearchTapped,
            onClearAll: () {
              context.read<SearchBloc>().add(
                const SearchEvent.clearRecentSearches(),
              );
            },
          ),
          const SizedBox(height: 24),
        ],

        // Recently viewed
        if (recentlyViewed.isNotEmpty) ...[
          RecentlyViewedSection(
            items: recentlyViewed,
            onClearAll: () {
              context.read<SearchBloc>().add(
                const SearchEvent.clearRecentlyViewed(),
              );
            },
          ),
          const SizedBox(height: 24),
        ],

        // Listing type
        const _SectionHeader(title: 'Listing type'),
        const SizedBox(height: 12),
        FilterButtonGrid(
          filters: SearchFilterType.listingTypes,
          onTap: (filter) => _onFilterTap(context, filter),
        ),
        const SizedBox(height: 24),

        // Browse
        const _SectionHeader(title: 'Browse'),
        const SizedBox(height: 12),
        FilterButtonGrid(
          filters: SearchFilterType.browseTypes,
          onTap: (filter) => _onFilterTap(context, filter),
        ),
        const SizedBox(height: 24),

        // Categories
        const _SectionHeader(title: 'Categories'),
        const SizedBox(height: 12),
        CategoryButtonGrid(
          categories: SearchFilterType.categories,
          onTap: (filter) => _onFilterTap(context, filter),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

// =============================================================================
// Filter results list (inline results after tapping a button)
// =============================================================================

class _FilterResultsList extends StatelessWidget {
  const _FilterResultsList({
    required this.filterType,
    required this.items,
    required this.hasMore,
    required this.isLoadingMore,
  });

  final SearchFilterType filterType;
  final List<FilterResultItem> items;
  final bool hasMore;
  final bool isLoadingMore;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          'No results found',
          style: TextStyle(
            fontSize: 14,
            color: context.mallowColors.textSecondary,
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if ((notification is ScrollUpdateNotification ||
                notification is ScrollEndNotification) &&
            notification.metrics.extentAfter <
                notification.metrics.viewportDimension &&
            hasMore &&
            !isLoadingMore) {
          context.read<SearchBloc>().add(
            const SearchEvent.loadMoreFilterResults(),
          );
        }
        return false;
      },
      child: ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(
          left: MallowTheme.spacing20,
          right: MallowTheme.spacing20,
          bottom: sheetBottomInset(context, gap: 40),
        ),
        itemCount: items.length + (isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: MallowLoadingIndicator()),
            );
          }

          final item = items[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Tappable(
              onTap: () => _onItemTap(context, item),
              child: _FilterResultRow(item: item),
            ),
          );
        },
      ),
    );
  }

  void _onItemTap(BuildContext context, FilterResultItem item) {
    if (item.mintAccount == null || item.mintAccount!.isEmpty) return;

    Navigator.of(context).pop(); // Close sheet

    if (filterType == SearchFilterType.exhibitions) {
      AppRoutes.rootNavigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => ExhibitionScreen(
            exhibitionSlug: item.mintAccount!,
            exhibitionTitle: item.title,
            exhibitionThumbnailUrl: item.thumbnailUrl,
          ),
        ),
      );
    } else {
      context.push('/artwork/${item.mintAccount}');
    }
  }
}

class _FilterResultRow extends StatelessWidget {
  const _FilterResultRow({required this.item});

  final FilterResultItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Row(
      children: [
        item.thumbnailUrl != null
            ? MallowArtworkMedia(
                imageUrl: item.thumbnailUrl!,
                nsfw: item.nsfw,
                logicalSize: 48,
                width: 48,
                height: 48,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                errorBuilder: (_) => ClipRRect(
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  child: _placeholder(context),
                ),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                child: _placeholder(context),
              ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.title,
                style: GoogleFonts.newsreader(
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (item.creatorUsername != null || item.creatorAddress != null)
                UserHandleText(
                  username: item.creatorUsername,
                  address: item.creatorAddress,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                )
              else if (item.subtitle != null)
                Text(
                  '@${item.subtitle}',
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: context.mallowColors.surfaceMuted,
    );
  }
}

// =============================================================================
// Shared UI components
// =============================================================================

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No results for "$query"',
        style: TextStyle(
          fontSize: 14,
          color: context.mallowColors.textSecondary,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        style: TextStyle(
          fontSize: 14,
          color: context.mallowColors.textSecondary,
        ),
      ),
    );
  }
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({required this.results});

  final SearchResults results;

  static const _maxPerSection = 5;

  @override
  Widget build(BuildContext context) {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
        bottom: sheetBottomInset(context, gap: 40),
      ),
      children: [
        if (results.users.isNotEmpty) ...[
          const _SectionHeader(title: 'Users'),
          const SizedBox(height: MallowTheme.spacing12),
          ...results.users
              .take(_maxPerSection)
              .map(
                (u) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tappable(
                    onTap: () => openSearchUser(context, u),
                    child: SearchUserItem(user: u),
                  ),
                ),
              ),
          const SizedBox(height: 24),
        ],
        if (results.artworks.isNotEmpty) ...[
          const _SectionHeader(title: 'Artwork'),
          const SizedBox(height: MallowTheme.spacing12),
          ...results.artworks
              .take(_maxPerSection)
              .map(
                (a) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tappable(
                    onTap: () => openSearchArtwork(context, a),
                    child: SearchArtworkItem(artwork: a),
                  ),
                ),
              ),
          const SizedBox(height: 24),
        ],
        if (results.collections.isNotEmpty) ...[
          const _SectionHeader(title: 'Collections'),
          const SizedBox(height: MallowTheme.spacing12),
          ...results.collections
              .take(_maxPerSection)
              .map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tappable(
                    onTap: () => openSearchCollection(context, c),
                    child: SearchCollectionItem(collection: c),
                  ),
                ),
              ),
          const SizedBox(height: 24),
        ],
        if (results.curations.isNotEmpty) ...[
          const _SectionHeader(title: 'Curations'),
          const SizedBox(height: MallowTheme.spacing12),
          ...results.curations
              .take(_maxPerSection)
              .map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tappable(
                    onTap: () => openSearchCuration(context, c),
                    child: SearchCurationItem(curation: c),
                  ),
                ),
              ),
          const SizedBox(height: 24),
        ],
        if (results.tokens.isNotEmpty) ...[
          const _SectionHeader(title: 'Tokens'),
          const SizedBox(height: MallowTheme.spacing12),
          ...results.tokens
              .take(_maxPerSection)
              .map(
                (t) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tappable(
                    onTap: () => openSearchToken(context, t),
                    child: SearchTokenItem(token: t),
                  ),
                ),
              ),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: GoogleFonts.newsreader(
        fontSize: 15,
        fontStyle: FontStyle.italic,
        color: context.mallowColors.textPrimary,
      ),
    );
  }
}
