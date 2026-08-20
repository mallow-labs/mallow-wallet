part of '../collection_screen.dart';

/// Sort label + view-mode toggle row, with a fade-out gradient at the bottom.
/// Used in two positions: in-flow at its natural scroll position
/// ([topInset] = 0) and as a floating overlay at the top of the screen when
/// pinning kicks in ([topInset] = system safe-area height).
class _CollectionSortBar extends StatelessWidget {
  const _CollectionSortBar({
    required this.sortLabel,
    required this.activeSort,
    required this.viewModeIconAsset,
    required this.onSort,
    required this.onCycleViewMode,
    this.topInset = 0,
    super.key,
  });

  final String sortLabel;
  final PortfolioSortOption activeSort;
  final String viewModeIconAsset;
  final ValueChanged<PortfolioSortOption> onSort;
  final VoidCallback onCycleViewMode;

  /// Reserved at the very top of the bar. Set to the system safe-area
  /// height for the floating overlay so the row clears the notch.
  final double topInset;

  static const double _topPadding = MallowTheme.spacingMd;
  static const double _rowHeight = 24;
  static const double _gradientHeight = 12;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColoredBox(
          color: colors.bgPrimary,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: topInset + _topPadding),
              SizedBox(
                height: _rowHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MallowTheme.spacing20,
                  ),
                  child: Row(
                    children: [
                      TapTargetExpander(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () async {
                            final result = await showSortBottomSheet(
                              context,
                              currentSort: activeSort,
                              // Count sorts group tabs by item count — it
                              // doesn't apply to a single collection's
                              // artworks.
                              options: const [
                                PortfolioSortOption.name,
                                PortfolioSortOption.recent,
                              ],
                            );
                            if (result != null) onSort(result);
                          },
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
                                sortLabel,
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
                          onTap: onCycleViewMode,
                          child: SvgPicture.asset(
                            viewModeIconAsset,
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
                ),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
            ],
          ),
        ),
        Container(
          height: _gradientHeight,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colors.bgPrimary, colors.bgPrimary.withValues(alpha: 0)],
            ),
          ),
        ),
      ],
    );
  }
}
