import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';
import 'mallow_button.dart';
import 'mallow_svg_icon.dart';

/// An error view with retry action.
///
/// Displays an error message with an optional retry button.
/// Used for showing error states throughout the app.
class MallowErrorView extends StatelessWidget {
  const MallowErrorView({
    required this.message,
    super.key,
    this.onRetry,
    this.iconAsset,
    this.title,
  });

  /// Error message to display
  final String message;

  /// Optional retry callback
  final VoidCallback? onRetry;

  /// Custom icon asset path (defaults to alert triangle)
  final String? iconAsset;

  /// Optional title above the message
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MallowTheme.spacingLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MallowSvgIcon(
              iconAsset ?? 'assets/icons/alert_triangle.svg',
              width: 64,
              height: 64,
              color: context.mallowColors.textTertiary,
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            if (title != null) ...[
              Text(
                title!,
                style: MallowTheme.editorialSubhead,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: MallowTheme.spacingSm),
            ],
            Text(
              message,
              style: MallowTheme.uiMeta.copyWith(
                color: context.mallowColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: MallowTheme.spacingLg),
              MallowButton(
                label: 'Try again',
                onPressed: onRetry,
                variant: MallowButtonVariant.secondary,
                size: MallowButtonSize.small,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An empty state view.
///
/// Displays when there's no content to show (empty lists, etc.)
class MallowEmptyView extends StatelessWidget {
  const MallowEmptyView({
    required this.message,
    super.key,
    this.iconAsset,
    this.title,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? iconAsset;
  final String? title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MallowTheme.spacingLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MallowSvgIcon(
              iconAsset ?? 'assets/icons/inbox.svg',
              width: 64,
              height: 64,
              color: context.mallowColors.textTertiary,
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            if (title != null) ...[
              Text(
                title!,
                style: MallowTheme.editorialSubhead,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: MallowTheme.spacingSm),
            ],
            Text(
              message,
              style: MallowTheme.uiMeta.copyWith(
                color: context.mallowColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: MallowTheme.spacingLg),
              MallowButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}

/// A network error view with offline indicator.
class MallowNetworkErrorView extends StatelessWidget {
  const MallowNetworkErrorView({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return MallowErrorView(
      iconAsset: 'assets/icons/no_wifi.svg',
      title: 'No connection',
      message: 'Please check your internet connection and try again.',
      onRetry: onRetry,
    );
  }
}
