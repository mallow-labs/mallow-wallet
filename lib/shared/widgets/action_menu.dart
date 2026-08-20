import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/remote_config.dart';
import '../../core/router/app_router.dart';
import '../../core/router/nav_bar_state.dart';
import '../../features/cast/widgets/now_casting_bar.dart';
import '../../features/receive/sheets/account_receive_sheet.dart';
import '../../features/send/widgets/send_sheet.dart';
import '../../features/swap/widgets/swap_sheet.dart';
import '../theme/mallow_theme.dart';
import 'chain_support_guard.dart';
import 'tap_target_expander.dart';
import 'view_only_prompt.dart';

/// Action menu popover that appears above the FAB.
///
/// Shows quick actions grouped into "Art" (Mint, Transfer, Sell) and
/// "Tokens" (Send, Receive, Swap) sections with an iOS-like scale + fade
/// animation originating from the bottom-right FAB position.
class ActionMenu {
  ActionMenu._();

  static bool _isOpen = false;

  /// Toggles the action menu. Shows it if closed, dismisses it if open.
  static void toggle(BuildContext context, GoRouter router) {
    if (_isOpen) {
      AppRoutes.rootNavigatorKey.currentState?.pop();
      return;
    }
    final navigator = AppRoutes.rootNavigatorKey.currentState;
    if (navigator == null) return;
    _isOpen = true;
    final barrier = context.mallowColors.scrim.withValues(alpha: 0.15);
    navigator
        .push(_ActionMenuRoute(router: router, barrierColor: barrier))
        .whenComplete(() {
          _isOpen = false;
        });
  }
}

