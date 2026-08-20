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

  static const double _rowHeight = 48;

  @override
  double get minExtent => topPadding + _rowHeight;

  @override
  double get maxExtent => topPadding + _rowHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colors = context.mallowColors;
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

    return Container(
      color: backgroundColor,
      padding: EdgeInsets.only(top: topPadding),
      child: SizedBox(
        height: _rowHeight,
        child: Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: MallowTheme.spacing20,
                  vertical: MallowTheme.spacingMd,
                ),
                child: MallowSvgIcon(
                  'assets/icons/arrow_left.svg',
                  width: 16,
                  height: 16,
                ),
              ),
            ),
            Expanded(
              child: centerText != null
                  ? Text(
                      centerText,
                      textAlign: TextAlign.center,
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textPrimary,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (loaded != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onShowDotsMenu(loaded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MallowTheme.spacing20,
                    vertical: MallowTheme.spacingMd,
                  ),
                  child: MallowSvgIcon(
                    'assets/icons/dots_vertical.svg',
                    width: 16,
                    height: 16,
                    color: colors.textPrimary,
                  ),
                ),
              )
            else
              const SizedBox(width: MallowTheme.spacing20 + 16),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _ArtworkDetailHeaderDelegate old) =>
      state != old.state ||
      topPadding != old.topPadding ||
      backgroundColor != old.backgroundColor;
}
