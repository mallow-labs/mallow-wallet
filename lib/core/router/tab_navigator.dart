import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../di.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/portfolio/screens/tokens_tab_content.dart';
import '../../features/home/widgets/account_menu_drawer.dart';
import '../../features/home/widgets/drawer_signal.dart';
import '../../features/accounts/services/account_wallet_bloc.dart';
import '../../features/wallets/services/wallet_drawer_bloc.dart';
import '../../features/portfolio/screens/your_art_screen.dart';
import '../../features/portfolio/services/token_balance_bloc.dart';
import '../../shared/theme/mallow_theme.dart';
import '../../shared/widgets/bottom_nav_bar.dart';
import '../../shared/widgets/session_initializer.dart';
import '../../shared/widgets/shared_header.dart';
import 'menu_drawer_controller.dart';
import 'nav_bar_state.dart';

/// Main tab navigator with horizontal slide transitions and account menu drawer.
///
/// The drawer wraps all three tabs so it can be opened from any screen
/// via edge swipe or [MenuDrawerController.of(context).toggle()].
class TabNavigator extends StatefulWidget {
  const TabNavigator({super.key, this.initialTab = 0});

  /// Initial tab index (0=home, 1=portfolio, 2=tokens)
  final int initialTab;

  @override
  State<TabNavigator> createState() => _TabNavigatorState();
}

