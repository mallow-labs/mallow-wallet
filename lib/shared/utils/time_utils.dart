/// Utility functions for time formatting.
library;

/// Formats a timestamp as a relative time string.
///
/// Examples:
/// - Just now (< 10 seconds)
/// - 30s ago (< 1 minute)
/// - 5m ago (< 1 hour)
/// - 2h ago (< 24 hours)
/// - 3d ago (< 30 days)
/// - 2mo ago (< 365 days)
/// - 1yr ago (>= 365 days)
///
/// Month/year buckets use the webapp's fixed 30/365-day intervals
/// (its `timeSince` helper) so both clients label the same event the same
/// way.
///
/// Returns empty string if [timestamp] is null.
String formatLastUpdated(DateTime? timestamp) {
  if (timestamp == null) return '';

  final now = DateTime.now();
  final diff = now.difference(timestamp);

  if (diff.isNegative) {
    // Future timestamp, shouldn't happen but handle gracefully
    return 'Just now';
  }

  if (diff.inSeconds < 10) {
    return 'Just now';
  }

  if (diff.inSeconds < 60) {
    return '${diff.inSeconds}s ago';
  }

  if (diff.inMinutes < 60) {
    return '${diff.inMinutes}m ago';
  }

  if (diff.inHours < 24) {
    return '${diff.inHours}h ago';
  }

  if (diff.inDays < 30) {
    return '${diff.inDays}d ago';
  }

  if (diff.inDays < 365) {
    return '${diff.inDays ~/ 30}mo ago';
  }

  return '${diff.inDays ~/ 365}yr ago';
}

/// Formats a timestamp as "Updated X ago" string.
///
/// Returns empty string if [timestamp] is null.
String formatUpdatedAgo(DateTime? timestamp) {
  final relative = formatLastUpdated(timestamp);
  if (relative.isEmpty) return '';
  return 'Updated $relative';
}
