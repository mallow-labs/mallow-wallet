import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_svg_icon.dart';
import 'tap_target_expander.dart';

/// A dismissible banner with an icon, message, and close button.
///
/// Used for promotional/informational banners across the app
/// (e.g. staking prompt, wallet import prompt).
class DismissibleBanner extends StatelessWidget {
  const DismissibleBanner({
    required this.message,
    required this.iconAsset,
    required this.onDismiss,
    super.key,
    this.iconColor,
  });

  final String message;
  final String iconAsset;
  final VoidCallback onDismiss;

  /// Icon color override. Defaults to [context.mallowColors.accent].
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.mallowColors.bgTransparent,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      padding: const EdgeInsets.all(8),
      child: Stack(
        children: [
          Row(
            children: [
              MallowSvgIcon(
                iconAsset,
                width: 24,
                height: 24,
                color: iconColor ?? context.mallowColors.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 20),
                  child: Text(
                    message,
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: -4,
            right: -4,
            child: TapTargetExpander(
              child: GestureDetector(
                onTap: onDismiss,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: MallowSvgIcon(
                    'assets/icons/x.svg',
                    width: 12,
                    height: 12,
                    color: context.mallowColors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
