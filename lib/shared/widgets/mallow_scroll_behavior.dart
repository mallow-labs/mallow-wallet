import 'package:flutter/material.dart';

/// App-wide scroll behavior that uses iOS-style rubber-band overscroll on
/// every platform.
///
/// Returns [BouncingScrollPhysics] regardless of platform and suppresses the
/// overscroll indicator, so Android never shows the Material stretch/glow
/// effect — instead content can be pulled past the edge and springs back on
/// release, matching the iOS UX.
class MallowScrollBehavior extends MaterialScrollBehavior {
  const MallowScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics();

  /// Dragging any scrollable dismisses the keyboard — the platform's own
  /// affordance (`UIScrollView.keyboardDismissMode = .onDrag`), not a bar we
  /// draw. It matters most for the amount fields: they ask for a decimal
  /// numpad, and on iOS that keypad has no return key at all, so without this
  /// the only way out is tapping a bare patch of the sheet.
  ///
  /// Reliable here because [getScrollPhysics] hands back bouncing physics
  /// app-wide: a short list still moves under a drag, so the gesture is
  /// available even when there is nothing to scroll.
  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
    BuildContext context,
  ) => ScrollViewKeyboardDismissBehavior.onDrag;

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // No stretch/glow — the bouncing physics is the overscroll affordance.
    return child;
  }
}
