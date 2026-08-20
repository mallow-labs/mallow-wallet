import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/transaction_executor.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

/// A single-required-signer tx (the fee payer) paying [recipient].
String _txBase64({
  required Ed25519HDPublicKey feePayer,
  required Ed25519HDPublicKey recipient,
}) {
  final compiled = Message.only(
    SystemInstruction.transfer(
      fundingAccount: feePayer,
      recipientAccount: recipient,
      lamports: 1,
    ),
  ).compile(recentBlockhash: base58encode(Uint8List(32)), feePayer: feePayer);
  final unsigned = SignedTx(
    signatures: List<Signature>.generate(
      compiled.requiredSignatureCount,
      (_) => Signature(List<int>.filled(64, 0), publicKey: feePayer),
    ),
    compiledMessage: compiled,
  );
  return base64Encode(unsigned.toByteArray().toList());
}

void main() {
  test('empty signers returns empty without decoding', () {
    expect(requiredSignersForTx('not-valid-base64', const []), isEmpty);
  });

  test('keeps only signers in the tx required-signer slots', () async {
    final payer = await Ed25519HDKeyPair.random();
    final other = await Ed25519HDKeyPair.random();
    final recipient = await Ed25519HDKeyPair.random();

    final tx = _txBase64(
      feePayer: payer.publicKey,
      recipient: recipient.publicKey,
    );

    // The fee payer is the tx's only required signer; `other` is not on the
    // tx at all. The filter must keep `payer` and drop `other` — passing
    // `other` to signCompiledTx would throw for this tx.
    final kept = requiredSignersForTx(tx, [payer, other]);
    expect(kept.map((k) => k.publicKey.toBase58()), [
      payer.publicKey.toBase58(),
    ]);
  });

  test('falls back to the full list on a decode failure', () async {
    final a = await Ed25519HDKeyPair.random();
    final kept = requiredSignersForTx('%%not-base64%%', [a]);
    expect(kept, [a]);
  });
}
