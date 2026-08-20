import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/avatar_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../artwork/widgets/artwork_context_menu_actions.dart';
import '../../cast/widgets/now_casting_bar.dart';
import '../../portfolio/services/portfolio_bloc.dart'
    show ArtGroup, ArtGroupType, PortfolioArtwork;
import '../../profile/screens/collection_screen.dart';
import '../../profile/screens/curation_screen.dart';
import '../../wallets/services/wallet_drawer_bloc.dart';
import '../data/home_feed_repository.dart';
import '../services/home_bloc.dart';
import '../widgets/circular_artist_card.dart';
import '../widgets/curation_card.dart';
import '../widgets/featured_listing_card.dart';
import '../widgets/home_resume_refresh_listener.dart';
import '../widgets/home_screen_skeleton.dart';
import '../widgets/notification_carousel.dart';
import '../widgets/popular_collection_card.dart';
import '../widgets/recommended_card.dart';
import '../widgets/spotlight_carousel.dart';

/// Home screen displaying discovery content.
///
/// Sections, in render order:
/// 1. Header
/// 2. Daily spotlight
/// 3. Notification carousel
/// 4. Popular curations
/// 5. Recommended for you
/// 6. Discover
/// 7. Featured listings
/// 8. Trending artists
/// 9. Popular collections
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<HomeBloc>()..add(const HomeEvent.load()),
      child: HomeResumeRefreshListener(
        repository: sl<HomeFeedRepository>(),
        child: BlocListener<WalletDrawerBloc, WalletDrawerState>(
          listenWhen: (prev, curr) {
            final prevId = prev.maybeWhen(
              loaded: (_, _, activeWalletId, _, _, _) => activeWalletId,
              offline: (_, activeWalletId, _) => activeWalletId,
              orElse: () => null,
            );
            final currId = curr.maybeWhen(
              loaded: (_, _, activeWalletId, _, _, _) => activeWalletId,
              offline: (_, activeWalletId, _) => activeWalletId,
              orElse: () => null,
            );
            return prevId != null && currId != null && prevId != currId;
          },
          listener: (context, state) {
            context.read<HomeBloc>().add(const HomeEvent.load());
          },
          child: BlocBuilder<HomeBloc, HomeState>(
            builder: (context, homeState) {
              // Show the skeleton for both the initial state and the explicit
              // loading state. Without covering HomeInitial, the body renders
              // blank until _onLoad's first `await` (the Drift DB cold-start on
              // the cache lookup) resolves and HomeLoading is emitted — which is
              // the multi-second blank-before-shimmers gap on cold start.
              if (homeState is HomeLoading || homeState is HomeInitial) {
                return const HomeScreenSkeleton();
              }
              return MallowRefreshIndicator(
                onRefresh: () async {
                  final bloc = context.read<HomeBloc>();
                  bloc.add(const HomeEvent.refresh());
                  // Hold the indicator until the revalidation completes
                  // (isRefreshing clears) rather than dropping it instantly.
                  await bloc.stream.firstWhere(
                    (state) => state is! HomeLoaded || !state.isRefreshing,
                  );
                },
                child: CustomScrollView(
                  slivers: [
                    if (homeState is HomeError)
                      SliverFillRemaining(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                homeState.message,
                                style: MallowTheme.uiMeta.copyWith(
                                  color: context.mallowColors.textSecondary,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: MallowTheme.spacingMd),
                              TextButton(
                                onPressed: () => context.read<HomeBloc>().add(
                                  const HomeEvent.load(),
                                ),
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (homeState is HomeLoaded) ...[
                      // 2. Daily spotlight
                      if (homeState.spotlightArtworks.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildDailySpotlight(
                            context,
                            homeState.spotlightArtworks,
                            refreshing: homeState.isRefreshing,
                          ),
                        ),
                      // 3. Notification carousel
                      const SliverToBoxAdapter(
                        child: HomeNotificationCarousel(),
                      ),
                      // 4. Popular curations
                      if (homeState.curations.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            title: 'Popular curations',
                            child: _buildCurationsRow(
                              context,
                              homeState.curations,
                            ),
                          ),
                        ),
                      // 5. Recommended for you
                      if (homeState.recommendedCategories.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            title: 'Recommended for you',
                            child: _buildRecommendedRow(
                              context,
                              homeState.recommendedCategories,
                            ),
                          ),
                        ),
                      // 6. Discover
                      if (homeState.artists.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            title: 'Discover',
                            child: _buildArtistAvatarRow(
                              context,
                              homeState.artists,
                            ),
                          ),
                        ),
                      // 7. Featured listings
                      if (homeState.featuredListings.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            title: 'Featured listings',
                            child: _buildFeaturedListingsRow(
                              context,
                              homeState.featuredListings,
                            ),
                          ),
                        ),
                      // 8. Trending artists
                      if (homeState.trendingArtists.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            title: 'Trending artists',
                            child: _buildArtistAvatarRow(
                              context,
                              homeState.trendingArtists,
                            ),
                          ),
                        ),
                      // 9. Popular collections
                      if (homeState.popularCollections.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildSection(
                            title: 'Popular collections',
                            child: _buildPopularCollectionsRow(
                              context,
                              homeState.popularCollections,
                            ),
                          ),
                        ),
                      // Bottom reserve for nav bar (grows to clear the cast
                      // bar when a session is active).
                      const SliverToBoxAdapter(child: NavBarBottomReserve()),
                    ] else ...[
                      const SliverToBoxAdapter(child: NavBarBottomReserve()),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDailySpotlight(
    BuildContext context,
    List<SpotlightArtwork> artworks, {
    required bool refreshing,
  }) {
    // Header lives inside SpotlightCarousel so it collapses with the carousel
    // when every tile's image fails to load.
    return SpotlightCarousel(
      artworks: artworks,
      // Refresh-cycle signal: lets the carousel re-try tiles whose poster
      // failed transiently even when the refresh returned identical data (the
      // bloc skips re-emitting an unchanged spotlight list).
      refreshing: refreshing,
      onArtworkLongPress: (artwork) => showAndHandleArtworkContextMenu(
        context,
        // The home feed can't know the owner's hidden state, so suppress the
        // Hide row (isHidden defaults false on this synthetic artwork).
        showHide: false,
        artwork: PortfolioArtwork(
          mintAccount: artwork.mintAccount,
          title: artwork.title,
          imageUrl: artwork.imageUrl,
          artistName: artwork.artistName,
          collectionName: artwork.collectionName,
          playbackId: artwork.playbackId,
          clipPlaybackId: artwork.clipPlaybackId,
          nsfw: artwork.nsfw,
        ),
      ),
    );
  }

  /// Wraps a horizontal scroll section with a Bodoni section title above it.
  Widget _buildSection({required String title, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(top: MallowTheme.spacing26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: Text(title, style: MallowTheme.editorialQuote),
          ),
          const SizedBox(height: MallowTheme.spacing12),
          child,
        ],
      ),
    );
  }

  Widget _buildCurationsRow(BuildContext context, List<Curation> curations) {
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        itemCount: curations.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: MallowTheme.spacingSm),
        itemBuilder: (context, index) {
          final c = curations[index];
          return CurationCard(
            name: c.name,
            curator: c.curatorName,
            curatorAddress: c.curatorAddress,
            imageUrls: c.imageUrls,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CurationScreen(
                    group: ArtGroup(
                      id: c.id,
                      type: ArtGroupType.curation,
                      name: c.name,
                      thumbnailUrl: c.imageUrls.isNotEmpty
                          ? c.imageUrls.first
                          : null,
                      artworkCount: 0,
                      creatorName: c.curatorName,
                    ),
                    ownerAddress: c.curatorAddress,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildRecommendedRow(
    BuildContext context,
    List<RecommendedCategory> categories,
  ) {
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        itemCount: categories.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: MallowTheme.spacingSm),
        itemBuilder: (_, index) {
          final cat = categories[index];
          return RecommendedCard(
            label: cat.label,
            imageUrls: cat.imageUrls,
            artistUsernames: cat.artistUsernames,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CurationScreen(
                    group: ArtGroup(
                      id: cat.label,
                      type: ArtGroupType.curation,
                      name: cat.label,
                      thumbnailUrl: cat.imageUrls.isNotEmpty
                          ? cat.imageUrls.first
                          : null,
                      artworkCount: cat.artworks.length,
                    ),
                    ownerAddress: '',
                    isEphemeral: true,
                    preloadedArtworks: cat.artworks,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildArtistAvatarRow(
    BuildContext context,
    List<ArtistPreview> artists,
  ) {
    return SizedBox(
      height: 122,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        itemCount: artists.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: MallowTheme.spacingSm),
        itemBuilder: (context, index) {
          final artist = artists[index];
          return CircularArtistCard(
            label: (artist.displayName?.isNotEmpty ?? false)
                ? artist.displayName!
                : artist.username,
            avatarUrl: artist.avatarUrl ?? artist.featuredArtworkUrl,
            avatarSeed: avatarSeedOf(
              address: artist.address,
              username: artist.username,
            ),
            onTap: () => context.goToProfile(artist.address),
          );
        },
      ),
    );
  }

  Widget _buildFeaturedListingsRow(
    BuildContext context,
    List<FeaturedListing> listings,
  ) {
    return SizedBox(
      height: 210,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        itemCount: listings.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: MallowTheme.spacingSm),
        itemBuilder: (context, index) {
          final listing = listings[index];
          return FeaturedListingCard(
            title: listing.title,
            artistName: listing.artistUsername,
            artistAddress: listing.artistAddress,
            imageUrl: listing.imageUrl,
            playbackId: listing.playbackId,
            clipPlaybackId: listing.clipPlaybackId,
            nsfw: listing.nsfw,
            priceRawAmount: listing.priceRawAmount,
            currencyMint: listing.currencyMint,
            buyerSetsPrice: listing.buyerSetsPrice,
            onTap: listing.mintAccount.isNotEmpty
                ? () => context.push(
                    AppRoutes.artworkDetailPath(listing.mintAccount),
                  )
                : null,
            onLongPress: listing.mintAccount.isNotEmpty
                ? () => showAndHandleArtworkContextMenu(
                    context,
                    // Home listings can't know the owner's hidden state, so
                    // suppress the Hide row (isHidden defaults false here).
                    showHide: false,
                    artwork: PortfolioArtwork(
                      mintAccount: listing.mintAccount,
                      title: listing.title,
                      imageUrl: listing.imageUrl,
                      artistName: listing.artistName,
                      artistUsername: listing.artistUsername,
                      collectionName: listing.collectionName,
                      playbackId: listing.playbackId,
                      clipPlaybackId: listing.clipPlaybackId,
                      nsfw: listing.nsfw,
                    ),
                  )
                : null,
          );
        },
      ),
    );
  }

  Widget _buildPopularCollectionsRow(
    BuildContext context,
    List<PopularCollection> collections,
  ) {
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        itemCount: collections.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: MallowTheme.spacingSm),
        itemBuilder: (context, index) {
          final col = collections[index];
          return PopularCollectionCard(
            name: col.name,
            artistName: col.artistName,
            artistAddress: col.artistAddress,
            imageUrl: col.imageUrl,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CollectionScreen(
                  group: ArtGroup(
                    id: col.id,
                    type: ArtGroupType.collection,
                    name: col.name,
                    thumbnailUrl: col.imageUrl,
                    artworkCount: 0,
                    artistAddress: col.artistAddress,
                    collectionMint: col.id,
                    creatorName: col.artistName,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
