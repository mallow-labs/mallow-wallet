import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'tap_target_expander.dart';

/// Collapsible "Fee details" section used by transaction confirmation
/// sheets (Confirm Purchase, Confirm Mint). Always starts collapsed;
/// tapping the header row toggles the [child] open with the same 200ms
/// easeOutCubic crossfade + `+`/`−` glyph switcher as [ExpandableText],
/// so disclosures read identically across the app.
class FeeDetailsDisclosure extends StatefulWidget {
  const FeeDetailsDisclosure({
    required this.child,
    this.label = 'Fee details',
    super.key,
  });

  final String label;
  final Widget child;

  @override
  State<FeeDetailsDisclosure> createState() => _FeeDetailsDisclosureState();
}

class _FeeDetailsDisclosureState extends State<FeeDetailsDisclosure> {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final headerStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textPrimary,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TapTargetExpander(
          child: GestureDetector(
            onTap: _toggle,
            behavior: HitTestBehavior.opaque,
            // The opaque Row already spans the full line width, so taps land
            // anywhere across the row. Extend the target 5px above and below
            // too — the thin 11px caption is otherwise an awkward hit.
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(child: Text(widget.label, style: headerStyle)),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _expanded ? '−' : '+',
                      key: ValueKey(_expanded),
                      style: headerStyle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
            child: widget.child,
          ),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }
}
