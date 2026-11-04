import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:web3dart/web3dart.dart'
    show EthPrivateKey, keccak256, padUint8ListTo32, sign, unsignedIntToBytes;

/// The device signs an `eth-sign-request` by path once the fingerprint
/// matches and ignores the address it was sent. Recovering the signer from the
/// reply is therefore the only proof the right key signed. These tests stand in
/// for the sheet and the device, answering the way a device would — or the
/// ways a stale screen, a second Keystone or the wrong account could.
void main() {
  late KeystoneSignController controller;
  late KeystoneSignService service;

  const fingerprint = 0x12121212;
  final wallet = EthPrivateKey(
    Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
  );
  final otherKey = EthPrivateKey(
    Uint8List.fromList(List<int>.generate(32, (i) => 99 - i)),
  );
  final address = wallet.address.eip55With0x;
  final unsignedTx = Uint8List.fromList([0x02, ...List.filled(40, 7)]);

  setUp(() {
    controller = KeystoneSignController();
    service = KeystoneSignService(controller);
  });

  tearDown(() => controller.dispose());

  /// r‖s‖v over [digest] by [by], with v written as [v] maps it from 0/1.
  Uint8List rsv(Uint8List digest, EthPrivateKey by, int Function(int) v) {
    final sig = sign(digest, by.privateKey);
    return Uint8List.fromList([
      ...padUint8ListTo32(unsignedIntToBytes(sig.r)),
      ...padUint8ListTo32(unsignedIntToBytes(sig.s)),
      v(sig.v - 27),
    ]);
  }

  UR replyFor(
    EthSignRequest request, {
    required Uint8List digest,
    EthPrivateKey? by,
    Uint8List? requestId,
    int Function(int parity)? v,
  }) => EthSignature(
    requestId: requestId ?? request.requestId,
    signature: rsv(digest, by ?? wallet, v ?? (p) => p),
  ).toUr();

  Future<Uint8List> signTx({int index = 0}) => service.signEthereum(
    signData: unsignedTx,
    dataType: EthDataType.typedTransaction,
    digest: keccak256(unsignedTx),
    chainId: 1,
    address: address,
    masterFingerprint: fingerprint,
    derivationIndex: index,
  );

  /// Answers every prompt with [answer]'s replies in turn, recording what
  /// each validation said. The first null completes the prompt, as the sheet
  /// does.
  List<String?> answerWith(
    List<UR> Function(EthSignRequest request) answer, {
    List<KeystoneSignPrompt>? prompts,
  }) {
    final rejections = <String?>[];
    final sub = controller.requests.listen((prompt) async {
      prompts?.add(prompt);
      final request = EthSignRequest.fromUr(prompt.request);
      for (final reply in answer(request)) {
        final rejection = await prompt.validate(reply);
        rejections.add(rejection);
        if (rejection == null) {
          prompt.completer.complete(reply);
          return;
        }
      }
      prompt.cancel();
    });
    addTearDown(sub.cancel);
    return rejections;
  }

  test('a transaction request names the row identity and returns a '
      'checked r‖s‖v', () async {
    final prompts = <KeystoneSignPrompt>[];
    answerWith(
      (r) => [replyFor(r, digest: keccak256(unsignedTx))],
      prompts: prompts,
    );

    final sig = await signTx(index: 3);

    final prompt = prompts.single;
    final request = EthSignRequest.fromUr(prompt.request);
    expect(prompt.replyType, 'eth-signature');
    expect(prompt.purpose, KeystoneSignPurpose.transaction);
    expect(request.dataType, EthDataType.typedTransaction);
    expect(request.signData, unsignedTx);
    expect(request.chainId, 1);
    expect(request.path.toPathString(), "m/44'/60'/0'/0/3");
    expect(request.path.sourceFingerprint, fingerprint);
    expect(request.address, wallet.address.value);
    expect(request.origin, 'mallow');
    expect(sig, hasLength(65));
    expect(sig[64], anyOf(27, 28));
    expect(
      MultiChainDerivation.recoverEthereumAddress(keccak256(unsignedTx), sig),
      address.toLowerCase(),
    );
  });

  for (final (name, v) in [
    ('0/1', (int p) => p),
    ('27/28', (int p) => 27 + p),
    ('EIP-155', (int p) => 1 * 2 + 35 + p),
  ]) {
    test('v written as $name is normalised to 27/28', () async {
      answerWith((r) => [replyFor(r, digest: keccak256(unsignedTx), v: v)]);
      final sig = await signTx();
      expect(
        MultiChainDerivation.recoverEthereumAddress(keccak256(unsignedTx), sig),
        address.toLowerCase(),
      );
      expect(sig[64], anyOf(27, 28));
    });
  }

  test('a reply signed by another key is refused, and the scan goes on to '
      'the right one', () async {
    final rejections = answerWith(
      (r) => [
        replyFor(r, digest: keccak256(unsignedTx), by: otherKey),
        replyFor(r, digest: keccak256(unsignedTx)),
      ],
    );

    await signTx();

    expect(rejections.first, contains('different account'));
    expect(rejections.last, isNull);
  });

  test('a signature over different bytes is refused', () async {
    final rejections = answerWith(
      (r) => [
        replyFor(r, digest: keccak256(Uint8List.fromList([1, 2, 3]))),
      ],
    );

    await expectLater(
      signTx(),
      throwsA(isA<KeystoneSigningCancelledException>()),
    );
    expect(rejections.single, contains('different account'));
  });

  test('a reply to another request is refused', () async {
    final rejections = answerWith(
      (r) => [
        replyFor(
          r,
          digest: keccak256(unsignedTx),
          requestId: EthSignRequest.newRequestId(),
        ),
      ],
    );

    await expectLater(
      signTx(),
      throwsA(isA<KeystoneSigningCancelledException>()),
    );
    expect(rejections.single, contains('different request'));
  });

  test('a Solana signature is not an Ethereum one', () async {
    final rejections = answerWith(
      (r) => [
        SolSignature(requestId: r.requestId, signature: Uint8List(64)).toUr(),
      ],
    );

    await expectLater(
      signTx(),
      throwsA(isA<KeystoneSigningCancelledException>()),
    );
    expect(rejections.single, contains('not a Keystone signature'));
  });

  test('a personal message is requested as a message', () async {
    final message = Uint8List.fromList(utf8.encode('mallow Login'));
    final digest = MultiChainDerivation.ethereumPersonalMessageDigest(message);
    final prompts = <KeystoneSignPrompt>[];
    answerWith((r) => [replyFor(r, digest: digest)], prompts: prompts);

    final sig = await service.signEthereum(
      signData: message,
      dataType: EthDataType.personalMessage,
      digest: digest,
      chainId: 1,
      address: address,
      masterFingerprint: fingerprint,
      derivationIndex: 0,
    );

    expect(prompts.single.purpose, KeystoneSignPurpose.message);
    expect(
      EthSignRequest.fromUr(prompts.single.request).dataType,
      EthDataType.personalMessage,
    );
    expect(
      '0x${sig.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
      await MultiChainDerivation.signEthereumPersonalMessageWithKey(
        wallet.privateKey,
        message,
      ),
    );
  });

  test('an empty personal message is signed, as EIP-191 allows', () async {
    final empty = Uint8List(0);
    final digest = MultiChainDerivation.ethereumPersonalMessageDigest(empty);
    answerWith((r) => [replyFor(r, digest: digest)]);

    final sig = await service.signEthereum(
      signData: empty,
      dataType: EthDataType.personalMessage,
      digest: digest,
      chainId: 1,
      address: address,
      masterFingerprint: fingerprint,
      derivationIndex: 0,
    );

    expect(
      MultiChainDerivation.recoverEthereumAddress(digest, sig),
      address.toLowerCase(),
    );
  });

  test('a row without a fingerprint never reaches the device', () async {
    final prompts = <KeystoneSignPrompt>[];
    answerWith((_) => [], prompts: prompts);
    await expectLater(
      service.signEthereum(
        signData: unsignedTx,
        dataType: EthDataType.typedTransaction,
        digest: keccak256(unsignedTx),
        chainId: 1,
        address: address,
        masterFingerprint: 0,
        derivationIndex: 0,
      ),
      throwsA(anything),
    );
    expect(prompts, isEmpty);
  });

  group('normalizeEthereumSignature', () {
    final rAndS = List<int>.filled(64, 1);

    test('refuses a v that is no recovery id', () {
      for (final v in [2, 26, 29, 34]) {
        expect(
          normalizeEthereumSignature(Uint8List.fromList([...rAndS, v])),
          isNull,
          reason: 'v = $v',
        );
      }
    });

    test('reads a multi-byte v big-endian', () {
      // chainId 137: v = 137 * 2 + 36 = 310, odd parity.
      final sig = normalizeEthereumSignature(
        Uint8List.fromList([...rAndS, 0x01, 0x36]),
      );
      expect(sig![64], 28);
    });

    test('refuses a short signature', () {
      expect(normalizeEthereumSignature(Uint8List(64)), isNull);
    });
  });
}
