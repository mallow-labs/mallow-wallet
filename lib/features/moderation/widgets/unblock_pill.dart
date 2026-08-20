import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Compact outlined "Unblock" pill, matching the drawer header's Switch pill
/// (same padding, border and caption type) but with the label in accent.
///
/// Unblock is a low-stakes, reversible action — a full-size button oversells
/// it next to the copy it sits under.
class UnblockPill extends StatelessWidget {
  const UnblockPill({required this.onTap, super.key, this.isLoading = false});

  final VoidCallback onTap;

  /// While true the pill is inert and shows a loader in place of the label.
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final label = Text(
      'Unblock',
      style: MallowTheme.uiCaption.copyWith(color: colors.accent),
    );

    return TapTargetExpander(
      child: GestureDetector(
        onTap: isLoading ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: colors.bgSurface,
            border: Border.all(color: colors.accent),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          // Keep the label laid out under the loader so the pill doesn't
          // change width the moment the unblock call starts.
          child: isLoading
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(opacity: 0, child: label),
                    MallowLoader(size: 14, color: colors.accent),
                  ],
                )
              : label,
        ),
      ),
    );
  }
}
