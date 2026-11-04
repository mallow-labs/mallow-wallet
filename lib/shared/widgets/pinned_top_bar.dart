import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_svg_icon.dart';

/// Compact top bar: back arrow, centred caption title, options kebab.
///
/// The artwork detail screen pins it permanently; the profile and collection
/// screens fade it in above their filter/sort bar once that bar pins.
class PinnedTopBar extends StatelessWidget {
  const PinnedTopBar({
    required this.onBack,
    this.title,
    this.onMenuTap,
    this.topInset = 0,
    this.backgroundColor,
    super.key,
  });

  /// Height of the row itself, excluding [topInset].
  static const double rowHeight = 48;

  final VoidCallback onBack;

  /// Centred, single-line caption. Nothing renders when null.
  final String? title;

  /// Opens the screen's options sheet. When null the kebab is omitted and its
  /// width is reserved, so [title] stays centred.
  final VoidCallback? onMenuTap;

  /// Reserved above the row — the system safe-area height when the bar sits
  /// at the very top of the screen.
  final double topInset;

  /// Defaults to `bgPrimary`.
  final Color? backgroundColor;

  static const double _iconSize = 16;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final title = this.title;
    final onMenuTap = this.onMenuTap;

    return Container(
      color: backgroundColor ?? colors.bgPrimary,
      padding: EdgeInsets.only(top: topInset),
      child: SizedBox(
        height: rowHeight,
        child: Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: MallowTheme.spacing20,
                  vertical: MallowTheme.spacingMd,
                ),
                child: MallowSvgIcon(
                  'assets/icons/arrow_left.svg',
                  width: _iconSize,
                  height: _iconSize,
                ),
              ),
            ),
            Expanded(
              child: title != null
                  ? Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textPrimary,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (onMenuTap != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onMenuTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MallowTheme.spacing20,
                    vertical: MallowTheme.spacingMd,
                  ),
                  child: MallowSvgIcon(
                    'assets/icons/dots_vertical.svg',
                    width: _iconSize,
                    height: _iconSize,
                    color: colors.textPrimary,
                  ),
                ),
              )
            else
              const SizedBox(width: MallowTheme.spacing20 * 2 + _iconSize),
          ],
        ),
      ),
    );
  }
}
