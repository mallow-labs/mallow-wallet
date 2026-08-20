import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/mallow_theme.dart';
import 'tappable.dart';

/// Tab items for the bottom navigation bar.
enum MallowNavTab { home, tokens, portfolio }

/// A floating pill-style bottom navigation bar with separate FAB.
///
/// Designed to match the Figma design system:
/// - Centered pill with 3 icon-only tabs
/// - White background with shadow
/// - Separate FAB on the right for quick actions
/// - Gradient fade at top for smooth content transition
class MallowBottomNavBar extends StatelessWidget {
  const MallowBottomNavBar({
    required this.currentTab,
    required this.onTabSelected,
    super.key,
    this.onFabPressed,
    this.showFab = true,
  });

  final MallowNavTab currentTab;
  final ValueChanged<MallowNavTab> onTabSelected;
  final VoidCallback? onFabPressed;
  final bool showFab;

  /// Selecting a *different* tab fires a selection haptic; re-tapping the
  /// active tab is a no-op change and stays silent.
  void _select(MallowNavTab tab) {
    if (tab != currentTab) HapticFeedback.selectionClick();
    onTabSelected(tab);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      // Gradient fade from transparent to background
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            context.mallowColors.bgPrimary.withValues(alpha: 0),
            context.mallowColors.bgPrimary.withValues(alpha: 0.2),
            context.mallowColors.bgPrimary.withValues(alpha: 0.6),
            context.mallowColors.bgPrimary,
          ],
          stops: const [0.0, 0.3, 0.6, 1.0],
        ),
      ),
      padding: const EdgeInsets.only(
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
        top: MallowTheme.spacingSm,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              // Left spacer to keep the center pill centered against the
              // right-side action FAB.
              if (showFab) const SizedBox(width: 48),
              // Center pill navigation
              Expanded(
                child: Center(
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: context.mallowColors.bgPrimary,
                      borderRadius: BorderRadius.circular(
                        MallowTheme.radiusCircular,
                      ),
                      boxShadow: MallowTheme.navBarShadow(context),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _NavItem(
                          assetPath: 'assets/icons/home.svg',
                          label: 'Home',
                          iconSize: 28,
                          isActive: currentTab == MallowNavTab.home,
                          onTap: () => _select(MallowNavTab.home),
                        ),
                        _NavItem(
                          assetPath: 'assets/icons/my_art.svg',
                          label: 'Portfolio',
                          iconSize: 24,
                          isActive: currentTab == MallowNavTab.portfolio,
                          onTap: () => _select(MallowNavTab.portfolio),
                        ),
                        _NavItem(
                          assetPath: 'assets/icons/coin.svg',
                          label: 'Tokens',
                          iconSize: 18,
                          isActive: currentTab == MallowNavTab.tokens,
                          onTap: () => _select(MallowNavTab.tokens),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // FAB on right
              if (showFab)
                _FloatingActionButton(onPressed: onFabPressed ?? () {}),
            ],
          ),
        ),
      ),
    );
  }
}

/// Navigation item with SVG icon. The icon carries no visible label, so a
/// [Semantics] wrapper exposes the tab name, button role, and selected state
/// to screen readers. A brief press-down dim gives sighted users tactile
/// feedback the bar otherwise lacked.
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.assetPath,
    required this.label,
    required this.iconSize,
    required this.isActive,
    required this.onTap,
  });

  final String assetPath;
  final String label;
  final double iconSize;
  final bool isActive;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.isActive,
      label: widget.label,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        behavior: HitTestBehavior.opaque,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.5 : 1,
          duration: const Duration(milliseconds: 100),
          // Hit area fills the full 48dp bar height so the target clears the
          // 44dp accessibility minimum (the icon stays visually centered).
          child: Container(
            width: 44,
            height: 48,
            alignment: Alignment.center,
            child: SvgPicture.asset(
              widget.assetPath,
              width: widget.iconSize,
              height: widget.iconSize,
              colorFilter: ColorFilter.mode(
                widget.isActive
                    ? context.mallowColors.accent
                    : context.mallowColors.textTertiary,
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating action button for quick actions (lightning bolt)
class _FloatingActionButton extends StatelessWidget {
  const _FloatingActionButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tappable(
      onTap: onPressed,
      enableHaptic: true,
      semanticLabel: 'Quick actions',
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: context.mallowColors.accent,
          borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
          boxShadow: MallowTheme.fabShadow(context),
        ),
        child: Center(
          child: SvgPicture.asset(
            'assets/icons/bolt.svg',
            width: 24,
            height: 24,
          ),
        ),
      ),
    );
  }
}
