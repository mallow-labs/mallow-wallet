import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';

/// Feedback beside the listing CTA, before any transaction is prepared.
class ListingEligibilityNotice extends StatelessWidget {
  const ListingEligibilityNotice({
    required this.message,
    required this.isChecking,
    this.onRetry,
    super.key,
  });

  final String? message;
  final bool isChecking;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacingMd),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isChecking) const MallowLoader(size: 24),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          if (!isChecking && onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
