import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../features/activity/widgets/activity_list_item.dart';
import '../../../features/activity/widgets/activity_day_header.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';

/// History tab content for the token detail screen.
///
/// Shows on-chain transfers for this token, sourced from Helius
/// `getTransfersByAddress`.
class TokenHistoryTab extends StatelessWidget {
  const TokenHistoryTab({
    required this.activities,
    required this.tokenMint,
    super.key,
    this.isLoadingMore = false,
    this.onActivityTap,
  });

  final List<api.Activity> activities;
  final String tokenMint;
  final bool isLoadingMore;
  final ValueChanged<api.Activity>? onActivityTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    if (activities.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingXl),
        child: Center(
          child: Text(
            'No transactions for this token yet',
            style: MallowTheme.uiCaption.copyWith(color: colors.textTertiary),
          ),
        ),
      );
    }

    // Build items with day headers
    final items = _buildItems(activities);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...items,
        if (isLoadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: MallowTheme.spacingLg),
            child: Center(child: MallowLoader(size: 18)),
          ),
        const SizedBox(height: MallowTheme.spacingXl),
      ],
    );
  }

  List<Widget> _buildItems(List<api.Activity> activities) {
    final items = <Widget>[];
    DateTime? currentDay;

    for (final activity in activities) {
      final day = DateTime(
        activity.dateTime.year,
        activity.dateTime.month,
        activity.dateTime.day,
      );

      if (day != currentDay) {
        currentDay = day;
        items.add(ActivityDayHeader(date: day));
      }

      items.add(
        Builder(
          builder: (context) => Column(
            children: [
              ActivityListItem(
                activity: activity,
                tokenMintContext: tokenMint,
                onTap: onActivityTap == null
                    ? null
                    : () => onActivityTap!(activity),
              ),
              Divider(
                height: 1,
                indent: MallowTheme.spacing20,
                endIndent: MallowTheme.spacing20,
                color: context.mallowColors.dividerLight,
              ),
            ],
          ),
        ),
      );
    }

    return items;
  }
}
