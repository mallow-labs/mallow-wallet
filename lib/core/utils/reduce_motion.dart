import 'package:flutter/widgets.dart';

/// Reads the platform "Reduce Motion" accessibility setting (iOS Settings →
/// Accessibility → Motion → Reduce Motion; the equivalent on Android/desktop)
/// for the nearest [MediaQuery].
///
/// Use it to soften or disable non-essential motion: freeze looping loaders on
/// a single frame, skip auto-playing inline video, and jump animated controls
/// straight to their target state instead of tweening.
///
/// Because it depends on the ambient [MediaQuery], read it inside `build`
/// (or `didChangeDependencies`) — never in `initState`, where the inherited
/// widget lookup is not yet valid.
extension ReduceMotion on BuildContext {
  /// `true` when the user has asked the system to reduce motion. Defaults to
  /// `false` when no [MediaQuery] ancestor is present.
  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;
}
