import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:web3auth_flutter/web3auth_flutter.dart';

import 'core/analytics/analytics_events.dart';
import 'core/analytics/analytics_service.dart';
import 'core/config/remote_config_service.dart';
import 'core/config/system_status_service.dart';
import 'core/crypto/wallet_manager.dart';
import 'core/models/account.dart';
import 'core/network/auth_service.dart';
import 'core/network/ledger_connect_controller.dart';
import 'core/network/ledger_verify_controller.dart';
import 'core/router/app_router.dart';
import 'core/router/auth_state_notifier.dart';
import 'core/router/nav_bar_state.dart';
import 'core/security/app_lock_bloc.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/preferences_service.dart';
import 'core/services/social_auth_service.dart';
import 'core/services/token_price_service.dart';
import 'core/services/twitter_connect_notifier.dart';
import 'core/services/wallet_repository.dart';
import 'di.dart';
import 'features/activity/widgets/pending_tx_resolution_listener.dart';
import 'features/cast/models/cast_queue.dart';
import 'features/cast/services/cast_awake_guard.dart';
import 'features/cast/services/cast_bloc.dart';
import 'features/cast/services/cast_service.dart';
import 'features/cast/widgets/airplay_mirroring_prompt_sheet.dart';
import 'features/cast/widgets/cast_configuration_sheet.dart';
import 'features/cast/widgets/cast_error_toast.dart';
import 'features/cast/widgets/cast_receiver_view.dart';
import 'features/cast/widgets/now_casting_bar.dart';
import 'features/home/widgets/drawer_signal.dart';
import 'features/ledger/widgets/ledger_connect_sheet.dart';
import 'features/ledger/widgets/ledger_verify_sheet.dart';
import 'shared/theme/mallow_theme.dart';
import 'shared/widgets/action_menu.dart';
import 'shared/widgets/bottom_nav_bar.dart';
import 'shared/widgets/force_upgrade_overlay.dart';
import 'shared/widgets/lock_screen.dart';
import 'shared/widgets/mallow_scroll_behavior.dart';
import 'shared/widgets/mallow_sheet.dart';
import 'shared/widgets/mallow_svg_icon.dart';
import 'shared/widgets/system_status_banner.dart';

/// The root widget of the mallow wallet app.
///
/// Initializes routing based on wallet state and provides
/// the Material theme. Also manages app lifecycle for security.
class MallowApp extends StatefulWidget {
  const MallowApp({super.key});

  @override
  State<MallowApp> createState() => _MallowAppState();
}

class _MallowAppState extends State<MallowApp> with WidgetsBindingObserver {
  late final Future<GoRouter> _routerFuture;
  late final AppLockBloc _appLockBloc;
  late final CastAwakeGuard _castAwakeGuard;
  DeepLinkService? _deepLinkService;
  bool _isInitialized = false;
  StreamSubscription<String>? _walletChangeSubscription;
  StreamSubscription<AppLockState>? _lockStateSubscription;
  StreamSubscription<CastState>? _castStateSubscription;
  StreamSubscription<SocialAuthResult>? _socialSignInSubscription;

  DateTime? _backgroundedAt;
  static const _backgroundLockThreshold = Duration(seconds: 60);

  // How long a resume waits before it treats a still-pending social sign-in as
  // an abandoned OAuth tab. Long enough for a successful redirect's session
  // authorization to land, short enough that a real back-out unwinds promptly.
  static const _customTabCloseGrace = Duration(seconds: 3);

