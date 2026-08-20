import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'tap_target_expander.dart';

/// Slop ring applied around every recognizer span's glyph rect, so taps in
/// the gap right next to a span wider/taller than [kMinTapTarget] (which the
/// minimum-size inflation alone wouldn't cover) still resolve to it.
const double _kGapSlop = 8;

/// A drop-in replacement for `Text.rich` that gives every recognizer-bearing
/// [TextSpan] a [kMinTapTarget]-sized effective tap area with zero layout
/// change.
///
/// The spans render byte-identically (they keep their own
/// [TapGestureRecognizer]s, so on-glyph taps and semantics behave exactly as
/// before — the span's recognizer enters the gesture arena first and wins).
/// This widget adds a fuzzy layer on top: a tap that lands near, but not on,
/// a recognizer span's glyphs — within the glyph rect inflated to
/// [minHitSize] per axis — invokes the nearest such span's recognizer.
///
/// Like [TapTargetExpander] (used internally for taps just outside the
/// paragraph itself), the expansion is bounded by the nearest ancestor render
/// box large enough to contain the tap point.
class TextSpanTapTargets extends StatefulWidget {
  const TextSpanTapTargets({
    required this.span,
    this.style,
    this.minHitSize = kMinTapTarget,
    super.key,
  });

  /// The rich text to render, unchanged.
  final InlineSpan span;

  /// Passed through to [Text.rich].
  final TextStyle? style;

  /// Minimum effective tap extent per axis for each recognizer span.
  final double minHitSize;

  @override
  State<TextSpanTapTargets> createState() => _TextSpanTapTargetsState();
}

class _TextSpanTapTargetsState extends State<TextSpanTapTargets> {
  final GlobalKey _textKey = GlobalKey();

  RenderParagraph? get _paragraph {
    final render = _textKey.currentContext?.findRenderObject();
    return render is RenderParagraph ? render : null;
  }

  /// The tap-recognizer spans of [TextSpanTapTargets.span] as
  /// (recognizer, text range) pairs, in span order.
  List<(TapGestureRecognizer, TextSelection)> _recognizerRanges() {
    final ranges = <(TapGestureRecognizer, TextSelection)>[];
    var offset = 0;
    void visit(InlineSpan span) {
      if (span is TextSpan) {
        final length = span.text?.length ?? 0;
        final recognizer = span.recognizer;
        if (recognizer is TapGestureRecognizer && length > 0) {
          ranges.add((
            recognizer,
            TextSelection(baseOffset: offset, extentOffset: offset + length),
          ));
        }
        offset += length;
        span.children?.forEach(visit);
      } else {
        // Placeholders occupy one object-replacement character.
        offset += 1;
      }
    }

    visit(widget.span);
    return ranges;
  }

  void _handleTapUp(TapUpDetails details) {
    final paragraph = _paragraph;
    if (paragraph == null) return;
    final position = paragraph.globalToLocal(details.globalPosition);

    TapGestureRecognizer? nearest;
    var nearestDistance = double.infinity;
    for (final (recognizer, selection) in _recognizerRanges()) {
      for (final box in paragraph.getBoxesForSelection(selection)) {
        final rect = box.toRect();
        // On-glyph taps never reach here (the span's recognizer wins the
        // arena), but guard anyway so they can't double-fire.
        if (rect.contains(position)) return;
        final expanded = Rect.fromCenter(
          center: rect.center,
          width: math.max(rect.width + 2 * _kGapSlop, widget.minHitSize),
          height: math.max(rect.height + 2 * _kGapSlop, widget.minHitSize),
        );
        if (!expanded.contains(position)) continue;
        final distance = (position - rect.center).distanceSquared;
        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearest = recognizer;
        }
      }
    }
    nearest?.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      minSize: widget.minHitSize,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: _handleTapUp,
        child: Text.rich(widget.span, style: widget.style, key: _textKey),
      ),
    );
  }
}
