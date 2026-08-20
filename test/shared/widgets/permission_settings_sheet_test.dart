import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/permission_settings_sheet.dart';

/// The channel `app_settings` uses. Nothing registers it under `flutter test`,
/// so every call fails with `MissingPluginException` unless a test mocks it —
/// which is exactly the "settings could not be opened" case the sheet has to
/// degrade gracefully for.
const _channel = MethodChannel('com.spencerccf.app_settings/methods');

/// Comfortably past `_sheetSettleBuffer` in `mallow_sheet.dart`, which swallows
/// taps landing right as a sheet settles.
const _entranceGuard = Duration(milliseconds: 250);

/// Pumps a host, opens the sheet for [permission] and returns the pending
/// hand-off result so a test can assert on the `true`-means-handed-off contract
/// that callers (`enablePushNotifications`) branch on.
Future<Future<bool>> _openSheet(
  WidgetTester tester,
  AppPermission permission,
) async {
  late final Future<bool> result;
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () =>
                  result = showPermissionSettingsSheet(context, permission),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  await tester.pump(_entranceGuard);
  return result;
}

/// Taps [label] and settles. The fallback path pushes a second sheet only once
/// the first one's exit animation has fully unwound and the failed hand-off has
/// been awaited, so one `pumpAndSettle` can return before that route exists.
Future<void> _tapAndSettle(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  await tester.pumpAndSettle();
  await tester.pump(_entranceGuard);
}

void main() {
  final calls = <MethodCall>[];

  void mockSettings({Object? Function(MethodCall call)? handler}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return handler?.call(call);
        });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('offers a real hand-off on every platform, not just iOS', (
    tester,
  ) async {
    // Android is where permission denial is least recoverable, and the sheet
    // used to show an OK-only dead end there. The primary action must be the
    // hand-off on both platforms.
    mockSettings();
    await _openSheet(tester, AppPermission.camera);

    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('hands off to the app detail page for camera', (tester) async {
    // Neither platform exposes a camera-only settings screen; the app detail
    // page is where the per-permission switch lives.
    mockSettings();
    final result = await _openSheet(tester, AppPermission.camera);

    await _tapAndSettle(tester, 'Open Settings');

    expect(calls.single.method, 'openSettings');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['type'],
      'settings',
    );
    expect(await result, isTrue);
  });

  testWidgets('hands off to the notification page for notifications', (
    tester,
  ) async {
    // Dropping the user on the generic app page would make them hunt for the
    // toggle; both platforms can deep-link the notification screen directly.
    mockSettings();
    final result = await _openSheet(tester, AppPermission.notifications);

    await _tapAndSettle(tester, 'Open Settings');

    expect(
      (calls.single.arguments as Map<Object?, Object?>)['type'],
      'notification',
    );
    expect(await result, isTrue);
  });

  testWidgets('declining reports no hand-off and opens nothing', (
    tester,
  ) async {
    // Callers re-check permission state on resume only when this returns true,
    // so "Not now" must not claim the user was sent anywhere.
    mockSettings();
    final result = await _openSheet(tester, AppPermission.camera);

    await _tapAndSettle(tester, 'Not now');

    expect(calls, isEmpty);
    expect(await result, isFalse);
  });

  testWidgets('falls back to the manual path when the intent fails', (
    tester,
  ) async {
    // A refused intent must not leave the user staring at a button that did
    // nothing — they still need to be told where the switch is. And the result
    // must stay false, because nobody was handed off.
    mockSettings(handler: (_) => throw PlatformException(code: 'error'));
    final result = await _openSheet(tester, AppPermission.notifications);

    await _tapAndSettle(tester, 'Open Settings');

    expect(
      find.textContaining(AppPermission.notifications.manualHint),
      findsOneWidget,
    );

    // The result only settles once the fallback sheet is dismissed — callers
    // must not act on a hand-off verdict while instructions are still on screen.
    await _tapAndSettle(tester, 'OK');
    expect(await result, isFalse);
  });

  testWidgets('falls back when the plugin is missing entirely', (tester) async {
    // A build where the native plugin failed to register answers with
    // `MissingPluginException` rather than a platform error — and nothing in
    // `flutter analyze` or `flutter test` catches a missing registration, so
    // this is the failure most likely to reach a user. It must degrade the same
    // way an OS refusal does.
    mockSettings(handler: (_) => throw MissingPluginException());
    final result = await _openSheet(tester, AppPermission.camera);

    await _tapAndSettle(tester, 'Open Settings');

    expect(
      find.textContaining(AppPermission.camera.manualHint),
      findsOneWidget,
    );

    await _tapAndSettle(tester, 'OK');
    expect(await result, isFalse);
  });
}
