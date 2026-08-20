import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/utils/file_size_format.dart';

void main() {
  group('formatBytes', () {
    test('values below 1 KiB render in bytes with no fractional part', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1), '1 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('1024 bytes is the KB threshold', () {
      expect(formatBytes(1024), '1.00 KB');
    });

    test('escalates to MB at 1 MiB', () {
      expect(formatBytes(1024 * 1024), '1.00 MB');
    });

    test('escalates to GB at 1 GiB', () {
      expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
    });

    test('escalates to TB at 1 TiB', () {
      const tib = 1024 * 1024 * 1024 * 1024;
      expect(formatBytes(tib), '1.00 TB');
    });

    test('caps unit escalation at TB even for absurd sizes', () {
      // 1 PiB stays in TB because the while loop is bounded by units.length-1.
      const pib = 1024 * 1024 * 1024 * 1024 * 1024;
      expect(formatBytes(pib), endsWith('TB'));
    });

    test('honours the fractionDigits override', () {
      expect(formatBytes(33800000), '32.23 MB');
      expect(formatBytes(33800000, fractionDigits: 0), '32 MB');
      expect(formatBytes(33800000, fractionDigits: 4), '32.2342 MB');
    });
  });
}
