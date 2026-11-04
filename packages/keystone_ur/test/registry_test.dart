import 'dart:typed_data';

import 'package:keystone_ur/keystone_ur.dart';
import 'package:test/test.dart';

import 'vectors/keystone_vectors.dart';

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
]);

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Decodes a complete single-part UR string.
UR decodeUr(String s) {
  final d = UrDecoder()..receivePart(s);
  return d.result!;
}

final throwsDecode = throwsA(isA<UrDecodeException>());

KeystoneKeypath path(String p, [int? fp]) => KeystoneKeypath.parse(p, sourceFingerprint: fp);

void main() {
  group('crypto-keypath', () {
    test('encodes and decodes the wildcard vector', () {
      final kp = KeystoneKeypath(
        components: const [
          KeypathComponent(44, hardened: true),
          KeypathComponent(118, hardened: true),
          KeypathComponent(0, hardened: true),
          KeypathComponent(0, hardened: false),
          KeypathComponent(null, hardened: false),
        ],
        sourceFingerprint: 0x78230804,
        depth: 5,
      );
      expect(hex(kp.toCbor()), keypathWildcardHex);
      expect(UrEncoder.encodeSinglePart(kp.toUr()), keypathWildcardUr);
      final back = KeystoneKeypath.fromCbor(unhex(keypathWildcardHex));
      expect(back, kp);
      expect(back.toPathString(), "m/44'/118'/0'/0/*");
    });

    test('encodes and decodes the concrete vector', () {
      final kp = KeystoneKeypath(
        components: path("44'/118'/0'/0/0").components,
        sourceFingerprint: 0x78230804,
        depth: 5,
      );
      expect(hex(kp.toCbor()), keypathHex);
      expect(UrEncoder.encodeSinglePart(kp.toUr()), keypathUr);
      expect(KeystoneKeypath.fromUr(decodeUr(keypathUr)), kp);
    });

    test('parse accepts m/, M/, bare, h and H forms', () {
      expect(path("m/44'/501'/0'/0'").toPathString(), "m/44'/501'/0'/0'");
      expect(path("44'/501'/0'/0'").toPathString(), "m/44'/501'/0'/0'");
      expect(path('M/44h/60H/0h/0/*').toPathString(), "m/44'/60'/0'/0/*");
      expect(path('m').components, isEmpty);
      expect(path("44'/501'", 0x12).sourceFingerprint, 0x12);
      expect(path("44'/501'").depth, isNull);
    });

    test('parse rejects garbage', () {
      for (final bad in ["m/44'/x", 'm//1', "m/2147483648'", 'm/-1', "m/44''"]) {
        expect(() => path(bad), throwsFormatException, reason: bad);
      }
    });

    test('decode rejects malformed maps', () {
      // Odd component array.
      expect(() => KeystoneKeypath.fromCbor(unhex('a10183182cf518')), throwsDecode);
      // Index with the hardening bit set.
      expect(() => KeystoneKeypath.fromCbor(unhex('a101821a80000000f5')), throwsDecode);
      // Range component ([1, 2]) is not supported.
      expect(
        () => KeystoneKeypath.fromCbor(unhex('a101828201 02f5'.replaceAll(' ', ''))),
        throwsDecode,
      );
      // Truncated.
      expect(() => KeystoneKeypath.fromCbor(unhex('a3018a182cf51876')), throwsDecode);
      // Not a map.
      expect(() => KeystoneKeypath.fromCbor(unhex('01')), throwsDecode);
    });
  });

  group('sol-sign-request', () {
    final requestId = unhex(requestIdHex);
    final signData = unhex(solSignDataHex);

    test('encodes the Rust SDK vector byte for byte', () {
      final req = SolSignRequest(
        requestId: requestId,
        signData: signData,
        path: path("m/44'/501'/0'/0'", 0x12121212),
        origin: 'solflare',
      );
      expect(hex(req.toCbor()), solSignRequestHex);
      expect(req.toUr().type, 'sol-sign-request');
    });

    test('omits the keypath depth even when the path carries one', () {
      final kp = solanaKeypath(KeystoneSolanaPath.standard, 0, 0x12121212);
      expect(kp.depth, 4);
      final req = SolSignRequest(
        requestId: requestId,
        signData: signData,
        path: kp,
        origin: 'solflare',
      );
      expect(hex(req.toCbor()), solSignRequestHex);
    });

    test('matches the JS SDK UR strings for both sign types', () {
      for (final (type, expected) in [
        (SolSignType.transaction, solSignRequestUrTx),
        (SolSignType.message, solSignRequestUrMessage),
      ]) {
        final req = SolSignRequest(
          requestId: requestId,
          signData: signData,
          path: path("m/44'/501'/0'/0'", 0x12345678),
          origin: 'solflare',
          type: type,
        );
        final encoder = UrEncoder(req.toUr(), maxFragmentLength: 1000);
        expect(encoder.isSinglePart, isTrue);
        expect(encoder.nextPart(), expected.toUpperCase());
        expect(encoder.nextPartLowercase(), expected);
      }
    });

    test('decodes the vector back', () {
      final req = SolSignRequest.fromUr(decodeUr(solSignRequestUrTx));
      expect(req.requestId, requestId);
      expect(req.signData, signData);
      expect(req.path.toPathString(), "m/44'/501'/0'/0'");
      expect(req.path.sourceFingerprint, 0x12345678);
      expect(req.origin, 'solflare');
      expect(req.type, SolSignType.transaction);
      expect(SolSignRequest.fromUr(decodeUr(solSignRequestUrMessage)).type, SolSignType.message);
    });

    test('defaults: origin mallow, transaction, never key 4', () {
      final req = SolSignRequest(
        requestId: requestId,
        signData: signData,
        path: solanaKeypath(KeystoneSolanaPath.legacy, 3, 0xdeadbeef),
      );
      final cbor = hex(req.toCbor());
      expect(cbor, startsWith('a5'));
      expect(cbor, contains('05666d616c6c6f77')); // 5: "mallow"
      expect(cbor, endsWith('0601'));
      expect(cbor, isNot(contains('0454'))); // no 4: bytes(20) …
      final back = SolSignRequest.fromCbor(req.toCbor());
      expect(back.origin, 'mallow');
      expect(back.path.toPathString(), "m/44'/501'/3'");
    });

    test('refuses an unusable request', () {
      SolSignRequest make({Uint8List? id, KeystoneKeypath? p, Uint8List? data}) => SolSignRequest(
        requestId: id ?? requestId,
        signData: data ?? signData,
        path: p ?? path("m/44'/501'/0'/0'", 1),
      );
      expect(() => make(id: Uint8List(15)).toCbor(), throwsArgumentError);
      expect(() => make(p: path("m/44'/501'/0'/0'")).toCbor(), throwsArgumentError);
      expect(() => make(p: path("m/44'/501'/0'/0'", 0)).toCbor(), throwsArgumentError);
      expect(() => make(p: path("m/44'/501'/*'", 1)).toCbor(), throwsArgumentError);
      expect(() => make(data: Uint8List(0)).toCbor(), throwsArgumentError);
    });

    test('newRequestId is a random RFC 4122 v4 UUID', () {
      final a = SolSignRequest.newRequestId();
      final b = SolSignRequest.newRequestId();
      expect(a.length, 16);
      expect(a[6] >> 4, 4);
      expect(a[8] >> 6, 2);
      expect(hex(a), isNot(hex(b)));
    });

    test('fromUr rejects malformed input', () {
      expect(
        () => SolSignRequest.fromUr(UR('sol-signature', unhex(solSignatureHex))),
        throwsDecode,
      );
      expect(
        () => SolSignRequest.fromCbor(unhex(solSignRequestHex.substring(0, 100))),
        throwsDecode,
      );
      // Sign type 3.
      final bad = '${solSignRequestHex.substring(0, solSignRequestHex.length - 2)}03';
      expect(() => SolSignRequest.fromCbor(unhex(bad)), throwsDecode);
    });
  });

  group('sol-signature', () {
    test('decodes the Rust SDK vector and the JS SDK UR', () {
      for (final ur in [UR('sol-signature', unhex(solSignatureHex)), decodeUr(solSignatureUr)]) {
        final sig = SolSignature.fromUr(ur);
        expect(hex(sig.requestId!), requestIdHex);
        expect(hex(sig.signature), signatureHex);
      }
    });

    test('encodes byte-identically, for fabricated replies', () {
      final sig = SolSignature(requestId: unhex(requestIdHex), signature: unhex(signatureHex));
      expect(hex(sig.toCbor()), solSignatureHex);
      expect(UrEncoder.encodeSinglePart(sig.toUr()), solSignatureUr);
      final noId = SolSignature(requestId: null, signature: unhex(signatureHex));
      final back = SolSignature.fromUr(noId.toUr());
      expect(back.requestId, isNull);
      expect(back.signature, unhex(signatureHex));
    });

    test('rejects duplicate signature keys in the raw CBOR map', () {
      final bytes = unhex('a2025840${'00' * 64}025840${'01' * 64}');
      expect(() => SolSignature.fromCbor(bytes), throwsDecode);
    });

    test('rejects a wrong type, a 63- or 65-byte signature, and truncation', () {
      expect(() => SolSignature.fromUr(UR('eth-signature', unhex(solSignatureHex))), throwsDecode);
      final short = SolSignature(requestId: unhex(requestIdHex), signature: Uint8List(63));
      expect(() => SolSignature.fromUr(short.toUr()), throwsDecode);
      final long = SolSignature(requestId: unhex(requestIdHex), signature: Uint8List(65));
      expect(() => SolSignature.fromUr(long.toUr()), throwsDecode);
      expect(() => SolSignature.fromCbor(unhex(solSignatureHex.substring(0, 60))), throwsDecode);
      // Request id without the uuid tag.
      expect(
        () => SolSignature.fromCbor(unhex(solSignatureHex.replaceFirst('d82550', '50'))),
        throwsDecode,
      );
      // Trailing garbage after the map.
      expect(() => SolSignature.fromCbor(unhex('${solSignatureHex}00')), throwsDecode);
      // Missing signature.
      expect(
        () => SolSignature.fromCbor(unhex('a101d8255000000000000000000000000000000000')),
        throwsDecode,
      );
    });
  });

  group('crypto-multi-accounts', () {
    test('real Solana export: six standard accounts, re-encodes identically', () {
      final ur = decodeUr(multiAccountsSolUr);
      final export = KeystoneMultiAccounts.fromUr(ur);
      expect(export.masterFingerprint, 0x23d048f0);
      expect(export.device, 'Keystone');
      expect(export.keys, hasLength(6));
      expect(hex(export.toCbor()), hex(ur.cbor));

      final accounts = solanaAccountsFromExport(export);
      expect(accounts.map((a) => a.index), [0, 1, 2, 3, 4, 5]);
      expect(accounts.every((a) => a.scheme == KeystoneSolanaPath.standard), isTrue);
      expect(accounts.every((a) => a.publicKey.length == 32), isTrue);
      expect(accounts.first.name, 'Keystone');
      expect(hex(accounts.first.publicKey), hex(export.keys.first.keyData));
      // Keystone writes depth 5 on these four-component origins; the mapper
      // must not rely on depth.
      expect(export.keys.first.origin!.depth, 5);
    });

    test('real mixed export: ETH xpub ignored, Solana legacy #0', () {
      final export = KeystoneMultiAccounts.fromUr(decodeUr(multiAccountsEthUr));
      expect(export.masterFingerprint, 0xeb16731f);
      expect(export.device, 'Keystone 3 Pro');
      expect(export.deviceVersion, '1.1.0');
      final accounts = solanaAccountsFromExport(export);
      expect(accounts, hasLength(1));
      expect(accounts.single.scheme, KeystoneSolanaPath.legacy);
      expect(accounts.single.index, 0);
      final eth = export.keys.first;
      expect(
        hex(eth.keyData),
        '03bf6bb4afd36a03ce0fd06d73e86ab21b3ff9c7ea81d2a0d25cf62e1a72a2de18',
      );
      expect(
        hex(eth.chainCode!),
        '33d3f3828fae03ec295b3ff107f83f932d8b054c99e29910c34e174470a83e57',
      );
    });

    test('firmware Backpack export: legacy accounts 0 and 1, re-encodes identically', () {
      final bytes = unhex(backpackExportHex);
      final export = KeystoneMultiAccounts.fromCbor(bytes);
      expect(hex(export.toCbor()), backpackExportHex);
      final accounts = solanaAccountsFromExport(export);
      expect(accounts.map((a) => (a.scheme, a.index)), [
        (KeystoneSolanaPath.legacy, 0),
        (KeystoneSolanaPath.legacy, 1),
      ]);
      expect(
        hex(accounts[0].publicKey),
        'e79ecfa6a398b265da28a2fdad84cf1064a8e2c29300eeb8d7fb9f6977029742',
      );
    });

    test('Rust SDK encoder vector round-trips', () {
      final bytes = unhex(multiAccountsEncodeHex);
      final export = KeystoneMultiAccounts.fromCbor(bytes);
      expect(export.masterFingerprint, 0xe9181cf3);
      expect(export.deviceId, '28475c8d80f6c06bafbe46a7d1750f3fcf2565f7');
      expect(export.deviceVersion, '1.0.0');
      expect(hex(export.toCbor()), multiAccountsEncodeHex);
    });

    test('a hand-built export round-trips through a UR string', () {
      final export = KeystoneMultiAccounts(
        masterFingerprint: 0x01020304,
        keys: [
          KeystoneHdKey(
            keyData: Uint8List(32)..fillRange(0, 32, 7),
            origin: path("m/44'/501'/2'/0'", 0x01020304),
          ),
          KeystoneHdKey(keyData: Uint8List(32), origin: path("m/44'/501'")),
        ],
        device: 'Keystone 3 Pro',
      );
      final encoder = UrEncoder(export.toUr());
      final decoder = UrDecoder(expectedTypes: {'crypto-multi-accounts'});
      while (!decoder.isComplete) {
        decoder.receivePart(encoder.nextPart());
      }
      final back = KeystoneMultiAccounts.fromUr(decoder.result!);
      expect(hex(back.toCbor()), hex(export.toCbor()));
      final accounts = solanaAccountsFromExport(back);
      expect(accounts.map((a) => (a.scheme, a.index)), [
        (KeystoneSolanaPath.standard, 2),
        (KeystoneSolanaPath.root, 0),
      ]);
    });

    test('rejects exports a Solana import cannot trust', () {
      KeystoneMultiAccounts one(String p, {int keyLen = 32, int fp = 0x0a0b0c0d, int? originFp}) =>
          KeystoneMultiAccounts(
            masterFingerprint: fp,
            keys: [KeystoneHdKey(keyData: Uint8List(keyLen), origin: path(p, originFp))],
          );
      expect(() => solanaAccountsFromExport(one("m/44'/501'/0'/0'", fp: 0)), throwsDecode);
      expect(() => solanaAccountsFromExport(one("m/44'/501'/0'/0'", keyLen: 33)), throwsDecode);
      expect(() => solanaAccountsFromExport(one("m/44'/501'/50'/0'")), throwsDecode);
      expect(() => solanaAccountsFromExport(one("m/44'/501'/50'")), throwsDecode);
      expect(() => solanaAccountsFromExport(one("m/44'/501'/0'/1'")), throwsDecode);
      expect(() => solanaAccountsFromExport(one("m/44'/501'/0'/0'/0'")), throwsDecode);
      expect(() => solanaAccountsFromExport(one("m/44'/501'/0'/0")), throwsDecode);
      expect(() => solanaAccountsFromExport(one("m/44/501/0/0")), throwsDecode);
      expect(() => solanaAccountsFromExport(one("m/44'/501'/0'/0'", originFp: 0x99)), throwsDecode);
      // The synthetic encoder vector carries a 33-byte key on a Solana path.
      expect(
        () =>
            solanaAccountsFromExport(KeystoneMultiAccounts.fromCbor(unhex(multiAccountsEncodeHex))),
        throwsDecode,
      );
      // Index 49 is the last one the device keeps.
      expect(solanaAccountsFromExport(one("m/44'/501'/49'/0'")).single.index, 49);
      // Other chains are ignored, not rejected.
      expect(solanaAccountsFromExport(one("m/44'/60'/0'", keyLen: 33)), isEmpty);
    });

    test('caps the key count', () {
      final export = KeystoneMultiAccounts(
        masterFingerprint: 1,
        keys: [
          for (var i = 0; i < 65; i++)
            KeystoneHdKey(keyData: Uint8List(32), origin: path("m/44'/501'/$i'")),
        ],
      );
      expect(() => KeystoneMultiAccounts.fromUr(export.toUr()), throwsDecode);
      expect(KeystoneMultiAccounts.fromUr(export.toUr(), maxKeys: 65).keys, hasLength(65));
    });

    test('rejects malformed CBOR and private keys', () {
      final ur = decodeUr(multiAccountsSolUr);
      expect(
        () => KeystoneMultiAccounts.fromUr(UR(ur.type, Uint8List.sublistView(ur.cbor, 0, 40))),
        throwsDecode,
      );
      expect(() => KeystoneMultiAccounts.fromUr(UR('crypto-hdkey', ur.cbor)), throwsDecode);
      // Missing keys array.
      expect(() => KeystoneMultiAccounts.fromCbor(unhex('a1011a01020304')), throwsDecode);
      // A key flagged private (2: true).
      expect(
        () => KeystoneMultiAccounts.fromCbor(
          unhex('a2011a010203040281d9012fa202f5035820${'00' * 32}'),
        ),
        throwsDecode,
      );
    });
  });

  group('solanaKeypath', () {
    test('builds the three shapes with fingerprint and depth', () {
      final std = solanaKeypath(KeystoneSolanaPath.standard, 7, 0xabcdef01);
      expect(std.toPathString(), "m/44'/501'/7'/0'");
      expect(std.sourceFingerprint, 0xabcdef01);
      expect(std.depth, 4);
      final legacy = solanaKeypath(KeystoneSolanaPath.legacy, 7, 1);
      expect(legacy.toPathString(), "m/44'/501'/7'");
      expect(legacy.depth, 3);
      final root = solanaKeypath(KeystoneSolanaPath.root, 0, 1);
      expect(root.toPathString(), "m/44'/501'");
      expect(root.depth, 2);
    });

    test('rejects impossible accounts', () {
      expect(() => solanaKeypath(KeystoneSolanaPath.standard, 50, 1), throwsArgumentError);
      expect(() => solanaKeypath(KeystoneSolanaPath.standard, -1, 1), throwsArgumentError);
      expect(() => solanaKeypath(KeystoneSolanaPath.root, 1, 1), throwsArgumentError);
      expect(() => solanaKeypath(KeystoneSolanaPath.standard, 0, 0), throwsArgumentError);
    });

    test('round-trips through an export', () {
      for (final scheme in KeystoneSolanaPath.values) {
        final index = scheme == KeystoneSolanaPath.root ? 0 : 12;
        final kp = solanaKeypath(scheme, index, 0x55667788);
        final export = KeystoneMultiAccounts(
          masterFingerprint: 0x55667788,
          keys: [KeystoneHdKey(keyData: Uint8List(32), origin: kp)],
        );
        final account = solanaAccountsFromExport(export).single;
        expect((account.scheme, account.index), (scheme, index));
      }
    });
  });

  group('ethereumStandardKeypath', () {
    test('is the BIP-44 standard address path with the fingerprint', () {
      final p = ethereumStandardKeypath(5, 0x12345678);
      expect(p.toPathString(), "m/44'/60'/0'/0/5");
      expect(p.sourceFingerprint, 0x12345678);
      expect(p.depth, 5);
    });

    test('refuses a hardened index and a missing fingerprint', () {
      expect(() => ethereumStandardKeypath(0x80000000, 1), throwsArgumentError);
      expect(() => ethereumStandardKeypath(-1, 1), throwsArgumentError);
      expect(() => ethereumStandardKeypath(0, 0), throwsArgumentError);
    });

    test('round-trips through an eth-sign-request', () {
      final req = EthSignRequest(
        requestId: EthSignRequest.newRequestId(),
        signData: Uint8List.fromList([1, 2, 3]),
        dataType: EthDataType.typedTransaction,
        chainId: 1,
        path: ethereumStandardKeypath(2, 0x12345678),
      );
      final decoded = EthSignRequest.fromUr(req.toUr());
      expect(decoded.path.toPathString(), "m/44'/60'/0'/0/2");
      expect(decoded.path.sourceFingerprint, 0x12345678);
      expect(decoded.requestId, hasLength(16));
    });
  });

  group('eth-sign-request', () {
    test('encodes the legacy Rust SDK vector byte for byte', () {
      final req = EthSignRequest(
        requestId: unhex(requestIdHex),
        signData: unhex(
          'f849808609184e72a00082271094000000000000000000000000000000000000000080a47f7465737432'
          '000000000000000000000000000000000000000000000000000000600057808080',
        ),
        dataType: EthDataType.transaction,
        chainId: 1,
        path: path("m/44'/1'/1'/0/1", 0x12345678),
        origin: 'metamask',
      );
      expect(hex(req.toCbor()), ethSignRequestLegacyHex);
      final back = EthSignRequest.fromCbor(unhex(ethSignRequestLegacyHex));
      expect(back.path.toPathString(), "m/44'/1'/1'/0/1");
      expect(back.dataType, EthDataType.transaction);
      expect(back.chainId, 1);
      expect(hex(back.signData), hex(req.signData));
    });

    test('encodes the typed-transaction (Avalanche C-chain) UR', () {
      final req = EthSignRequest(
        requestId: unhex(requestIdHex),
        signData: unhex(ethAvaxSignDataHex),
        dataType: EthDataType.typedTransaction,
        chainId: 43113,
        path: path("m/44'/60'/0'/0/6", 0xbdeee782),
        origin: 'core wallet',
      );
      expect(UrEncoder.encodeSinglePart(req.toUr()), ethSignRequestAvaxUr);
      final back = EthSignRequest.fromUr(decodeUr(ethSignRequestAvaxUr));
      expect(back.chainId, 43113);
      expect(back.origin, 'core wallet');
    });

    test('writes the address when given, and validates it', () {
      final base = EthSignRequest(
        requestId: unhex(requestIdHex),
        signData: Uint8List.fromList([1, 2, 3]),
        dataType: EthDataType.personalMessage,
        chainId: 1,
        path: path("m/44'/60'/0'/0/0", 1),
        address: Uint8List(20)..[19] = 0xAA,
      );
      final back = EthSignRequest.fromUr(base.toUr());
      expect(back.address, base.address);
      expect(back.origin, 'mallow');
      final bad = EthSignRequest(
        requestId: unhex(requestIdHex),
        signData: Uint8List(1),
        dataType: EthDataType.personalMessage,
        chainId: 1,
        path: path("m/44'/60'/0'/0/0", 1),
        address: Uint8List(19),
      );
      expect(bad.toCbor, throwsArgumentError);
    });
  });

  group('eth-signature', () {
    test('decodes and re-encodes the Rust SDK vector', () {
      final sig = EthSignature.fromUr(UR('eth-signature', unhex(ethSignatureHex)));
      expect(hex(sig.requestId!), requestIdHex);
      expect(sig.signature.length, 65);
      expect(sig.signature.last, 0x13);
      expect(sig.origin, 'keystone');
      expect(hex(sig.toCbor()), ethSignatureHex);
      expect(hex(EthSignature.fromUr(sig.toUr()).toCbor()), ethSignatureHex);
    });

    test('rejects short signatures and the wrong type', () {
      final short = EthSignature(requestId: null, signature: Uint8List(64));
      expect(() => EthSignature.fromUr(short.toUr()), throwsDecode);
      expect(() => EthSignature.fromUr(UR('sol-signature', unhex(ethSignatureHex))), throwsDecode);
    });
  });

  group('crypto-hdkey and ETH exports', () {
    test('decodes and re-encodes the JS SDK ETH xpub', () {
      final key = KeystoneHdKey.fromUr(decodeUr(ethHdKeyUr));
      expect(hex(key.toCbor()), ethHdKeyHex);
      expect(UrEncoder.encodeSinglePart(key.toUr()), ethHdKeyUr);
      expect(key.origin!.toPathString(), "m/44'/60'/0'");
      expect(key.origin!.sourceFingerprint, 0xe9181cf3);
      expect(key.parentFingerprint, 0xd32e4508);
    });

    test('a crypto-hdkey with no note or children is BIP-44 standard', () {
      final ur = UR('crypto-hdkey', unhex(ethHdKeyHex));
      expect(classifyEthExport(ur), KeystoneEthExportKind.bip44Standard);
      final xpub = ethStandardXpubFromUr(ur);
      expect(xpub.keyData.length, 33);
      expect(xpub.chainCode!.length, 32);
    });

    KeystoneHdKey ethKey({String? note, String? children, bool chainCode = true}) => KeystoneHdKey(
      keyData: Uint8List(33)..[0] = 0x02,
      chainCode: chainCode ? Uint8List(32) : null,
      origin: path("m/44'/60'/0'", 0x11223344),
      children: children == null ? null : path(children),
      note: note,
      useInfoCoinType: 60,
      useInfoNetwork: 0,
      isPrivate: false,
    );

    test('classifies by note and children', () {
      expect(
        classifyEthExport(ethKey(note: 'account.standard', children: '0/*').toUr()),
        KeystoneEthExportKind.bip44Standard,
      );
      expect(
        classifyEthExport(ethKey(note: 'account.ledger_legacy', children: '*').toUr()),
        KeystoneEthExportKind.ledgerLegacy,
      );
      expect(classifyEthExport(ethKey(children: '*').toUr()), KeystoneEthExportKind.ledgerLegacy);
      expect(
        classifyEthExport(ethKey(note: 'account.ledger_live').toUr()),
        KeystoneEthExportKind.ledgerLive,
      );
      expect(classifyEthExport(ethKey(chainCode: false).toUr()), KeystoneEthExportKind.unknown);
      expect(classifyEthExport(ethKey(children: '1/*').toUr()), KeystoneEthExportKind.unknown);
      expect(
        classifyEthExport(UR('sol-signature', unhex(solSignatureHex))),
        KeystoneEthExportKind.unknown,
      );
    });

    test('a hand-built key round-trips with every field', () {
      final key = ethKey(note: 'account.standard', children: '0/*');
      final back = KeystoneHdKey.fromUr(key.toUr());
      expect(hex(back.toCbor()), hex(key.toCbor()));
      expect(back.useInfoCoinType, 60);
      expect(back.useInfoNetwork, 0);
      expect(back.isPrivate, false);
      expect(back.children!.toPathString(), 'm/0/*');
    });

    test('ethStandardXpubFromUr refuses Ledger layouts', () {
      expect(
        () => ethStandardXpubFromUr(ethKey(note: 'account.ledger_legacy', children: '*').toUr()),
        throwsDecode,
      );
      expect(
        () => ethStandardXpubFromUr(UR('crypto-account', unhex(ledgerLiveAccountHex))),
        throwsDecode,
      );
      final badKey = KeystoneHdKey(
        keyData: Uint8List(33)..[0] = 0x04,
        chainCode: Uint8List(32),
        origin: path("m/44'/60'/0'", 1),
      );
      expect(() => ethStandardXpubFromUr(badKey.toUr()), throwsDecode);
      final noFp = KeystoneHdKey(
        keyData: Uint8List(33)..[0] = 0x03,
        chainCode: Uint8List(32),
        origin: path("m/44'/60'/0'"),
      );
      expect(() => ethStandardXpubFromUr(noFp.toUr()), throwsDecode);
    });

    test('a firmware Ledger Live crypto-account is ledgerLive', () {
      expect(
        classifyEthExport(UR('crypto-account', unhex(ledgerLiveAccountHex))),
        KeystoneEthExportKind.ledgerLive,
      );
    });

    test('1103 exports: the standard xpub wins, fingerprint filled from the export', () {
      final backpack = UR('crypto-multi-accounts', unhex(backpackExportHex));
      expect(classifyEthExport(backpack), KeystoneEthExportKind.bip44Standard);
      final xpub = ethStandardXpubFromUr(backpack);
      expect(xpub.note, 'account.standard');
      expect(
        hex(xpub.keyData),
        '02eae4b876a8696134b868f88cc2f51f715f2dbedb7446b8e6edf3d4541c4eb67b',
      );

      final device = decodeUr(multiAccountsEthUr);
      expect(classifyEthExport(device), KeystoneEthExportKind.bip44Standard);
      final deviceXpub = ethStandardXpubFromUr(device);
      expect(deviceXpub.origin!.sourceFingerprint, 0xeb16731f);

      final solOnly = decodeUr(multiAccountsSolUr);
      expect(classifyEthExport(solOnly), KeystoneEthExportKind.unknown);
      expect(() => ethStandardXpubFromUr(solOnly), throwsDecode);
    });

    test('malformed ETH exports throw UrDecodeException', () {
      expect(
        () => classifyEthExport(UR('crypto-account', unhex(ledgerLiveAccountHex.substring(0, 50)))),
        throwsDecode,
      );
      expect(() => classifyEthExport(UR('crypto-hdkey', unhex('a0'))), throwsDecode);
    });
  });
}
