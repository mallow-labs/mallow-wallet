import 'dart:convert';
import 'dart:typed_data';

import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

/// Payer-funded token accounts in a refund transaction. Explicit creates carry
/// their rent in the instruction; associated creates need pre/post balances
/// because an idempotent create can leave an existing account unchanged.
class TokenRefundRent {
  const TokenRefundRent(this.explicitLamports, this.associatedAccounts);

  final int explicitLamports;
  final List<String> associatedAccounts;

  static TokenRefundRent? decode(String transaction, String payer) {
    try {
      final message = SignedTx.fromBytes(
        base64Decode(transaction),
      ).compiledMessage;
      final keys = message.accountKeys;
      var rent = 0;
      final associated = <String>{};
      for (final instruction in message.instructions) {
        final program = keys[instruction.programIdIndex].toBase58();
        final data = Uint8List.fromList(instruction.data.toList());
        final accounts = instruction.accountKeyIndexes;
        if (program == SystemProgram.programId &&
            data.length == 52 &&
            ByteData.sublistView(data).getUint32(0, Endian.little) == 0 &&
            keys[accounts.first].toBase58() == payer) {
          final owner = Ed25519HDPublicKey(data.sublist(20)).toBase58();
          if (_isTokenProgram(owner)) {
            rent += ByteData.sublistView(data).getUint64(4, Endian.little);
          }
        } else if (program == AssociatedTokenAccountProgram.programId &&
            (data.isEmpty || (data.length == 1 && data.first <= 1)) &&
            accounts.length >= 6 &&
            keys[accounts.first].toBase58() == payer &&
            _isTokenProgram(keys[accounts[5]].toBase58())) {
          associated.add(keys[accounts[1]].toBase58());
        }
      }
      return TokenRefundRent(rent, associated.toList(growable: false));
    } catch (_) {
      // Unknown transaction shapes cannot support an accurate rent quote.
      return null;
    }
  }

  int? resolve(Map<String, int> pre, Map<String, int> post) {
    var rent = explicitLamports;
    for (final address in associatedAccounts) {
      final before = pre[address];
      final after = post[address];
      if (before == null || after == null) return null;
      // An already funded ATA can be reused or topped up. Only the increase
      // is paid by this transaction, never its entire existing deposit.
      if (after > before) rent += after - before;
    }
    return rent;
  }

  static bool _isTokenProgram(String owner) =>
      owner == TokenProgram.programId || owner == Token2022Program.programId;
}
