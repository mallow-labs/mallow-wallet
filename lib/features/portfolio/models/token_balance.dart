import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:mallow_api/mallow_api.dart' show EvmHolding;

import '../../../core/data/mallow_tokens.dart' as mallow_tokens;
import '../../../core/utils/address_format.dart';

import '../../../shared/utils/chain.dart';
part 'token_balance.freezed.dart';
part 'token_balance.g.dart';

int _pow10(int exp) {
  var result = 1;
  for (var i = 0; i < exp; i++) {
    result *= 10;
  }
  return result;
}

/// `10^exp` as a double — used for EVM UI-balance math where the raw amount
/// (wei, 18 decimals) can exceed the int64 range and must come from a [BigInt].
double _pow10Double(int exp) {
  var result = 1.0;
  for (var i = 0; i < exp; i++) {
    result *= 10;
  }
  return result;
}

@freezed
sealed class TokenBalance with _$TokenBalance {
  const factory TokenBalance({
    required String mint,
    required String symbol,
    required String name,
    required int decimals,
    required int rawBalance,
    required double uiBalance,
    String? logoUrl,
    double? pricePerToken,
    double? totalUsdValue,

    /// 24-hour price change as a percentage (e.g. -5.23 means -5.23%).
    double? priceChange24h,

    /// True for the native chain asset (e.g. native SOL). Distinguishes it
    /// from the wrapped SPL variant, which shares the same mint address.
    @Default(false) bool isNative,

    /// True when the mint carries Jupiter's `verified` tag (Solana) or appears
    /// on the Uniswap token list (Ethereum), or when it's one of
    /// [alwaysVerifiedMints]. Used to surface unrecognized airdrops in a
    /// separate "Unverified tokens" section.
    @Default(false) bool isVerified,

    /// Which chain this balance lives on. Defaults to Solana so every existing
    /// call-site and cached row (written before multi-chain) stays valid.
    @Default(Chain.solana) Chain chain,
  }) = _TokenBalance;
  const TokenBalance._();

  factory TokenBalance.fromJson(Map<String, dynamic> json) =>
      _$TokenBalanceFromJson(json);

  /// Creates a [TokenBalance] for native SOL.
  ///
  /// [lamports] - The balance in lamports (1 SOL = 1e9 lamports).
  /// [pricePerToken] - Optional USD price per SOL from Jupiter.
  factory TokenBalance.nativeSol({
    required int lamports,
    double? pricePerToken,
  }) {
    const decimals = 9;
    final uiBalance = lamports / _pow10(decimals);
    return TokenBalance(
      mint: solMint,
      symbol: 'SOL',
      name: 'Solana',
      decimals: decimals,
      rawBalance: lamports,
      uiBalance: uiBalance,
      logoUrl: solLogoUrl,
      pricePerToken: pricePerToken,
      totalUsdValue: pricePerToken != null ? uiBalance * pricePerToken : null,
      isNative: true,
      isVerified: true,
    );
  }

  /// Creates a 0-or-more native ETH [TokenBalance]. [wei] is the balance in
  /// wei (1 ETH = 1e18); defaults to zero for the empty-state placeholder.
  factory TokenBalance.nativeEth({BigInt? wei, double? pricePerToken}) {
    const decimals = 18;
    final raw = wei ?? BigInt.zero;
    final uiBalance = raw.toDouble() / _pow10Double(decimals);
    final clampedRaw = raw.isValidInt ? raw.toInt() : _maxSafeInt;
    return TokenBalance(
      mint: evmNativeSentinel,
      symbol: 'ETH',
      name: 'Ethereum',
      decimals: decimals,
      rawBalance: clampedRaw,
      uiBalance: uiBalance,
      logoUrl: ethLogoUrl,
      pricePerToken: pricePerToken,
      totalUsdValue: pricePerToken != null ? uiBalance * pricePerToken : null,
      isNative: true,
      isVerified: true,
      chain: Chain.ethereum,
    );
  }

  /// Creates a 0-or-more native XTZ [TokenBalance]. [mutez] is the balance in
  /// mutez (1 XTZ = 1e6); defaults to zero for the empty-state placeholder.
  factory TokenBalance.nativeTezos({int mutez = 0, double? pricePerToken}) {
    const decimals = 6;
    final uiBalance = mutez / _pow10(decimals);
    return TokenBalance(
      mint: tezosNativeSentinel,
      symbol: 'XTZ',
      name: 'Tezos',
      decimals: decimals,
      rawBalance: mutez,
      uiBalance: uiBalance,
      logoUrl: tezosLogoUrl,
      pricePerToken: pricePerToken,
      totalUsdValue: pricePerToken != null ? uiBalance * pricePerToken : null,
      isNative: true,
      isVerified: true,
      chain: Chain.tezos,
    );
  }

  /// Zero-balance native ("base") token for [chain] — SOL for Solana, ETH for
  /// Ethereum, XTZ for Tezos. Used to seed a swap's buy side; the actual
  /// balance is filled in once [TokenBalanceBloc] refreshes the selection.
  factory TokenBalance.nativeForChain(Chain chain) => switch (chain) {
    Chain.solana => TokenBalance.nativeSol(lamports: 0),
    Chain.ethereum => TokenBalance.nativeEth(),
    Chain.tezos => TokenBalance.nativeTezos(),
  };

