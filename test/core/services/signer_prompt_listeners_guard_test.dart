import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scanning guard that the three signer-sheet listeners in `app.dart`
/// feed `SignerPromptTracker`.
///
/// The tracker is what tells other presenters (anything that swaps, closes or
/// pushes over a sheet) that a hardware-signer sheet is on screen. Those sheets
/// pop with a bare `Navigator.of(context).pop()`, so a presenter acting under
/// them pops the wrong route. The listeners are private to `app.dart` and need
/// a live navigator plus three controllers to pump, so the link is checked
/// textually: each listener must call `opened()` immediately before it shows
/// its sheet — after every early return — and `closed()` inside that sheet's
/// `whenComplete`.
void main() {
  final source = File('lib/app.dart').readAsStringSync();

  /// The signer listeners and the call each uses to show its sheet.
  const listeners = {
    '_HardwareVerifyListenerState': 'showMallowSheet<void>(',
    '_LedgerConnectListenerState': 'showMallowSheet<void>(',
    '_KeystoneSignListenerState': 'showKeystoneSignSheet(',
  };

  /// The body of `class [name]`, up to the class's closing brace (a `}` in
  /// column 0).
  String classBody(String name) {
    final start = source.indexOf('class $name ');
    expect(start, isNonNegative, reason: '$name no longer exists in app.dart');
    final end = source.indexOf('\n}\n', start);
    expect(end, isNonNegative);
    return source.substring(start, end);
  }

  int count(String haystack, String needle) =>
      needle.allMatches(haystack).length;

  for (final MapEntry(key: name, value: show) in listeners.entries) {
    group(name, () {
      late final String body;
      setUpAll(() => body = classBody(name));

      test('opens the tracker exactly once, closes it exactly once', () {
        expect(count(body, '..opened()'), 1);
        expect(count(body, 'tracker.closed()'), 1);
        expect(count(body, show), 1);
      });

      test('opens immediately before showing, after every early return', () {
        final opened = body.indexOf('..opened()');
        final shown = body.indexOf(show);
        final guardsEnd = body.lastIndexOf('return;', opened);
        expect(opened, lessThan(shown));
        expect(
          guardsEnd,
          lessThan(opened),
          reason: 'opened() must follow every early return',
        );
        // Nothing that can bail out sits between opened() and the show call.
        expect(body.substring(opened, shown), isNot(contains('return')));
        expect(body.substring(opened, shown), isNot(contains('await')));
      });

      test('closes inside the sheet whenComplete', () {
        final shown = body.indexOf(show);
        final complete = body.indexOf('.whenComplete(', shown);
        final closed = body.indexOf('tracker.closed()', shown);
        expect(complete, isNonNegative);
        expect(closed, greaterThan(complete));
        expect(
          body.substring(complete, closed),
          isNot(contains('return')),
          reason: 'closed() must run on every path through whenComplete',
        );
      });
    });
  }

  test(
    'no other code in app.dart shows a signer sheet or touches the tracker',
    () {
      expect(count(source, 'sl<SignerPromptTracker>()'), listeners.length);
      expect(count(source, '.opened()'), listeners.length);
      expect(count(source, '.closed()'), listeners.length);
    },
  );
}
