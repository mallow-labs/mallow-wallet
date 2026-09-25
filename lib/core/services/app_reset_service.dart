import 'package:get_it/get_it.dart';
import 'package:sentry_flutter/sentry_flutter.dart' show SentryLevel;

import '../analytics/analytics_service.dart';
import '../crypto/wallet_manager.dart';
import '../network/auth_service.dart';
import '../security/secure_storage.dart' show EraseFailure;
import 'sentry_service.dart';

/// Which user action asked for the wipe. Recorded as a breadcrumb so a later
/// "my wallet vanished" report can be matched to a deliberate reset on that
/// device.
enum ResetReason { resetApp, startFresh }

/// The one teardown behind Settings → Reset app and the reinstall screen's
/// Start fresh: session, secrets, database file, preferences, analytics
/// identity — in that order, best-effort, with every failure collected.
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
  }) : _authService = authService,
       _walletManager = walletManager,
       _analytics = analytics;

  factory AppResetService.fromLocator() => AppResetService(
    authService: GetIt.instance<AuthService>(),
    walletManager: GetIt.instance<WalletManager>(),
    analytics: GetIt.instance<AnalyticsService>(),
  );

  final AuthService _authService;
  final WalletManager _walletManager;
  final AnalyticsService _analytics;

  /// Run the full wipe. Returns the steps that failed (empty on success).
  /// Nothing here throws.
  Future<List<EraseFailure>> resetApp({required ResetReason reason}) async {
    SentryService.addBreadcrumb(category: 'wipe', message: reason.name);
    final failures = <EraseFailure>[];

    // Session first: the live auth interceptor replays the login token from
    // memory even after the on-disk copy is gone, so it must be torn down
    // explicitly — neither wipe used to call this.
    try {
      await _authService.logout();
    } catch (e) {
      failures.add(EraseFailure('auth.logout', e.runtimeType.toString()));
    }

    // Secrets, database file, preferences (and the social SDK session).
    failures.addAll(await _walletManager.deleteWallet());

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
