import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Android passkey plugin is vendored (packages/passkeys_android) for one
/// reason: upstream logs a credential response it cannot parse, and hands the
/// parse exception to Dart. The response holds the PRF output that unlocks a
/// social vault, and a JSONException's message quotes the value it could not
/// convert. This fails when a copy of a newer upstream brings either back.
///
/// The copy also leaves out two permissions upstream's manifest asks for and
/// the plugin cannot use. A library's permissions are merged into every build
/// of the app, so a newer upstream copied over would ask for them again.
void main() {
  final source = File(
    'packages/passkeys_android/android/src/main/java/com/corbado/'
    'passkeys_android/MessageHandler.java',
  ).readAsStringSync();

  test('no log line carries a credential response', () {
    final logCalls = RegExp(r'Log\.[a-z]+\([^;]*;').allMatches(source);
    expect(logCalls, isNotEmpty);
    // The two names a credential response is held under.
    final response = RegExp(r'\b(?:resp|responseJson)\b');
    for (final call in logCalls) {
      final text = call.group(0)!;
      expect(response.hasMatch(text), isFalse, reason: text);
    }
  });

  test('a response that cannot be parsed is reported without its text', () {
    final parses = RegExp(
      r'parse(?:Register|Authenticate)Response\((?:resp|responseJson)\)',
    ).allMatches(source).toList();
    expect(parses, hasLength(5));
    for (final parse in parses) {
      final after = source.substring(parse.end);
      final handler = RegExp(
        r'catch \(JSONException e\) \{([^}]*)\}',
      ).firstMatch(after)!.group(1)!;
      expect(handler.trim(), 'result.error(unreadableResponse(e));');
    }
  });

  test('the manifest asks only for the permission the plugin uses', () {
    final manifest = File(
      'packages/passkeys_android/android/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final permissions = RegExp(
      r'<uses-permission\s+android:name="([^"]+)"',
    ).allMatches(manifest).map((m) => m.group(1)).toList();
    expect(permissions, ['android.permission.USE_BIOMETRIC']);
  });
}
