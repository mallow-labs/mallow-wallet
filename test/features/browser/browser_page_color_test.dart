import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/widgets/browser_webview_host.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

void main() {
  const clear = [0, 0, 0, 0];
  const white = [255, 255, 255, 255];
  const navy = [16, 24, 64, 255];
  const coral = [255, 159, 143, 255];

  test('the root background wins over the body and the theme colour', () {
    expect(
      pickBrowserPageColor({'root': navy, 'body': white, 'theme': coral}),
      const Color(0xFF101840),
    );
  });

  test('a clear root falls through to the body, as CSS paints the canvas', () {
    expect(
      pickBrowserPageColor({'root': clear, 'body': white, 'theme': coral}),
      const Color(0xFFFFFFFF),
    );
  });

  test('a page with no background of its own offers its theme colour', () {
    expect(
      pickBrowserPageColor({'root': clear, 'body': clear, 'theme': coral}),
      const Color(0xFFFF9F8F),
    );
    expect(
      pickBrowserPageColor({'root': clear, 'body': null, 'theme': coral}),
      const Color(0xFFFF9F8F),
    );
  });

  test('translucent colours are never used', () {
    // A half-transparent root draws over a backdrop the page cannot see, so
    // neither it nor the body under it says what is on screen.
    expect(
      pickBrowserPageColor({
        'root': [255, 255, 255, 128],
        'body': navy,
        'theme': null,
      }),
      isNull,
    );
    expect(
      pickBrowserPageColor({
        'root': clear,
        'body': [16, 24, 64, 254],
        'theme': [255, 159, 143, 10],
      }),
      isNull,
    );
  });

  test('nothing usable gives null, so the browser keeps its own colour', () {
    expect(pickBrowserPageColor(null), isNull);
    expect(pickBrowserPageColor('{not json'), isNull);
    expect(pickBrowserPageColor(const ['not', 'a', 'map']), isNull);
    expect(
      pickBrowserPageColor({'root': clear, 'body': clear, 'theme': null}),
      isNull,
    );
    expect(
      pickBrowserPageColor({
        'root': ['255', 255, 255, 255],
        'body': [1, 2, 3],
        'theme': {'r': 1},
      }),
      isNull,
    );
  });

  test('accepts the JSON text and fractional numbers Android returns', () {
    expect(
      pickBrowserPageColor(
        jsonEncode({
          'root': [16.0, 24.0, 64.0, 255.0],
          'body': null,
          'theme': null,
        }),
      ),
      const Color(0xFF101840),
    );
  });

  test('the system bar icons contrast with the background', () {
    final overDark = MallowTheme.systemBarsOver(Brightness.dark);
    expect(overDark.statusBarIconBrightness, Brightness.light);
    expect(overDark.systemNavigationBarIconBrightness, Brightness.light);
    expect(overDark.statusBarBrightness, Brightness.dark);
    final overLight = MallowTheme.systemBarsOver(Brightness.light);
    expect(overLight.statusBarIconBrightness, Brightness.dark);
    expect(overLight.statusBarBrightness, Brightness.light);
    expect(overLight.statusBarColor, Colors.transparent);
    expect(overLight.systemNavigationBarColor, Colors.transparent);
    expect(overLight, isA<SystemUiOverlayStyle>());
  });
}