  // Privacy blur overlay: shown whenever the app isn't fully resumed so
  // the OS app-switcher snapshot captures a blurred frame.
  bool _isObscured = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLockBloc = sl<AppLockBloc>();
    // Force-clear the privacy blur on unlock transitions. The OS biometric
    // prompt drives the app to `inactive` (which sets _isObscured=true);
    // on some devices `resumed` is never re-delivered after the prompt
    // dismisses, stranding the blur over the now-unlocked app.
    _lockStateSubscription = _appLockBloc.stream.listen((state) {
      if (state is AppLockStateUnlocked && _isObscured && mounted) {
        setState(() => _isObscured = false);
      }
    });
    // Same workaround for AirPlay: when the external display scene tears
    // down (e.g. the receiver stops mirroring from its side), iOS fires a
    // transient `inactive` on the primary scene during the reconfiguration
    // but never re-fires `resumed` — stranding the blur, which is opaque
    // and absorbs touches, leaving the app appearing fully black and
    // unresponsive. Clear it when the cast session ends.
    _castStateSubscription = sl<CastBloc>().stream.listen((state) {
      if ((state is CastIdle || state is CastError) && _isObscured && mounted) {
        setState(() => _isObscured = false);
      }
    });
    // Keeps the screen awake while casting — an auto-locked phone is a
    // suspended app, and the slideshow is driven from here. Pairs that with
    // an idle re-lock so the awake phone isn't left transactable.
    _castAwakeGuard = CastAwakeGuard(
      castBloc: sl<CastBloc>(),
      appLockBloc: _appLockBloc,
    )..start();
    _routerFuture = _initializeRouter();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_castAwakeGuard.dispose());
    _walletChangeSubscription?.cancel();
    _lockStateSubscription?.cancel();
    _castStateSubscription?.cancel();
    _socialSignInSubscription?.cancel();
    _deepLinkService?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Toggle the privacy blur as early as possible — runs even before
    // _isInitialized so the very first backgrounding is covered.
    final shouldObscure =
        state != AppLifecycleState.resumed &&
        state != AppLifecycleState.detached;
    if (shouldObscure != _isObscured) {
      setState(() => _isObscured = shouldObscure);
    }

    if (!_isInitialized) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundedAt ??= DateTime.now();
        _castAwakeGuard.setForegrounded(false);
      case AppLifecycleState.resumed:
        _castAwakeGuard.setForegrounded(true);
        unawaited(_notifyWeb3AuthCustomTabClosed());
        final pausedAt = _backgroundedAt;
        _backgroundedAt = null;
        if (pausedAt != null &&
            DateTime.now().difference(pausedAt) >= _backgroundLockThreshold) {
          _appLockBloc.add(const AppLockEvent.lock());
        }
        _refreshSessionIfNeeded();
        // Refresh the analytics session boundary and drain any offline queue.
        // The foreground itself is not an event — best-effort.
        unawaited(sl<AnalyticsService>().onForegrounded());
        // Pick up a flow kill-switch flip that landed while we were away.
        // TTL-guarded and deduped inside the service; best-effort.
        unawaited(sl<RemoteConfigService>().refreshIfStale());
        // Same for a maintenance window or operator broadcast published while
        // we were away. Also re-evaluates the *clock*, so a window that has
        // since opened stops being announced as upcoming.
        unawaited(sl<SystemStatusService>().refreshIfStale());
        break;
      case AppLifecycleState.inactive:
        // A Face ID / passcode prompt, the share sheet, or an OAuth browser
        // hop parks the app here without ever backgrounding it, and no
        // pointer events arrive while it is up. Stand the cast idle countdown
        // down rather than lock the app underneath an auth in progress.
        _castAwakeGuard.setForegrounded(false);
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Tells the Web3Auth SDK its Android custom tab is gone, so an OAuth tab the
  /// user backed out of fails the pending login instead of wedging it. Chrome
  /// custom tabs expose no close callback, so the resume is the only signal;
  /// nothing to do on iOS.
  ///
  /// The SDK reads this call as "the user closed the tab" and fails whatever
  /// login is in flight (`setResultUrl(null)` → `UserCancelledException`), so
  /// it only fires while a sign-in round-trip is pending — and only if it is
  /// *still* pending after a settle window. Both guards matter:
  ///
  /// - The SDK's tab-closed flag is set for *any* custom-tab teardown, the
  ///   successful ones included, so an ungated resume can trip a stale flag
  ///   and cancel work that has nothing to do with a browser hop.
  /// - The success redirect resumes the app and only *then* authorizes the
  ///   session over the network, so the login the user just completed is still
  ///   pending during the resume that carried it — cancelling there drops the
  ///   user back on the welcome screen with no wallet and no error.
  ///
  /// Plugin failures are swallowed: widget tests pump lifecycle events with no
  /// platform side registered, and a throw here would fail them.
  Future<void> _notifyWeb3AuthCustomTabClosed() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final pending = sl<SocialAuthService>().requestPending;
    if (!pending.value) return;
    await Future<void>.delayed(_customTabCloseGrace);
    if (!pending.value) return;
    try {
      await Web3AuthFlutter.setCustomTabsClosed();
    } on MissingPluginException {
      // Native channel not wired (e.g. widget tests).
    } on PlatformException {
      // No login pending, or the native call failed — nothing to recover.
    }
  }

  Future<GoRouter> _initializeRouter() async {
    final authStateNotifier = sl<AuthStateNotifier>();
    await authStateNotifier.initialize();

    // Set up wallet change listener for multi-wallet support
    _setupWalletChangeListener();

    // Initialize app lock state
    _appLockBloc.add(const AppLockEvent.init());

    // Warm token price cache for the buy/listing UIs. Best-effort —
    // failures are swallowed inside the service so they can't block boot.
    sl<TokenPriceService>().start();

    // Warm the flow kill-switch / force-upgrade config. Best-effort and
    // fail-open — a failure leaves every flow enabled rather than blocking
    // boot.
    sl<RemoteConfigService>().start();

    // Warm the maintenance / operator-broadcast feeds. Same static CDN objects
    // the webapp reads; failures announce nothing.
    sl<SystemStatusService>().start();

    _isInitialized = true;

    final router = createRouter(authStateNotifier: authStateNotifier);

    // Drive social-wallet routing from the service's durable stream rather
    // than the sign-in sheet. The Google/Apple OAuth round-trip backgrounds
    // the app, so the result can land *after* the sheet (and its screen) have
    // been disposed by the resume rebuild — which used to silently drop the
    // result and create no account. This listener survives that teardown.
    _socialSignInSubscription = sl<SocialAuthService>().onSignInComplete.listen(
      (result) => _onSocialSignInComplete(result, router, authStateNotifier),
    );

    // Start capturing inbound App Links / Universal Links now that the router
    // exists. Best-effort — failures are swallowed inside the service so they
    // can't block boot.
    _deepLinkService = DeepLinkService(
      router: router,
      twitterConnectNotifier: sl<TwitterConnectNotifier>(),
    );
    unawaited(_deepLinkService!.start());

    return router;
  }

  /// Set up listener for wallet changes to trigger re-login.
  void _setupWalletChangeListener() {
    final walletManager = sl<WalletManager>();
    final authService = sl<AuthService>();

    _walletChangeSubscription = walletManager.onWalletChanged.listen((
      newAddress,
    ) async {
      // Re-login with new wallet
      try {
        await authService.switchWallet(newAddress);
      } catch (e) {
        // Log error but don't crash - user can retry
        debugPrint('Failed to switch wallet session: $e');
      }
    });
  }

  /// Route to the right place once a social sign-in completes. Centralises what
  /// used to live (duplicated) in the welcome and add-account screens, and runs
  /// independent of whether those screens are still mounted — the OAuth
  /// round-trip backgrounds the app, so the result can land after the sheet
  /// that started it is gone.
  ///
  /// The account and its wallet rows are persisted by [SocialAuthService]
  /// before the result is published; `existed` distinguishes a first sign-in
  /// from a re-login onto an account already on device.
  ///
  /// During onboarding (no wallet finished setup yet) this continues to
  /// biometric setup. Post-onboarding it makes the wallet active and returns
  /// home with the accounts drawer flagged to open.
  Future<void> _onSocialSignInComplete(
    SocialAuthResult result,
    GoRouter router,
    AuthStateNotifier authStateNotifier,
  ) async {
    final walletManager = sl<WalletManager>();
    final isOnboarding = !authStateNotifier.hasCompletedOnboarding;
    try {
      if (!result.existed) {
        // A first sign-in provisions a new embedded wallet — record it as a
        // creation, tagged with the provider (google/apple) via `method`. A
        // re-login onto an existing account creates nothing.
        unawaited(
          sl<AnalyticsService>().track(
            AnalyticsEvent.walletCreated,
            properties: {
              AnalyticsProp.chain: AnalyticsChain.solana.wire,
              AnalyticsProp.method: result.provider,
            },
          ),
        );
      }
      if (isOnboarding) {
        authStateNotifier.onWalletCreated();
        router.go(AppRoutes.biometricSetup);
      } else {
        await walletManager.switchWalletById(result.wallet.id);
        await _revealHomeForSocialWallet(result.wallet.address, router);
      }
    } catch (e, st) {
      debugPrint('[SocialImport] social sign-in routing failed: $e\n$st');
    }
  }

  /// Make the new social wallet the active session, then open home with the
  /// accounts drawer.
  ///
  /// The wallet selection is already persisted (via
  /// [WalletManager.switchWalletById]) by the caller. That emits
  /// `onWalletChanged`, which the wallet-change listener picks up to re-login —
  /// but that path is fire-and-forget, so home (and the drawer header, which
  /// reads `AuthService.currentAddress` non-reactively) would render the
  /// *previous* profile before the login lands. Awaiting the session switch
  /// here sequences the login before navigation so the new account is in
  /// context. The await is dedup-coalesced with the listener's call, so only
  /// one login runs. Non-fatal: navigate regardless so the user isn't stranded
  /// if the login itself fails.
  Future<void> _revealHomeForSocialWallet(
    String address,
    GoRouter router,
  ) async {
    try {
      await sl<AuthService>().switchWallet(address);
    } catch (e) {
      debugPrint('[SocialImport] session switch failed (non-fatal): $e');
    }
    DrawerSignal.showAccountsOnNextOpen = true;
    router.go(AppRoutes.home);
  }

  /// Refresh session in background when returning from background.
  ///
  /// This ensures we have fresh data and the backend triggers
  /// any necessary indexing jobs.
  Future<void> _refreshSessionIfNeeded() async {
    final authService = sl<AuthService>();

    // Only refresh if we have an active session
    if (!authService.hasSession) return;

    // Refresh in background - don't block the UI
    try {
      await authService.refresh();
    } catch (e) {
      // Log error but don't disrupt user experience
      // The session is still valid from the previous login
      debugPrint('Session refresh failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // PreferencesService is a @preResolve DI singleton — its themeNotifier is
    // populated synchronously from SharedPreferences before runApp(), so it's
    // safe to read here and keep the splash on the user's chosen theme
    // instead of flashing light-mode while the router resolves.
    final themeNotifier = sl<PreferencesService>().themeNotifier;
    // Every touch in the app — routed screens, sheets, the lock screen —
    // hit-tests through this listener, so it is the app-wide "user is still
    // here" signal that holds off the cast idle re-lock. Pointer *down* only:
    // a drag would restart the countdown on every move for no extra signal.
    return Listener(
      onPointerDown: (_) => _castAwakeGuard.notifyInteraction(),
      child: BlocProvider.value(
        value: _appLockBloc,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: themeNotifier,
          builder: (context, themeMode, _) {
            return FutureBuilder<GoRouter>(
              future: _routerFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return MaterialApp(
                    title: 'mallow',
                    debugShowCheckedModeBanner: false,
                    theme: MallowTheme.lightTheme,
                    darkTheme: MallowTheme.darkTheme,
                    themeMode: themeMode,
                    home: const _SplashScreen(),
                  );
                }

                if (snapshot.hasError) {
                  return MaterialApp(
                    title: 'mallow',
                    debugShowCheckedModeBanner: false,
                    theme: MallowTheme.lightTheme,
                    darkTheme: MallowTheme.darkTheme,
                    themeMode: themeMode,
                    home: _ErrorScreen(error: snapshot.error.toString()),
                  );
                }

                return _AppWithLockScreen(
                  router: snapshot.data!,
                  isObscured: _isObscured,
                  themeMode: themeMode,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// True when the current state is an AirPlay session whose iOS Screen
/// Mirroring scene hasn't attached yet. Used to gate the "Open Control
/// Center → Screen Mirroring" prompt sheet — we don't want to show it for
/// non-AirPlay sessions, or when mirror is already live.
bool _airPlayNeedsMirrorPrompt(CastState state) {
  if (state is! CastActive) return false;
  if (state.device.type != CastDeviceType.airplay) return false;
  return !sl<CastBloc>().isExternalDisplayActive;
}

/// Wraps the main app with a lock screen overlay.
class _AppWithLockScreen extends StatelessWidget {
  const _AppWithLockScreen({
    required this.router,
    required this.isObscured,
    required this.themeMode,
  });

  final GoRouter router;
  final bool isObscured;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppLockBloc, AppLockState>(
      builder: (context, lockState) {
        return MaterialApp.router(
          title: 'mallow',
          debugShowCheckedModeBanner: false,
          theme: MallowTheme.lightTheme,
          darkTheme: MallowTheme.darkTheme,
          themeMode: themeMode,
          scrollBehavior: const MallowScrollBehavior(),
          routerConfig: router,
          builder: (context, child) {
            final Widget content;
            if (lockState is AppLockStateUninitialized) {
              // While the lock bloc is still resolving its initial
              // state, never render the routed app — show the splash.
              // Prevents a one-frame flash of post-auth content on
              // cold launch.
              content = const _SplashScreen();
            } else if (lockState is AppLockStateLocked) {
              content = Stack(
                children: [
                  ?child,
                  const Positioned.fill(child: LockScreen()),
                ],
              );
            } else {
              // Global fallback for a cast failure that happens with no cast
              // surface open — without it a mid-session drop while browsing
              // just removes the now-casting bar and says nothing. Stands
              // down when a sheet/Now Playing is showing the error inline.
              content = CastErrorToastListener(
                child: MultiBlocListener(
                  listeners: [
                    BlocListener<CastBloc, CastState>(
                      listenWhen: (prev, curr) =>
                          prev is! CastDiscovering && curr is CastDiscovering,
                      listener: (context, state) {
                        final navContext =
                            AppRoutes.rootNavigatorKey.currentContext;
                        if (navContext == null) return;
                        showCastConfigurationSheet(navContext);
                      },
                    ),
                    BlocListener<CastBloc, CastState>(
                      // Fires on the transition INTO an AirPlay session where
                      // iOS Screen Mirroring hasn't been enabled yet. The
                      // native plugin emits the mirror event before
                      // session=connected so `isExternalDisplayActive` is
                      // current by the time CastActive lands here.
                      listenWhen: (prev, curr) =>
                          !_airPlayNeedsMirrorPrompt(prev) &&
                          _airPlayNeedsMirrorPrompt(curr),
                      listener: (context, state) {
                        final navContext =
                            AppRoutes.rootNavigatorKey.currentContext;
                        if (navContext == null) return;
                        // Defer the push by one microtask so any other
                        // CastActive listener that pops itself (e.g. the
                        // cast configuration sheet's auto-close) runs first
                        // — otherwise our pushed prompt lands above the
                        // still-open sheet and its pop removes the prompt
                        // instead of the sheet.
                        Future.microtask(() {
                          if (!navContext.mounted) return;
                          showAirPlayMirroringPromptSheet(navContext);
                        });
                      },
                    ),
                  ],
                  child: Stack(
                    children: [
                      // Routed content. Wrapped in [CastBarMediaQueryInset]
                      // so every screen sees `MediaQuery.padding.bottom`
                      // inflated by the cast bar's visible height while
                      // a session is active — SafeArea/padding-aware
                      // descendants lift content automatically without
                      // each screen wiring it up.
                      _LedgerVerifyListener(
                        child: _LedgerConnectListener(
                          child: PendingTxResolutionListener(
                            child: CastBarMediaQueryInset(
                              child: child ?? const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                      _PersistentNavBar(router: router),
                      // Cast bar renders ABOVE the nav bar so the nav
                      // bar's bottom gradient/shadow can't bleed onto
                      // the cast bar during the shift-up transition.
                      // Suppressed by [NowPlayingScreen] while it's
                      // mounted, since that screen is the bar's
                      // full-screen takeover.
                      ValueListenableBuilder<bool>(
                        valueListenable: NowCastingBar.suppressed,
                        builder: (context, suppressed, _) {
                          if (suppressed) return const SizedBox.shrink();
                          return const Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: NowCastingBar(),
                          );
                        },
                      ),
                      // Local cast receiver — fullscreen artwork +
                      // overlay when casting to this device. No-op
                      // otherwise.
                      const LocalCastReceiverOverlay(),
                    ],
                  ),
                ),
              );
            }
            // CastBloc is provided ABOVE the locked/unlocked branch, not
            // inside it. The branch swap reparents the router's Navigator (it
            // carries a GlobalKey, so routes and sheets survive), and
            // reactivation rebuilds the elements inside it. A sheet still on
            // the stack that reads CastBloc during build — NowPlayingScreen's
            // playback controls do — would throw ProviderNotFound if the
            // provider only existed on the unlocked side. Reachable whenever
            // the cast idle timeout re-locks with a session up.
            return BlocProvider.value(
              value: sl<CastBloc>(),
              // Clamp system text scaling to a band the layouts can absorb —
              // very large accessibility sizes would otherwise clip
              // fixed-height rows.
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: MediaQuery.textScalerOf(
                    context,
                  ).clamp(minScaleFactor: 1.0, maxScaleFactor: 1.3),
                ),
                child: Stack(
                  children: [
                    content,
                    // Operator announcements (scheduled maintenance / broadcast).
                    // Floats over the top of whatever is routed rather than
                    // taking layout: it must be visible from every screen and
                    // from inside a sheet, and it renders nothing the vast
                    // majority of the time. Listed before the force-upgrade wall
                    // (which supersedes any announcement) and before the privacy
                    // blur (which must stay topmost so the OS snapshot is
                    // blurred) — in a Stack, later children paint on top.
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SystemStatusBanner(),
                    ),
                    // Force-upgrade wall. Above the router (and the lock
                    // screen) so no route can get behind it, but below the
                    // privacy blur — the blur must stay topmost so the OS
                    // snapshot is always the blurred frame.
                    Positioned.fill(
                      child: ForceUpgradeOverlay(
                        config: sl<RemoteConfigService>().config,
                      ),
                    ),
                    Positioned.fill(
                      child: _PrivacyBlurOverlay(visible: isObscured),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Full-screen blur + tint shown whenever the app is not fully resumed,
/// so the OS app-switcher / recents thumbnail captures a privacy-safe frame.
///
/// Appears instantly when [visible] flips to true (privacy must not lag
/// behind the OS snapshot), and fades out smoothly when it flips back to
/// false — typically after biometric/PIN auth has dropped the lock screen.
/// The overlay unmounts itself once the fade completes so the BackdropFilter
/// stops sampling the frame.
class _PrivacyBlurOverlay extends StatefulWidget {
  const _PrivacyBlurOverlay({required this.visible});

  final bool visible;

  @override
  State<_PrivacyBlurOverlay> createState() => _PrivacyBlurOverlayState();
}

class _PrivacyBlurOverlayState extends State<_PrivacyBlurOverlay> {
  static const _fadeOutDuration = Duration(milliseconds: 280);
  // AnimatedOpacity.onEnd is the primary unmount path; this watchdog covers
  // the case where the fade is interrupted (rapid lifecycle flips, hot
  // reload) and the callback never fires.
  static const _unmountWatchdog = Duration(milliseconds: 500);

  late bool _mounted = widget.visible;
  Timer? _unmountTimer;

  @override
  void didUpdateWidget(_PrivacyBlurOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !_mounted) {
      _unmountTimer?.cancel();
      _unmountTimer = null;
      setState(() => _mounted = true);
    } else if (!widget.visible && _mounted) {
      _unmountTimer?.cancel();
      _unmountTimer = Timer(_unmountWatchdog, () {
        if (!widget.visible && mounted && _mounted) {
          setState(() => _mounted = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _unmountTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_mounted) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        opacity: widget.visible ? 1.0 : 0.0,
        duration: widget.visible ? Duration.zero : _fadeOutDuration,
        curve: Curves.easeOut,
        onEnd: () {
          if (!widget.visible && mounted) {
            _unmountTimer?.cancel();
            _unmountTimer = null;
            setState(() => _mounted = false);
          }
        },
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: ColoredBox(
            color: context.mallowColors.bgPrimary.withValues(alpha: 0.6),
            child: ColoredBox(
              color: context.mallowColors.scrim.withValues(alpha: 0.35),
              child: Center(
                child: SvgPicture.asset(
                  'assets/icons/mallow_icon.svg',
                  width: 42,
                  height: 42,
                  colorFilter: ColorFilter.mode(
                    context.mallowColors.accent,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Listens to [LedgerVerifyController] and shows the verification bottom sheet
/// when a Ledger wallet needs interactive signature verification.
class _LedgerVerifyListener extends StatefulWidget {
  const _LedgerVerifyListener({required this.child});
  final Widget child;

  @override
  State<_LedgerVerifyListener> createState() => _LedgerVerifyListenerState();
}

class _LedgerVerifyListenerState extends State<_LedgerVerifyListener> {
  late final StreamSubscription<LedgerVerifyRequest> _sub;
  bool _isShowing = false;

  @override
  void initState() {
    super.initState();
    _sub = sl<LedgerVerifyController>().requests.listen(_onRequest);
  }

  void _onRequest(LedgerVerifyRequest request) {
    if (_isShowing) {
      // Another sheet is already showing — reject this request
      request.completer.complete(false);
      return;
    }

    // Use the root navigator's context (below the Navigator) rather than
    // this widget's context which sits above the Navigator in the
    // MaterialApp.router builder.
    final navContext = AppRoutes.rootNavigatorKey.currentContext;
    if (navContext == null) {
      request.completer.complete(false);
      return;
    }

    _isShowing = true;

    showMallowSheet<void>(
      context: navContext,
      isScrollControlled: true,
      builder: (_) => LedgerVerifySheet(
        address: request.address,
        completer: request.completer,
      ),
    ).whenComplete(() {
      _isShowing = false;
      // Ensure completer is resolved even if sheet was dismissed externally
      if (!request.completer.isCompleted) {
        request.completer.complete(false);
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Listens to [LedgerConnectController] and shows the connect bottom sheet
/// when a Ledger signing call needs the BLE link re-established.
class _LedgerConnectListener extends StatefulWidget {
  const _LedgerConnectListener({required this.child});
  final Widget child;

  @override
  State<_LedgerConnectListener> createState() => _LedgerConnectListenerState();
}

class _LedgerConnectListenerState extends State<_LedgerConnectListener> {
  late final StreamSubscription<LedgerConnectRequest> _sub;
  bool _isShowing = false;

  @override
  void initState() {
    super.initState();
    debugPrint('[LedgerConnectListener] initState — subscribing to controller');
    _sub = sl<LedgerConnectController>().requests.listen(_onRequest);
  }

  void _onRequest(LedgerConnectRequest request) {
    debugPrint('[LedgerConnectListener] _onRequest — _isShowing=$_isShowing');
    if (_isShowing) {
      debugPrint('[LedgerConnectListener] dropping request — already showing');
      request.completer.complete(false);
      return;
    }

    final navContext = AppRoutes.rootNavigatorKey.currentContext;
    debugPrint(
      '[LedgerConnectListener] navContext=${navContext != null ? "non-null" : "null"}',
    );
    if (navContext == null) {
      request.completer.complete(false);
      return;
    }

    _isShowing = true;
    debugPrint('[LedgerConnectListener] showing LedgerConnectSheet');

    showMallowSheet<void>(
      context: navContext,
      isScrollControlled: true,
      builder: (_) => LedgerConnectSheet(
        address: request.address,
        completer: request.completer,
      ),
    ).whenComplete(() {
      debugPrint('[LedgerConnectListener] sheet closed');
      _isShowing = false;
      if (!request.completer.isCompleted) {
        request.completer.complete(false);
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Persistent bottom nav bar overlay. Visibility is owned by
/// [NavBarState.visible] — opt-in only, driven by the [TabNavigator]
/// route via [navBarRouteObserver]. The overlay also reads
/// [NavBarState.activeTab] for the highlight indicator and
/// [NavBarState.offset] for the drawer push animation.
class _PersistentNavBar extends StatefulWidget {
  const _PersistentNavBar({required this.router});

  final GoRouter router;

  @override
  State<_PersistentNavBar> createState() => _PersistentNavBarState();
}

class _PersistentNavBarState extends State<_PersistentNavBar> {
  bool _isWatchOnly = false;
  StreamSubscription<String>? _walletChangeSub;

  @override
  void initState() {
    super.initState();
    _refreshActiveWalletType();
    _walletChangeSub = sl<WalletManager>().onWalletChanged.listen(
      (_) => _refreshActiveWalletType(),
    );
  }

  @override
  void dispose() {
    _walletChangeSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshActiveWalletType() async {
    final wallet = await sl<WalletRepository>().getActiveWallet();
    if (!mounted) return;
    final isWatchOnly = wallet?.walletType == WalletType.viewOnly;
    if (isWatchOnly != _isWatchOnly) {
      setState(() => _isWatchOnly = isWatchOnly);
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = widget.router;
    return BlocBuilder<CastBloc, CastState>(
      buildWhen: (a, b) =>
          (a is CastActive && a.queue.currentItem != null) !=
          (b is CastActive && b.queue.currentItem != null),
      builder: (context, castState) {
        final showCast =
            castState is CastActive && castState.queue.currentItem != null;
        final bottom = showCast
            ? NowCastingBar.contentHeight + NowCastingBar.gapAboveNavBar
            : 0.0;
        return AnimatedPositioned(
          left: 0,
          right: 0,
          bottom: bottom,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: ValueListenableBuilder<bool>(
            valueListenable: NavBarState.visible,
            builder: (context, visible, child) {
              return IgnorePointer(
                ignoring: !visible,
                child: AnimatedSlide(
                  offset: visible ? Offset.zero : const Offset(0, 1),
                  duration: const Duration(milliseconds: 220),
                  curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
                  child: AnimatedOpacity(
                    opacity: visible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: child,
                  ),
                ),
              );
            },
            child: ValueListenableBuilder<double>(
              valueListenable: NavBarState.offset,
              builder: (context, offset, child) {
                return Transform.translate(
                  offset: Offset(offset, 0),
                  child: child,
                );
              },
              child: ValueListenableBuilder<MallowNavTab>(
                valueListenable: NavBarState.activeTab,
                builder: (context, activeTab, _) {
                  return MallowBottomNavBar(
                    currentTab: activeTab,
                    showFab: !_isWatchOnly,
                    onFabPressed: () => ActionMenu.toggle(context, router),
                    onTabSelected: (tab) {
                      NavBarState.selectedTab.value = tab;
                    },
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Splash screen shown while initializing the app.
///
/// Mirrors the centered logo treatment used by the home session loading view
/// so the transition from splash into the loading state is seamless.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: Center(
        child: SvgPicture.asset(
          'assets/icons/mallow_icon.svg',
          width: 42,
          height: 42,
          colorFilter: ColorFilter.mode(
            context.mallowColors.accent,
            BlendMode.srcIn,
          ),
        ),
      ),
    );
  }
}

/// Error screen shown if initialization fails.
class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(MallowTheme.spacingLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MallowSvgIcon(
                'assets/icons/alert_triangle.svg',
                width: 64,
                height: 64,
                color: context.mallowColors.error,
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              Text('Something went wrong', style: MallowTheme.editorialSubhead),
              const SizedBox(height: MallowTheme.spacingSm),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    error,
                    style: MallowTheme.uiMeta.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
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
