import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../di.dart';
import '../config/environment.dart';
import '../observability/sentry_privacy_transport.dart';
import '../security/secret_scrubber.dart';
import 'preferences_service.dart';

/// Sentry error tracking service with defence-in-depth filtering.
///
/// SECURITY: Dart events, breadcrumbs and outgoing envelopes pass through
/// [SecretScrubber], which redacts text shaped like a mnemonic, a private key,
/// an auth token or one of the address formats it recognises, and replaces
/// values stored under sensitive field names. It is pattern matching, not a
/// guarantee: callers must still never hand a secret to this service. Native
/// crash reports bypass these Dart hooks; scope synchronization stays off.
///
/// Diagnostics share the single "Share usage analytics" opt-out with the
/// product-analytics pipeline — see [PreferencesService.analyticsOptOut].
class SentryService {
  SentryService._();

  static bool _initialized = false;
  static bool _analyticsEnabled = true;

  /// Whether Sentry reporting is currently active.
  static bool get isEnabled => _initialized && _analyticsEnabled;

  /// Whether the user has opted in to analytics (independent of SDK state).
  static bool get analyticsEnabled => _analyticsEnabled;

  /// Resolve the user's diagnostics choice from the one shared preference.
  ///
  /// POLARITY: the pref stores opt-**OUT** (on-by-default), so diagnostics are
  /// enabled exactly when it is `false`. Inverting this ships the opposite of
  /// what the user asked for, silently — hence [SentryService] never stores
  /// its own copy of the key.
  ///
  /// `main()` calls `configureDependencies()` before [init], so the injected
  /// [PreferencesService] is available by the time this runs. The registration
  /// guard covers callers that run without a DI container (tests, the cast
  /// receiver isolate) and fails *safe* toward the on-by-default posture.
  static bool _readAnalyticsEnabled() {
    if (!sl.isRegistered<PreferencesService>()) return true;
    return !sl<PreferencesService>().analyticsOptOut;
  }

  /// Initialize Sentry with the app.
  ///
  /// Call this in main() before runApp():
  /// ```dart
  /// await SentryService.init(
  ///   appRunner: () => runApp(const MallowApp()),
  /// );
  /// ```
  static Future<void> init({
    required FutureOr<void> Function() appRunner,
  }) async {
    if (_initialized) {
      await appRunner();
      return;
    }

    // Respect the user's analytics opt-out preference. Resolved before the DSN
    // check so the opted-out state is recorded either way.
    _analyticsEnabled = _readAnalyticsEnabled();
    if (!_analyticsEnabled) {
      debugPrint('Analytics disabled by user, skipping Sentry initialization');
      await appRunner();
      return;
    }

    final dsn = Config.sentryDsn;

    // Skip initialization if no DSN provided
    if (dsn.isEmpty) {
      debugPrint('Sentry DSN not provided, skipping initialization');
      await appRunner();
      return;
    }

    await debugSdkInit(_configureOptions(dsn), appRunner: appRunner);

    _initialized = true;
  }

  /// Bring the Sentry hub in line with the current value of
  /// [PreferencesService.analyticsOptOut], mid-session.
  ///
  /// The preference itself is written by the caller (Settings) — this only
  /// applies it: closing the hub on opt-out so nothing further leaves the
  /// device, and re-initialising on opt-in without re-running the app.
  static Future<void> applyAnalyticsPreference() async {
    _analyticsEnabled = _readAnalyticsEnabled();

    if (!_analyticsEnabled) {
      if (_initialized) {
        await Sentry.close();
        _initialized = false;
      }
      return;
    }

    if (_initialized) return;

    final dsn = Config.sentryDsn;
    if (dsn.isEmpty) return;

    await debugSdkInit(_configureOptions(dsn));
    _initialized = true;
  }

  /// The SDK entry point both init paths call. Tests substitute a wrapper
  /// that still runs the real [SentryFlutter.init] with the production
  /// options callback, but supplies a fake native binding and a recording
  /// transport, so no platform channel or network request is made.
  @visibleForTesting
  static Future<void> Function(
    FlutterOptionsConfiguration configure, {
    AppRunner? appRunner,
  })
  debugSdkInit = SentryFlutter.init;

