/// Token registry — port of `tokens`, minus the retired
/// memecoin listing currencies (`ART`, `SILLY`, `GUAC`, `VALUE`, `PXLPSHR`,
/// `WEN`, `FWOG`). Those are deliberately absent rather than stale: a mint the
/// registry doesn't key renders as nothing at all
/// (`PriceFormatter.formatRawAmount`), which is the same thing the webapp does
/// for an unrecognized currency — never a wrong number under a wrong ticker.
///
/// Used by listing flows (auction reserve price, buy-now price) to look up a
/// token's decimals, display precision, and minimum on-chain listing price.
/// On-chain prices are stored as raw integers in the smallest unit
/// (e.g. lamports for SOL); divide by `10^decimals` to render and multiply
/// when constructing payloads.
library;

import '../../shared/utils/chain.dart';
import '../config/environment.dart';

class MallowToken {
  const MallowToken({
    required this.symbol,
    required this.mint,
    required this.decimals,
    required this.inputDecimals,
    required this.minListingPrice,
    this.coinGeckoId,
    this.disablePrice = false,
    this.disableSwap = false,
    this.isDevnet = false,
  });

  /// Display symbol, e.g. "SOL", "USDC".
  final String symbol;

  /// Registry key: a base58 mint address on Solana, or the chain's own
  /// currency identifier elsewhere (the `xtz` sentinel, an FA contract).
  final String mint;

  /// On-chain precision — divide raw amount by `10^decimals` to render.
  final int decimals;

  /// Number of decimal places to show in number-input fields.
  final int inputDecimals;

  /// Minimum listing price as a raw on-chain amount (already scaled by
  /// `10^decimals`). e.g. SOL = 0.01 * 1e9 = 10_000_000.
  final int minListingPrice;

  final String? coinGeckoId;
  final bool disablePrice;
  final bool disableSwap;

  /// True for tokens scoped to devnet only — excluded from mainnet pickers.
  final bool isDevnet;

  /// Display amount = raw / 10^decimals.
  double rawToDisplay(int rawAmount) => rawAmount / _pow10(decimals).toDouble();

  /// Raw amount = display * 10^decimals (rounded to int).
  int displayToRaw(double display) => (display * _pow10(decimals)).round();

  /// Minimum listing price in display units.
  double get minListingDisplay => rawToDisplay(minListingPrice);
}

