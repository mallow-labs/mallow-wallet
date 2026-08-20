import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../shared/theme/mallow_theme.dart';

/// Section header for grouping activities by day.
class ActivityDayHeader extends StatelessWidget {
  const ActivityDayHeader({required this.date, super.key});

  final DateTime date;

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
        _formatDateHeader(date),
        style: MallowTheme.editorialQuote.copyWith(
          color: context.mallowColors.textPrimary,
        ),
      ),
    );
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dateOnly = DateTime(date.year, date.month, date.day);

    if (dateOnly == today) {
      return 'Today';
    } else if (dateOnly == yesterday) {
      return 'Yesterday';
    } else if (now.difference(date).inDays < 7) {
      // Within the last week, show day name
      return DateFormat.EEEE().format(date); // e.g., "Monday"
    } else {
      // Show as "1 Mar 2025"
      return DateFormat('d MMM yyyy').format(date);
    }
  }
}