  factory TokenBalance.fromHeliusAsset(Map<String, dynamic> asset) {
    final tokenInfo = asset['token_info'] as Map<String, dynamic>?;
    final content = asset['content'] as Map<String, dynamic>?;
    final metadata = content?['metadata'] as Map<String, dynamic>?;
    final files = (content?['files'] as List?)?.cast<Map<String, dynamic>>();
    final priceInfo = tokenInfo?['price_info'] as Map<String, dynamic>?;

    final decimals = (tokenInfo?['decimals'] as num?)?.toInt() ?? 0;
    final rawBalance = (tokenInfo?['balance'] as num?)?.toInt() ?? 0;
    final uiBalance = decimals > 0
        ? rawBalance / _pow10(decimals)
        : rawBalance.toDouble();

    final mint = asset['id'] as String;
    final override = _metadataOverrides[mint];
    final registry = mallow_tokens.tokenByMint(mint);

    return TokenBalance(
      mint: mint,
      symbol:
          override?.symbol ??
          registry?.symbol ??
          tokenInfo?['symbol'] as String? ??
          metadata?['symbol'] as String? ??
          '',
      name:
          override?.name ??
          metadata?['name'] as String? ??
          truncateAddress(mint),
      decimals: decimals,
      rawBalance: rawBalance,
      uiBalance: uiBalance,
      logoUrl: _logoOverrides[mint] ?? files?.firstOrNull?['uri'] as String?,
      pricePerToken: (priceInfo?['price_per_token'] as num?)?.toDouble(),
      totalUsdValue: (priceInfo?['total_price'] as num?)?.toDouble(),
    );
  }

  /// Builds a [TokenBalance] from one generated [EvmHolding] row of the backend
  /// EVM balances response (`GET {apiV2BaseUrl}/evm/balances`, and the reused
  /// `/tezos/balances`). Fields come from the OpenAPI-generated model:
  /// `contractAddress` ([evmNativeSentinel] for the native coin), `symbol`,
  /// `name`, `decimals`, `rawBalance` (string, atomic units), `logoUrl`,
  /// `usdPrice`, `priceChange24h`.
  ///
  /// `rawBalance` is parsed as a [BigInt] so 18-decimal wei amounts above the
  /// int64 range don't overflow when computing [uiBalance]; the int [rawBalance]
  /// field is clamped (it is unused on the display-only path — a future EVM
  /// send must carry full-precision wei separately, not via this int).
  /// [isVerified] is left false here and resolved by the service against the
  /// cached Uniswap token list.
  factory TokenBalance.fromEvmHolding(
    EvmHolding holding, {
    Chain chain = Chain.ethereum,
  }) {
    final contract = holding.contractAddress.trim();
    final rawContract = contract.toLowerCase();
    final isNative = rawContract.isEmpty || rawContract == evmNativeSentinel;
    final decimals = holding.decimals?.toInt() ?? 18;

    final raw = BigInt.tryParse(holding.rawBalance) ?? BigInt.zero;
    final uiBalance = decimals > 0
        ? raw.toDouble() / _pow10Double(decimals)
        : raw.toDouble();
    final clampedRaw = raw.isValidInt ? raw.toInt() : _maxSafeInt;

    final price = holding.usdPrice;
    // Native-coin mint sentinel is chain-specific: Tezos (XTZ) has its own
    // [tezosNativeSentinel] that the send/detail/pricing flows key off — using
    // the EVM sentinel here would make those lookups miss and the wallet read
    // as holding no XTZ (e.g. "No Tezos wallet available to send from").
    final isTezosNative = isNative && chain == Chain.tezos;
    // 🛑 Only EVM contracts are lowercased. EVM hex is case-insensitive and the
    // backend/token-list/CDN all key it lowercase, so an EIP-55 address must be
    // folded. Tezos base58 is case-SENSITIVE: a lowercased `KT1…` is not the
    // same address, so it can't be used as a TzKT `token.contract` filter (the
    // per-token History tab) or as an FA transfer destination.
    final mint = isNative
        ? (isTezosNative ? tezosNativeSentinel : evmNativeSentinel)
        : (chain == Chain.tezos ? contract : rawContract);

    return TokenBalance(
      mint: mint,
      symbol: holding.symbol?.trim() ?? '',
      name: holding.name?.trim().isNotEmpty == true
          ? holding.name!.trim()
          : (isNative
                ? (isTezosNative ? 'Tezos' : 'Ethereum')
                : truncateAddress(mint)),
      decimals: decimals,
      rawBalance: clampedRaw,
      uiBalance: uiBalance,
      logoUrl: holding.logoUrl?.trim(),
      pricePerToken: price,
      totalUsdValue: price != null ? uiBalance * price : null,
      priceChange24h: holding.priceChange24h,
      isNative: isNative,
      chain: chain,
    );
  }

