import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'tappable.dart';

/// The outlined "Switch" pill that changes the active wallet: an accent outline
/// on the surface colour, its label in the caption style.
///
/// The one wallet-switch affordance shared by the account drawer, the dapp
/// connect sheet and every other sheet that offers a switch, so the control
/// reads the same wherever a wallet can be swapped. [label] defaults to "Switch"; the drawer
/// passes "Close" while its account list is showing. [semanticLabel] is what a
/// screen reader announces, for a visible label that is terse out of context.
///
/// A null [onTap] renders the pill disabled: outline and label in the tertiary
/// text colour, with no gestures and no button role.
class SwitchPill extends StatelessWidget {
  const SwitchPill({
    required this.onTap,
    this.label = 'Switch',
    this.semanticLabel,
    super.key,
  });

  final VoidCallback? onTap;
  final String label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final enabled = onTap != null;
    // Its own semantics node, so a pill inside a row or card is not merged into
    // its parent's label.
    return Semantics(
      container: true,
      child: Tappable(
        onTap: onTap,
        semanticLabel: semanticLabel ?? label,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: colors.bgSurface,
              border: Border.all(
                color: enabled ? colors.accent : colors.textTertiary,
              ),
              borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
            ),
            child: Text(
              label,
              style: MallowTheme.uiCaption.copyWith(
                color: enabled ? colors.textPrimary : colors.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
