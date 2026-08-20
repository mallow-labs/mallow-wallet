import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart' show GoogleFonts;

/// Guards the offline-fonts setup: every GoogleFonts (family, weight, style)
/// combination used in lib/ must resolve from assets/fonts/ with runtime
/// fetching disabled (as configured in main.dart). A missing variant here
/// means text would silently render in the platform fallback font on device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  test('all Inter variants used in the app are bundled', () async {
    for (final weight in [FontWeight.w400, FontWeight.w500, FontWeight.w600]) {
      GoogleFonts.inter(fontWeight: weight);
    }
    await expectLater(GoogleFonts.pendingFonts(), completes);
  });

  test('all Newsreader variants used in the app are bundled', () async {
    for (final weight in [FontWeight.w400, FontWeight.w500, FontWeight.w600]) {
      GoogleFonts.newsreader(fontWeight: weight, fontStyle: FontStyle.italic);
    }
    await expectLater(GoogleFonts.pendingFonts(), completes);
  });

  // The other half of the same setup, and the half nothing else would catch:
  // bundling a font is a licence obligation, not just an asset decision. The
  // OFL text ships beside each family, but it only reaches the user through
  // the app's license page if `main.dart` registers it — Flutter collects
  // LICENSE files from packages, never from an asset. Geist was bundled and
  // used for the entire UI while only Inter and Newsreader were registered,
  // and nothing failed: an unregistered licence is invisible at build time,
  // at analyze time and on device.
  test('every bundled OFL licence is registered in main.dart', () {
    final bundled =
        Directory('assets/fonts')
            .listSync()
            .map((e) => e.path.split(Platform.pathSeparator).last)
            .where((name) => name.endsWith('-OFL.txt'))
            .toList()
          ..sort();
    expect(bundled, isNotEmpty, reason: 'no OFL files found in assets/fonts');

    final main = File('lib/main.dart').readAsStringSync();
    for (final licence in bundled) {
      expect(
        main.contains('assets/fonts/$licence'),
        isTrue,
        reason:
            '$licence ships but LicenseRegistry never yields it, so the '
            "app's license page omits that family. Add a "
            'LicenseEntryWithLineBreaks for it in main.dart.',
      );
    }
  });
}
