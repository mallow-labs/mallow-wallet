part of '../user_profile_screen.dart';

/// Sort row with sort button and trailing view mode toggle.
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
          Tappable(
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
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// Single row inside the profile options bottom sheet.
class _OptionsMenuItem extends StatelessWidget {
  const _OptionsMenuItem({
    required this.assetPath,
    required this.label,
    required this.onTap,
  });

  final String assetPath;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Tappable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: 14,
        ),
        child: Row(
          children: [
            SvgPicture.asset(
              assetPath,
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(
                colors.textPrimary,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: MallowTheme.spacingMd),
            Text(
              label,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Icon button for SVG assets.
class _IconButton extends StatelessWidget {
  const _IconButton({required this.onTap, required this.assetPath});

  final String assetPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tappable(
      onTap: onTap,
      child: SvgPicture.asset(
        assetPath,
        width: 24,
        height: 24,
        colorFilter: ColorFilter.mode(
          context.mallowColors.textPrimary,
          BlendMode.srcIn,
        ),
      ),
    );
  }
}

/// Filter chip row + sort row with a fade-out gradient at the bottom.
/// Used in two positions: in-flow at its natural scroll position (no
/// [topInset]) and as a floating overlay at the top of the screen when
/// pinning kicks in ([topInset] = system safe-area height).
class _FilterSortBar extends StatelessWidget {
  const _FilterSortBar({
    required this.visibleTabs,
    required this.activeTab,
    required this.activeSort,
    required this.sortLabel,
    required this.viewModeIconAsset,
    required this.onFilterTap,
    required this.filterCount,
    super.key,
    this.topInset = 0,
  });

  final List<ProfileTab> visibleTabs;
  final ProfileTab activeTab;
  final PortfolioSortOption activeSort;
  final String sortLabel;
  final String viewModeIconAsset;

  /// Opens the artwork-filters sheet.
  final VoidCallback onFilterTap;

  /// Number of active filter constraints; drives the badge on the button.
  final int filterCount;

  /// Reserved at the very top of the bar. Set to the system safe-area
  /// height for the floating overlay so the chips clear the notch.
  final double topInset;

  static const double _topPadding = MallowTheme.spacingMd;
  static const double _filterRowHeight = 32;
  static const double _sortRowHeight = 24;
  static const double _gradientHeight = 12;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final selectedIndex = visibleTabs.indexOf(activeTab);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColoredBox(
          color: colors.bgPrimary,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: topInset + _topPadding),
              if (visibleTabs.isNotEmpty) ...[
                SizedBox(
                  height: _filterRowHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: MallowTheme.spacing20,
                    ),
                    child: Row(
                      children: [
                        Tappable(
                          onTap: onFilterTap,
                          child: FilterBadgeIcon(count: filterCount),
                        ),
                        const SizedBox(width: MallowTheme.spacingSm),
                        Expanded(
                          child: ArtMenuTab(
                            labels: visibleTabs
                                .map((t) => _profileTabLabels[t]!)
                                .toList(),
                            selectedIndex: selectedIndex >= 0
                                ? selectedIndex
                                : null,
                            onChanged: (index) {
                              if (index != null) {
                                context.read<UserProfileBloc>().add(
                                  UserProfileEvent.changeTab(
                                    tab: visibleTabs[index],
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: MallowTheme.spacingMd),
              ],
              SizedBox(
                height: _sortRowHeight,
                child: _SortRow(
                  label: sortLabel,
                  onTap: () async {
                    final result = await showSortBottomSheet(
                      context,
                      currentSort: activeSort,
                      // Count sorts groups by item count — the artwork tabs
                      // render a flat artwork list, so there is nothing to
                      // count.
                      options: isArtworkListTab(activeTab)
                          ? const [
                              PortfolioSortOption.name,
                              PortfolioSortOption.recent,
                            ]
                          : PortfolioSortOption.values,
                    );
                    if (result != null && context.mounted) {
                      context.read<UserProfileBloc>().add(
                        UserProfileEvent.setSort(sort: result),
                      );
                    }
                  },
                  trailing: _IconButton(
                    assetPath: viewModeIconAsset,
                    onTap: () {
                      context.read<UserProfileBloc>().add(
                        const UserProfileEvent.toggleViewMode(),
                      );
                    },
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
