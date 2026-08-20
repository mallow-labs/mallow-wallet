import '../../../di.dart';
import '../../../shared/utils/chain.dart';
import '../models/token_balance.dart';
import 'ethereum_token_service.dart';
import 'tezos_token_service.dart';
import 'token_repository.dart';

/// Per-wallet USD totals for the account/profile lists, routed to the token
/// service that can actually answer for the address's chain.
///
/// 🛑 Every chain writes its rows into the same `CachedBalances` table keyed by
/// address, but only [TokenRepository] speaks Solana DAS. Feeding a `0x…` or
/// `tz1…` address to `TokenRepository.getTokenBalances` asks Helius
/// `searchAssets` for an owner it cannot parse, which comes back empty — and the
/// write-through `cacheBalances(address, [])` then *deletes* that wallet's real
/// Ethereum/Tezos rows. The account row drops to $0 while the header (which
/// fans out per chain via `TokenBalanceBloc`) still shows the true total; that
/// divergence is the bug this file exists to prevent. Route by chain, always.
///
/// [TokenRepository.calculateTotalValue] is a chain-agnostic sum, so it stays
/// the one place a list of holdings becomes a USD number.

/// Cached USD total for [address], or null when that chain's cache holds no
/// rows for it — callers render "still resolving" for a missing entry, which a
/// genuine $0 must not be confused with.
Future<double?> cachedWalletTotalUsd(String address) async {
  final repo = sl<TokenRepository>();
  final cached = switch (Chain.fromAddress(address)) {
    Chain.ethereum => await sl<EthereumTokenService>().getCachedBalances(
      address,
    ),
    Chain.tezos => await sl<TezosTokenService>().getCachedBalances(address),
    Chain.solana => await repo.getCachedBalances(address),
  };
  return cached.isEmpty ? null : repo.calculateTotalValue(cached);
}

/// Fresh USD total for [address] from that chain's backend, write-through
/// cached so the drawer and the tokens tab share one warm cache.
///
/// Throws whatever the underlying service throws — callers keep the cached
/// total they already painted rather than replacing it with a wrong zero.
Future<double> fetchWalletTotalUsd(String address) async {
  final repo = sl<TokenRepository>();
  final tokens = switch (Chain.fromAddress(address)) {
    // The Ethereum and Tezos services cache inside their own fetch; only the
    // Solana repository needs the explicit write-back.
    Chain.ethereum => await sl<EthereumTokenService>().getTokenBalances(
      address,
    ),
    Chain.tezos => await sl<TezosTokenService>().getTokenBalances(address),
    Chain.solana => await _solanaTokens(repo, address),
  };
  return repo.calculateTotalValue(tokens);
}

Future<List<TokenBalance>> _solanaTokens(
  TokenRepository repo,
  String address,
) async {
  final tokens = await repo.getTokenBalances(address);
  await repo.cacheBalances(address, tokens);
  return tokens;
}
