import 'dart:async';

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:injectable/injectable.dart';

import '../../di.dart';
import '../../shared/utils/notification_link.dart';
import '../../shared/widgets/in_app_push_banner.dart';
import '../../shared/widgets/permission_settings_sheet.dart';
import '../config/environment.dart';
import '../router/app_router.dart';
import 'preferences_service.dart';
import 'wallet_repository.dart';

/// Service for managing push notifications via Firebase Cloud Messaging.
///
/// Handles FCM token lifecycle, permission requests, and token registration
/// with the mallow backend. Uses raw Dio calls with cookie auth (same pattern
/// as AuthService).
///
/// Deep-link routing is handled via [pendingDeepLink]: the widget layer
/// observes this notifier and calls context.go() when a value is set.
/// This avoids a circular DI dependency between the service and GoRouter.
@lazySingleton
class PushNotificationService {
  PushNotificationService(this._dio, this._wallets, this._prefs) {
    // Every wallet mutation bumps this, so an import, a removal, an account
    // delete and a full reset all re-sync without their own wiring.
    _wallets.walletsRevision.addListener(_scheduleSync);
  }

  final Dio _dio;
  final WalletRepository _wallets;
  final PreferencesService _prefs;

  /// Resolved per call, never in a field initializer.
  ///
  /// `FirebaseMessaging.instance` throws `[core/no-app]` when no Firebase app
  /// exists — a hermetic E2E run that skips `Firebase.initializeApp()`, or a
  /// device where that call failed. As a field initializer that throw escapes
  /// the *constructor*, which DI resolves from `SessionInitializer.initState`,
  /// so it takes the entire main shell down with an ErrorWidget. Deferring it
  /// moves the throw into the individual methods, whose call sites already
  /// guard (session init catches, the settings/notifications screens only run
  /// on a real device).
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  String? _currentToken;
  bool _initialized = false;

  /// Fingerprint of the last `token + addresses` set successfully synced, so a
  /// revision bump that did not change the wallet set (a rename, a reorder, a
  /// wallet switch) costs nothing.
  String? _syncedFingerprint;

  Timer? _syncDebounce;

  /// Notifier for deep-link navigation triggered by notification taps.
  ///
  /// Set when:
  /// - App is launched from a terminated-state notification tap
  ///   ([getInitialMessage] in [initialize]).
  /// - A notification is tapped while the app is in the background
  ///   ([onMessageOpenedApp] listener).
  ///
  /// The widget layer (SessionInitializer) observes this and calls
  /// context.go() when a non-null value appears, then clears it.
  final ValueNotifier<String?> pendingDeepLink = ValueNotifier(null);

  /// Initialize push notifications.
  ///
  /// Sets up listeners for token refresh and incoming messages, handles
  /// terminated-state deep links, and — if the user has already granted
  /// permission in a prior session — fetches the FCM token and registers
  /// it with the backend.
  ///
  /// Does NOT request OS permission. The dialog is triggered from the
  /// onboarding push step, the Settings toggle, or the Notifications screen on
  /// first visit (see [requestPermission]).
  ///
  /// Note: [FirebaseMessaging.onBackgroundMessage] is registered in main()
  /// before runApp() to guarantee the handler is in place before any
  /// background isolate is spawned.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Check current authorization without prompting.
    final settings = await _messaging.getNotificationSettings();
    final authorized =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    debugPrint(
      '[PushNotification] Permission: ${settings.authorizationStatus}',
    );

    // Only fetch + register the token when we already have permission.
    // Calling getToken() before the user grants on iOS can return null and
    // emit warnings.
    //
    // Isolated from the rest of initialize(): a getToken() that throws (no
    // network, no APNs token yet) must not skip the listener registration
    // below, because `_initialized` is already latched and nothing would
    // re-run it. Nothing is lost — the next wallet mutation re-syncs.
    if (authorized) {
      try {
        await syncAddresses();
      } catch (e) {
        debugPrint('[PushNotification] Initial address sync failed: $e');
      }
    }

    // Listeners are registered unconditionally — they're no-ops without
    // permission, and getInitialMessage() must run on every cold start to
    // catch terminated-state notification taps from prior granted sessions.
    _messaging.onTokenRefresh.listen(_onTokenRefresh);

