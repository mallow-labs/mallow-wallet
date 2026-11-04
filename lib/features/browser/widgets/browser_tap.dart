import 'package:flutter/widgets.dart';

import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/tappable.dart';

/// A [Tappable] whose [label] is the whole accessible name: the visible text
/// inside is excluded, so a screen reader hears "3 open tabs", not "3 open
/// tabs, 3".
class BrowserTap extends StatelessWidget {
  const BrowserTap({
    required this.label,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.pressedOpacity = 0.55,
    this.minHitSize = kMinTapTarget,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedOpacity;
  final double? minHitSize;
  final Widget child;

  @override
  // Its own semantics node, so a button inside a list item or card is not
  // merged into its parent's label.
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Tappable(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: label,
      pressedOpacity: pressedOpacity,
      minHitSize: minHitSize,
      child: ExcludeSemantics(child: child),
    ),
  );
}
