import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
// web3dart 3.x folded crypto.dart into the root library and re-homed
// EthereumAddress/EtherAmount in package:wallet.
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/web3dart.dart';
import 'package:web3dart/web3dart.dart' as web3crypto;

void main() {
  // BIP39 official test vector mnemonic — entropy 0x00...00.
  const abandonMnemonic =
      'abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon abandon abandon about';
  // Second standard BIP39 vector to confirm the second mnemonic also
  // round-trips deterministically and produces a distinct address tree.
  const legalWinnerMnemonic =
      'legal winner thank year wave sausage worth useful legal '
      'winner thank yellow';

  group('MultiChainDerivation.deriveSolana', () {
    test('is deterministic for the same mnemonic', () async {
      final a = await MultiChainDerivation.deriveSolana(abandonMnemonic);
      final b = await MultiChainDerivation.deriveSolana(abandonMnemonic);
      expect(a.address, b.address);
    });

    test('different mnemonics produce different addresses', () async {
      final a = await MultiChainDerivation.deriveSolana(abandonMnemonic);
      final b = await MultiChainDerivation.deriveSolana(legalWinnerMnemonic);
      expect(a.address, isNot(b.address));
    });

    test('whitespace + uppercase mnemonic produce same address', () async {
      final canonical = await MultiChainDerivation.deriveSolana(
        abandonMnemonic,
      );
      final messy = await MultiChainDerivation.deriveSolana(
        '  ${abandonMnemonic.toUpperCase()}\n',
      );
      expect(canonical.address, messy.address);
    });

    test(
      'matches deriveSolanaWithAccount(account: 0) — the documented default',
      () async {
        final defaultKp = await MultiChainDerivation.deriveSolana(
          abandonMnemonic,
        );
        final explicit = await MultiChainDerivation.deriveSolanaWithAccount(
          abandonMnemonic,
          account: 0,
        );
        expect(defaultKp.address, explicit.address);
      },
    );

    test('public key bytes are 32 bytes (ed25519)', () async {
      final kp = await MultiChainDerivation.deriveSolana(abandonMnemonic);
      final pub = await kp.extractPublicKey();
      expect(pub.bytes.length, 32);
    });
  });

  group('MultiChainDerivation account-index variants', () {
    test('different account indices yield distinct addresses', () async {
      final addresses = <String>{};
      for (var i = 0; i < 5; i++) {
        addresses.add(
          await MultiChainDerivation.getSolanaAddressAtIndex(
            abandonMnemonic,
            i,
          ),
        );
      }
      expect(
        addresses.length,
        5,
        reason: 'BIP44 hardened indices must produce distinct keys',
      );
    });

    test('getSolanaAddress matches getSolanaAddressAtIndex(0)', () async {
      final fromDefault = await MultiChainDerivation.getSolanaAddress(
        abandonMnemonic,
      );
      final fromIndex = await MultiChainDerivation.getSolanaAddressAtIndex(
        abandonMnemonic,
        0,
      );
      expect(fromDefault, fromIndex);
    });

    test('getSolanaPublicKey address matches getSolanaAddress', () async {
      final pub = await MultiChainDerivation.getSolanaPublicKey(
        abandonMnemonic,
      );
      final addr = await MultiChainDerivation.getSolanaAddress(abandonMnemonic);
      expect(pub.toBase58(), addr);
    });
  });

  group('MultiChainDerivation.deriveSolanaAddresses', () {
    test('returns the requested count of distinct addresses', () async {
      final list = await MultiChainDerivation.deriveSolanaAddresses(
        abandonMnemonic,
        count: 3,
      );
      expect(list.length, 3);
      expect(list.toSet().length, 3);
    });

    test('first entry equals the canonical account-0 address', () async {
      final list = await MultiChainDerivation.deriveSolanaAddresses(
        abandonMnemonic,
        count: 2,
      );
      final canonical = await MultiChainDerivation.getSolanaAddress(
        abandonMnemonic,
      );
      expect(list.first, canonical);
    });
  });

  group('MultiChainDerivation.getSolanaAddressesAtIndices (batch isolate)', () {
    test('matches per-index derivation for the same indices', () async {
      const indices = [0, 1, 4, 9];
      final batch = await MultiChainDerivation.getSolanaAddressesAtIndices(
        abandonMnemonic,
        indices,
      );
      expect(batch.length, indices.length);

      for (var i = 0; i < indices.length; i++) {
        final perIndex = await MultiChainDerivation.getSolanaAddressAtIndex(
          abandonMnemonic,
          indices[i],
        );
        expect(
          batch[i],
          perIndex,
          reason:
              'batch derivation must agree with sequential derivation '
              'for index ${indices[i]}',
        );
      }
    });

    test('respects index ordering in input/output', () async {
      final asc = await MultiChainDerivation.getSolanaAddressesAtIndices(
        abandonMnemonic,
        [0, 1, 2],
      );
      final reversed = await MultiChainDerivation.getSolanaAddressesAtIndices(
        abandonMnemonic,
        [2, 1, 0],
      );
      expect(asc, reversed.reversed.toList());
    });

    test('handles empty index list', () async {
      final result = await MultiChainDerivation.getSolanaAddressesAtIndices(
        abandonMnemonic,
        const [],
      );
      expect(result, isEmpty);
    });
  });

  group('MultiChainDerivation path constants', () {
    test('Solana path is the BIP44 path used by Phantom/Solflare', () {
      expect(MultiChainDerivation.solanaPath, "m/44'/501'/0'/0'");
    });

    test('Ethereum path is the BIP44 ETH default', () {
      expect(MultiChainDerivation.ethereumPath, "m/44'/60'/0'/0/0");
    });
  });

  group('MultiChainDerivation.signEthereumTransaction', () {
    // A fully-populated EIP-1559 transaction, as the send flow builds it after
    // fetching nonce/gas/fees. `to`, `value`, and `data` are the only bits that
    // vary between a native-ETH and an ERC-20 send.
    Transaction nativeEthTx() => Transaction(
      to: EthereumAddress.fromHex('0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'),
      value: EtherAmount.inWei(BigInt.parse('500000000000000000')), // 0.5 ETH
      maxGas: 21000,
      maxFeePerGas: EtherAmount.inWei(BigInt.from(40000000000)),
      maxPriorityFeePerGas: EtherAmount.inWei(BigInt.from(1500000000)),
      nonce: 0,
      // data intentionally omitted (null) — a native transfer has no calldata.
    );

    test(
      'signs a native-ETH (null-data) EIP-1559 tx without a rlp-encode error',
      () async {
        // Regression: web3dart's RLP encoder throws "null cannot be rlp-encoded"
        // when a native transfer's data is null, since offline signing bypasses
        // the client default. The signer must normalize it to an empty list.
        final signed = await MultiChainDerivation.signEthereumTransaction(
          abandonMnemonic,
          0,
          nativeEthTx(),
          1,
        );
        expect(signed, isNotEmpty);
        // EIP-1559 (type-2) txs are broadcast with a leading 0x02 type byte.
        expect(signed.first, 0x02);
      },
    );

    test('imported-key path signs the same native-ETH tx', () async {
      final priv = MultiChainDerivation.privateKeyBytesFromHex(
        '4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318',
      );
      final signed = await MultiChainDerivation.signEthereumTransactionWithKey(
        priv,
        nativeEthTx(),
        1,
      );
      expect(signed, isNotEmpty);
      expect(signed.first, 0x02);
    });
  });

  group('MultiChainDerivation.encodeSignedEip1559Transaction (Ledger path)', () {
    // A Ledger returns only the raw (v, r, s); the reassembly must produce the
    // exact broadcast bytes a locally-held key would. This is the correctness
    // contract: a Ledger-signed tx must be byte-indistinguishable from a
    // seed-signed one, or it will be rejected / spend from the wrong signer.
    final priv = MultiChainDerivation.privateKeyBytesFromHex(
      '4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318',
    );

    // Pad a signature component to the 32 big-endian bytes the device emits.
    Uint8List pad32(BigInt v) {
      final raw = web3crypto.unsignedIntToBytes(v);
      final out = Uint8List(32);
      out.setRange(32 - raw.length, 32, raw);
      return out;
    }

    Future<void> expectLedgerMatchesLocal(Transaction tx, int chainId) async {
      final reference =
          await MultiChainDerivation.signEthereumTransactionWithKey(
            priv,
            tx,
            chainId,
          );
      // Simulate the device: it keccak256-hashes the exact unsigned payload we
      // hand it and secp256k1-signs, returning v (27/28) + 32-byte r/s.
      final unsigned = MultiChainDerivation.unsignedEip1559Payload(tx, chainId);
      final msgSig = web3crypto.sign(web3crypto.keccak256(unsigned), priv);
      final ledger = MultiChainDerivation.encodeSignedEip1559Transaction(
        tx,
        chainId,
        v: msgSig.v,
        r: pad32(msgSig.r),
        s: pad32(msgSig.s),
      );
      expect(ledger, equals(reference));
      expect(ledger.first, 0x02);
    }

    test('native-ETH tx matches the locally-signed bytes', () async {
      final tx = Transaction(
        to: EthereumAddress.fromHex(
          '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        ),
        value: EtherAmount.inWei(BigInt.parse('500000000000000000')),
        maxGas: 21000,
        maxFeePerGas: EtherAmount.inWei(BigInt.from(40000000000)),
        maxPriorityFeePerGas: EtherAmount.inWei(BigInt.from(1500000000)),
        nonce: 0,
      );
      await expectLedgerMatchesLocal(tx, 1);
    });

    test('ERC-20 (calldata, zero value) tx matches', () async {
      // transfer(0xdAC1…7ec7, 1_000_000) ABI-encoded calldata.
      final data = Uint8List.fromList([
        0xa9, 0x05, 0x9c, 0xbb, // transfer selector
        ...List.filled(12, 0),
        0xda, 0xC1, 0x7F, 0x95, 0x8D, 0x2e, 0xe5, 0x23,
        0xa2, 0x20, 0x62, 0x06, 0x99, 0x45, 0x97, 0xC1,
        0x3D, 0x83, 0x1e, 0xc7,
        ...List.filled(29, 0),
        0x0F, 0x42, 0x40, // 1_000_000
      ]);
      final tx = Transaction(
        to: EthereumAddress.fromHex(
          '0xdAC17F958D2ee523a2206206994597C13D831ec7',
        ),
        value: EtherAmount.zero(),
        data: data,
        maxGas: 60000,
        maxFeePerGas: EtherAmount.inWei(BigInt.from(35000000000)),
        maxPriorityFeePerGas: EtherAmount.inWei(BigInt.from(2000000000)),
        nonce: 7,
      );
      await expectLedgerMatchesLocal(tx, 1);
    });

    test('normalizes a device v of {0, 1} identically to {27, 28}', () async {
      final tx = Transaction(
        to: EthereumAddress.fromHex(
          '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
        ),
        value: EtherAmount.inWei(BigInt.one),
        maxGas: 21000,
        maxFeePerGas: EtherAmount.inWei(BigInt.from(40000000000)),
        maxPriorityFeePerGas: EtherAmount.inWei(BigInt.from(1500000000)),
        nonce: 0,
      );
      final unsigned = MultiChainDerivation.unsignedEip1559Payload(tx, 1);
      final msgSig = web3crypto.sign(web3crypto.keccak256(unsigned), priv);
      final asRaw = MultiChainDerivation.encodeSignedEip1559Transaction(
        tx,
        1,
        v: msgSig.v, // 27 or 28
        r: pad32(msgSig.r),
        s: pad32(msgSig.s),
      );
      final asParity = MultiChainDerivation.encodeSignedEip1559Transaction(
        tx,
        1,
        v: msgSig.v - 27, // 0 or 1
        r: pad32(msgSig.r),
        s: pad32(msgSig.s),
      );
      expect(asRaw, equals(asParity));
    });
  });
}
