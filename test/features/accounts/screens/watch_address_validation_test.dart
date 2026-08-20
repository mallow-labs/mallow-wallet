import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/accounts/screens/watch_address_screen.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

/// The watch flow persists whatever it accepts via `addViewOnlyWallet`, which
/// infers the chain with [Chain.fromAddress] — and that falls through to
/// Solana for anything it doesn't recognise. So every malformed input the
/// screen lets through becomes a permanently-empty "Solana" watch wallet that
/// is sent as an owner on every feed read with no way for the user to tell
/// what went wrong. These cases pin the gate that stops that.
void main() {
  const solana = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const ethereum = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
  const tezos = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

  group('isWatchableAddress', () {
    test('accepts a checksummed Ethereum address', () {
      expect(isWatchableAddress(ethereum), isTrue);
      expect(Chain.fromAddress(ethereum), Chain.ethereum);
    });

    test('rejects a 0x address truncated by one character', () {
      final truncated = ethereum.substring(0, ethereum.length - 1);
      expect(truncated.length, 41);
      // Length-only validation passed this, and Chain.fromAddress would have
      // filed it under Solana.
      expect(Chain.fromAddress(truncated), Chain.solana);
      expect(isWatchableAddress(truncated), isFalse);
    });

    test('rejects 0x input that is the right length but not hex', () {
      expect(isWatchableAddress('0x${'z' * 40}'), isFalse);
    });

    test('accepts a Solana base58 address', () {
      expect(isWatchableAddress(solana), isTrue);
      expect(Chain.fromAddress(solana), Chain.solana);
    });

    test('rejects non-base58 garbage inside the 32-44 char range', () {
      const garbage = 'not a real address!!!!!!!!!!!!!!!!!!';
      expect(garbage.length, inInclusiveRange(32, 44));
      expect(isWatchableAddress(garbage), isFalse);
    });

    test('rejects an address shorter than any supported chain', () {
      expect(isWatchableAddress('abc123'), isFalse);
    });

    test('still accepts Tezos addresses, which store as Tezos not Solana', () {
      expect(isWatchableAddress(tezos), isTrue);
      expect(Chain.fromAddress(tezos), Chain.tezos);
    });
  });
}