  /// The single options block, shared by the boot path and the mid-session
  /// re-init. Kept in one place deliberately: a drift between the two is how
  /// the scrubbers silently stop applying after a toggle.
  static FlutterOptionsConfiguration _configureOptions(String dsn) {
    return (options) {
      options.dsn = dsn;
      options.environment = Config.environment.name;
      // SDK debug logging can print events before our send hook runs.
      options.debug = false;
      options.tracesSampleRate = Config.isProduction ? 0.1 : 1.0;
      options.attachScreenshot =
          false; // Don't capture screenshots (may contain sensitive info)
      // ignore: experimental_member_use
      options.attachViewHierarchy = false;

      // SECURITY: the SDK default (`true`) makes DebugPrintIntegration
      // reassign the global `debugPrint` in RELEASE builds so every call site
      // writes a Sentry breadcrumb. The app has hundreds of ungated
      // `debugPrint`s; none of them are consented telemetry.
      options.enablePrintBreadcrumbs = false;
      // Native crash reports are written by the native SDK and never pass
      // through Dart beforeSend or SentryPrivacyTransport. Scope sync would
      // mirror Dart contexts, tags, extras, user and breadcrumbs into that
      // unfiltered channel, so it stays off, as do native and UI-interaction
      // breadcrumbs (which can carry widget text).
      options.enableScopeSync = false;
      options.enableAutoNativeBreadcrumbs = false;
      options.enableUserInteractionBreadcrumbs = false;
      // Trace sync is a different channel: it hands the native SDK only the
      // random trace id and span id of the current Dart propagation context
      // (`setTrace(traceId, spanId)`), so a native crash can be correlated
      // with the Dart transaction it interrupted. No scope data travels.
      options.enableNativeTraceSync = true;

      // Configure sensitive data scrubbing
      options.beforeSend = beforeSend;
      options.addIntegration(SentryPrivacyIntegration());
      options.enableLogs = false;
      // SentryPrivacyTransport forwards only event, transaction and client
      // report items, so metric items would be dropped anyway. Off, so the
      // SDK does not buffer what can never be sent.
      options.enableMetrics = false;
      options.beforeBreadcrumb = beforeBreadcrumb;

      // Don't send PII by default
      options.sendDefaultPii = false;
    };
  }

  /// Capture an exception with optional context.
  ///
  /// [extras] field names are matched conservatively: a key is replaced
  /// wholesale with `[REDACTED]` when its letters contain a sensitive word such
  /// as `token`, `auth`, `seed`, `secret`, `private`, `password` or `mnemonic`,
  /// or when it is exactly `pin` or `key`, and structural names such as
  /// `request`, `response`, `user`, `headers` and `body` are dropped outright.
  /// [SecretScrubber] holds the authoritative lists. Ordinary wallet vocabulary
  /// is swallowed on purpose: `tokenMint`, `tokenSymbol`, `seedPhraseId` and
  /// `authority` all arrive redacted. For genuinely public metadata, choose a
  /// clear name such as `mint` or `symbol`; never rename a sensitive field to
  /// evade filtering or relax the matcher — a missed secret cannot be recalled.
  static Future<void> captureException(
    dynamic exception, {
    dynamic stackTrace,
    String? message,
    Map<String, dynamic>? extras,
  }) async {
    if (!isEnabled) return;

    await Sentry.captureException(
      exception,
      stackTrace: stackTrace,
      withScope: (scope) {
        if (message != null) {
          scope.setContexts('info', {'message': scrubString(message)});
        }
        if (extras != null) {
          // Scrub extras before adding
          final scrubbedExtras = SecretScrubber.scrubMap(extras);
          scope.setContexts('extras', scrubbedExtras);
        }
      },
    );
  }

  /// Capture a message for logging.
  ///
  /// [extras] follows the same reserved field names as [captureException].
  static Future<void> captureMessage(
    String message, {
    SentryLevel level = SentryLevel.info,
    Map<String, dynamic>? extras,
  }) async {
    if (!isEnabled) return;

    // Scrub the message
    final scrubbedMessage = scrubString(message);

    await Sentry.captureMessage(
      scrubbedMessage,
      level: level,
      withScope: (scope) {
        if (extras != null) {
          scope.setContexts('extras', SecretScrubber.scrubMap(extras));
        }
      },
    );
  }

  /// Add a breadcrumb for debugging.
  static void addBreadcrumb({
    required String message,
    String? category,
    Map<String, dynamic>? data,
    SentryLevel level = SentryLevel.info,
  }) {
    if (!isEnabled) return;

    Sentry.addBreadcrumb(
      Breadcrumb(
        message: scrubString(message),
        category: category,
        data: data != null ? SecretScrubber.scrubMap(data) : null,
        level: level,
      ),
    );
  }

  /// Sanitize the serialized event, including SDK-populated fields. Rebuilding
  /// removes the original throwable so it cannot be serialized again later.
  /// A sanitizer failure must drop the event: the SDK otherwise catches hook
  /// errors and can continue with the original unsanitized event.
  @visibleForTesting
  static SentryEvent? beforeSend(SentryEvent event, Hint hint) {
    try {
      hint.attachments.clear();
      hint.screenshot = null;
      hint.viewHierarchy = null;
      hint.response = null;
      // Transactions must retain their SDK subtype. Their complete serialized
      // payload (including spans) is filtered by SentryPrivacyTransport.
      if (event is SentryTransaction) return event;
      return SentryEvent.fromJson(SecretScrubber.scrubMap(event.toJson()));
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Breadcrumb? beforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
    if (breadcrumb == null) return null;
    try {
      return Breadcrumb.fromJson(SecretScrubber.scrubMap(breadcrumb.toJson()));
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static String scrubString(String input) => SecretScrubber.scrubString(input);
}
