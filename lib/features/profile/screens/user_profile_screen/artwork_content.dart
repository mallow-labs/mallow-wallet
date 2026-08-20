part of '../user_profile_screen.dart';

ArtGroupDisplayType _mapGroupType(ArtGroupType type) => switch (type) {
  ArtGroupType.artist => ArtGroupDisplayType.artist,
  ArtGroupType.collection => ArtGroupDisplayType.collection,
  ArtGroupType.curation => ArtGroupDisplayType.curation,
};

ArtGroupGridDisplayType _mapGridGroupType(ArtGroupType type) => switch (type) {
  ArtGroupType.artist => ArtGroupGridDisplayType.artist,
  ArtGroupType.collection => ArtGroupGridDisplayType.collection,
  ArtGroupType.curation => ArtGroupGridDisplayType.curation,
};

void _openCollectionScreen(
  BuildContext context,
  UserProfileLoaded state,
  ArtGroup group,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CollectionScreen(group: group, profile: state.profile),
    ),
  );
}

void _openCurationScreen(
  BuildContext context,
  UserProfileLoaded state,
  ArtGroup group,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CurationScreen(
        group: group,
        ownerAddress: state.profile.address,
        isFollowing: state.isFollowing,
      ),
    ),
  );
}

VoidCallback? _groupTapHandler(
  BuildContext context,
  UserProfileLoaded state,
  ArtGroup group,
) {
  if (group.type == ArtGroupType.artist && group.artistAddress != null) {
    return () => context.goToProfile(group.artistAddress!);
  }
  if (group.type == ArtGroupType.collection) {
    return () => _openCollectionScreen(context, state, group);
  }
  if (group.type == ArtGroupType.curation) {
    return () => _openCurationScreen(context, state, group);
  }
  return null;
}

Widget _buildGroupList(
  BuildContext context,
  UserProfileLoaded state,
  List<ArtGroup> groups,
) {
  return SliverList(
    delegate: SliverChildBuilderDelegate(
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      (context, index) {
        final itemIndex = index ~/ 2;
        if (index.isOdd) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
              vertical: MallowTheme.spacingMd,
            ),
            child: Divider(height: 1, color: context.mallowColors.dividerLight),
          );
        }
        final group = groups[itemIndex];
        return ArtGroupTile(
          name: group.name,
          imageUrls: group.thumbnailUrl != null ? [group.thumbnailUrl!] : [],
          count: group.artworkCount,
          displayType: _mapGroupType(group.type),
          collectionName: group.creatorName,
          onTap: _groupTapHandler(context, state, group),
        );
      },
      childCount: groups.length * 2 - 1,
    ),
  );
}

Widget _buildGroupGrid(
  BuildContext context,
  UserProfileLoaded state,
  List<ArtGroup> groups,
) {
  return SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
    sliver: SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 40,
        crossAxisSpacing: 12,
        childAspectRatio: 170.5 / 228,
      ),
      delegate: SliverChildBuilderDelegate(
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        (context, index) {
          final group = groups[index];
          return ArtGroupGridTile(
            name: group.name,
            imageUrls: group.thumbnailUrl != null ? [group.thumbnailUrl!] : [],
            count: group.artworkCount,
            displayType: _mapGridGroupType(group.type),
            collectionName: group.creatorName,
            onTap: _groupTapHandler(context, state, group),
          );
        },
        childCount: groups.length,
      ),
    ),
  );
}

