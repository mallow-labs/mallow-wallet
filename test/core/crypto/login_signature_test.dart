import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:pointycastle/digests/blake2b.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';
// web3dart 3.x folded crypto.dart into the root library.
import 'package:web3dart/web3dart.dart';

/// Standard BIP-39 test vector (abandon…about). Index 0 derives the canonical
/// MetaMask Ethereum address asserted below.
const _abandon =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// Kukai's published 24-word Tezos vector (matches multichain_derivation_test).
const _kukai =
    'gym exact clown can answer hope sample mirror knife twenty powder super '
    'imitate lion churn almost shed chalk dust civil gadget pyramid helmet trade';

/// The exact bytes the backend signs/verifies: `<prefix>\n\ntoken:<token>`.
const _message = 'mallow Login\n\ntoken:abc123XYZ';

void main() {
  // These tests independently re-verify each signature the same way the
  // backend's `/authToken/verify` endpoint does — recovering the ETH signer
  // with secp256k1 and verifying the Tezos `edsig` over the Blake2b-hashed
  // Micheline payload with Ed25519. If the signing encoding drifts from what the
  // backend expects, these fail.

  group('Ethereum login signature (EIP-191 personal_sign)', () {
    test(
      'recovers to the wallet address (matches viem verifyMessage)',
      () async {
        final address = await MultiChainDerivation.getEthereumAddressAtIndex(
          _abandon,
          0,
        );
        expect(address, '0x9858EfFD232B4033E47d90003D41EC34EcaEda94');

        final messageBytes = utf8.encode(_message);
        final sigHex = await MultiChainDerivation.signEthereumPersonalMessage(
          _abandon,
          0,
          messageBytes,
        );

        expect(sigHex, startsWith('0x'));
        final sig = hexToBytes(sigHex);
        expect(sig.length, 65, reason: 'r(32) + s(32) + v(1)');
        final v = sig[64];
        expect(v == 27 || v == 28, isTrue, reason: 'EIP-191 recovery id');

        expect(
          _recoverPersonalSign(sigHex, messageBytes),
          address.toLowerCase(),
        );
      },
    );

    test('recovers to the wallet address at a non-zero index', () async {
      // Index 0 cannot prove the account-index component of the signing path
      // tracks the address derivation — both read `.../0` there. Signing and
      // address derivation are separate call paths, and a drifted index yields
      // a valid signature from a different wallet, which fails silently rather
      // than erroring. Recovering at index 1 is what pins the two together.
      final address = await MultiChainDerivation.getEthereumAddressAtIndex(
        _abandon,
        1,
      );
      final messageBytes = utf8.encode(_message);
      final sigHex = await MultiChainDerivation.signEthereumPersonalMessage(
        _abandon,
        1,
        messageBytes,
      );

      expect(_recoverPersonalSign(sigHex, messageBytes), address.toLowerCase());
    });

    test('is deterministic and index-specific', () async {
      final msg = utf8.encode(_message);
      final a0 = await MultiChainDerivation.signEthereumPersonalMessage(
        _abandon,
        0,
        msg,
      );
      final a0Again = await MultiChainDerivation.signEthereumPersonalMessage(
        _abandon,
        0,
        msg,
      );
      final a1 = await MultiChainDerivation.signEthereumPersonalMessage(
        _abandon,
        1,
        msg,
      );
      expect(a0, a0Again);
      expect(a0, isNot(a1));
    });
  });

  group('Tezos login signature (Micheline / Blake2b / Ed25519)', () {
    // A fixed timestamp stands in for the wallet's sign-time stamp; the backend
    // rebuilds the payload from whatever timestamp the client sends.
    const timestamp = '2024-01-01T00:00:00.000Z';
    const formatted = 'Tezos Signed Message: mallow.art $timestamp $_message';

    test('edpk re-derives the tz1 address and edsig verifies', () async {
      final address = await MultiChainDerivation.getTezosAddressAtIndex(
        _kukai,
        0,
      );
      expect(address, 'tz1TyyX7U6r6tB1uSS4aUnfKX9rj3y9NCEVL');

      final result = await MultiChainDerivation.signTezosMicheline(
        _kukai,
        0,
        formatted,
      );
      expect(result.signature, startsWith('edsig'));
      expect(result.publicKey, startsWith('edpk'));

      // The public key we hand the backend must derive back to the address it
      // is verifying (the backend's getPkhfromPk == address check).
      final pubKeyBytes = _base58CheckPayload(result.publicKey, 4); // edpk
      expect(
        MultiChainDerivation.tezosAddressFromPublicKey(
          Uint8List.fromList(pubKeyBytes),
        ),
        address,
      );

      // Replicate the backend: pack the payload, Blake2b-256 it, Ed25519-verify
      // the edsig against the edpk.
      final messageHex = _bytesToHex(utf8.encode(formatted));
      final lenHex = (messageHex.length ~/ 2).toRadixString(16).padLeft(8, '0');
      final packed = _hexToBytes('0501$lenHex$messageHex');
      final hash = _blake2b256(packed);
      final sigBytes = _base58CheckPayload(result.signature, 5); // edsig

      final ok = await verifySignature(
        message: hash,
        signature: sigBytes,
        publicKey: Ed25519HDPublicKey(pubKeyBytes),
      );
      expect(ok, isTrue);
    });

    test('packTezosMicheline matches the inline backend packing recipe', () {
      // The Ledger path streams these exact bytes to the device, which
      // Blake2b-256-hashes and signs them — so they MUST equal what the
      // seed-phrase path and the backend pack, or a hardware-signed challenge
      // would verify against a different digest and be rejected.
      final messageHex = _bytesToHex(utf8.encode(formatted));
      final lenHex = (messageHex.length ~/ 2).toRadixString(16).padLeft(8, '0');
      final expected = _hexToBytes('0501$lenHex$messageHex');

      expect(MultiChainDerivation.packTezosMicheline(formatted), expected);
    });

    test('a tampered message does not verify', () async {
      final result = await MultiChainDerivation.signTezosMicheline(
        _kukai,
        0,
        formatted,
      );
      final pubKeyBytes = _base58CheckPayload(result.publicKey, 4);
      final sigBytes = _base58CheckPayload(result.signature, 5);

      // Hash a different payload than what was signed.
      final tamperedHex = _bytesToHex(utf8.encode('$formatted tampered'));
      final lenHex = (tamperedHex.length ~/ 2)
          .toRadixString(16)
          .padLeft(8, '0');
      final hash = _blake2b256(_hexToBytes('0501$lenHex$tamperedHex'));

      final ok = await verifySignature(
        message: hash,
        signature: sigBytes,
        publicKey: Ed25519HDPublicKey(pubKeyBytes),
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

Uint8List _blake2b256(Uint8List input) {
  final digest = Blake2bDigest(digestSize: 32);
  digest.update(input, 0, input.length);
  final out = Uint8List(32);
  digest.doFinal(out, 0);
  return out;
}

/// Recover the lower-case signer address from an EIP-191 `personal_sign`
/// signature, the way the backend's viem `verifyMessage` does: rebuild the
/// `\x19Ethereum Signed Message:\n<len>` digest, then ecRecover over it.
String _recoverPersonalSign(String sigHex, List<int> messageBytes) {
  final sig = hexToBytes(sigHex);
  final prefix =
      '${String.fromCharCode(0x19)}Ethereum Signed Message:\n'
      '${messageBytes.length}';
  final digest = keccak256(
    Uint8List.fromList([...ascii.encode(prefix), ...messageBytes]),
  );
  final recoveredPubKey = ecRecover(
    digest,
    MsgSignature(
      _bytesToBigInt(sig.sublist(0, 32)),
      _bytesToBigInt(sig.sublist(32, 64)),
      sig[64],
    ),
  );
  return '0x${bytesToHex(publicKeyToAddress(recoveredPubKey))}';
}

BigInt _bytesToBigInt(List<int> bytes) =>
    bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));

String _bytesToHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
