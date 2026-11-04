import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/solana_v1_transaction.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:solana/solana.dart';

import '../../support/solana_v1_fixture.dart';

String _encode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<Ed25519HDKeyPair> _key(int fill) =>
    Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: List.filled(32, fill));

void main() {
  group('SolanaV1Transaction', () {
    test('reads the signers, blockhash and message of a kit-built v1 tx', () {
      final tx = SolanaV1Transaction.fromBytes(hexBytes(v1Unsigned));

      expect(tx.requiredSignatures, 2);
      expect(tx.signerKeys, [v1Payer, v1Cosigner]);
      expect(tx.recentBlockhash, v1Blockhash);
      expect(_encode(tx.messageBytes), v1Message);
      expect(tx.hasPreAttachedSignature, isFalse);
    });

    test('signing the message bytes reproduces kit\'s signed wire', () async {
      final payer = await _key(1);
      final cosigner = await _key(2);
      var tx = SolanaV1Transaction.fromBytes(hexBytes(v1Unsigned));

      for (final key in [cosigner, payer]) {
        final signature = await key.sign(tx.messageBytes);
        tx = tx.withSignature(key.publicKey.toBase58(), signature.bytes);
      }

      expect(_encode(tx.toBytes()), v1Signed);
      expect(tx.hasPreAttachedSignature, isTrue);
    });

    test('a blockhash refresh rewrites only the blockhash', () {
      final tx = SolanaV1Transaction.fromBytes(hexBytes(v1Unsigned));
      const fresh = '11111111111111111111111111111111';

      final refreshed = tx.withRecentBlockhash(fresh);

      expect(refreshed.recentBlockhash, fresh);
      final before = tx.toBytes();
      final after = refreshed.toBytes();
      for (var i = 0; i < before.length; i++) {
        if (i >= 8 && i < 40) continue;
        expect(after[i], before[i], reason: 'byte $i changed');
      }
    });

    test('refuses a signer that has no slot', () async {
      final tx = SolanaV1Transaction.fromBytes(hexBytes(v1Unsigned));
      final stranger = await _key(3);

      expect(
        () =>
            tx.withSignature(stranger.publicKey.toBase58(), List.filled(64, 1)),
        throwsStateError,
      );
    });

    test('tells v1 apart from legacy and v0 by its first byte', () {
      expect(SolanaV1Transaction.isV1Wire(hexBytes(v1Unsigned)), isTrue);
      // Legacy and v0 begin with the signature count.
      expect(SolanaV1Transaction.isV1Wire([1, 0, 0]), isFalse);
      expect(
        () => SolanaV1Transaction.fromBytes([1, 0, 0]),
        throwsFormatException,
      );
    });

    test(
      'rejects a header that claims more signatures than the bytes hold',
      () {
        final bytes = hexBytes(v1Unsigned)..[1] = 60;
        expect(
          () => SolanaV1Transaction.fromBytes(bytes),
          throwsFormatException,
        );
      },
    );
  });

  group('executor helpers on a v1 tx', () {
    test('an unsigned v1 tx can be freshened client-side', () {
      final unsigned = base64Encode(hexBytes(v1Unsigned));
      expect(needsBuilderRebuild([unsigned]), isFalse);
    });

    test('a co-signed v1 tx goes back to its builder', () {
      final signed = base64Encode(hexBytes(v1Signed));
      expect(needsBuilderRebuild([signed]), isTrue);
    });

    test('additional signers are filtered to the v1 signer slots', () async {
      final cosigner = await _key(2);
      final stranger = await _key(3);

      final kept = requiredSignersForTx(base64Encode(hexBytes(v1Unsigned)), [
        cosigner,
        stranger,
      ]);

      expect(kept, [cosigner]);
    });
  });
}