/// Build the slivers for an artwork-list tab (Created, Listed, or Owned). Renders
/// shimmer while loading, an empty state when the list is empty, the
/// masonry/detail/grid view based on the current view mode, and a loading
/// footer for pagination.
List<Widget> _buildArtworkSlivers(
  BuildContext context,
  UserProfileLoaded state, {
  required List<PortfolioArtwork>? artworks,
  required bool isLoadingMore,
  required String emptyTitle,
  required String? emptySubtitle,
  required String heroSource,
}) {
  if (artworks == null) {
    return const [_ContentSkeleton()];
  }
  if (artworks.isEmpty) {
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: _EmptyState(
          iconAsset: 'assets/icons/my_art.svg',
          title: emptyTitle,
          subtitle: emptySubtitle,
        ),
      ),
    ];
  }

  void openArtwork(PortfolioArtwork artwork) => context.push(
    AppRoutes.artworkDetailPath(artwork.mintAccount),
    // Matching tag threaded to the tile so the detail image flies in from it.
    extra: artworkHeroTag(heroSource, artwork.mintAccount),
  );

  Future<void> longPressArtwork(PortfolioArtwork artwork) =>
      // Optimistic removal is handled globally via [ArtworkRemovalSignal] —
      // UserProfileBloc drops the item from its Owned / you-own lists on the
      // spot, so no per-call-site refetch is wired here.
      showAndHandleArtworkContextMenu(context, artwork: artwork);

  final content = switch (state.artworkViewMode) {
    ArtworkViewMode.masonry => AllArtMasonry(
      artworks: artworks,
      heroSource: heroSource,
      onTap: openArtwork,
      onLongPress: longPressArtwork,
    ),
    ArtworkViewMode.detail => AllArtDetail(
      artworks: artworks,
      heroSource: heroSource,
      onTap: openArtwork,
      onLongPress: longPressArtwork,
    ),
    ArtworkViewMode.grid => AllArtGrid(
      artworks: artworks,
      heroSource: heroSource,
      onTap: openArtwork,
      onLongPress: longPressArtwork,
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

/// Build a single sliver for the given filter tab. Used by the fade-swap
/// in the main build. Driving rendered content off the visible-tab argument
/// (rather than [state.activeTab]) is what lets the previous tab keep
/// displaying its own data while fading out.
Widget _artworkContentSliver(
  BuildContext context,
  UserProfileLoaded state,
  ProfileTab tab, {
  required bool isOwnProfile,
}) {
  switch (tab) {
    case ProfileTab.created:
      return SliverMainAxisGroup(
        slivers: _buildArtworkSlivers(
          context,
          state,
          artworks: state.artworks,
          isLoadingMore: state.isLoadingMore,
          emptyTitle: isOwnProfile ? 'No art yet' : 'No artwork created',
          emptySubtitle: isOwnProfile
              ? null
              : 'This user has not created any artwork yet',
          // Distinct source per tab: Created and Owned can both be mounted
          // during the tab fade-swap, and an artwork the user both made and
          // holds would otherwise share a tag across the two grids and crash.
          heroSource: 'profile-created',
        ),
      );
    case ProfileTab.listed:
      return SliverMainAxisGroup(
        slivers: _buildArtworkSlivers(
          context,
          state,
          artworks: state.listedArtworks,
          isLoadingMore: state.isLoadingMoreListed,
          emptyTitle: 'Nothing listed',
          emptySubtitle: isOwnProfile
              ? 'Art you list for sale will appear here'
              : 'This user has no artwork listed for sale',
          heroSource: 'profile-listed',
        ),
      );
    case ProfileTab.owned:
      return SliverMainAxisGroup(
        slivers: _buildArtworkSlivers(
          context,
          state,
          artworks: state.ownedArtworks,
          isLoadingMore: state.isLoadingMoreOwned,
          emptyTitle: 'Nothing collected yet',
          emptySubtitle: isOwnProfile
              ? 'Art you collect will appear here'
              : 'This user has not collected any artwork yet',
          heroSource: 'profile-owned',
        ),
      );
    case ProfileTab.collections:
    case ProfileTab.curations:
      final groups = _filteredGroupsFor(state, tab);
      if (groups == null) {
        return state.groupViewMode == PortfolioViewMode.list
            ? const PortfolioSkeletonList()
            : const PortfolioSkeletonGrid();
      }

      final isCurations = tab == ProfileTab.curations;
      final curationsError = isCurations ? state.curationsError : null;
      final showVerifyCta = isCurations && state.showVerifyPrivateCurationsCta;

      // "Verify wallet" CTA shown above the list for own-profile Ledger
      // wallets that haven't unlocked private curations yet.
      final banner = showVerifyCta
          ? SliverToBoxAdapter(
              child: VerifyPrivateCurationsBanner(
                isVerifying: state.isVerifyingCurations,
                onVerify: () => context.read<UserProfileBloc>().add(
                  const UserProfileEvent.verifyForPrivateCurations(),
                ),
              ),
            )
          : null;

      final Widget body;
      if (curationsError != null && groups.isEmpty) {
        body = SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            iconAsset: 'assets/icons/curations.svg',
            title: 'Couldn\'t load curations',
            subtitle: curationsError,
          ),
        );
      } else if (groups.isEmpty) {
        // With a name search active, an empty list means no matches — point
        // at the search instead of claiming the tab has no content.
        final searchActive = state.groupSearch != null;
        body = SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            iconAsset: tab == ProfileTab.collections
                ? 'assets/icons/my_curations.svg'
                : 'assets/icons/curations.svg',
            title: searchActive
                ? 'No results'
                : tab == ProfileTab.collections
                ? 'No collections'
                : 'No curations',
            subtitle: searchActive
                ? 'Try a different search'
                : tab == ProfileTab.collections
                ? 'Collected artworks grouped by collection appear here'
                : 'Curated art sets appear here',
          ),
        );
      } else {
        body = state.groupViewMode == PortfolioViewMode.list
            ? _buildGroupList(context, state, groups)
            : _buildGroupGrid(context, state, groups);
      }

      if (banner == null) return body;
      return SliverMainAxisGroup(slivers: [banner, body]);
  }
}

List<ArtGroup>? _filteredGroupsFor(UserProfileLoaded state, ProfileTab tab) {
  final groups = state.groups;
  if (groups == null) return null;
  final filterType = tab == ProfileTab.collections
      ? ArtGroupType.collection
      : ArtGroupType.curation;
  var filtered = groups.where((g) => g.type == filterType);
  // Group-tab name search from the filters sheet (client-side).
  final search = state.groupSearch?.toLowerCase();
  if (search != null) {
    filtered = filtered.where((g) => g.matchesSearch(search));
  }
  return filtered.toList();
}
