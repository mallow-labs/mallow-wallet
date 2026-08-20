import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';

/// Section header introducing tokens not on Jupiter's verified list. Matches
/// [ActivityDayHeader]'s styling so the visual language is consistent.
class UnverifiedTokensHeader extends StatelessWidget {
  const UnverifiedTokensHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: MallowTheme.spacing20,
        right: MallowTheme.spacing20,
        top: MallowTheme.spacing20,
        bottom: MallowTheme.spacingSm,
      ),
      child: Text(
        'Unverified tokens',
        style: MallowTheme.editorialQuote.copyWith(
          color: context.mallowColors.textPrimary,
        ),
      ),
    );
  }
}
