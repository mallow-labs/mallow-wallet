import 'package:flutter/material.dart';

/// A single-line label that always lays out as wide as the widest of
/// [reserve], so a control that toggles its text (Follow / Following) keeps
/// the same footprint in every state and never shifts its neighbours.
///
/// Only [text] is painted and announced; the reserved labels are measured but
/// invisible, and hidden from semantics. [text] is included in the measurement
/// itself, so a label missing from [reserve] can never be clipped.
class StableWidthText extends StatelessWidget {
  const StableWidthText(
    this.text, {
    super.key,
    required this.reserve,
    this.style,
  });

  final String text;

  /// Every label the control can show.
  final List<String> reserve;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        for (final label in reserve.where((l) => l != text))
          ExcludeSemantics(
            child: Opacity(
              opacity: 0,
              child: Text(label, maxLines: 1, style: style),
            ),
          ),
        Text(text, maxLines: 1, textAlign: TextAlign.center, style: style),
      ],
    );
  }
}
