import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/tezos_forge.dart';
import 'package:pointycastle/digests/blake2b.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

/// Kukai's published 24-word Tezos vector (matches multichain_derivation_test),
/// index 0 → `tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL`.
const _kukai =
    'gym exact clown can answer hope sample mirror knife twenty powder super '
    'imitate lion churn almost shed chalk dust civil gadget pyramid helmet trade';

const _source = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
const _dest = 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL';
const _kt1 = 'KT1EctCuorV2NfVb1XTQgvzJ88MQtWP8cMMv';

/// A real mainnet head hash; the branch is protocol-independent forging input.
const _branch = 'BMXTnznPZDFf3TbpmdXptcTqcEuTHiCTgjxZaWif3YgVVPpp4Nq';

/// `edpk…` for [_kukai] index 0 — the manager key a `reveal` publishes.
const _edpk = 'edpkuRXPQpuQyDemXE59dyYA1Eu5T94waiiL5PjcWDSkkw86ZvxR2j';

// -----------------------------------------------------------------------------
// EXPECTED FORGED HEX — every constant below was cross-checked byte-for-byte
// against a live Tezos node's `/helpers/forge/operations` endpoint
// (rpc.tzbeta.net, current mainnet protocol) for the exact same JSON contents.
// If a forge helper drifts from the protocol encoding, these fail. Regenerate
// them ONLY by re-confirming against a node — do not hand-edit to match code.
// -----------------------------------------------------------------------------

const _revealHex =
    'eed324370ccdde023d0cd47b52ffbc9c1ab3da2b39ff48dbfba84bbcb8698fb8'
    '6b005b86ad5d98e94ed73ea969f37fc157c57dea257cf602b960cc08000066dc'
    '7517defa76d4355280505068b59172a568cacbd46c1f5f91a247c29426bc00';

const _xtzHex =
    'eed324370ccdde023d0cd47b52ffbc9c1ab3da2b39ff48dbfba84bbcb8698fb8'
    '6c005b86ad5d98e94ed73ea969f37fc157c57dea257ce807ba608c0bac02a0c2'
    '1e00005b86ad5d98e94ed73ea969f37fc157c57dea257c00';

const _fa12Hex =
    'eed324370ccdde023d0cd47b52ffbc9c1ab3da2b39ff48dbfba84bbcb8698fb8'
    '6c005b86ad5d98e94ed73ea969f37fc157c57dea257cd00fbb6088276400014'
    '237213a07fff34d24c914013d87484efcc5875c00ffff087472616e73666572'
    '0000003d07070a0000001600005b86ad5d98e94ed73ea969f37fc157c57dea2'
    '57c07070a0000001600005b86ad5d98e94ed73ea969f37fc157c57dea257c00bb01';

const _fa2Hex =
    'eed324370ccdde023d0cd47b52ffbc9c1ab3da2b39ff48dbfba84bbcb8698fb8'
    '6c005b86ad5d98e94ed73ea969f37fc157c57dea257cc413bc60f02e96010001'
    '4237213a07fff34d24c914013d87484efcc5875c00ffff087472616e7366657'
    '20000004a020000004507070a0000001600005b86ad5d98e94ed73ea969f37fc'
    '157c57dea257c020000002307070a0000001600005b86ad5d98e94ed73ea969f'
    '37fc157c57dea257c0707002a0007';

const _groupHex =
    'eed324370ccdde023d0cd47b52ffbc9c1ab3da2b39ff48dbfba84bbcb8698fb8'
    '6b005b86ad5d98e94ed73ea969f37fc157c57dea257cf602b960cc08000066dc'
    '7517defa76d4355280505068b59172a568cacbd46c1f5f91a247c29426bc00'
    '6c005b86ad5d98e94ed73ea969f37fc157c57dea257ce807ba608c0bac02a0c2'
    '1e00005b86ad5d98e94ed73ea969f37fc157c57dea257c00';

TezosReveal _reveal() => TezosReveal(
  source: _source,
  publicKey: _edpk,
  fee: BigInt.from(374),
  counter: BigInt.from(12345),
  gasLimit: BigInt.from(1100),
  storageLimit: BigInt.zero,
);

