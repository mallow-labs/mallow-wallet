import '../models/token_balance.dart';

/// One holding's absolute balance immediately after a confirmed transaction,
/// read from that transaction's own metadata, alongside the balance it moved
/// from. [previousRawBalance] is what makes a *stale* portfolio read
/// recognisable: a fetch still reporting it demonstrably predates this
/// transaction.
typedef ConfirmedBalance = ({
  String mint,
  bool isNative,
  int rawBalance,
  int previousRawBalance,
});

/// The [owner]'s post-transaction balances, parsed from a `getTransaction`
/// result fetched with `encoding: jsonParsed`.
///
/// A confirmed transaction already carries the exact post balances of every
/// account it touched, so the wallet's holdings can be corrected the moment it
/// lands instead of waiting for the indexer-backed refetch to catch up.
///
/// - Native SOL comes from `meta.postBalances` at the owner's index in the
///   message account keys, so it nets out the fee and any ATA rent. The owner
///   signs the transaction, so it is always among the static account keys —
///   lookup-table addresses (which follow them in the balance arrays) can
///   never shift its index.
/// - SPL rows come from `meta.postTokenBalances` filtered to [owner]; multiple
///   token accounts for one mint are summed.
/// - A token account drained to empty may be absent from `postTokenBalances`
///   (a swap selling the whole balance can close the ATA), so a mint present
///   pre- but not post- is reported as zero rather than left stale.
///
/// Returns an empty list for a failed or unparseable transaction — callers
/// fall back to a refetch.
List<ConfirmedBalance> parseOwnerPostBalances(
  Map<String, dynamic> transaction,
  String owner,
) {
  final meta = transaction['meta'];
  if (meta is! Map<String, dynamic>) return const [];
  if (meta['err'] != null) return const [];

  final balances = <ConfirmedBalance>[];

  final ownerIndex = _accountKeys(transaction).indexOf(owner);
  final postLamports = _lamportsAt(meta['postBalances'], ownerIndex);
  if (postLamports != null) {
    balances.add((
      mint: TokenBalance.solMint,
      isNative: true,
      rawBalance: postLamports,
      previousRawBalance:
          _lamportsAt(meta['preBalances'], ownerIndex) ?? postLamports,
    ));
  }

  final post = _ownedTokenAmounts(meta['postTokenBalances'], owner);
  final pre = _ownedTokenAmounts(meta['preTokenBalances'], owner);
  for (final entry in post.entries) {
    balances.add((
      mint: entry.key,
      isNative: false,
      rawBalance: entry.value,
      previousRawBalance: pre[entry.key] ?? 0,
    ));
  }
  for (final entry in pre.entries) {
    if (!post.containsKey(entry.key)) {
      balances.add((
        mint: entry.key,
        isNative: false,
        rawBalance: 0,
        previousRawBalance: entry.value,
      ));
    }
  }
  return balances;
}

/// Lamports at [index] of a pre/postBalances array, or null when the array
/// doesn't cover it.
int? _lamportsAt(dynamic balances, int index) {
  if (index < 0 || balances is! List || index >= balances.length) return null;
  final lamports = balances[index];
  return lamports is num ? lamports.toInt() : null;
}

/// Static account keys of the transaction message, in balance-array order.
/// `jsonParsed` yields `{pubkey, signer, …}` objects; plain `json` encoding
/// yields bare address strings.
List<String> _accountKeys(Map<String, dynamic> transaction) {
  final message = (transaction['transaction'] as Map?)?['message'];
  final keys = (message as Map?)?['accountKeys'];
  if (keys is! List) return const [];
  return [
    for (final key in keys)
      if (key is String)
        key
      else if (key is Map && key['pubkey'] is String)
        key['pubkey'] as String
      else
        '',
  ];
}

/// Raw token amounts per mint for [owner] in a pre/postTokenBalances list.
Map<String, int> _ownedTokenAmounts(dynamic entries, String owner) {
  if (entries is! List) return const {};
  final amounts = <String, int>{};
  for (final entry in entries) {
    if (entry is! Map) continue;
    if (entry['owner'] != owner) continue;
    final mint = entry['mint'];
    final amount = (entry['uiTokenAmount'] as Map?)?['amount'];
    if (mint is! String) continue;
    final raw = amount is String
        ? int.tryParse(amount)
        : (amount is num ? amount.toInt() : null);
    if (raw == null) continue;
    amounts[mint] = (amounts[mint] ?? 0) + raw;
  }
  return amounts;
}
