import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/mallow_theme.dart';
import 'tappable.dart';

/// A single tappable menu row inside a bottom sheet — 24px icon + label with
/// the shared disabled/destructive treatment. Used by the artwork context
/// menu and its sibling option sheets (group kebab, download destination).
class SheetMenuRow extends StatelessWidget {
  const SheetMenuRow({
    required this.label,
    required this.onTap,
    this.assetPath,
    this.subtitle,
    this.isDestructive = false,
    this.isWarning = false,
    this.enabled = true,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final String? assetPath;

  /// Optional second line under [label], in the muted caption treatment.
  ///
  /// Exists for the remote kill-switch: a row disabled by an operator carries
  /// the server's explanation here, so a greyed-out action says *why* instead
  /// of just refusing. Null keeps the original single-line layout byte for
  /// byte.
  final String? subtitle;
  final bool isDestructive;

  /// Cautionary treatment for moderation actions (Report …) — the warning
  /// token rather than [isDestructive]'s error red, which is reserved for
  /// irreversible actions on the viewer's own content (burn, delete, block).
  final bool isWarning;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final activeColor = isDestructive
        ? colors.error
        : isWarning
        ? colors.warning
        : colors.textPrimary;
    final textColor = enabled ? activeColor : colors.textTertiary;

    return Tappable(
      onTap: enabled ? onTap : null,
      semanticLabel: label,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
            vertical: 14,
          ),
          child: Row(
            children: [
              if (assetPath != null) ...[
                SvgPicture.asset(
                  assetPath!,
                  width: 24,
                  height: 24,
                  colorFilter: isDestructive && enabled
                      ? null
                      : ColorFilter.mode(textColor, BlendMode.srcIn),
                ),
                const SizedBox(width: MallowTheme.spacingMd),
              ],
              if (subtitle == null)
                Text(
                  label,
                  style: MallowTheme.uiBody.copyWith(color: textColor),
                )
              else
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: MallowTheme.uiBody.copyWith(color: textColor),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: MallowTheme.uiMeta.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