class _TabNavigatorState extends State<TabNavigator>
    with TickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  static const _menuWidth = 300.0;
  static const _edgeSwipeWidth = 20.0;

  // Live balance blocs created by the [MultiBlocProvider] below. Captured here
  // so the foreground refresh can target the on-screen instances — they are
  // factory-scoped, so resolving fresh ones from the locator would refresh
  // orphans, not what the user sees. Ownership/disposal stays with the
  // providers; these are non-owning references.
  TokenBalanceBloc? _tokenBalanceBloc;
  AccountWalletBloc? _accountWalletBloc;

  /// Whether this TabNavigator is currently registered as a "show" with
  /// [NavBarState]. Tracked locally so request/release stay balanced if
  /// RouteAware events arrive in unexpected orders.
  bool _navBarShown = false;
  ModalRoute<dynamic>? _subscribedRoute;

  // — Tab transition —
  late int _currentIndex;
  late AnimationController _tabController;
  late Animation<double> _fadeAnimation;

  // — Drawer —
  late AnimationController _drawerController;
  late Animation<double> _drawerAnimation;
  bool _initialShowAccounts = false;
  final _drawerKey = GlobalKey<AccountMenuDrawerState>();

  late final List<Widget> _screens;

  /// Tabs that have been shown at least once. Visited tabs stay mounted
  /// (offstage) across switches so their blocs and scroll positions survive —
  /// returning to a tab repaints its existing state instead of recreating the
  /// screen and re-running its load from a skeleton. Unvisited tabs are not
  /// built, so startup still only pays for the initial tab.
  final Set<int> _visitedTabs = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentIndex = widget.initialTab;

    _screens = const [HomeScreen(), YourArtScreen(), TokensTabContent()];

    // Tab slide/fade
    _tabController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _tabController, curve: Curves.easeOut));
    _tabController.value = 1.0;

    // Drawer
    _drawerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _drawerAnimation = CurvedAnimation(
      parent: _drawerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _drawerAnimation.addListener(_syncNavBarOffset);

    // Report initial active tab and listen for tab selections
    NavBarState.activeTab.value = _indexToTab(_currentIndex);
    NavBarState.selectedTab.addListener(_onNavBarTabSelected);

    // Auto-open drawer after account creation
    if (DrawerSignal.showAccountsOnNextOpen) {
      debugPrint('[SocialImport][TabNav] initState path — showAccounts signal');
      DrawerSignal.showAccountsOnNextOpen = false;
      _initialShowAccounts = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openDrawer();
      });
    }
  }

  void _syncNavBarOffset() {
    NavBarState.offset.value = _drawerAnimation.value * _menuWidth;
  }

  static MallowNavTab _indexToTab(int index) => switch (index) {
    1 => MallowNavTab.portfolio,
    2 => MallowNavTab.tokens,
    _ => MallowNavTab.home,
  };

  void _onNavBarTabSelected() {
    final tab = NavBarState.selectedTab.value;
    final newIndex = switch (tab) {
      MallowNavTab.home => 0,
      MallowNavTab.portfolio => 1,
      MallowNavTab.tokens => 2,
    };

    // Keep the highlight in lockstep with the selection unconditionally —
    // even when the index is unchanged — so the indicator can never lag the
    // content.
    NavBarState.activeTab.value = tab;

    if (newIndex == _currentIndex) return;

    // Close drawer on tab switch
    if (_drawerController.value > 0) {
      _closeDrawer();
    }

    setState(() {
      _currentIndex = newIndex;
      // Only start a fresh fade-in from a settled tab. A switch that lands
      // mid-fade continues from the current opacity instead of hard-cutting
      // back to 0, so rapid taps don't blink through a blank frame.
      if (!_tabController.isAnimating) _tabController.value = 0.0;
      _tabController.forward();
    });
  }

  @override
  void didUpdateWidget(TabNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // go_router reconciles the three tab routes onto the same State (they
    // share a null-keyed NoTransitionPage), so a navigation like
    // `context.go(AppRoutes.home)` updates `widget.initialTab` without
    // re-running initState. Honor the new route's tab so the displayed
    // content follows the URL instead of retaining the previous tab.
    if (widget.initialTab != oldWidget.initialTab &&
        widget.initialTab != _currentIndex) {
      setState(() {
        _currentIndex = widget.initialTab;
        // See _onNavBarTabSelected: preserve a mid-fade presentation value
        // rather than blinking back to a blank frame on rapid route changes.
        if (!_tabController.isAnimating) _tabController.value = 0.0;
        _tabController.forward();
      });
      // Deferred: didUpdateWidget runs during the reconcile phase, and the
      // persistent nav bar listens to `activeTab` — writing it synchronously
      // here would mark that overlay dirty mid-build.
      final tab = _indexToTab(_currentIndex);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) NavBarState.activeTab.value = tab;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is ModalRoute<dynamic> && route != _subscribedRoute) {
      if (_subscribedRoute != null) {
        navBarRouteObserver.unsubscribe(this);
      }
      _subscribedRoute = route;
      navBarRouteObserver.subscribe(this, route);
    }
  }

  void _showNavBar() {
    // The TabNavigator that owns the visible nav bar also owns the highlight:
    // force `activeTab` to this instance's content tab every time the bar is
    // (re)shown. Because exactly one TabNavigator is the topmost route at a
    // time, this makes it impossible for the indicator to highlight a
    // different tab than the screen on display — e.g. after an import flow
    // returns home over a tokens-tab instance, or after go_router reuses vs.
    // recreates the element. Runs before the dedup guard so a redundant show
    // still re-asserts the invariant.
    NavBarState.activeTab.value = _indexToTab(_currentIndex);
    if (_navBarShown) return;
    _navBarShown = true;
    NavBarState.requestShow();
  }

  void _hideNavBar() {
    if (!_navBarShown) return;
    _navBarShown = false;
    NavBarState.releaseShow();
  }

  @override
  void didPush() => _showNavBar();

  @override
  void didPopNext() => _showNavBar();

  @override
  void didPushNext() => _hideNavBar();

  @override
  void didPop() => _hideNavBar();

  /// Pull fresh token balances whenever the app returns to the foreground, so
  /// the tokens tab, header total, and drawer per-account balances reflect any
  /// on-chain activity that happened while backgrounded. Best-effort: the
  /// refresh handlers keep the current data if no address resolves.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    _tokenBalanceBloc?.add(const TokenBalanceEvent.refresh());
    _accountWalletBloc?.add(const AccountWalletEvent.refreshBalances());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    navBarRouteObserver.unsubscribe(this);
    _hideNavBar();
    _drawerAnimation.removeListener(_syncNavBarOffset);
    NavBarState.selectedTab.removeListener(_onNavBarTabSelected);
    NavBarState.offset.value = 0.0;
    _tabController.dispose();
    _drawerController.dispose();
    super.dispose();
  }

  // — Drawer controls —

  void _openDrawer() {
    // Re-check the unread-notification badge on every open (the drawer's State
    // is created once and never rebuilt).
    _drawerKey.currentState?.refreshNotificationBadge();
    _drawerController.forward();
  }

  void _closeDrawer() {
    _drawerKey.currentState?.collapseAccounts();
    _drawerController.reverse();
  }

  void _toggleDrawer() {
    if (_drawerController.isCompleted) {
      _closeDrawer();
    } else {
      _openDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SessionInitializer(
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            // The header + tokens tab show the whole active session's worth, so
            // a Profile aggregates across its linked Solana wallets (matching
            // the drawer's per-profile total). Per-signer instances elsewhere
            // leave this off and stay scoped to the active wallet.
            create: (_) => _tokenBalanceBloc = sl<TokenBalanceBloc>()
              ..aggregateAcrossSession = true
              ..add(const TokenBalanceEvent.load()),
          ),
          BlocProvider(
            create: (_) =>
                _accountWalletBloc = sl<AccountWalletBloc>()
                  ..add(const AccountWalletEvent.load()),
          ),
          BlocProvider(
            create: (_) =>
                sl<WalletDrawerBloc>()..add(const WalletDrawerEvent.load()),
          ),
        ],
        child: Builder(
          builder: (context) {
            // Handle DrawerSignal on rebuild (e.g. returning via context.go)
            if (DrawerSignal.showAccountsOnNextOpen) {
              debugPrint(
                '[SocialImport][TabNav] build path — showAccounts signal',
              );
              DrawerSignal.showAccountsOnNextOpen = false;
              _initialShowAccounts = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                debugPrint(
                  '[SocialImport][TabNav] postFrame: load + showAccounts + '
                  'openDrawer (drawerState=${_drawerKey.currentState != null})',
                );
                context.read<WalletDrawerBloc>().add(
                  const WalletDrawerEvent.load(),
                );
                // The drawer may already be alive (e.g. returning here via
                // context.go after a social sign-in), in which case
                // initialShowAccounts — read only in initState — won't flip it.
                // Flip it imperatively so the new account is visible.
                _drawerKey.currentState?.showAccounts();
                _openDrawer();
              });
            }
            if (DrawerSignal.reloadDrawerOnReturn) {
              DrawerSignal.reloadDrawerOnReturn = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                context.read<WalletDrawerBloc>().add(
                  const WalletDrawerEvent.load(),
                );
              });
            }

            return BlocListener<WalletDrawerBloc, WalletDrawerState>(
              listenWhen: (prev, curr) {
                final prevId = prev.maybeWhen(
                  loaded: (_, _, activeWalletId, _, _, _) => activeWalletId,
                  offline: (_, activeWalletId, _) => activeWalletId,
                  orElse: () => null,
                );
                final currId = curr.maybeWhen(
                  loaded: (_, _, activeWalletId, _, _, _) => activeWalletId,
                  offline: (_, activeWalletId, _) => activeWalletId,
                  orElse: () => null,
                );
                return currId != null && prevId != currId;
              },
              listener: (context, state) {
                context.read<TokenBalanceBloc>().add(
                  const TokenBalanceEvent.load(),
                );
              },
              child: MenuDrawerController(
                toggle: _toggleDrawer,
                open: _openDrawer,
                close: _closeDrawer,
                // Repurpose the Android back gesture/button on a tab root:
                // open the drawer if closed, close it if open. Prevents the
                // app from exiting on left-edge swipe and gives the swipe
                // an in-app meaning, since Android caps gesture-exclusion
                // at 200dp/side and we can't reserve the full edge for the
                // drawer's own GestureDetector. Routes pushed on top of
                // TabNavigator are unaffected and still pop normally.
                child: PopScope(
                  canPop: false,
                  onPopInvokedWithResult: (didPop, _) {
                    if (didPop) return;
                    if (_drawerController.value > 0) {
                      _closeDrawer();
                    } else {
                      _openDrawer();
                    }
                  },
                  child: Scaffold(
                    backgroundColor: context.mallowColors.bgSurface,
                    body: _buildBody(context),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    _visitedTabs.add(_currentIndex);
    final totalUsd = context.watch<TokenBalanceBloc>().state.maybeMap(
      loaded: (loaded) => loaded.totalUsdValue,
      orElse: () => 0.0,
    );

    // Built once per build() and referenced (not reconstructed) inside the
    // per-frame AnimatedBuilder closure below — so sliding the drawer doesn't
    // rebuild the whole drawer or the active tab screen every frame.
    final drawerPanel = SizedBox(
      width: _menuWidth,
      child: AccountMenuDrawer(
        key: _drawerKey,
        onClose: _closeDrawer,
        totalUsdValue: totalUsd,
        initialShowAccounts: _initialShowAccounts,
      ),
    );

    final tabContent = Column(
      children: [
        // Persistent header across all tabs
        const SafeArea(bottom: false, child: SharedHeader()),
        // Tab content with fade transition. All visited tabs stay in the
        // tree; only the current one is on stage (painted, ticking, hit-
        // testable).
        Expanded(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Stack(
              children: [
                for (var i = 0; i < _screens.length; i++)
                  if (_visitedTabs.contains(i))
                    Offstage(
                      offstage: i != _currentIndex,
                      child: TickerMode(
                        enabled: i == _currentIndex,
                        child: _screens[i],
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );

    return AnimatedBuilder(
      animation: _drawerAnimation,
      builder: (context, _) {
        final drawerProgress = _drawerAnimation.value;
        final slideOffset = drawerProgress * _menuWidth;

        return Stack(
          children: [
            // Drawer panel (slides in from left)
            Transform.translate(
              offset: Offset(slideOffset - _menuWidth, 0),
              child: drawerPanel,
            ),

            // Tab content (slides right when drawer opens)
            Transform.translate(
              offset: Offset(slideOffset, 0),
              child: Stack(
                children: [
                  tabContent,

                  // Blur overlay when drawer is open
                  if (drawerProgress > 0)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: _closeDrawer,
                        child: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(
                              sigmaX: 10 * drawerProgress,
                              sigmaY: 10 * drawerProgress,
                            ),
                            child: Container(
                              color: context.mallowColors.scrim.withValues(
                                alpha: 0.3 * drawerProgress,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Edge-swipe gesture: narrow strip when closed, full-width when open
            if (drawerProgress == 0)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _edgeSwipeWidth,
                child: GestureDetector(
                  onHorizontalDragUpdate: _onDrawerDragUpdate,
                  onHorizontalDragEnd: _onDrawerDragEnd,
                ),
              )
            else
              Positioned.fill(
                child: GestureDetector(
                  onHorizontalDragUpdate: _onDrawerDragUpdate,
                  onHorizontalDragEnd: _onDrawerDragEnd,
                  behavior: HitTestBehavior.translucent,
                ),
              ),
          ],
        );
      },
    );
  }

  void _onDrawerDragUpdate(DragUpdateDetails details) {
    if (details.primaryDelta != null) {
      final newValue =
          _drawerController.value + details.primaryDelta! / _menuWidth;
      _drawerController.value = newValue.clamp(0.0, 1.0);
    }
  }

  void _onDrawerDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    // A decisive flick settles in the direction it was thrown regardless of how
    // far the drawer was actually dragged; a slow release falls back to
    // position (past the halfway point opens). The controller runs
    // 0 (closed) → 1 (open), so a rightward (positive) flick opens.
    final bool open;
    if (velocity.abs() > kMinFlingVelocity) {
      open = velocity > 0;
    } else {
      open = _drawerController.value > 0.5;
    }
    // Settling closed collapses the expanded accounts list, matching
    // _closeDrawer.
    if (!open) _drawerKey.currentState?.collapseAccounts();
    // fling seeds a spring with the release velocity so the settle carries the
    // finger's momentum. primaryVelocity is px/s; dividing by _menuWidth
    // converts it to the controller's 0..1 units. A slow release that didn't
    // clear the fling threshold is driven toward the position-chosen target
    // with a nominal velocity of the right sign.
    final flingVelocity = velocity.abs() > kMinFlingVelocity
        ? velocity / _menuWidth
        : (open ? 1.0 : -1.0);
    _drawerController.fling(velocity: flingVelocity);
  }
}
