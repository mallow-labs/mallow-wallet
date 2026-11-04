import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Puts the browser's WebViews on the wallet's theme instead of the system's.
///
/// An iOS WebView takes its appearance from the system, and the wallet's
/// theme can differ from it: the wallet defaults to dark whatever the system
/// is set to. Two things then disagree with the browser around the page:
///
/// - Pages read the system's `prefers-color-scheme`.
/// - Where a page has no background of its own to offer, WebKit paints the
///   area outside it in the system background, pure white or pure black. On
///   iOS 26 the page starts below the address bar, so that area is a visible
///   band under the bar whenever the page is scrolled to the top.
///
/// [apply] sets the WebViews' interface style to the wallet's brightness, so
/// both follow the wallet. It deliberately leaves `underPageBackgroundColor`
/// alone: WebKit also uses that colour for the fills it paints under the bars
/// on iOS 26, and overriding it left the area under the floating pills
/// showing the wallet's background instead of the page.
///
/// Android is left alone. Its WebView is laid out between the bars, so it
/// never shows that area.
class BrowserAppearance {
  BrowserAppearance._();

  static const _channel = MethodChannel('mallow_wallet/browser_appearance');

  /// Gives the app's WebViews the dark or the light interface style.
  static Future<void> apply({required bool dark}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>('apply', {'dark': dark});
    } on Exception {
      // An older native build without the channel keeps the system style.
    }
  }
}
