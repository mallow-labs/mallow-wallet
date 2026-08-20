import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/tappable.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../portfolio/widgets/sort_bottom_sheet.dart';

/// Sort row + view-mode toggle with a fade-out gradient at the bottom.
/// Used in two positions: in-flow at its natural scroll position (no
/// [topInset]) and as a floating overlay at the top of the screen when
/// pinning kicks in ([topInset] = system safe-area height).
///
/// Shared by the Curation screen and the portfolio group drilldown.
class SortViewModeBar extends StatelessWidget {
  const SortViewModeBar({
    required this.sortLabel,
    required this.currentSort,
    required this.viewModeIcon,
    required this.onSortChanged,
    required this.onViewModeToggle,
    super.key,
    this.topInset = 0,
  });

  final String sortLabel;
  final PortfolioSortOption currentSort;
  final String viewModeIcon;
  final ValueChanged<PortfolioSortOption> onSortChanged;
  final VoidCallback onViewModeToggle;

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
                      Tappable(
                        onTap: () async {
                          final result = await showSortBottomSheet(
                            context,
                            currentSort: currentSort,
                            // Count sorts group tabs by item count — it
                            // doesn't apply to a single curation's artworks.
                            options: const [
                              PortfolioSortOption.name,
                              PortfolioSortOption.recent,
                            ],
                          );
                          if (result != null) onSortChanged(result);
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
                      const Spacer(),
                      Tappable(
                        onTap: onViewModeToggle,
                        child: SvgPicture.asset(
                          viewModeIcon,
                          width: 24,
                          height: 24,
                          colorFilter: ColorFilter.mode(
                            colors.textPrimary,
                            BlendMode.srcIn,
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