int _pow10(int n) {
  var v = 1;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

// Mint constants — kept in sync with `tokens` and
// `lib/core/utils/price_formatter.dart`.
const String solMint = 'So11111111111111111111111111111111111111112';
const String mallowSolMint = 'MLLWWq9TLHK3oQznWqwPyqD7kH4LXTHSKXK4yLz7LjD';
const String usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const String usdcDevMint = '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU';
const String usdStarMint = 'star9agSpjiFe3M49B3RniVU4CMBBEK3Qnaqn3RGiFM';
const String geckoMint = '6CNHDCzD5RkvBWxxyokQQNQPjFWgoHF94D7BmC73X6ZK';
const String foxyMint = 'FoXyMu5xwXre7zEoSvzViRk3nGawHUp9kUh97y2NDhcq';
const String bonkMint = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';
const String jupMint = 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN';
const String lspMint = 'BAy5FmGzFwcVcZq1yXaDvF1mEAChF3MPtBLrUMBsnLN9';
const String moutaiMint = '45EgCwcPXYagBC7KqBin4nCFgEZWN7f3Y6nACwxqMCWX';
const String stashMint = 'EWMfSJgDCE7CXDAYz3hbCaA7NsFHTnddySXx3shco2Hs';
const String buuMint = '28tVhteKZkzzWjrdHGXzxfm4SQkhrDrjLur9TYCDVULE';
const String boopMint = 'Gx2yQqgguqpKwGCrrgx4dr8toTYevczEtGd6B1pKpump';
const String gloomMint = 'Dx7MFxtRKGcVmLCT2ZVTKeCj9UcwyurSnhWH1B85moKK';
const String gcatsMint = 'UbESBaztbkxJRWxPcfDeK8Fft15igTbrv3sed1bsegM';
const String smoresMint = 'smoEhMZMweWBnpd1QoU4ZjuVNBxMFchqy4NRMBbtW7V';
const String xnuMint = 'EKuYvkDkNxkvGgpnmDJtFyp7bpaeKffMPp5DoTSJpHjs';
const String xnuDevMint = 'AgztsuN5VDesPvwoTosw2J5webyeHkURWKCbByG4LBAJ';
const String ethMint = '7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs';

/// Tezos listing currencies. Unlike the Solana tokens above these aren't
/// mints — objkt reports a listing's currency as either the `xtz` sentinel
/// (native tez) or the FA contract of a wrapped token — but they arrive on the
/// same `currencyMint` field, so the registry keys them the same way.
const String xtzMint = 'xtz';
const String oXtzMint = 'KT1TjnZYs5CGLbmV6yuW169P8Pnr9BiVwwjz';

const List<MallowToken> _tokens = [
  MallowToken(
    symbol: 'SOL',
    mint: solMint,
    decimals: 9,
    inputDecimals: 3,
    minListingPrice: 10000000, // 0.01 * 1e9
    coinGeckoId: 'solana',
  ),
  MallowToken(
    symbol: 'mallowSOL',
    mint: mallowSolMint,
    decimals: 9,
    inputDecimals: 3,
    minListingPrice: 10000000,
  ),
  MallowToken(
    symbol: 'oXTZ',
    mint: oXtzMint,
    decimals: 6,
    inputDecimals: 2,
    minListingPrice: 1000000, // 1 * 1e6
    coinGeckoId: 'tezos',
    disableSwap: true,
  ),
  MallowToken(
    symbol: 'XTZ',
    mint: xtzMint,
    decimals: 6,
    inputDecimals: 2,
    minListingPrice: 1000000,
    coinGeckoId: 'tezos',
    disableSwap: true,
  ),
  MallowToken(
    symbol: 'USDC',
    mint: usdcMint,
    decimals: 6,
    inputDecimals: 2,
    minListingPrice: 1000000,
    coinGeckoId: 'usd-coin',
  ),
  MallowToken(
    symbol: 'USD*',
    mint: usdStarMint,
    decimals: 6,
    inputDecimals: 2,
    minListingPrice: 1000000,
  ),
  MallowToken(
    symbol: 'SMORES',
    mint: smoresMint,
    decimals: 6,
    inputDecimals: 0,
    minListingPrice: 1000000,
  ),
  MallowToken(
    symbol: 'LSP',
    mint: lspMint,
    decimals: 6,
    inputDecimals: 0,
    minListingPrice: 3000000000, // 3_000 * 1e6
  ),
  MallowToken(
    symbol: 'BUU',
    mint: buuMint,
    decimals: 9,
    inputDecimals: 0,
    minListingPrice: 2500000000000, // 2_500 * 1e9
    disableSwap: true,
  ),
  MallowToken(
    symbol: 'STASH',
    mint: stashMint,
    decimals: 6,
    inputDecimals: 0,
    minListingPrice: 10000000000, // 10_000 * 1e6
  ),
  MallowToken(
    symbol: 'MOUTAI',
    mint: moutaiMint,
    decimals: 6,
    inputDecimals: 0,
    minListingPrice: 300000000, // 300 * 1e6
  ),
  MallowToken(
    symbol: 'JUP',
    mint: jupMint,
    decimals: 6,
    inputDecimals: 1,
    minListingPrice: 1000000,
    coinGeckoId: 'jupiter',
  ),
  MallowToken(
    symbol: 'BONK',
    mint: bonkMint,
    decimals: 5,
    inputDecimals: 0,
    minListingPrice: 5000000000, // 50_000 * 1e5
    coinGeckoId: 'bonk',
  ),
  MallowToken(
    symbol: 'FOXY',
    mint: foxyMint,
    decimals: 0,
    inputDecimals: 0,
    minListingPrice: 1000,
    coinGeckoId: 'famous-fox-federation',
  ),
  MallowToken(
    symbol: 'GECKO',
    mint: geckoMint,
    decimals: 6,
    inputDecimals: 0,
    minListingPrice: 5000000000, // 5_000 * 1e6
    coinGeckoId: 'gecko-meme',
  ),
  MallowToken(
    symbol: 'BOOP',
    mint: boopMint,
    decimals: 6,
    inputDecimals: 0,
    minListingPrice: 5000000000, // 5_000 * 1e6
  ),
  MallowToken(
    symbol: 'GLOOM',
    mint: gloomMint,
    decimals: 9,
    inputDecimals: 0,
    minListingPrice: 25000000000000, // 25_000 * 1e9
    disableSwap: true,
  ),
  MallowToken(
    symbol: 'GCATS',
    mint: gcatsMint,
    decimals: 6,
    inputDecimals: 0,
    minListingPrice: 8000000000, // 8_000 * 1e6
  ),
  MallowToken(
    symbol: 'XNU',
    mint: xnuMint,
    decimals: 9,
    inputDecimals: 9,
    minListingPrice: 100000000000, // 100 * 1e9
    disablePrice: true,
  ),
  MallowToken(
    symbol: 'ETH',
    mint: ethMint,
    decimals: 8,
    inputDecimals: 4,
    minListingPrice: 100000, // 0.001 * 1e8
    coinGeckoId: 'ethereum',
    disableSwap: true,
  ),
  // Devnet entries — kept for parity, excluded from the bid-currency picker.
  MallowToken(
    symbol: 'USDC_DEV',
    mint: usdcDevMint,
    decimals: 6,
    inputDecimals: 2,
    minListingPrice: 1000000,
    coinGeckoId: 'usd-coin',
    isDevnet: true,
  ),
  MallowToken(
    symbol: 'XNU_DEV',
    mint: xnuDevMint,
    decimals: 9,
    inputDecimals: 9,
    minListingPrice: 100000000000,
    disablePrice: true,
    isDevnet: true,
  ),
];

final Map<String, MallowToken> _tokenByMint = {
  for (final t in _tokens) t.mint: t,
};
final Map<String, MallowToken> _tokenBySymbol = {
  for (final t in _tokens) t.symbol: t,
};

/// Mints resolved at runtime from a DAS `getAsset` read, keyed the same way as
/// the static table. Owned by `core/services/token_metadata_service.dart`,
/// which is the only writer; this map is the read side so **every** existing
/// `tokenByMint` caller (price formatting, balance checks, proceeds
/// breakdowns) renders a resolved token correctly without being rewired.
///
/// Deliberately *not* folded into [_tokenByMint]: the static table is what
/// [mallowTokenMints], [swappableTokens] and [pickableBidTokens] mean by
/// "a mallow token", and a mint we merely learned the decimals of must never
/// become verified, swappable, or offerable in the seller's currency picker.
final Map<String, MallowToken> _resolvedTokens = {};

/// Publish a runtime-resolved token. Static registry entries always win, so a
/// bad DAS read can never shadow a curated entry.
void registerResolvedToken(MallowToken token) {
  if (_tokenByMint.containsKey(token.mint)) return;
  _resolvedTokens[token.mint] = token;
}

/// Whether [mint] is in the hand-maintained static table (as opposed to the
/// runtime overlay). Callers deciding *whether to look a mint up* must use
/// this, not [tokenByMint] — otherwise an already-overlaid entry reads as
/// registered and its 30-day TTL never expires.
bool isRegistryMint(String? mint) =>
    mint != null && _tokenByMint.containsKey(mint);

/// Test-only: drop every runtime-resolved entry. Nothing in `lib/` calls this.
void clearResolvedTokens() => _resolvedTokens.clear();

MallowToken? tokenByMint(String? mint) =>
    mint == null ? null : (_tokenByMint[mint] ?? _resolvedTokens[mint]);

MallowToken? tokenBySymbol(String symbol) => _tokenBySymbol[symbol];

/// All mints in the mallow token registry — used by the wallet to treat
/// hardcoded tokens as verified even when Jupiter's `verified` tag set
/// doesn't include them.
final Set<String> mallowTokenMints = Set.unmodifiable(_tokenByMint.keys);

MallowToken get defaultBidToken => _tokenByMint[solMint]!;

/// The currency a chain settles in natively, or null for an unknown or absent
/// chain. Port of the webapp's `getBaseTokenForChain` (which throws on an
/// unsupported chain; callers here fall back to SOL conventions instead).
///
/// Answers "what does a price with no `currencyMint` mean on this chain" — a
/// tez-denominated price must not render with SOL's symbol and 1e9 scaling
/// instead of tez's 1e6. It is **not** a fallback for a currency the registry
/// doesn't key: an unkeyed mint (an objkt FA contract, an ERC-20) is not the
/// chain's base token, and rendering it as one produces a wrong number under a
/// wrong ticker. Those resolve through `TokenMetadataService` or not at all.
MallowToken? baseTokenForChain(String? chain) =>
    switch (Chain.tryParse(chain)) {
      Chain.solana => _tokenByMint[solMint],
      Chain.ethereum => _tokenByMint[ethMint],
      Chain.tezos => _tokenByMint[xtzMint],
      null => null,
    };

/// Registry tokens offered in the swap buy-side picker even when the user
/// doesn't hold them yet.
List<MallowToken> swappableTokens() =>
    _tokens.where((t) => !t.isDevnet && !t.disableSwap).toList(growable: false);

/// Default symbols shown in the seller's currency picker. Mirrors
/// `DEFAULT_TOKEN_SYMBOLS` in `Constants`, where the
/// USDC entry is swapped for USDC_DEV on devnet so listings use the devnet
/// mint instead of the real mainnet one.
List<String> get defaultListingTokenSymbols => Config.isDevnet
    ? const ['SOL', 'mallowSOL', 'USDC_DEV', 'SMORES', 'LSP']
    : const ['SOL', 'mallowSOL', 'USDC', 'SMORES', 'LSP'];

/// Tokens eligible for the seller's currency picker — the default short list
/// plus any extra mints the user has explicitly enabled on their profile
/// (`User.listingTokenMints`). Mirrors `getTokenOptionsForUser` in
/// `Constants`: devnet-only tokens are excluded on
/// mainnet but kept on devnet.
List<MallowToken> pickableBidTokens({List<String>? userListingMints}) => _tokens
    .where((t) => Config.isDevnet ? true : !t.isDevnet)
    .where(
      (t) =>
          defaultListingTokenSymbols.contains(t.symbol) ||
          (userListingMints?.contains(t.mint) ?? false),
    )
    .toList(growable: false);
