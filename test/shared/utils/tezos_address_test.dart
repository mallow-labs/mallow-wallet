import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/tezos_address.dart';
import 'package:solana/base58.dart' as base58;

/// Base58Check-encode a Tezos [prefix] + 20-byte [hash]. Mirrors the encoder in
/// `derivation.dart`; used only to synthesize valid tz2/tz3/KT1 vectors for the
/// prefix-classification tests, since mallow only *derives* tz1. The real tz1
/// vectors below independently prove the checksum-verification path against an
/// external reference (kukai), so a checksum bug in the validator would surface
/// there — this helper is not load-bearing for that guarantee.
String encodeTezos(List<int> prefix, List<int> hash) {
  final body = [...prefix, ...hash];
  final checksum = crypto.sha256
      .convert(crypto.sha256.convert(body).bytes)
      .bytes
      .sublist(0, 4);
  return base58.base58encode([...body, ...checksum]);
}

void main() {
  // Real tz1 addresses derived by MultiChainDerivation from the standard
  // kukai-crypto-swift test mnemonic (see multichain_derivation_test.dart).
  const realTz1 = [
    'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL',
    'tz1WCBJKr1rRivyCnN9hREpRAMqrLdmqDcym',
  ];

  // The 20-byte hash of the first real tz1, reused to synthesize other kinds.
  final tz1Hash = base58.base58decode(realTz1.first).sublist(3, 3 + 20);

  group('tezosAddressKind', () {
    test('accepts real tz1 addresses and classifies them as tz1', () {
      for (final addr in realTz1) {
        expect(tezosAddressKind(addr), TezosAddressKind.tz1, reason: addr);
      }
    });

    test('classifies tz2 / tz3 / KT1 by version prefix', () {
      expect(
        tezosAddressKind(encodeTezos([6, 161, 161], tz1Hash)),
        TezosAddressKind.tz2,
      );
      expect(
        tezosAddressKind(encodeTezos([6, 161, 164], tz1Hash)),
        TezosAddressKind.tz3,
      );
      expect(
        tezosAddressKind(encodeTezos([2, 90, 121], tz1Hash)),
        TezosAddressKind.kt1,
      );
    });

    test('rejects a checksum-corrupted address', () {
      // Flip the last character of a valid tz1 — a common transcription error
      // that must never be accepted as a transfer recipient.
      final addr = realTz1.first;
      final last = addr[addr.length - 1];
      final swapped = last == 'L' ? 'M' : 'L';
      final corrupted = addr.substring(0, addr.length - 1) + swapped;
      expect(corrupted, isNot(addr));
      expect(tezosAddressKind(corrupted), isNull);
    });

    test('rejects an unknown version prefix even with a valid checksum', () {
      // Base58Check is well-formed but the prefix is not a Tezos address kind.
      expect(tezosAddressKind(encodeTezos([1, 2, 3], tz1Hash)), isNull);
    });

    test('rejects a wrong-length payload', () {
      expect(
        tezosAddressKind(encodeTezos([6, 161, 159], tz1Hash.sublist(0, 19))),
        isNull,
      );
    });

    test('rejects non-Tezos strings', () {
      expect(tezosAddressKind(''), isNull);
      expect(tezosAddressKind('not-an-address'), isNull);
      // A Solana base58 pubkey decodes fine but is the wrong length/prefix.
      expect(
        tezosAddressKind('So11111111111111111111111111111111111111112'),
        isNull,
      );
      // An EVM address contains non-base58 characters (0).
      expect(
        tezosAddressKind('0x742d35Cc6634C0532925a3b844Bc454e4438f44e'),
        isNull,
      );
    });
  });

  group('isValidTezosAddress', () {
    test('true for tz1 and KT1, false for junk', () {
      expect(isValidTezosAddress(realTz1.first), isTrue);
      expect(isValidTezosAddress(encodeTezos([2, 90, 121], tz1Hash)), isTrue);
      expect(isValidTezosAddress('nope'), isFalse);
    });
  });

  group('isValidTezosImplicitAddress', () {
    test('accepts implicit accounts, rejects KT1 contracts', () {
      expect(isValidTezosImplicitAddress(realTz1.first), isTrue);
      expect(
        isValidTezosImplicitAddress(encodeTezos([6, 161, 161], tz1Hash)),
        isTrue,
      );
      expect(
        isValidTezosImplicitAddress(encodeTezos([2, 90, 121], tz1Hash)),
        isFalse,
      );
    });
  });

  // The FA send path forges a `transfer` against exactly these two values, so
  // getting either wrong moves the wrong asset (or nothing at all).
  group('parseTezosTokenRef', () {
    final kt1 = encodeTezos([2, 90, 121], tz1Hash);

    test('a bare KT1 is token id 0 — the FA1.2 and common FA2 case', () {
      expect(
        parseTezosTokenRef(kt1),
        TezosTokenRef(contract: kt1, tokenId: BigInt.zero),
      );
    });

    test('a `{KT1}-{tokenId}` suffix is an FA2 multitoken', () {
      expect(
        parseTezosTokenRef('$kt1-7'),
        TezosTokenRef(contract: kt1, tokenId: BigInt.from(7)),
      );
      // Token ids are unbounded nats on-chain, so they must not go through int.
      expect(
        parseTezosTokenRef('$kt1-99999999999999999999999')?.tokenId,
        BigInt.parse('99999999999999999999999'),
      );
    });

    test('rejects a lower-cased KT1', () {
      // The regression this guards: the balances mapper used to lower-case
      // every contract, and Base58Check is case-significant — the result no
      // longer decodes, so it can never be forged against. Recovering the case
      // from the string is impossible, so it has to be refused rather than
      // guessed at.
      expect(parseTezosTokenRef(kt1.toLowerCase()), isNull);
    });

    test('rejects non-FA mints', () {
      expect(parseTezosTokenRef(''), isNull);
      expect(parseTezosTokenRef('   '), isNull);
      // The native XTZ sentinel is not a contract.
      expect(parseTezosTokenRef('tez-native'), isNull);
      // An implicit account is not a token contract.
      expect(parseTezosTokenRef(realTz1.first), isNull);
      expect(
        parseTezosTokenRef('So11111111111111111111111111111111111111112'),
        isNull,
      );
      expect(
        parseTezosTokenRef('0x742d35Cc6634C0532925a3b844Bc454e4438f44e'),
        isNull,
      );
    });

    test('rejects a malformed token id rather than defaulting it to 0', () {
      // Silently reading `KT1…-abc` as token id 0 would transfer a *different*
      // token out of a multitoken contract.
      expect(parseTezosTokenRef('$kt1-abc'), isNull);
      expect(parseTezosTokenRef('$kt1--1'), isNull);
      expect(parseTezosTokenRef('$kt1-'), isNull);
    });
  });
}
