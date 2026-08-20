import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart' show GoogleFonts;
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'app.dart';
import 'core/analytics/analytics_events.dart';
import 'core/analytics/analytics_service.dart';
import 'core/config/environment.dart';
import 'core/services/sentry_service.dart';
import 'core/utils/local_timezone.dart';
import 'di.dart';
import 'features/cast/cast_receiver_app.dart';

/// Top-level background message handler for FCM.
///
/// Must be a top-level function (not a class method) so Firebase can invoke
/// it in an isolate when the app is in the background or terminated.
/// The @pragma annotation prevents tree-shaking in release builds.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[PushNotification] Background message: ${message.messageId}');
}

/// Entry point for the secondary FlutterEngine that drives the iOS AirPlay
/// receiver on an external UIScreen.
///
/// Booted from `AirPlayPlugin.mount(on:)` via `FlutterEngineGroup.makeEngine`.
/// Runs in its own Dart isolate with no access to the main app's DI graph or
/// state — it only listens on the receiver method channel for state pushes.
@pragma('vm:entry-point')
void castReceiverMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CastReceiverApp());
}

Future<void> main() async {
  // Catch every uncaught async error at the zone boundary so a startup
  // failure surfaces as a visible error screen instead of a blank white
  // screen on TestFlight / release builds.
  await runZonedGuarded(_bootstrap, (error, stackTrace) {
    debugPrint('[main] Uncaught zone error: $error\n$stackTrace');
    unawaited(SentryService.captureException(error, stackTrace: stackTrace));
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The native manifests (AndroidManifest screenOrientation, Info.plist
  // UISupportedInterfaceOrientations) are the authoritative portrait lock and
  // apply before the first frame; this runtime call is belt-and-suspenders, so
  // don't let it gate bootstrap.
  unawaited(
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
  );

  // Inter and Newsreader are bundled in assets/fonts/ (google_fonts matches
  // them by filename, e.g. Inter-Medium.ttf), so disable network fetching
  // from fonts.gstatic.com and register the bundled OFL licenses instead.
  //
  // Geist is registered here for a different reason: it is declared in
  // pubspec's `fonts:` block, and Flutter collects LICENSE files from
  // *packages* only — a family shipped as an asset contributes no entry of
  // its own. Without this the license page would omit the licence of the one
  // family the whole UI is set in. All three OFL files that ship must appear
  // here; `bundled_google_fonts_test.dart` fails if one does not.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'google_fonts',
    ], await rootBundle.loadString('assets/fonts/Inter-OFL.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'google_fonts',
    ], await rootBundle.loadString('assets/fonts/Newsreader-OFL.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Geist',
    ], await rootBundle.loadString('assets/fonts/Geist-OFL.txt'));
  });

  // Size the image cache for the dense artwork grids. With MallowNetworkImage
  // capping decoded NFT tiles to the 350-bucket (~0.5 MB each), 200 MB holds
  // ~400 tiles, and the 500-image count covers several screens of scroll-back
  // without re-decoding — the win the portfolio/profile grids were missing.
  // The byte budget stays the real guardrail (keeps big 800-bucket decodes and
  // small thumbnails from together pinning too much on iOS, where video and the
  // detail screen also need headroom).
  PaintingBinding.instance.imageCache
    ..maximumSize = 500
    ..maximumSizeBytes = 200 << 20;

  // Forward framework-level errors so post-init crashes are also visible.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      SentryService.captureException(
        details.exception,
        stackTrace: details.stack,
        message: 'FlutterError.onError',
      ),
    );
  };

  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );

    // Build vars are compiled in via `--dart-define-from-file=.env` (plus
    // `.env.local` for dev runs) — see `Config`. Nothing is read from disk
    // here: `.env` is deliberately not a bundled asset.
    Config.printStatus();
    Config.validateOrThrow();

    await _initLocalTimezone();

    await Firebase.initializeApp();

    // Gap 3 fix: Register background handler before runApp() to ensure it
    // is in place before any background isolate is spawned.
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    await configureDependencies();

    // Initialize analytics and record the cold start. Best-effort — the
    // service self-disables on any init failure and never throws.
    final analytics = sl<AnalyticsService>();
    await analytics.init();
    unawaited(
      analytics.track(
        AnalyticsEvent.appOpened,
        properties: {AnalyticsProp.coldStart: true},
      ),
    );

    // Sentry wraps runApp so post-init exceptions inside the widget tree
    // are also captured. SentryService gracefully no-ops when DSN is empty.
    await SentryService.init(appRunner: () => runApp(const MallowApp()));
  } catch (error, stackTrace) {
    debugPrint('[main] Startup failed: $error\n$stackTrace');
    unawaited(
      SentryService.captureException(
        error,
        stackTrace: stackTrace,
        message: 'Startup failure in main()',
      ),
    );
    runApp(_StartupErrorApp(error: error, stackTrace: stackTrace));
  }
}

Future<void> _initLocalTimezone() async {
  tz_data.initializeTimeZones();
  try {
    final name = await LocalTimezone.name();
    tz.setLocalLocation(tz.getLocation(name));
  } catch (e) {
    debugPrint('[main] Failed to resolve local timezone, using UTC: $e');
  }
}

/// Minimal, theme-free error screen shown when [main] fails before
/// [MallowApp] can run. Has no dependency on mallow theme or DI so it
/// renders even if those subsystems are exactly what crashed.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error, required this.stackTrace});

  final Object error;
  final StackTrace stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        // Pre-theme startup error screen — runs before MallowApp loads the theme, so theme tokens are unavailable. Literals intentional.
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'mallow failed to start',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  '$error',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Stack trace',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      stackTrace.toString(),
                      style: const TextStyle(
                        color: Colors.white60,
                        fontFamily: 'Courier',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
