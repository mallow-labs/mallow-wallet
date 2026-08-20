import '../../../shared/utils/chain.dart';
import '../models/token_balance.dart';
import '../widgets/token_sort_header.dart';

/// Native chains pinned to the top of a token list, in this fixed order,
/// regardless of the selected sort.
const _nativePinOrder = [Chain.solana, Chain.tezos, Chain.ethereum];

/// [tokens] in the order the tokens portfolio renders them: the chain gas
/// tokens first (fixed SOL → XTZ → ETH order), then everything else by [sort].
///
/// Shared with the send flow's token picker so a holding sits in the same place
/// in both lists — the picker is reached from the same rows, so a different
/// order there reads as a different set of tokens.
List<TokenBalance> sortTokensForDisplay(
  Iterable<TokenBalance> tokens, {
  TokenSortOption sort = TokenSortOption.topValue,
}) {
  final sorted = List<TokenBalance>.of(tokens);
  switch (sort) {
    case TokenSortOption.topValue:
      sorted.sort(
        (a, b) => (b.totalUsdValue ?? 0).compareTo(a.totalUsdValue ?? 0),
      );
    case TokenSortOption.name:
      sorted.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
  }
  final natives = <TokenBalance>[];
  final rest = <TokenBalance>[];
  for (final token in sorted) {
    (token.isNative ? natives : rest).add(token);
  }
  natives.sort((a, b) {
    int rank(Chain c) {
      final i = _nativePinOrder.indexOf(c);
      return i == -1 ? _nativePinOrder.length : i;
    }

    return rank(a.chain).compareTo(rank(b.chain));
  });
  return [...natives, ...rest];
}
