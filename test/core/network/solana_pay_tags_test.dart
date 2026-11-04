import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/solana_pay_tags.dart';
import 'package:solana/solana.dart';

void main() {
  const payer = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const merchant = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const ref1 = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';
  const ref2 = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

  final transfer = SystemInstruction.transfer(
    fundingAccount: Ed25519HDPublicKey.fromBase58(payer),
    recipientAccount: Ed25519HDPublicKey.fromBase58(merchant),
    lamports: 1000,
  );

  test('no tags leaves the transfer as it is', () {
    expect(const SolanaPayTags().apply(transfer), [same(transfer)]);
  });

  test('the memo goes immediately before the transfer, which stays last', () {
    final tagged = const SolanaPayTags(memo: 'order 42').apply(transfer);
    expect(tagged, hasLength(2));
    expect(tagged.first.programId, MemoProgram.id);
    expect(tagged.first.accounts, isEmpty, reason: 'the memo needs no signer');
    expect(String.fromCharCodes(tagged.first.data), 'order 42');
    expect(tagged.last.programId, transfer.programId);
    expect(tagged.last.data, transfer.data);
  });

  test('references are read-only, non-signer keys after the transfer\'s own, '
      'in order', () {
    final tagged = const SolanaPayTags(
      references: [ref1, ref2],
    ).apply(transfer);
    final accounts = tagged.single.accounts;
    expect(accounts.take(transfer.accounts.length), transfer.accounts);
    final added = accounts.skip(transfer.accounts.length).toList();
    expect([for (final a in added) a.pubKey.toBase58()], [ref1, ref2]);
    for (final a in added) {
      expect(a.isWriteable, isFalse);
      expect(a.isSigner, isFalse);
    }
  });
}
