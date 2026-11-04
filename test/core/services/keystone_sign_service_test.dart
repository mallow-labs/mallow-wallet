import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:solana/solana.dart';

/// The Keystone reply carries no public key, so the service is the only place
/// that can tell a signature from *this* wallet apart from a valid signature
/// by some other key. These tests stand in for the sheet and the device: they
/// read the request the service emits and answer it the way a device would —
/// or the ways a device, a stale screen or a second Keystone could.
void main() {
  late KeystoneSignController controller;
  late KeystoneSignService service;
  late Ed25519HDKeyPair wallet;
  late Ed25519HDKeyPair otherKey;

  const fingerprint = 0x12121212;
  final payload = Uint8List.fromList(List<int>.generate(120, (i) => i));

  setUp(() async {
    controller = KeystoneSignController();
    service = KeystoneSignService(controller);
    wallet = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: List<int>.filled(32, 7),
    );
    otherKey = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: List<int>.filled(32, 9),
    );
  });

  tearDown(() => controller.dispose());

  Future<Uint8List> sign({
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
    int index = 0,
    KeystoneSignPurpose purpose = KeystoneSignPurpose.transaction,
    Future<void>? cancelled,
  }) => service.signSolana(
    payload: payload,
    address: wallet.address,
    masterFingerprint: fingerprint,
    derivationIndex: index,
    scheme: scheme,
    purpose: purpose,
    cancelled: cancelled,
  );

  /// The reply a device would show for [request], signed by [by].
  Future<UR> replyFor(
    SolSignRequest request, {
    required Ed25519HDKeyPair by,
    Uint8List? requestId,
  }) async {
    final signature = await by.sign(request.signData);
    return SolSignature(
      requestId: requestId ?? request.requestId,
      signature: Uint8List.fromList(signature.bytes),
    ).toUr();
  }

  group('prompt context', () {
    const context = KeystoneSignContext(
      notice: 'Approve the rebuilt transaction.',
      index: 1,
      total: 3,
    );
    late List<KeystoneSignPrompt> prompts;

    setUp(() {
      prompts = [];
      final sub = controller.requests.listen((prompt) async {
        prompts.add(prompt);
        final request = SolSignRequest.fromUr(prompt.request);
        final reply = await replyFor(request, by: wallet);
        expect(await prompt.validate(reply), isNull);
        prompt.completer.complete(reply);
      });
      addTearDown(sub.cancel);
    });

    void expectNoContext(KeystoneSignPrompt prompt) {
      expect(prompt.notice, isNull);
      expect(prompt.index, isNull);
      expect(prompt.total, isNull);
    }

    test('copies context to prompts only while the body runs', () async {
      final result = await controller.withContext(context, () async {
        await sign();
        await sign();
        return 42;
      });
      await sign();

      expect(result, 42);
      for (final prompt in prompts.take(2)) {
        expect(prompt.notice, context.notice);
        expect(prompt.index, 1);
        expect(prompt.total, 3);
      }
      expectNoContext(prompts.last);
    });

    test('clears context even when no prompt was needed', () async {
      await controller.withContext(context, () async => 42);
      await sign();

      expectNoContext(prompts.single);
    });

    test('clears context when the body throws after a prompt', () async {
      await expectLater(
        controller.withContext<void>(context, () async {
          await sign();
          throw StateError('signing failed');
        }),
        throwsStateError,
      );
      await sign();

      expect(prompts.first.notice, context.notice);
      expectNoContext(prompts.last);
    });

    test('clears context when the body throws without a prompt', () async {
      await expectLater(
        controller.withContext<void>(context, () async {
          throw StateError('local signing failed');
        }),
        throwsStateError,
      );
      await sign();

      expectNoContext(prompts.single);
    });

    test('an unrelated prompt cannot inherit an active scope', () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final scoped = controller.withContext(context, () async {
        entered.complete();
        await resume.future;
        await sign();
      });
      await entered.future;
      await sign();
      resume.complete();
      await scoped;

      expectNoContext(prompts.first);
      expect(prompts.last.notice, context.notice);
    });

    test('work outliving the body cannot retain its context', () async {
      final resume = Completer<void>();
      late Future<Uint8List> later;
      await controller.withContext(context, () async {
        later = resume.future.then((_) => sign());
      });
      resume.complete();
      await later;

      expectNoContext(prompts.single);
    });
  });

  test('builds the request from the row identity and accepts the right '
      'signature', () async {
    final prompts = <KeystoneSignPrompt>[];
    final sub = controller.requests.listen((prompt) async {
      prompts.add(prompt);
      final request = SolSignRequest.fromUr(prompt.request);
      final reply = await replyFor(request, by: wallet);
      expect(await prompt.validate(reply), isNull);
      prompt.completer.complete(reply);
    });
    addTearDown(sub.cancel);

    final signature = await sign(
      scheme: SolanaDerivationScheme.legacy,
      index: 3,
    );

    final request = SolSignRequest.fromUr(prompts.single.request);
    expect(request.signData, payload);
    expect(request.path.toPathString(), "m/44'/501'/3'");
    expect(request.path.sourceFingerprint, fingerprint);
    expect(request.type, SolSignType.transaction);
    expect(request.origin, 'mallow');
    expect(prompts.single.address, wallet.address);
    expect(signature, (await wallet.sign(payload)).bytes);
  });

  test('a message is requested as a message', () async {
    final sub = controller.requests.listen((prompt) async {
      final request = SolSignRequest.fromUr(prompt.request);
      expect(request.type, SolSignType.message);
      final reply = await replyFor(request, by: wallet);
      await prompt.validate(reply);
      prompt.completer.complete(reply);
    });
    addTearDown(sub.cancel);

    await sign(purpose: KeystoneSignPurpose.message);
  });

  test('a signature from a different key is refused with a reason', () async {
    // The case the check exists for: a request that named the wrong path or
    // the wrong device comes back with a perfectly valid signature — from
    // another address.
    String? rejection;
    final sub = controller.requests.listen((prompt) async {
      final request = SolSignRequest.fromUr(prompt.request);
      rejection = await prompt.validate(await replyFor(request, by: otherKey));
      prompt.cancel();
    });
    addTearDown(sub.cancel);

    await expectLater(
      sign(),
      throwsA(isA<KeystoneSigningCancelledException>()),
    );
    expect(rejection, contains('different account'));
  });

  test('a reply to a different request is refused', () async {
    // A stale signature still on the device's screen from the last request.
    String? rejection;
    final sub = controller.requests.listen((prompt) async {
      final request = SolSignRequest.fromUr(prompt.request);
      rejection = await prompt.validate(
        await replyFor(
          request,
          by: wallet,
          requestId: SolSignRequest.newRequestId(),
        ),
      );
      prompt.cancel();
    });
    addTearDown(sub.cancel);

    await expectLater(
      sign(),
      throwsA(isA<KeystoneSigningCancelledException>()),
    );
    expect(rejection, contains('different request'));
  });

  test('a code that is not a signature is refused', () async {
    String? rejection;
    final sub = controller.requests.listen((prompt) async {
      rejection = await prompt.validate(prompt.request);
      prompt.cancel();
    });
    addTearDown(sub.cancel);

    await expectLater(
      sign(),
      throwsA(isA<KeystoneSigningCancelledException>()),
    );
    expect(rejection, isNotNull);
  });

  test('cancelling the flow cancels the prompt', () async {
    final cancel = Completer<void>();
    final shown = Completer<KeystoneSignPrompt>();
    final sub = controller.requests.listen(shown.complete);
    addTearDown(sub.cancel);

    final result = sign(cancelled: cancel.future);
    final prompt = await shown.future;
    cancel.complete();

    await expectLater(
      result,
      throwsA(isA<KeystoneSigningCancelledException>()),
    );
    expect(prompt.completer.isCompleted, isTrue);
  });

  test('a cancel reads as a cancel, not an error', () {
    // Every flow renders `isCancelled` failures as a quiet abort.
    expect(
      AppFailure.from(KeystoneSigningCancelledException()).isCancelled,
      isTrue,
    );
    expect(
      KeystoneSigningCancelledException(),
      isA<TransactionAuthCancelledException>(),
    );
  });

  test('with no sheet listening it fails loud instead of waiting', () async {
    await expectLater(
      sign(),
      throwsA(isA<KeystoneSigningUnavailableException>()),
    );
  });

  test('a row without a fingerprint never reaches the device', () async {
    var shown = false;
    final sub = controller.requests.listen((_) => shown = true);
    addTearDown(sub.cancel);

    await expectLater(
      service.signSolana(
        payload: payload,
        address: wallet.address,
        masterFingerprint: 0,
        derivationIndex: 0,
        scheme: SolanaDerivationScheme.standard,
        purpose: KeystoneSignPurpose.transaction,
      ),
      throwsA(isA<SigningException>()),
    );
    expect(shown, isFalse);
  });

  test('scheme mapping round-trips', () {
    for (final scheme in SolanaDerivationScheme.values) {
      expect(solanaSchemeFromKeystone(keystoneSolanaPath(scheme)), scheme);
    }
    expect(formatMasterFingerprint(0x0012ABCD), '0012ABCD');
  });
}
