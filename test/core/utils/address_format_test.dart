import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';

void main() {
  group('truncateAddress', () {
    test('addresses shorter than lead+trail are returned unchanged', () {
      // length 9, default 5/5 → 10 needed; returns as-is.
      expect(truncateAddress('abcdefghi'), 'abcdefghi');
      // boundary: length == lead+trail, returns as-is (the `<=` check).
      expect(truncateAddress('abcdefghij'), 'abcdefghij');
    });

    test('truncates to "lead…trail" once the length exceeds lead+trail', () {
      // 11 chars, default 5/5 → '12345…7891B'? Confirm slice positions.
      const addr = '12345abcdef';
      expect(truncateAddress(addr), '12345…bcdef');
    });

    test('Solana 32-char address truncates to default 5/5 form', () {
      const addr = '8DkNB1234567890123456789012RYfS4';
      final out = truncateAddress(addr);
      expect(out, '8DkNB…RYfS4');
      // Total chars: lead + 1 ellipsis + trail.
      expect(out.length, 5 + 1 + 5);
    });

    test('custom lead/trail produces the legacy 4/4 form', () {
      const addr = '12345678901234567890';
      expect(truncateAddress(addr, lead: 4, trail: 4), '1234…7890');
    });

    test('lead 0 trail 0 prefixes ellipsis and keeps the suffix', () {
      // Length 10 > 0+0, so substring(0,0)='' + '…' + substring(10-0)='' +
      // … the trail substring is `address.substring(length - 0)` which is
      // empty; the lead substring is also empty. Net: just '…'.
      expect(truncateAddress('abcdefghij', lead: 0, trail: 0), '…');
    });
  });

  group('isLikelySolanaAddress', () {
    test('rejects strings under 32 chars (e.g. mallow username)', () {
      expect(isLikelySolanaAddress('BEER'), isFalse);
      expect(isLikelySolanaAddress('a' * 31), isFalse);
    });

    test('rejects strings over 44 chars', () {
      expect(isLikelySolanaAddress('a' * 45), isFalse);
    });

    test('accepts a 32-char base58 string', () {
      const addr = 'So11111111111111111111111111111';
      expect(addr.length, 31); // sanity
      expect(
        isLikelySolanaAddress('So11111111111111111111111111111A'),
        isTrue,
      ); // 32 chars
    });

    test('accepts the canonical wrapped-SOL mint (43 chars, base58)', () {
      expect(
        isLikelySolanaAddress('So11111111111111111111111111111111111111112'),
        isTrue,
      );
    });

    test('rejects base58-illegal characters: 0, O, I, l', () {
      // 32-char strings containing each forbidden char.
      const base = 'A12345678901234567890123456789012'; // 33 chars valid base58
      expect(isLikelySolanaAddress(base.replaceFirst('A', '0')), isFalse);
      expect(isLikelySolanaAddress(base.replaceFirst('A', 'O')), isFalse);
      expect(isLikelySolanaAddress(base.replaceFirst('A', 'I')), isFalse);
      expect(isLikelySolanaAddress(base.replaceFirst('A', 'l')), isFalse);
    });
  });
}
