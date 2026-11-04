import 'package:collection/collection.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

/// The parts of a Solana Pay transfer request that go into the transaction
/// rather than into its amount: the [references] the merchant searches for
/// and the [memo] it reads.
///
/// A merchant finds its payment by looking up transactions that mention a
/// reference key, then checks the transfer instruction, which it expects to
/// be the last one, with the memo immediately before it. A transfer that
/// moves the right amount without them is a payment the merchant never sees.
class SolanaPayTags {
  const SolanaPayTags({this.references = const [], this.memo});

  /// Base58 public keys, kept in the order the request listed them.
  final List<String> references;
  final String? memo;

  bool get isEmpty => references.isEmpty && memo == null;

  /// [transfer] tagged the way the Solana Pay specification requires: the
  /// memo as an SPL Memo instruction immediately before it, and each
  /// reference as a read-only, non-signer key appended to its accounts.
  ///
  /// The System and Token programs ignore accounts past the ones they read,
  /// so the extra keys change only what the transaction mentions. Returns
  /// `[transfer]` unchanged when there is nothing to add.
  List<Instruction> apply(Instruction transfer) {
    if (isEmpty) return [transfer];
    final memo = this.memo;
    return [
      if (memo != null) MemoInstruction(signers: const [], memo: memo),
      Instruction(
        programId: transfer.programId,
        accounts: [
          ...transfer.accounts,
          for (final reference in references)
            AccountMeta.readonly(
              pubKey: Ed25519HDPublicKey.fromBase58(reference),
              isSigner: false,
            ),
        ],
        data: transfer.data,
      ),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is SolanaPayTags &&
      other.memo == memo &&
      const ListEquality<String>().equals(other.references, references);

  @override
  int get hashCode =>
      Object.hash(memo, const ListEquality<String>().hash(references));
}