  /// True when this balance lives on an EVM chain (Ethereum today).
  bool get isEvm => chain == Chain.ethereum;

  /// True when [rawBalance] hit the int64 ceiling and is therefore a **floor**,
  /// not the amount held: the parsers clamp any atomic balance past int64 to
  /// [_maxSafeInt], and the exact figure is discarded there.
  ///
  /// Any token with enough decimals can trip this — 18-decimal ERC-20s, and on
  /// Tezos the 18-decimal FA1.2s (kUSD, PLY), where holding more than ~9.22
  /// tokens is already past the ceiling. Spending paths must treat a clamped
  /// balance as *unknown* rather than as the number: comparing against it
  /// false-blocks a legitimate amount, and offering it as Max silently
  /// under-sends. [uiBalance] is computed from the exact [BigInt] **before**
  /// the clamp, so it remains a good ~16-significant-digit approximation.
  ///
  /// A holding of exactly [_maxSafeInt] atomic units reads as clamped. That
  /// costs nothing: every caller's fallback is the conservative branch.
  bool get isRawBalanceClamped => rawBalance == _maxSafeInt;

  /// True only when the price feed **affirmatively** priced this token's
  /// holding at zero — we *know* it is worth nothing, as opposed to a value we
  /// merely failed to look up. Signing surfaces use this to skip the step-up
  /// auth gate for genuinely worthless dust (see [TransactionAuthGate]).
  ///
  /// Fail-closed by construction: a missing / null price (feed outage, indexer
  /// gap, newly-listed-but-valuable token) leaves [totalUsdValue] null, which
  /// is never `== 0`, so this stays false and the gate still applies. Only an
  /// explicit `0` from the feed skips auth. Native coins (SOL/ETH/XTZ) are
  /// excluded: they always carry real value, so a missing price there is a
  /// failed lookup, not worthlessness.
  bool get hasKnownZeroValue => !isNative && totalUsdValue == 0;

  /// Sentinel [mint] for a non-Solana chain's native coin (e.g. native ETH),
  /// which has no contract address. Solana keeps its real [solMint].
  static const evmNativeSentinel = 'native';

  /// Sentinel [mint] for native Tezos (XTZ), which has no contract address.
  static const tezosNativeSentinel = 'tez-native';

  /// Applies per-mint metadata overrides (name/symbol) to a [TokenBalance],
  /// returning a new instance when an override exists. Used on cache reads
  /// so legacy cached entries pick up overrides without a refresh.
  ///
  /// Precedence: explicit [_metadataOverrides] entry (name + symbol) ->
  /// mallow token registry (symbol only) -> existing cached values.
  static TokenBalance applyMetadataOverrides(TokenBalance token) {
    final override = _metadataOverrides[token.mint];
    if (override != null) {
      return token.copyWith(name: override.name, symbol: override.symbol);
    }
    final registry = mallow_tokens.tokenByMint(token.mint);
    if (registry != null && registry.symbol != token.symbol) {
      return token.copyWith(symbol: registry.symbol);
    }
    return token;
  }

  /// Largest int64 — fallback for EVM raw balances that overflow [int] (the
  /// int [rawBalance] is display-vestigial; [uiBalance] holds the real value).
  static const _maxSafeInt = 9223372036854775807;

  /// Native SOL mint address (wrapped SOL).
  static const solMint = 'So11111111111111111111111111111111111111112';

  /// Standard Solana logo URL from the token list.
  static const solLogoUrl =
      'https://raw.githubusercontent.com/solana-labs/token-list/main/assets/mainnet/So11111111111111111111111111111111111111112/logo.png';

  /// Native ETH / XTZ logo URLs (Trust Wallet assets), used for the empty-state
  /// gas-token placeholder rows where no backend balance has been fetched.
  static const ethLogoUrl =
      'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/info/logo.png';
  static const tezosLogoUrl =
      'https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tezos/info/logo.png';

  /// Mints we always treat as verified regardless of Jupiter's tags. Pulled
  /// from the mallow token registry so any token we've hardcoded in
  /// `mallow_tokens.dart` (SMORES, USDC_DEV, GLOOM, BUU, etc.) is trusted even
  /// when Jupiter hasn't tagged it as verified.
  static final Set<String> alwaysVerifiedMints = mallow_tokens.mallowTokenMints;

  /// Per-mint logo URL overrides (takes priority over Helius metadata).
  static const _logoOverrides = <String, String>{
    'smoEhMZMweWBnpd1QoU4ZjuVNBxMFchqy4NRMBbtW7V':
        'https://ipfs.io/ipfs/QmXELXMhWsfJRJjq6HkS4RKo74jAoSPUVt4K1aKUFpVooG',
  };

  /// Per-mint name/symbol overrides applied at parse + cache-read time.
  /// Local-asset image overrides live in `token_image_utils.dart`.
  static const _metadataOverrides = <String, ({String name, String symbol})>{
    '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU': (
      name: 'USDC (DEV)',
      symbol: 'USDC_DEV',
    ),
  };
}
