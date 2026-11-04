import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tells the browser's WebView which of its edges the browser chrome covers,
/// so the page treats them as unsafe: it keeps fixed and sticky elements
/// clear of the bars while its content still scrolls beneath them, and its
/// scroll range grows by the same insets so the end of the page can scroll
/// out from under the bottom bar.
///
/// Only iOS 26 and later can do this (`WKWebView.obscuredContentInsets`).
/// Everywhere else [supported] is false and the browser lays its WebView out
/// between the bars instead. On Android the page may still run under the
/// bottom bar, but only while a probe finds that safe for it (see
/// `BrowserBottomOverlay`).
class BrowserObscuredInsets {
  BrowserObscuredInsets._();

  static const _channel = MethodChannel('mallow_wallet/browser_insets');
  static Future<bool>? _supported;

  /// Overrides [supported] in tests.
  @visibleForTesting
  static bool? debugSupported;

  /// Whether the WebView may sit under the bars.
  static Future<bool> supported() {
    if (debugSupported case final value?) return Future.value(value);
    return _supported ??= _query();
  }

  static Future<bool> _query() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } on Exception {
      return false;
    }
  }

  /// Applies [top] and [bottom] (logical pixels) to the WebView laid out at
  /// [frame] in global coordinates. Returns how many WebViews took them: 0
  /// while the platform view is not attached yet, so the caller retries.
  static Future<int> apply(
    Rect frame, {
    required double top,
    required double bottom,
  }) async {
    try {
      return await _channel.invokeMethod<int>('apply', {
            'x': frame.left,
            'y': frame.top,
            'width': frame.width,
            'height': frame.height,
            'top': top,
            'bottom': bottom,
          }) ??
          0;
    } on Exception {
      return 0;
    }
  }
}
