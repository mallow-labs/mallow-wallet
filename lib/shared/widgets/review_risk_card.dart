import 'package:flutter/material.dart';

import '../theme/mallow_theme.dart';

/// Danger-tier card for a permission or authority change: red outline, a
/// small uppercase [tag], a [title] that names the grant and a [body] saying
/// who receives it. Shown above the balance changes because a lasting grant
/// outlives the transaction that creates it.
class ReviewRiskCard extends StatelessWidget {
  const ReviewRiskCard({
    required this.tag,
    required this.title,
    this.body,
    super.key,
  });

  final String tag;
  final String title;

  /// Usually a `Text.rich` with the beneficiary as an address chip.
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final light = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: light ? 0.04 : 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colors.error.withValues(alpha: light ? 0.45 : 0.6),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: colors.error,
              borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
            ),
            child: Text(
              tag.toUpperCase(),
              style: MallowTheme.uiCaption.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                // Same pairing as the danger button: white reads on the light
                // red, the near-white text token on the dark one.
                color: light ? colors.bgSurface : colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: MallowTheme.uiTitle.copyWith(
              letterSpacing: -0.2,
              color: colors.textPrimary,
            ),
          ),
          if (body != null) ...[
            const SizedBox(height: 10),
            DefaultTextStyle.merge(
              style: MallowTheme.uiBody.copyWith(
                fontSize: 14,
                height: 1.45,
                color: colors.textPrimary,
              ),
              child: body!,
            ),
          ],
        ],
      ),
    );
  }
}
