import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/shared/utils/user_display.dart';

void main() {
  // Long base58-like address to exercise the truncation path.
  const address = 'AbCdEfGhIjKlMnOpQrStUvWxYz1234567890ABCDEFGH';
  const ethereumAddress = '0x742d35Cc6634C0532925a3b844Bc454e4438f44e';
  // Helper to compute the canonical truncated form so this test stays in
  // lockstep with the address_format implementation.
  final truncated = truncateAddress(address);

  group('formatUsernameOrAddress', () {
    test('returns username when non-empty', () {
      expect(
        formatUsernameOrAddress(username: 'alice', address: address),
        'alice',
      );
    });

    test('falls back to truncated address when username is null or empty', () {
      expect(formatUsernameOrAddress(address: address), truncated);
      expect(
        formatUsernameOrAddress(username: '', address: address),
        truncated,
      );
    });

    test('returns empty string when neither is set', () {
      expect(formatUsernameOrAddress(), '');
      expect(formatUsernameOrAddress(username: '', address: ''), '');
      // Explicit nulls behave the same as omitted arguments.
      // ignore: avoid_redundant_argument_values
      expect(formatUsernameOrAddress(username: null, address: null), '');
    });

    test('does not prepend @ to the username', () {
      expect(formatUsernameOrAddress(username: 'bob'), 'bob');
    });

    test('truncates an address returned in the username field', () {
      expect(
        formatUsernameOrAddress(username: ethereumAddress),
        truncateAddress(ethereumAddress),
      );
    });
  });

  group('formatHandleOrAddress', () {
    test('prepends @ to username when set', () {
      expect(
        formatHandleOrAddress(username: 'alice', address: address),
        '@alice',
      );
    });

    test('falls back to truncated address when no username', () {
      expect(formatHandleOrAddress(address: address), truncated);
      expect(formatHandleOrAddress(username: '', address: address), truncated);
    });

    test('returns empty string when neither is set', () {
      expect(formatHandleOrAddress(), '');
      expect(formatHandleOrAddress(username: '', address: ''), '');
    });

    test('does not add @ when the username field contains an address', () {
      expect(
        formatHandleOrAddress(username: ethereumAddress),
        truncateAddress(ethereumAddress),
      );
    });
  });

  group('formatDisplayLabel', () {
    test('prefers displayName as-is (no prefix)', () {
      expect(
        formatDisplayLabel(
          displayName: 'Alice Liddell',
          username: 'alice',
          address: address,
        ),
        'Alice Liddell',
      );
    });

    test('falls back to bare username when displayName missing', () {
      expect(formatDisplayLabel(username: 'alice', address: address), 'alice');
      expect(formatDisplayLabel(displayName: '', username: 'alice'), 'alice');
    });

    test('falls back to truncated address when only address is set', () {
      expect(formatDisplayLabel(address: address), truncated);
    });

    test('truncates an address returned in the username field', () {
      expect(
        formatDisplayLabel(username: ethereumAddress),
        truncateAddress(ethereumAddress),
      );
    });

    test('returns empty when nothing is set', () {
      expect(formatDisplayLabel(), '');
      expect(
        formatDisplayLabel(displayName: '', username: '', address: ''),
        '',
      );
    });

    test('empty displayName does not block username fallback', () {
      // Regression guard: a present-but-empty displayName must not short
      // circuit and leave us with an empty label when a username exists.
      expect(formatDisplayLabel(displayName: '', username: 'alice'), 'alice');
    });
  });
}
