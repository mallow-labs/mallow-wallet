import 'package:flutter/widgets.dart';

/// Page-route visibility and app lifecycle are independent. Resuming the app
/// must not uncover a browser behind settings or another full-screen route.
class BrowserVisibility {
  bool routeVisible = true;
  int nativeOverlays = 0;
  bool _foreground = true;
  bool _suspended = false;
  bool _externalHop = false;

  bool get canReceiveRequests =>
      routeVisible && _foreground && nativeOverlays == 0;

  /// Looser than [canReceiveRequests] for work already in flight. An external
  /// signer's activity (the Seed Vault approval) returns its result while the
  /// app is still inactive, before it resumes; backgrounding still cancels.
  bool get canContinueRequests =>
      routeVisible && !_suspended && nativeOverlays == 0;

  /// Only a covering page route drops the WebView. Backgrounding and the app
  /// lock cover the page but keep it, so returning finds it as it was left:
  /// rebuilding the view reloads the site and loses its state.
  bool get retainWebView => routeVisible;
  bool get coverWebView => !_foreground || !routeVisible;

  /// The user is about to leave for a page they opened from the review UI
  /// (the Explorer simulation link). The next hide/pause is theirs, not a
  /// real backgrounding: the pending request and the page survive it, and
  /// the next resume ends the hop. New requests stay blocked while away, and
  /// the app lock still cancels everything if they are gone long enough.
  void beginExternalHop() => _externalHop = true;

  /// The launch failed, so no hop happened.
  void endExternalHop() => _externalHop = false;

  /// Inactive covers private content while preserving an in-flight native
  /// biometric prompt. Actual backgrounding also cancels unsigned work; the
  /// app-lock callback independently cancels on lock.
  bool updateLifecycle(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    final backgrounded =
        state == AppLifecycleState.detached ||
        (!_externalHop &&
            (state == AppLifecycleState.hidden ||
                state == AppLifecycleState.paused));
    if (backgrounded) _suspended = true;
    if (_foreground) {
      _suspended = false;
      _externalHop = false;
    }
    return backgrounded;
  }
}

/// Native review dialogs are PopupRoutes and deliberately leave the current
/// request alive. A covering PageRoute always suspends the website instead.
final browserPageRouteObserver = RouteObserver<PageRoute<dynamic>>();
