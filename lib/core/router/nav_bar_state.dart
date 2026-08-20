import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../shared/widgets/bottom_nav_bar.dart';

/// Global state for the persistent bottom nav bar overlay.
///
/// The nav bar follows an opt-in whitelist model: it is hidden by default
/// and only shown when at least one mounted route has registered via
/// [requestShow]. Currently only `TabNavigator` opts in, via a
/// [RouteAware] subscription on [navBarRouteObserver] — so the bar is
/// visible exactly when a TabNavigator route is the topmost [ModalRoute].
/// Any [ModalRoute] pushed on top (sheet, dialog, full-flow form screen)
/// automatically hides the bar via `didPushNext`; a pop (button OR
/// swipe-back) restores it via `didPopNext`.
///
/// [offset] is driven by the drawer animation in `TabNavigator` so the
/// overlay slides in sync with the drawer.
///
/// [selectedTab] is written by the persistent nav bar and read by
/// `TabNavigator` to switch tabs without recreating the widget.
///
/// [activeTab] is written by `TabNavigator` to tell the persistent nav
/// bar which tab is currently displayed.
class NavBarState {
  NavBarState._();

  static final offset = ValueNotifier<double>(0.0);

  static final selectedTab = ValueNotifier<MallowNavTab>(MallowNavTab.home);

  static final activeTab = ValueNotifier<MallowNavTab>(MallowNavTab.home);

  /// Whether the nav bar should be shown. Driven by the [_showRefCount]
  /// refcount — always toggle via [requestShow] / [releaseShow].
  static final visible = ValueNotifier<bool>(false);

  static int _showRefCount = 0;

  /// Increment the show refcount. Pair every call with [releaseShow].
  static void requestShow() {
    _showRefCount++;
    _setVisible(true);
  }

  /// Decrement the show refcount. The bar hides once it reaches 0.
  static void releaseShow() {
    if (_showRefCount > 0) _showRefCount--;
    if (_showRefCount == 0) _setVisible(false);
  }

  /// Writes [visible] safely. RouteAware callbacks may fire during the
  /// build phase (e.g. as part of a parent's didChangeDependencies);
  /// defer notification to the next frame to avoid setState-during-build
  /// in listeners.
  static void _setVisible(bool value) {
    if (visible.value == value) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        visible.value = value;
      });
    } else {
      visible.value = value;
    }
  }
}

/// Marker for routes that should not affect nav bar visibility when
/// pushed on top of a TabNavigator route. The action menu popover
/// implements this so the FAB can open it without flicker-hiding the
/// bar it's anchored to.
abstract class NavBarTransparentRoute {}

/// Custom RouteObserver that ignores [NavBarTransparentRoute]s. Without
/// this, the action menu's [PopupRoute] would fire `didPushNext` on the
/// underlying TabNavigator route and hide the nav bar.
class _NavBarRouteObserver extends RouteObserver<ModalRoute<dynamic>> {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is NavBarTransparentRoute) return;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is NavBarTransparentRoute) return;
    super.didPop(route, previousRoute);
  }
}

/// Global RouteObserver used by `TabNavigator` to opt in to showing the
/// nav bar. Registered on the root [GoRouter] navigator so it observes
/// every push/pop on the root stack — including modal sheets and
/// dialogs, which hide the bar while they're on top.
final navBarRouteObserver = _NavBarRouteObserver();
