import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Horizontal tab bar with "About", "Stats", "Wallets" tabs.
///
/// Active tab: 2px bottom border in [color_text_primary].
/// Inactive tabs: 1px bottom border in [color_border_subtle].
/// Trailing flex-fill area also has the 1px subtle border.
class ProfileTabBar extends StatelessWidget {
  const ProfileTabBar({
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
    super.key,
  });

  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...List.generate(tabs.length, (i) {
                final isActive = i == selectedIndex;
                return TapTargetExpander(
                  child: GestureDetector(
                    onTap: () => onTabSelected(i),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: isActive
                                ? context.mallowColors.textPrimary
                                : context.mallowColors.dividerLight,
                            width: isActive ? 2.0 : 1.0,
                          ),
                        ),
                      ),
                      child: Text(
                        tabs[i],
                        style: MallowTheme.uiCaption.copyWith(
                          color: context.mallowColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                );
              }),
              // Trailing flex fill with the same 1px subtle bottom border
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: context.mallowColors.dividerLight,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
