import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'tap_target_expander.dart';

/// Single-line clamped text with a `+` / `−` toggle that animates open to
/// reveal the full content. Mirrors the disclosure used in the user profile
/// bio: 200ms easeOutCubic crossfade + a switcher between the two glyphs.
///
/// The toggle is only rendered when [text] would actually be truncated at
/// [collapsedMaxLines] given the available width. Short content renders as
/// plain text with no affordance.
///
/// No internal padding; callers control surrounding chrome.
class ExpandableText extends StatefulWidget {
  const ExpandableText({
    required this.text,
    this.style,
    this.collapsedMaxLines = 1,
    super.key,
  });

  final String text;
  final TextStyle? style;
  final int collapsedMaxLines;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final style =
        widget.style ??
        MallowTheme.uiCaption.copyWith(color: context.mallowColors.textPrimary);
    final textDirection = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final togglePainter = TextPainter(
          text: TextSpan(text: '+', style: style),
          textDirection: textDirection,
        )..layout();
        final reservedToggleWidth = togglePainter.width + MallowTheme.spacingSm;

        final textPainter =
            TextPainter(
              text: TextSpan(text: widget.text, style: style),
              maxLines: widget.collapsedMaxLines,
              textDirection: textDirection,
            )..layout(
              maxWidth: (constraints.maxWidth - reservedToggleWidth).clamp(
                0.0,
                double.infinity,
              ),
            );

        if (!textPainter.didExceedMaxLines) {
          return Text(widget.text, style: style);
        }

        return TapTargetExpander(
          child: GestureDetector(
            onTap: _toggle,
            behavior: HitTestBehavior.opaque,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AnimatedCrossFade(
                    firstChild: Text(
                      widget.text,
                      maxLines: widget.collapsedMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                    secondChild: Text(widget.text, style: style),
                    crossFadeState: _expanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    duration: const Duration(milliseconds: 200),
                    sizeCurve: Curves.easeOutCubic,
                  ),
                ),
                const SizedBox(width: MallowTheme.spacingSm),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _expanded ? '−' : '+',
                    key: ValueKey(_expanded),
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
