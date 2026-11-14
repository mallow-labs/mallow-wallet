import 'dart:async';

import 'package:flutter/widgets.dart';

/// Lets whatever a Google or Apple sign-in shows afterwards wait for where
/// the sign-in takes the user.
///
/// A sign-in publishes its result, and the app shell answers by making the
/// new wallet the active one and replacing the screen the sign-in started
/// from: with Home, or with the app-lock setup during onboarding. That takes
/// about a second. Every screen of the app is a page of the root navigator,
/// so a sheet or a warning pushed in the meantime sits on the page that is
/// about to be replaced and is removed with it — dismissed by the app, not by
/// its reader.
///
/// The app shell calls [begin] the moment a result reaches it and runs the
/// callback it gets back once the navigation has been issued (also when its
/// routing fails). A notice awaits [settled] before it shows anything.
class SocialSignInRouting {
  SocialSignInRouting._();

  static final SocialSignInRouting instance = SocialSignInRouting._();

  /// How long [settled] waits for a routing that does not end. A notice
  /// shown over a page that is then replaced is asked again at the next
  /// check; a notice that never shows is not.
  static const settleTimeout = Duration(seconds: 20);

  /// A backgrounded app draws no frames, so no wait for one is open-ended.
  static const _frameTimeout = Duration(seconds: 1);

  int _inFlight = 0;
  Completer<void>? _idle;

  /// The app shell has a sign-in result and is about to route for it. Call
  /// before the first `await` of that routing, and call the returned
  /// function when the navigation has been issued or the routing has
  /// failed. Calling it twice does nothing.
  VoidCallback begin() {
    _inFlight++;
    _idle ??= Completer<void>();
    var finished = false;
    return () {
      if (finished) return;
      finished = true;
      unawaited(_finish());
    };
  }

  Future<void> _finish() async {
    await navigationApplied();
    if (_inFlight > 0) _inFlight--;
    if (_inFlight > 0) return;
    _idle?.complete();
    _idle = null;
  }

  /// Completes when a navigation issued just now has reached the navigator.
  ///
  /// The router applies a new location on a later microtask, and the
  /// navigator swaps its pages in the build of the frame after that. Two
  /// frames cover both.
  static Future<void> navigationApplied() async {
    for (var i = 0; i < 2; i++) {
      try {
        await WidgetsBinding.instance.endOfFrame.timeout(_frameTimeout);
      } catch (_) {
        return;
      }
    }
  }

  /// Completes once no sign-in is being routed for: at once when none is,
  /// and after [timeout] at the latest.
  Future<void> settled({Duration timeout = settleTimeout}) async {
    // A result reaches the app shell through a stream, which delivers on a
    // later microtask. One turn of the event loop lets the shell call
    // [begin] before this looks.
    await Future<void>.delayed(Duration.zero);
    final idle = _idle;
    if (idle == null) return;
    await idle.future.timeout(timeout, onTimeout: () {});
  }

  /// Forget every routing in flight, so one test does not wait for another's.
  @visibleForTesting
  void reset() {
    _inFlight = 0;
    _idle?.complete();
    _idle = null;
  }
}