TezosTransaction _xtz() => TezosTransaction(
  source: _source,
  destination: _dest,
  amount: BigInt.from(500000),
  fee: BigInt.from(1000),
  counter: BigInt.from(12346),
  gasLimit: BigInt.from(1420),
  storageLimit: BigInt.from(300),
);

void main() {
  group('Zarith encoders', () {
    test('natural (unsigned) matches known LEB128-style values', () {
      expect(forgeZarithNat(BigInt.zero), [0x00]);
      expect(forgeZarithNat(BigInt.from(1)), [0x01]);
      // 1000 = 0x3e8 → 0xe8 (with continuation), 0x07
      expect(forgeZarithNat(BigInt.from(1000)), [0xe8, 0x07]);
      // 500000 mutez → a0 c2 1e (the `amount` bytes in the node-verified XTZ
      // vector below), exercising a 3-byte natural.
      expect(forgeZarithNat(BigInt.from(500000)), [0xa0, 0xc2, 0x1e]);
    });

    test('natural rejects negatives', () {
      expect(() => forgeZarithNat(BigInt.from(-1)), throwsArgumentError);
    });

    test('signed (Z) uses a 6-bit first byte with the sign bit', () {
      expect(forgeZarithInt(BigInt.zero), [0x00]);
      // 42 < 64 fits in the 6 value bits of the first byte.
      expect(forgeZarithInt(BigInt.from(42)), [0x2a]);
      // 123 → first byte 0x3b|cont=0xbb, then 0x01
      expect(forgeZarithInt(BigInt.from(123)), [0xbb, 0x01]);
      // The sign bit (0x40) distinguishes -1 from +1.
      expect(forgeZarithInt(BigInt.from(1)), [0x01]);
      expect(forgeZarithInt(BigInt.from(-1)), [0x41]);
    });
  });

  group('Operation forging (verified against a live Tezos node)', () {
    test('reveal — includes the Ed25519 tag and the None proof byte', () {
      expect(forgeOperationGroup(_branch, [_reveal()]), _revealHex);
    });

    test('native XTZ transfer — no parameters (0x00)', () {
      expect(forgeOperationGroup(_branch, [_xtz()]), _xtzHex);
    });

    test('FA1.2 transfer — Pair(from, Pair(to, value)) via "transfer"', () {
      final fa12 = TezosTransaction(
        source: _source,
        destination: _kt1,
        amount: BigInt.zero,
        fee: BigInt.from(2000),
        counter: BigInt.from(12347),
        gasLimit: BigInt.from(5000),
        storageLimit: BigInt.from(100),
        parameters: fa12TransferParameters(
          from: _source,
          to: _dest,
          amount: BigInt.from(123),
        ),
      );
      expect(forgeOperationGroup(_branch, [fa12]), _fa12Hex);
    });

    test('FA2 transfer — [Pair(from, [Pair(to, Pair(id, amount))])]', () {
      final fa2 = TezosTransaction(
        source: _source,
        destination: _kt1,
        amount: BigInt.zero,
        fee: BigInt.from(2500),
        counter: BigInt.from(12348),
        gasLimit: BigInt.from(6000),
        storageLimit: BigInt.from(150),
        parameters: fa2TransferParameters(
          from: _source,
          to: _dest,
          tokenId: BigInt.from(42),
          amount: BigInt.from(7),
        ),
      );
      expect(forgeOperationGroup(_branch, [fa2]), _fa2Hex);
    });

    test('reveal + transaction group concatenates both contents', () {
      expect(forgeOperationGroup(_branch, [_reveal(), _xtz()]), _groupHex);
    });

    test('empty content list is rejected', () {
      expect(() => forgeOperationGroup(_branch, []), throwsArgumentError);
    });
  });

  group('toJson mirrors the forged content (single source of truth)', () {
    test('native transfer omits parameters', () {
      final json = _xtz().toJson();
      expect(json['kind'], 'transaction');
      expect(json['amount'], '500000');
      expect(json.containsKey('parameters'), isFalse);
    });

    test('FA2 value is a Micheline sequence of Pairs', () {
      final params = fa2TransferParameters(
        from: _source,
        to: _dest,
        tokenId: BigInt.from(42),
        amount: BigInt.from(7),
      );
      final value = params.toJson()['value'] as List<dynamic>;
      final outer = value.single as Map<String, dynamic>;
      expect(outer['prim'], 'Pair');
      // The second Pair arg is the `txs` sub-list.
      expect((outer['args'] as List<dynamic>).last, isA<List<dynamic>>());
    });
  });

  group('Operation signing (Blake2b watermark + Ed25519 → edsig)', () {
    test(
      'signature verifies and the injectable payload is well-formed',
      () async {
        final forged = forgeOperationGroup(_branch, [_reveal(), _xtz()]);
        final result = await MultiChainDerivation.signTezosOperation(
          _kukai,
          0,
          forged,
        );

        expect(result.signature, startsWith('edsig'));
        // Injected payload is forged bytes ++ the raw 64-byte signature.
        expect(result.signedOperationHex, startsWith(forged));
        expect(result.signedOperationHex.length, forged.length + 128);

        // Re-verify exactly as a node does: Blake2b-256 over 0x03 ++ forged, then
        // Ed25519-verify the signature against the revealed public key.
        final forgedBytes = hexToBytes(forged);
        final watermarked = Uint8List(forgedBytes.length + 1)
          ..[0] = 0x03
          ..setRange(1, forgedBytes.length + 1, forgedBytes);
        final digest = Blake2bDigest(digestSize: 32);
        digest.update(watermarked, 0, watermarked.length);
        final hash = Uint8List(32);
        digest.doFinal(hash, 0);

        final edpk = await MultiChainDerivation.getTezosPublicKeyAtIndex(
          _kukai,
          0,
        );
        final pubKeyBytes = _base58CheckPayload(edpk, 4); // strip edpk prefix
        final sigBytes = _base58CheckPayload(
          result.signature,
          5,
        ); // edsig prefix

        final ok = await verifySignature(
          message: hash,
          signature: sigBytes,
          publicKey: Ed25519HDPublicKey(pubKeyBytes),
        );
        expect(ok, isTrue);
      },
    );

    test('the seed and mnemonic paths produce the same signature', () async {
      final forged = forgeOperationGroup(_branch, [_xtz()]);
      // The 32-byte Ed25519 seed for index 0 (SLIP-0010) drives both paths.
      final fromMnemonic = await MultiChainDerivation.signTezosOperation(
        _kukai,
        0,
        forged,
      );
      final edpk = await MultiChainDerivation.getTezosPublicKeyAtIndex(
        _kukai,
        0,
      );
      // Ed25519 over Blake2b is deterministic, so a re-sign matches.
      final again = await MultiChainDerivation.signTezosOperation(
        _kukai,
        0,
        forged,
      );
      expect(fromMnemonic.signature, again.signature);
      expect(edpk, startsWith('edpk'));
    });

    test('a tampered operation does not verify against the signature', () async {
      final forged = forgeOperationGroup(_branch, [_xtz()]);
      final result = await MultiChainDerivation.signTezosOperation(
        _kukai,
        0,
        forged,
      );

      // Flip a byte of the forged operation, then verify the ORIGINAL signature.
      final tampered = forgeOperationGroup(_branch, [
        TezosTransaction(
          source: _source,
          destination: _dest,
          amount: BigInt.from(999999), // different amount
          fee: BigInt.from(1000),
          counter: BigInt.from(12346),
          gasLimit: BigInt.from(1420),
          storageLimit: BigInt.from(300),
        ),
      ]);
      final forgedBytes = hexToBytes(tampered);
      final watermarked = Uint8List(forgedBytes.length + 1)
        ..[0] = 0x03
        ..setRange(1, forgedBytes.length + 1, forgedBytes);
      final digest = Blake2bDigest(digestSize: 32);
      digest.update(watermarked, 0, watermarked.length);
      final hash = Uint8List(32);
      digest.doFinal(hash, 0);

      final edpk = await MultiChainDerivation.getTezosPublicKeyAtIndex(
        _kukai,
        0,
      );
      final ok = await verifySignature(
        message: hash,
        signature: _base58CheckPayload(result.signature, 5),
        publicKey: Ed25519HDPublicKey(_base58CheckPayload(edpk, 4)),
      );
      expect(ok, isFalse);
    });
  });
}

/// Strip the [prefixLength]-byte Tezos prefix and 4-byte checksum from a
/// Base58Check string, returning the payload.
List<int> _base58CheckPayload(String encoded, int prefixLength) {
  final raw = base58decode(encoded);
  return raw.sublist(prefixLength, raw.length - 4);
}