class _ActionMenuRoute extends PopupRoute<void>
    implements NavBarTransparentRoute {
  _ActionMenuRoute({required this.router, required Color barrierColor})
    : _barrierColor = barrierColor;

  final GoRouter router;
  final Color _barrierColor;

  @override
  Color? get barrierColor => _barrierColor;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss action menu';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 224);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return const SizedBox.shrink();
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final scaleAnim = CurvedAnimation(
      parent: animation,
      curve: const ReducedOvershootCurve(),
      reverseCurve: Curves.easeIn,
    );
    final fadeAnim = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    // Position above the FAB pill: safe area + nav bar pill (48) +
    // container top padding (8) + gap (8). The route's `MediaQuery`
    // already includes the cast bar's contentHeight via the root
    // `CastBarMediaQueryInset` — add the extra gap-above-nav-bar so
    // the menu maintains the same 16px gap above the pill in both
    // cast and no-cast states (the nav bar shifts up by
    // `contentHeight + gapAboveNavBar`, but MediaQuery.padding only
    // carries the contentHeight portion).
    return CastBarBottomInsetBuilder(
      builder: (context, castBarInset) {
        final bottomPadding = MediaQuery.of(context).padding.bottom;
        final extraNavBarGap = castBarInset > 0
            ? NowCastingBar.gapAboveNavBar
            : 0.0;
        final menuBottom = bottomPadding + 64 + extraNavBarGap;
        return Stack(
          children: [
            Positioned(
              right: MallowTheme.spacing20,
              bottom: menuBottom,
              child: FadeTransition(
                opacity: fadeAnim,
                child: ScaleTransition(
                  scale: scaleAnim,
                  alignment: Alignment.bottomRight,
                  child: _ActionMenuCard(
                    onReceive: () {
                      final outerContext = Navigator.of(context).context;
                      Navigator.of(context).pop();
                      unawaited(showSessionReceiveSheet(outerContext));
                    },
                    // The chain guard runs before the view-only guard so a user
                    // on an unsupported chain is told the action doesn't exist
                    // for them, rather than being told to swap in a signer for
                    // a flow this build can't run on their chain anyway.
                    onSigningNavigate: (route, flow, action) async {
                      final outerContext = Navigator.of(context).context;
                      Navigator.of(context).pop();
                      if (guardUnsupportedChain(
                        outerContext,
                        flow,
                        action: action,
                      )) {
                        return;
                      }
                      if (await guardViewOnly(outerContext)) return;
                      unawaited(router.push(route));
                    },
                    // No chain guard here: `showSwapSheet` hosts it alongside
                    // the kill-switch gate, so every caller inherits both.
                    onSwap: () async {
                      final outerContext = Navigator.of(context).context;
                      Navigator.of(context).pop();
                      if (await guardViewOnly(outerContext)) return;
                      if (!outerContext.mounted) return;
                      unawaited(showSwapSheet(outerContext));
                    },
                    onSend: () async {
                      final outerContext = Navigator.of(context).context;
                      Navigator.of(context).pop();
                      // No token yet, so no chain: a signable wallet on any
                      // non-Solana chain is enough to open the sheet, which
                      // then narrows by token and source. Gating on the active
                      // (Solana) selection blocked ETH/XTZ sends outright.
                      if (await guardCannotSend(outerContext)) return;
                      if (!outerContext.mounted) return;
                      unawaited(showSendSheet(outerContext));
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ActionMenuCard extends StatelessWidget {
  const _ActionMenuCard({
    required this.onReceive,
    required this.onSigningNavigate,
    required this.onSwap,
    required this.onSend,
  });

  final VoidCallback onReceive;

  /// `(route, flow, action)` — [flow] is the capability cell the destination
  /// fronts, [action] the sentence-leading name shown if it isn't supported.
  final void Function(String route, AppFlow flow, String action)
  onSigningNavigate;
  final VoidCallback onSwap;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: 178,
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        decoration: BoxDecoration(
          color: context.mallowColors.bgSurface,
          borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
          boxShadow: MallowTheme.fabShadow(context),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ActionMenuSection(
              label: 'Art',
              items: [
                _ActionMenuItem(
                  icon: 'assets/icons/mint.svg',
                  label: 'Mint',
                  // The chooser fronts nftMint/editionMint/collectionMint,
                  // all Solana-only — any one of them answers the gate.
                  onTap: () => onSigningNavigate(
                    AppRoutes.mintChooser,
                    AppFlow.nftMint,
                    'Minting',
                  ),
                ),
                _ActionMenuItem(
                  icon: 'assets/icons/send.svg',
                  label: 'Transfer',
                  onTap: () => onSigningNavigate(
                    AppRoutes.transferChooser,
                    AppFlow.nftTransfer,
                    'Transferring artwork',
                  ),
                ),
                _ActionMenuItem(
                  icon: 'assets/icons/shop.svg',
                  label: 'Sell',
                  // fixedPriceCreate and auctionCreate share a chain set.
                  onTap: () => onSigningNavigate(
                    AppRoutes.sellChooser,
                    AppFlow.fixedPriceCreate,
                    'Selling artwork',
                  ),
                ),
              ],
            ),
            const SizedBox(height: MallowTheme.spacing20),
            _ActionMenuSection(
              label: 'Tokens',
              items: [
                _ActionMenuItem(
                  icon: 'assets/icons/send.svg',
                  label: 'Send',
                  onTap: onSend,
                ),
                _ActionMenuItem(
                  icon: 'assets/icons/qr.svg',
                  label: 'Receive',
                  onTap: onReceive,
                ),
                _ActionMenuItem(
                  icon: 'assets/icons/data_transfer.svg',
                  label: 'Swap',
                  onTap: onSwap,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionMenuSection extends StatelessWidget {
  const _ActionMenuSection({required this.label, required this.items});

  final String label;
  final List<Widget> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: MallowTheme.spacing20),
          items[i],
        ],
      ],
    );
  }
}

/// Like [Curves.easeOutBack] but with 50% less overshoot. Shared by the
/// action menu and now-casting bar pop-open transitions.
class ReducedOvershootCurve extends Curve {
  const ReducedOvershootCurve();

  // Standard easeOutBack uses s = 1.70158; halving the overshoot.
  static const double _s = 1.70158 * 0.5;

  @override
  double transformInternal(double t) {
    final t1 = t - 1;
    return t1 * t1 * ((_s + 1) * t1 + _s) + 1;
  }
}

class _ActionMenuItem extends StatelessWidget {
  const _ActionMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.disabled = false,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final color = disabled ? colors.textTertiary : colors.textPrimary;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(2),
              child: SvgPicture.asset(
                icon,
                width: 22,
                height: 22,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            Text(label, style: MallowTheme.uiBody.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}
