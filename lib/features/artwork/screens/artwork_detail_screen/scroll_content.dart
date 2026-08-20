// ignore_for_file: invalid_use_of_protected_member

part of '../artwork_detail_screen.dart';

/// Scroll body builders for [_ArtworkDetailViewState]. Separated from the
/// screen file so the state class focuses on bloc orchestration and the
/// persistent action sheet stack.
extension _ArtworkDetailScrollContent on _ArtworkDetailViewState {
  Widget _buildScrollContent(
    BuildContext context,
    ArtworkState artworkState, {
    double bottomPad = 0,
  }) {
    final topPadding = MediaQuery.of(context).padding.top;
    return MallowRefreshIndicator(
      onRefresh: () async {
        final bloc = context.read<ArtworkBloc>();
        bloc.add(const ArtworkEvent.refresh());
        // `refresh` doesn't transition through loading — it refetches in
        // place and emits the next loaded/error state. Await that emission
        // so the spinner stays up until the refetch resolves.
        await bloc.stream.first;
      },
      child: CustomScrollView(
        // Allow the pull gesture even when the loaded content is short
        // enough not to overflow the viewport.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _ArtworkDetailHeaderDelegate(
              state: artworkState,
              topPadding: topPadding,
              backgroundColor: context.mallowColors.bgPrimary,
              // Falls back to home rather than popping blind: this screen is a
              // deep-link target, and if it ever ends up alone on the stack a
              // bare `pop` is a dead tap that strands the user here.
              onBack: () =>
                  context.canPop() ? context.pop() : context.go(AppRoutes.home),
              onShowDotsMenu: _showDotsMenu,
            ),
          ),
          if (artworkState is ArtworkLoading)
            const SliverFillRemaining(child: Center(child: MallowLoader()))
          else if (artworkState is ArtworkError)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  artworkState.message,
                  style: MallowTheme.uiMeta.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else if (artworkState is ArtworkLoaded) ...[
            SliverToBoxAdapter(
              child: _ArtworkImage(
                artwork: artworkState.artwork,
                heroTag: widget.heroTag,
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  MallowTheme.spacing20,
                  MallowTheme.spacing20,
                  MallowTheme.spacing20,
                  MallowTheme.spacing20 + bottomPad,
                ),
                child: _buildBody(artworkState.artwork, artworkState.revision),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Resolve usernames for every address the info-tabs view needs, then
  /// build the body widget. Username loading is a deduped side-effect on
  /// the state; the body itself is a pure rebuild from the resolved map.
  Widget _buildBody(ArtworkDetails artwork, int revision) {
    _maybeLoadCreatorUsernames(_collectArtworkInfoAddresses(artwork));
    final viewData = _buildArtworkInfoViewData(
      artwork,
      _creatorUsernames,
      // Whole object, not just the bps: the Royalties row must tell an
      // in-flight read (null) from a failed one from a resolved 0%.
      permissions: _permissions,
    );
    return _ArtworkDetailBody(
      artwork: artwork,
      revision: revision,
      viewData: viewData,
      onOpenCollection: artwork.collectionMint != null
          ? () => _openCollection(artwork)
          : null,
      onOpenCurations: artwork.curations.isNotEmpty
          ? () => _openCurations(artwork)
          : null,
    );
  }
}
