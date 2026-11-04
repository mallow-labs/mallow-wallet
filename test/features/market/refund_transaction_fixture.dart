import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

/// Refund fee shape: 15,000 lamports priority + 5,000 per required signature.
String refundTransactionFixture({
  required String payerAddress,
  required String accountAddress,
  int rent = 0,
  bool associated = false,
  bool token2022 = false,
  bool versioned = false,
  String? funderAddress,
}) {
  final payer = Ed25519HDPublicKey.fromBase58(payerAddress);
  final funder = Ed25519HDPublicKey.fromBase58(funderAddress ?? payerAddress);
  final account = Ed25519HDPublicKey.fromBase58(accountAddress);
  final tokenProgram = token2022 ? Token2022Program.id : TokenProgram.id;
  final message =
      Message(
        instructions: [
          ComputeBudgetInstruction.setComputeUnitLimit(units: 200000),
          ComputeBudgetInstruction.setComputeUnitPrice(microLamports: 75000),
          if (associated)
            AssociatedTokenAccountInstruction.createAccountIdempotent(
              funder: funder,
              address: account,
              owner: payer,
              mint: account,
              tokenProgramId: tokenProgram,
            )
          else if (rent > 0)
            SystemInstruction.createAccount(
              fundingAccount: funder,
              newAccount: account,
              lamports: rent,
              space: token2022 ? 200 : 165,
              owner: tokenProgram,
            )
          else
            SystemInstruction.transfer(
              fundingAccount: payer,
              recipientAccount: payer,
              lamports: 0,
            ),
        ],
      ).compile(
        recentBlockhash: '11111111111111111111111111111111',
        feePayer: payer,
      );
  return SignedTx(
    compiledMessage: versioned
        ? CompiledMessage.v0(
            header: message.header,
            accountKeys: message.accountKeys,
            recentBlockhash: message.recentBlockhash,
            instructions: message.instructions,
            addressTableLookups: const [],
          )
        : message,
    signatures: [
      for (var i = 0; i < message.requiredSignatureCount; i++)
        Signature(
          List<int>.filled(64, i == 0 ? 0 : 7),
          publicKey: message.accountKeys[i],
        ),
    ],
  ).encode();
}
