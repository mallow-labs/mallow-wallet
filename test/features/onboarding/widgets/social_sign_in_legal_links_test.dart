import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/onboarding/widgets/import_wallet_menu.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// The channel `MethodChannelUrlLauncher` talks to — the implementation
/// `UrlLauncherPlatform.instance` falls back to under `flutter test`.
const MethodChannel _urlLauncherChannel = MethodChannel(
  'plugins.flutter.io/url_launcher',
);

/// The legal links in the onboarding sheets are the only place a user can read
/// the terms they are agreeing to before a wallet exists, so a tap that does
/// nothing is a compliance problem, not a cosmetic one.
///
/// These tests pin the failure that shipped: the handler gated on
/// `canLaunchUrl`, which Android 11+ package visibility answers `false` for on
/// ordinary https URLs unless the manifest declares a matching `<queries>`
/// intent — so both links silently no-opped on Android.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// URLs handed to the platform, in call order.
  late List<String> launched;

  /// Whether the platform accepts the launch. False models a device with no
  /// Custom Tabs provider, which makes the in-app browser view unavailable.
  late bool launchSucceeds;

  setUp(() {
    launched = <String>[];
    launchSucceeds = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncherChannel, (call) async {
          switch (call.method) {
            // Android 11+ reports "no handler visible" for https without a
            // <queries> declaration, even with a browser installed. The sheet
            // must not treat that as "there is nothing to open".
            case 'canLaunch':
              return false;
            case 'launch':
              final args = call.arguments as Map<Object?, Object?>;
              launched.add(args['url']! as String);
              return launchSucceeds;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncherChannel, null);
  });

  Future<void> pumpSheet(WidgetTester tester) async {
    // Wide enough that the test font (every glyph a fixed, oversized box)
    // doesn't overflow the button rows the way a real font wouldn't.
    tester.view.physicalSize = const Size(2400, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: ImportWalletMenu(
            onGoogleSignIn: () async => null,
            onAppleSignIn: () async => null,
            onPrivateKeyTap: () {},
            onHardwareWalletTap: () {},
            onRecoveryPhraseTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Terms of Service opens the hosted terms page', (tester) async {
    await pumpSheet(tester);

    await tester.tapOnText(find.textRange.ofSubstring('Terms of Service'));
    await tester.pumpAndSettle();

    expect(launched, <String>['https://wallet.mallow.art/terms']);
  });

  testWidgets('Privacy Policy opens the hosted privacy page', (tester) async {
    await pumpSheet(tester);

    await tester.tapOnText(find.textRange.ofSubstring('Privacy Policy'));
    await tester.pumpAndSettle();

    expect(launched, <String>['https://wallet.mallow.art/privacy']);
  });

  testWidgets('falls back to an external browser when the in-app view is '
      'unavailable', (tester) async {
    launchSucceeds = false;
    await pumpSheet(tester);

    await tester.tapOnText(find.textRange.ofSubstring('Terms of Service'));
    await tester.pumpAndSettle();

    // Retried rather than abandoned: a device with no Custom Tabs provider
    // still has to be able to reach the terms.
    expect(launched, <String>[
      'https://wallet.mallow.art/terms',
      'https://wallet.mallow.art/terms',
    ]);
  });
}
