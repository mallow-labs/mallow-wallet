part of '../artwork_detail_screen.dart';

/// Pinned header delegate: back arrow + optional center label + dots menu.
/// Stays at the top of the screen while the artwork image and content
/// scroll behind it.
class _ArtworkDetailHeaderDelegate extends SliverPersistentHeaderDelegate {
  _ArtworkDetailHeaderDelegate({
    required this.state,
    required this.topPadding,
    required this.backgroundColor,
    required this.onBack,
    required this.onShowDotsMenu,
  });

  final ArtworkState state;
  final double topPadding;
  final Color backgroundColor;
  final VoidCallback onBack;
  final void Function(ArtworkDetails) onShowDotsMenu;

  @override
  double get minExtent => topPadding + PinnedTopBar.rowHeight;

  @override
  double get maxExtent => topPadding + PinnedTopBar.rowHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final loaded = state is ArtworkLoaded
        ? (state as ArtworkLoaded).artwork
        : null;

    String? centerText;
    if (loaded != null) {
      centerText = loaded.supplyType.supplyTitle(
        maxSupply: loaded.maxSupply,
        editionNumber: loaded.editionNumber,
      );
    }

    return PinnedTopBar(
      topInset: topPadding,
      backgroundColor: backgroundColor,
      onBack: onBack,
      title: centerText,
      onMenuTap: loaded != null ? () => onShowDotsMenu(loaded) : null,
    );
  }

  @override
  bool shouldRebuild(covariant _ArtworkDetailHeaderDelegate old) =>
      state != old.state ||
      topPadding != old.topPadding ||
      backgroundColor != old.backgroundColor;
}
