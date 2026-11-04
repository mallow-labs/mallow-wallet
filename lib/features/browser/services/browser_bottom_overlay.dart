/// Decides whether the page may run under the browser's bottom bar where the
/// WebView cannot be told the bar covers it (Android).
///
/// iOS 26 makes the covered strip unsafe for every page through
/// `WKWebView.obscuredContentInsets`. Android has no equivalent: a page laid
/// out under the bar would keep its fixed bottom UI (a dapp's main button, a
/// tab bar) beneath the pills, and the end of the page could never scroll out
/// from under them. So the page floats under the bar only while a probe of
/// the page finds neither problem, and the browser adds scroll room at its end.
/// Otherwise the WebView stops at the bar, as it always did.
///
/// The probe can disagree with itself as the page settles, and every change
/// resizes the WebView, so the two directions are not symmetric:
///
/// - Back to the bar at once on any report that the strip is unsafe: a
///   covered button is worse than a strip.
/// - Under the bar only after [_confirmations] reports in a row agree.
/// - A page that has left the overlay [_maxExits] times within [_exitWindow]
///   stays at the bar for the rest of the document.
class BrowserBottomOverlay {
  static const _confirmations = 2;
  static const _maxExits = 3;
  static const _exitWindow = Duration(seconds: 10);

  /// The page runs under the bottom bar.
  bool get overlay => _overlay;
  bool _overlay = false;

  int _agreeing = 0;
  bool _pinned = false;
  final List<DateTime> _exits = [];

  /// Takes one probe result: whether the strip under the bar is safe for the
  /// page. Returns whether [overlay] changed.
  bool report(bool safe, {DateTime? now}) {
    if (!safe) {
      _agreeing = 0;
      if (!_overlay) return false;
      _overlay = false;
      final at = now ?? DateTime.now();
      _exits
        ..add(at)
        ..removeWhere((exit) => at.difference(exit) > _exitWindow);
      if (_exits.length >= _maxExits) _pinned = true;
      return true;
    }
    if (_overlay || _pinned) return false;
    if (++_agreeing < _confirmations) return false;
    _agreeing = 0;
    _overlay = true;
    return true;
  }

  /// A new document starts its own count. The current mode carries over, so
  /// navigating within a site does not resize the WebView on every page; the
  /// first probe of the new document corrects it.
  void newDocument() {
    _agreeing = 0;
    _pinned = false;
    _exits.clear();
  }
}
