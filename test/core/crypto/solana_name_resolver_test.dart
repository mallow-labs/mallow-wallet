import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/solana_name_resolver.dart';

void main() {
  group('SolanaNameResolver.isDomain', () {
    test('accepts .sns, legacy .sol and .skr', () {
      expect(SolanaNameResolver.isDomain('alice.sns'), isTrue);
      expect(SolanaNameResolver.isDomain('alice.sol'), isTrue);
      expect(SolanaNameResolver.isDomain('alice.skr'), isTrue);
    });

    test('rejects .eth, bare names and addresses', () {
      expect(SolanaNameResolver.isDomain('alice.eth'), isFalse);
      expect(SolanaNameResolver.isDomain('alice'), isFalse);
      expect(
        SolanaNameResolver.isDomain(
          'So11111111111111111111111111111111111111112',
        ),
        isFalse,
      );
    });
  });

  group('SolanaNameResolver.notice', () {
    test('warns on a .sol name and names the .sns it was read as', () {
      final notice = SolanaNameResolver.notice('Alice.sol');
      expect(notice, contains('alice.sns'));
    });

    test('says nothing for .sns and .skr', () {
      expect(SolanaNameResolver.notice('alice.sns'), isNull);
      expect(SolanaNameResolver.notice('alice.skr'), isNull);
    });
  });
}