    // Gap 2 fix: Handle terminated-state notification tap.
    // getInitialMessage() returns the RemoteMessage that caused the app to
    // open from a fully-terminated state. onMessageOpenedApp does NOT fire
    // in this case — this is the only way to catch it.
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint(
        '[PushNotification] Launched from terminated-state notification: '
        '${initialMessage.messageId}',
      );
      final route = _routeFromNotification(initialMessage);
      pendingDeepLink.value = route;
    }

    // Gap 2 fix (iOS): Configure foreground notification presentation.
    // By default, iOS suppresses alerts/sound/badge when the app is in the
    // foreground. This call opts in to showing them while the app is open.
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );

    // Foreground message handler (notification received while app is open)
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    // Background-tap handler: app was in background and user tapped notification
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      debugPrint(
        '[PushNotification] Opened from background notification: '
        '${message.messageId}',
      );
      final route = _routeFromNotification(message);
      pendingDeepLink.value = route;
    });
  }

  /// Show an in-app banner for a notification that arrives while the app is
  /// open, and route the same way a notification tap does when it's tapped.
  ///
  /// Android only: iOS re-presents the notification itself via
  /// [FirebaseMessaging.setForegroundNotificationPresentationOptions] above, so
  /// a banner there would double up. Android has no foreground presentation at
  /// all, which is why the platform showed nothing before this.
  ///
  /// The service has no [BuildContext], so the banner goes onto the root
  /// navigator's overlay — the same key the action menu and other global
  /// overlays already use.
  void _onForegroundMessage(RemoteMessage message) {
    debugPrint('[PushNotification] Foreground message: ${message.messageId}');
    if (defaultTargetPlatform != TargetPlatform.android) return;

    // Data-only messages carry nothing to display.
    final notification = message.notification;
    if (notification == null) return;

    final context = AppRoutes.rootNavigatorKey.currentContext;
    if (context == null) return;

    InAppPushBanner.show(
      context,
      title: notification.title,
      body: notification.body,
      // Reuse pendingDeepLink so a foreground tap and a background tap go
      // through the exact same resolution + navigation path.
      onTap: () => pendingDeepLink.value = _routeFromNotification(message),
    );
  }

  /// Whether the OS will currently deliver notifications to this app.
  ///
  /// Never prompts — use [requestPermission] for that.
  Future<bool> isAuthorized() async {
    final settings = await _messaging.getNotificationSettings();
    return _isGranted(settings.authorizationStatus);
  }

  /// Prompt the OS push-permission dialog and, on grant, register the
  /// device token with the backend.
  ///
  /// Idempotent at the OS level: iOS only shows the dialog once per install;
  /// subsequent calls return the current authorization status without
  /// prompting. Returns the resulting [AuthorizationStatus] so callers can
  /// drive UI follow-up (e.g. show an in-app banner on denial).
  Future<AuthorizationStatus> requestPermission() async {
    final settings = await _messaging.requestPermission();
    debugPrint(
      '[PushNotification] requestPermission result: ${settings.authorizationStatus}',
    );
    // Record that the OS dialog has had its one shot, whichever entry point
    // asked — otherwise the Notifications screen re-runs its "first visit"
    // prompt after the Settings toggle already burned it.
    await _prefs.setHasPromptedForPushPermission(true);
    final granted = _isGranted(settings.authorizationStatus);
    if (granted) {
      await syncAddresses();
    }
    return settings.authorizationStatus;
  }

  /// Push the device's current wallet set to the backend.
  ///
  /// The stored mapping is `token -> addresses on this device`. It has no
  /// account, profile, session or signature in it: a device holding wallets
  /// with nobody signed in still needs push for them, and a wallet the user
  /// removed must stop receiving push whether or not anyone is logged in.
  ///
  /// Sends the whole set every time and lets the server replace what it had.
  /// A delta protocol drifts permanently the moment one call is lost, and the
  /// device is the only party that knows the truth.
  ///
  /// View-only wallets are excluded: those are addresses the user is watching,
  /// not holding, and their notifications belong to whoever owns the key.
  Future<void> syncAddresses() async {
    if (!_prefs.pushNotificationsEnabled) return;

    final token = _currentToken ?? await _messaging.getToken();
    if (token == null) return;
    _currentToken = token;

    final addresses =
        (await _wallets.getAllWallets())
            .where((w) => w.canSign && w.address.isNotEmpty)
            .map((w) => w.address)
            .toSet()
            .toList()
          ..sort();

    await _syncToBackend(token, addresses);
  }

  /// Stop this device receiving push, without touching the wallets on it.
  ///
  /// Used by the Settings toggle. Syncing an empty set clears every row for
  /// this token server-side, so it needs no session — unlike the older
  /// `/unregister`, which deletes only the row for the address you happen to be
  /// logged in as and therefore cannot clear a multi-wallet device.
  Future<void> unregister() async {
    final token = _currentToken;
    if (token == null) return;
    await _syncToBackend(token, const []);
    _currentToken = null;
  }

  /// Seed the FCM token so a test can drive [syncAddresses] without Firebase.
  ///
  /// `FirebaseMessaging.instance` throws `[core/no-app]` in a hermetic run, and
  /// the token is the only thing [syncAddresses] needs it for.
  @visibleForTesting
  Future<void> debugSyncWithToken(String token) {
    _currentToken = token;
    return syncAddresses();
  }

  /// Coalesce a burst of wallet mutations into one sync.
  ///
  /// Importing a seed phrase runs many mutations back to back; without this
  /// each one would POST.
  void _scheduleSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 1500), () {
      syncAddresses().catchError((Object e) {
        debugPrint('[PushNotification] Wallet-change sync failed: $e');
      });
    });
  }

  /// Resolve a [RemoteMessage] to a notification destination.
  ///
  /// Parses the `link` field from [RemoteMessage.data] — the same link the
  /// in-app notification row carries, absolutised by the sender — and runs it
  /// through [resolveNotificationLink] so a tapped push and a tapped row land
  /// in the same place. The result is either an in-app route path or a
  /// mallow.art URL for a destination mobile has no screen for; the observer
  /// (SessionInitializer) branches on which.
  ///
  /// Falls back to [AppRoutes.home] for a missing or unparseable link.
  String _routeFromNotification(RemoteMessage message) {
    final link = message.data['link'] as String?;
    final destination = resolveNotificationLink(link);
    if (destination == null) {
      debugPrint('[PushNotification] Unhandled link: $link');
      return AppRoutes.home;
    }
    return destination;
  }

  /// Handle FCM token refresh.
  Future<void> _onTokenRefresh(String newToken) async {
    debugPrint('[PushNotification] Token refreshed');

    // Clear the superseded token's rows FIRST, and do it whether or not the
    // preference is on. FCM has already invalidated the old token but the
    // backend has not heard that, so leaving those rows makes every
    // notification pay for a send that can only fail. Skipping this while push
    // is switched off would strand them for good: the toggle-off path clears
    // `_currentToken`, which by then is the NEW token.
    final previousToken = _currentToken;
    if (previousToken != null && previousToken != newToken) {
      await _syncToBackend(previousToken, const []);
    }

    _currentToken = newToken;
    // The fingerprint is keyed on the token, so a new one always re-syncs.
    await syncAddresses();
  }

  /// Replace this token's address set on the backend.
  ///
  /// Skips the call when nothing changed since the last confirmed sync, and
  /// records the fingerprint only on success so a failure is retried by the
  /// next trigger rather than being treated as done.
  Future<void> _syncToBackend(String token, List<String> addresses) async {
    final fingerprint = '$token|${addresses.join(',')}';
    if (fingerprint == _syncedFingerprint) return;

    try {
      await _dio.post<Map<String, dynamic>>(
        '${Config.apiBaseUrl}/v1/deviceToken/sync',
        data: {
          'token': token,
          'platform': defaultTargetPlatform == TargetPlatform.iOS
              ? 'ios'
              : 'android',
          'addresses': addresses,
        },
      );
      _syncedFingerprint = fingerprint;
      debugPrint('[PushNotification] Synced ${addresses.length} addresses');
    } on DioException catch (e) {
      debugPrint('[PushNotification] Address sync failed: ${e.message}');
    }
  }
}

