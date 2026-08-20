import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/auth_service.dart';
import '../../core/services/push_notification_service.dart';
import '../../core/session/session_manager.dart';
import '../../di.dart';
import '../../features/home/widgets/home_screen_skeleton.dart';
import '../theme/mallow_theme.dart';
import '../utils/notification_link.dart';
import 'mallow_button.dart';
import 'mallow_svg_icon.dart';

/// Wraps main app content and ensures session is initialized.
///
/// Shows loading screen during login, error screen with retry on failure.
/// Only shows child content after successful session initialization.
///
/// This widget should wrap the main app shell to ensure
/// the user is authenticated before accessing any main content.
///
/// Also handles push notification deep-link routing:
/// - **Terminated state**: after [initialize] completes, a pending route from
///   [PushNotificationService.pendingDeepLink] is consumed via
///   [WidgetsBinding.addPostFrameCallback].
/// - **Background tap**: a [ValueNotifier] listener fires [_onDeepLink]
///   whenever [PushNotificationService.pendingDeepLink] changes while the
///   app is running.
class SessionInitializer extends StatefulWidget {
  const SessionInitializer({required this.child, super.key});

  final Widget child;

  @override
  State<SessionInitializer> createState() => _SessionInitializerState();
}

class _SessionInitializerState extends State<SessionInitializer> {
  late Future<void> _initFuture;
  late final PushNotificationService _pushService;
  bool _sessionReady = false;

  @override
  void initState() {
    super.initState();
    _pushService = sl<PushNotificationService>();

    // Listen for background notification taps (app was backgrounded, user taps
    // a notification, onMessageOpenedApp fires and sets pendingDeepLink).
    _pushService.pendingDeepLink.addListener(_onDeepLink);

    _initFuture = _initializeSession();
  }

  @override
  void dispose() {
    _pushService.pendingDeepLink.removeListener(_onDeepLink);
    super.dispose();
  }

  Future<void> _initializeSession() async {
    // Rebuild the persisted Account/Profile session first so the login below
    // is scoped to the held wallets (multi-address) rather than a single one.
    try {
      await sl<SessionManager>().restore();
    } catch (e) {
      debugPrint('[SessionInitializer] Session restore failed: $e');
    }

    final authService = sl<AuthService>();
    await authService.initializeSession();

    // A restored Profile session persists only the profile id; rebuild the full
    // ProfileGroup now that we're authenticated so session-scoped surfaces (the
    // receive sheet, drawer header) span all linked wallets, not just the active
    // signing wallet. Best-effort — failure leaves the account-scoped session.
    try {
      await sl<SessionManager>().restoreActiveProfile();
    } catch (e) {
      debugPrint('[SessionInitializer] Profile restore failed: $e');
    }

    // Warm the profile bulk-lookup cache for every local wallet (no-op if the
    // profile restore above already did). Lets owned/created gates resolve
    // profile-linked wallets in Account sessions too, without waiting for the
    // drawer to open. Best-effort — offline just leaves the cache cold.
    try {
      await sl<SessionManager>().warmProfileLookup();
    } catch (e) {
      debugPrint('[SessionInitializer] Profile lookup warm failed: $e');
    }

    // Register for push notifications after successful auth
    try {
      await _pushService.initialize();
    } catch (e) {
      debugPrint('[SessionInitializer] Push notification init failed: $e');
    }

    _sessionReady = true;
  }

  /// Called when [PushNotificationService.pendingDeepLink] changes value.
  ///
  /// Handles background-tap routing: fires while the app is running and a
  /// notification tap triggers [onMessageOpenedApp] in [PushNotificationService].
  void _onDeepLink() {
    if (!_sessionReady) return; // Don't navigate during init
    final route = _pushService.pendingDeepLink.value;
    if (route != null && mounted) {
      _pushService.pendingDeepLink.value = null;
      _navigateToDeepLink(route);
    }
  }

  /// A pending deep link is either an in-app route path or a mallow.art URL
  /// for a notification whose destination has no mobile screen (Gumball,
  /// Jellybean, store, Talk post, staking). Handing the latter to `context.go`
  /// would land on "Page not found".
  void _navigateToDeepLink(String destination) {
    if (isNotificationWebLink(destination)) {
      openNotificationWebLink(destination);
      return;
    }
    context.go(destination);
  }

  void _retry() {
    setState(() {
      _initFuture = _initializeSession();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SessionLoadingView();
        }

        if (snapshot.hasError) {
          return _SessionErrorView(onRetry: _retry);
        }

        // Terminated-state deep-link: getInitialMessage() may have set a
        // pending route during initialize(). Navigate after the first frame
        // so the router is fully mounted.
        final pendingRoute = _pushService.pendingDeepLink.value;
        if (pendingRoute != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _pushService.pendingDeepLink.value != null) {
              final route = _pushService.pendingDeepLink.value!;
              _pushService.pendingDeepLink.value = null;
              _navigateToDeepLink(route);
            }
          });
        }

        return widget.child;
      },
    );
  }
}

/// Loading view shown while initializing session.
///
/// Renders the home screen's shimmer skeleton directly so the user lands on
/// a structured layout rather than a centered spinner — keeping the loading
/// frame visually consistent with the content that's about to appear.
class _SessionLoadingView extends StatelessWidget {
  const _SessionLoadingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgSurface,
      body: const SafeArea(child: HomeScreenSkeleton()),
    );
  }
}

/// Error view shown when session initialization fails.
class _SessionErrorView extends StatelessWidget {
  const _SessionErrorView({required this.onRetry});

  final VoidCallback onRetry;

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
                'assets/icons/no_wifi.svg',
                width: 64,
                height: 64,
                color: context.mallowColors.textTertiary,
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              Text('Connection Error', style: MallowTheme.editorialSubhead),
              const SizedBox(height: MallowTheme.spacingSm),
              Text(
                'Unable to connect to mallow. Please check your internet connection and try again.',
                style: MallowTheme.uiMeta.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              MallowButton(label: 'Retry', onPressed: onRetry),
            ],
          ),
        ),
      ),
    );
  }
}
