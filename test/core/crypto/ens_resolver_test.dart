import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/ens_resolver.dart';

void main() {
  group('EnsResolver.isEthDomain', () {
    test('accepts a normal .eth domain', () {
      expect(EnsResolver.isEthDomain('mallow.eth'), isTrue);
    });

    test('rejects bare ".eth" with no name (length <= 4)', () {
      // The guard requires length > 4 to keep the resolver from issuing a
      // request for an empty name.
      expect(EnsResolver.isEthDomain('.eth'), isFalse);
    });

    test('rejects strings without the .eth suffix', () {
      expect(EnsResolver.isEthDomain('mallow'), isFalse);
      expect(EnsResolver.isEthDomain('mallow.sol'), isFalse);
      expect(EnsResolver.isEthDomain(''), isFalse);
    });

    test('is case-insensitive and trims surrounding whitespace', () {
      expect(EnsResolver.isEthDomain('MALLOW.ETH'), isTrue);
      expect(EnsResolver.isEthDomain('  mallow.eth  '), isTrue);
      expect(EnsResolver.isEthDomain('mallow.Eth'), isTrue);
    });

    test('a raw Ethereum address is NOT a .eth domain', () {
      expect(
        EnsResolver.isEthDomain('0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045'),
        isFalse,
      );
    });
  });
}
