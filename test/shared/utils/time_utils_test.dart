import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/time_utils.dart';

void main() {
  group('formatLastUpdated', () {
    test('null timestamp -> empty string (caller uses isEmpty as a guard)', () {
      expect(formatLastUpdated(null), '');
    });

    test('< 10s ago -> "Just now"', () {
      final t = DateTime.now().subtract(const Duration(seconds: 3));
      expect(formatLastUpdated(t), 'Just now');
    });

    test('10s..59s -> "<s>s ago"', () {
      final t = DateTime.now().subtract(const Duration(seconds: 30));
      expect(formatLastUpdated(t), endsWith('s ago'));
      expect(formatLastUpdated(t), '30s ago');
    });

    test('1m..59m -> "<m>m ago"', () {
      final t = DateTime.now().subtract(const Duration(minutes: 5));
      expect(formatLastUpdated(t), '5m ago');
    });

    test('1h..23h -> "<h>h ago"', () {
      final t = DateTime.now().subtract(const Duration(hours: 2));
      expect(formatLastUpdated(t), '2h ago');
    });

    test('1d..29d -> "<d>d ago"', () {
      final t = DateTime.now().subtract(const Duration(days: 3));
      expect(formatLastUpdated(t), '3d ago');
    });

    // Month/year buckets mirror the webapp's fixed 30/365-day intervals
    // so both clients label the same event the same way.
    test('30d..364d -> "<mo>mo ago" (not a growing day count)', () {
      final t = DateTime.now().subtract(const Duration(days: 75));
      expect(formatLastUpdated(t), '2mo ago');
    });

    test('>= 365d -> "<yr>yr ago"', () {
      final t = DateTime.now().subtract(const Duration(days: 400));
      expect(formatLastUpdated(t), '1yr ago');
    });

    test('future timestamp falls back to "Just now" (clock drift safety)', () {
      final t = DateTime.now().add(const Duration(seconds: 30));
      expect(formatLastUpdated(t), 'Just now');
    });

    test('exactly 1 minute is rendered in minutes, not seconds', () {
      final t = DateTime.now().subtract(const Duration(seconds: 60));
      expect(formatLastUpdated(t), '1m ago');
    });

    test('exactly 1 hour is rendered in hours', () {
      final t = DateTime.now().subtract(const Duration(minutes: 60));
      expect(formatLastUpdated(t), '1h ago');
    });

    test('exactly 24h is rendered in days', () {
      final t = DateTime.now().subtract(const Duration(hours: 24));
      expect(formatLastUpdated(t), '1d ago');
    });

    test('exactly 30 days is rendered in months, not days', () {
      final t = DateTime.now().subtract(const Duration(days: 30));
      expect(formatLastUpdated(t), '1mo ago');
    });

    test('exactly 365 days is rendered in years, not months', () {
      final t = DateTime.now().subtract(const Duration(days: 365));
      expect(formatLastUpdated(t), '1yr ago');
    });
  });

  group('formatUpdatedAgo', () {
    test('null timestamp -> empty string (no "Updated " prefix on empty)', () {
      expect(formatUpdatedAgo(null), '');
    });

    test('prefixes "Updated " when timestamp is non-null', () {
      final t = DateTime.now().subtract(const Duration(seconds: 30));
      expect(formatUpdatedAgo(t), 'Updated 30s ago');
    });
  });
}
