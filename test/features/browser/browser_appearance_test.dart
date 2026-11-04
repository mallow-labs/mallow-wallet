import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/browser_appearance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mallow_wallet/browser_appearance');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sends only the brightness on iOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await BrowserAppearance.apply(dark: true);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'apply');
    expect(calls.single.arguments, {'dark': true});
  });

  test('sends every call, repeats included', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await BrowserAppearance.apply(dark: false);
    await BrowserAppearance.apply(dark: false);
    expect(calls, hasLength(2));
  });

  test('a native build without the channel does not throw', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await BrowserAppearance.apply(dark: true);
  });

  test('does nothing on Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await BrowserAppearance.apply(dark: true);
    expect(calls, isEmpty);
  });
}
