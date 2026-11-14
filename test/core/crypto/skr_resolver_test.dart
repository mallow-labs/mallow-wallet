import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/skr_resolver.dart';

/// `alice.skr`'s name account, captured from mainnet: a live, never-expiring
/// name owned by [_aliceOwner].
const _aliceAccount =
    'REhYLA+nZ/PQkRssJac6RUW3MEbYZkOSyaLiM38ITowKt0gsuxZTurb+VmlF5SZPZPrX+lKc'
    '8UCIiVO180uF8+BCwZ6onvndAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAKHSn2gAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _aliceOwner = 'DKL92bc1PSzTTpaTX3qpN8zMRQZrwdtUFfjomXCDKimr';

const _now = 1793404800; // 2026-10-31

/// [_aliceAccount] with [bytes] written at [offset].
List<int> _aliceWith(int offset, List<int> bytes) =>
    base64Decode(_aliceAccount)..setRange(offset, offset + bytes.length, bytes);

List<int> _u64(int value) =>
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List();

void main() {
  group('SkrResolver.isSkrDomain', () {
    test('accepts a .skr name, case- and whitespace-insensitively', () {
      expect(SkrResolver.isSkrDomain('alice.skr'), isTrue);
      expect(SkrResolver.isSkrDomain('  Alice.SKR '), isTrue);
    });

    test('rejects a bare suffix and other TLDs', () {
      expect(SkrResolver.isSkrDomain('.skr'), isFalse);
      expect(SkrResolver.isSkrDomain('alice.sns'), isFalse);
      expect(SkrResolver.isSkrDomain('alice'), isFalse);
    });
  });

  group('SkrResolver.deriveNameAccount', () {
    // Pinned to Solana Mobile's `@solana-mobile/skr-domain` derivation.
    test('derives the name account under the .skr parent', () async {
      expect(
        (await SkrResolver.deriveNameAccount('alice.skr'))!.toBase58(),
        '82VxVcUmTZJF7WdwfJtrGToaek6jiyD6jA4MP9JCTvTv',
      );
      expect(
        (await SkrResolver.deriveNameAccount(' BOB.skr '))!.toBase58(),
        'CD54AC2CArrd7WXXJttGgzmdFvKc94kEcWfzEnWHGe46',
      );
    });

    test('rejects subdomains and empty labels', () async {
      expect(await SkrResolver.deriveNameAccount('sub.alice.skr'), isNull);
      expect(await SkrResolver.deriveNameAccount('.skr'), isNull);
    });
  });

  group('SkrResolver.resolveFromAccount', () {
    test('a live name resolves to its owner', () {
      expect(
        SkrResolver.resolveFromAccount(
          base64Decode(_aliceAccount),
          nowSeconds: _now,
        ),
        _aliceOwner,
      );
    });

    test('a missing or truncated account does not resolve', () {
      expect(SkrResolver.resolveFromAccount(null, nowSeconds: _now), isNull);
      expect(
        SkrResolver.resolveFromAccount(
          base64Decode(_aliceAccount).sublist(0, 199),
          nowSeconds: _now,
        ),
        isNull,
      );
    });

    test('an expired name does not resolve — anyone can re-register it', () {
      expect(
        SkrResolver.resolveFromAccount(
          _aliceWith(104, _u64(_now - 1)),
          nowSeconds: _now,
        ),
        isNull,
      );
      expect(
        SkrResolver.resolveFromAccount(
          _aliceWith(104, _u64(_now + 1)),
          nowSeconds: _now,
        ),
        _aliceOwner,
      );
    });

    test('an account under another parent does not resolve', () {
      expect(
        SkrResolver.resolveFromAccount(
          _aliceWith(8, List<int>.filled(32, 7)),
          nowSeconds: _now,
        ),
        isNull,
      );
    });

    test('an off-curve owner (NFT-wrapped name) does not resolve', () {
      // The SNS root account is a PDA, so it stands in for the Name House
      // NFT-record PDA a wrapped name is owned by.
      final pda = base64Decode('PVPCSzg2DtOBOiPfst/YIKtYIct5KaONLqqyUug4JZU=');
      expect(
        SkrResolver.resolveFromAccount(_aliceWith(40, pda), nowSeconds: _now),
        isNull,
      );
    });
  });
}