/// Whether [status] means the OS will deliver notifications.
bool _isGranted(AuthorizationStatus status) =>
    status == AuthorizationStatus.authorized ||
    status == AuthorizationStatus.provisional;

/// Result of [enablePushFromUserAction].
enum PushEnableOutcome {
  /// The OS will deliver notifications; the preference is persisted and the
  /// device token is registered.
  granted,

  /// The OS refused and the user stayed in the app. Nothing was persisted.
  denied,

  /// The OS refused and the user was sent to the device settings app. The
  /// caller should re-check on resume (see `PushNotificationService.isAuthorized`).
  sentToSettings,
}

/// Turn push notifications on in response to an explicit user action (the
/// Settings toggle, the Notifications-screen banner).
///
/// The OS permission comes first: [PushNotificationService.register] alone only
/// fetches a token, so persisting an "enabled" preference without a granted
/// permission leaves a toggle that is on while nothing can ever arrive. On a
/// denial — including a permanent one, where iOS and Android 13+ return denied
/// without showing a dialog at all — the user gets the shared recovery sheet
/// rather than silence. [offerSettingsOnDenial] turns that sheet off for the
/// one caller that does not want it: the onboarding step, where the dialog is
/// shown for the very first time, so a refusal there answers the question the
/// screen just asked rather than reporting a permission stuck off.
///
/// Lives here rather than in a widget file so the Settings screen and the
/// Notifications banner share one path (cf. `core/security/reauth_gate.dart`,
/// which likewise pairs a core-level gate with a shared sheet).
Future<PushEnableOutcome> enablePushFromUserAction(
  BuildContext context, {
  bool offerSettingsOnDenial = true,
}) async {
  final service = sl<PushNotificationService>();
  final prefs = sl<PreferencesService>();

  final status = await service.requestPermission();
  if (_isGranted(status)) {
    // requestPermission() already registered the token when the preference was
    // on; flip it on and register only when it wasn't.
    if (!prefs.pushNotificationsEnabled) {
      await prefs.setPushNotificationsEnabled(true);
      await service.syncAddresses();
    }
    return PushEnableOutcome.granted;
  }

  if (!offerSettingsOnDenial || !context.mounted) {
    return PushEnableOutcome.denied;
  }
  final openedSettings = await showPermissionSettingsSheet(
    context,
    AppPermission.notifications,
  );
  return openedSettings
      ? PushEnableOutcome.sentToSettings
      : PushEnableOutcome.denied;
}
