import 'package:get_it/get_it.dart';
import 'package:sentry_flutter/sentry_flutter.dart' show SentryLevel;

import '../../features/browser/services/browser_data_clearer.dart';
import '../../features/walletconnect/services/walletconnect_service.dart';
import '../analytics/analytics_service.dart';
import '../crypto/wallet_manager.dart';
import '../network/auth_service.dart';
import '../security/secure_storage.dart' show EraseFailure;
import 'post_session_action_registry.dart';
import 'sentry_service.dart';

/// Which user action asked for the wipe. Recorded as a breadcrumb so a later
/// "my wallet vanished" report can be matched to a deliberate reset on that
/// device.
enum ResetReason { resetApp, startFresh }

/// The one teardown behind Settings → Reset app and the reinstall screen's
/// Start fresh: browser, WalletConnect sessions, auth session, secrets,
/// database file, preferences, analytics identity — in that order,
/// best-effort, with every failure collected.
///
/// Best-effort is the point: stopping at the first error used to leave the
/// user half-wiped (some keys gone, session intact). Every step runs; the
/// caller gets the list back and tells the user when it is not empty.
///
/// Not DI-registered: the screens build it with [AppResetService.fromLocator]
/// and tests pass their own collaborators.
class AppResetService {
  AppResetService({
    required AuthService authService,
    required WalletManager walletManager,
    required AnalyticsService analytics,
    required BrowserDataClearer browserDataClearer,
  }) : _authService = authService,
       _walletManager = walletManager,
       _analytics = analytics,
       _browserDataClearer = browserDataClearer;

  factory AppResetService.fromLocator() => AppResetService(
    authService: GetIt.instance<AuthService>(),
    walletManager: GetIt.instance<WalletManager>(),
    analytics: GetIt.instance<AnalyticsService>(),
    browserDataClearer: BrowserDataClearer.platform(),
  );

  final AuthService _authService;
  final WalletManager _walletManager;
  final AnalyticsService _analytics;
  final BrowserDataClearer _browserDataClearer;

  /// Run the full wipe. Returns the steps that failed (empty on success).
  /// Nothing here throws.
  Future<List<EraseFailure>> resetApp({required ResetReason reason}) async {
    SentryService.addBreadcrumb(category: 'wipe', message: reason.name);
    final failures = <EraseFailure>[];

    try {
      final browserFailures = await _browserDataClearer.clearForAppReset();
      failures.addAll(
        browserFailures.map(
          (failure) =>
              EraseFailure('browser.${failure.step}', failure.errorType),
        ),
      );
    } catch (e) {
      failures.add(EraseFailure('browser.teardown', e.runtimeType.toString()));
    }

    // Before the preferences go: ending each session tells its website, and
    // the session keys sit in the secure store, which the wallet wipe below
    // does not enumerate.
    try {
      final walletConnect = WalletConnectService.instance;
      if (walletConnect != null) {
        failures.addAll(
          (await walletConnect.reset()).map(
            (step) => EraseFailure('walletconnect.$step', 'erase'),
          ),
        );
      }
    } catch (e) {
      failures.add(EraseFailure('walletconnect', e.runtimeType.toString()));
    }

    // The live auth interceptor replays the login token from memory even after
    // the on-disk copy is gone, so it must be torn down explicitly.
    try {
      await _authService.logout();
    } catch (e) {
      failures.add(EraseFailure('auth.logout', e.runtimeType.toString()));
    }

    // Secrets, database file, preferences (and the social SDK session).
    failures.addAll(await _walletManager.deleteWallet());

    // No session has been ready since the wipe, and whatever a feature held for
    // the user goes with it.
    try {
      final locator = GetIt.instance;
      if (locator.isRegistered<PostSessionActionRegistry>()) {
        locator<PostSessionActionRegistry>().reset();
      }
    } catch (e) {
      failures.add(EraseFailure('session.reset', e.runtimeType.toString()));
    }

    try {
      await _analytics.resetDeviceIdentity();
    } catch (e) {
      failures.add(EraseFailure('analytics.reset', e.runtimeType.toString()));
    }

    if (failures.isNotEmpty) {
      await SentryService.captureMessage(
        'wipe (${reason.name}): ${failures.length} step(s) failed',
        level: SentryLevel.error,
        extras: {'steps': failures.map((f) => f.toString()).toList()},
      );
    }
    return failures;
  }
}
