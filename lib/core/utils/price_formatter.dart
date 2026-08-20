import 'dart:math';

import '../../shared/utils/price_format.dart'
    show groupThousands, stripTrailingZeros;
import '../data/mallow_tokens.dart';

/// Copy shown in place of a figure when a currency cannot be resolved.
///
/// Declared here rather than beside `TokenMetadataService` because the
/// formatters are the first place an unresolvable currency surfaces: only a
/// handful of price surfaces route through `TokenAmountText`, and every other
/// caller would otherwise render a blank where a price belongs.
const String kUnknownTokenLabel = 'Unknown token';

/// Price formatting utilities matching the server's own `formatPrice` logic.
///
/// All on-chain prices from the mallow API (buyNowMetadata.amount, lastSale.price)
/// are in raw smallest units (e.g. lamports for SOL). This class handles conversion
/// to display format and formatting with K/M/B abbreviations.
class PriceFormatter {
  const PriceFormatter._();

  // Well-known token mint addresses
  static const solMint = 'So11111111111111111111111111111111111111112';
  static const mallowSolMint = 'MLLWWq9TLHK3oQznWqwPyqD7kH4LXTHSKXK4yLz7LjD';
  static const usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
  static const usdcDevMint = '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU';
  static const usdStarMint = 'star9agSpjiFe3M49B3RniVU4CMBBEK3Qnaqn3RGiFM';
  static const bonkMint = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';
  static const jupMint = 'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN';
  static const ethMint = '7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs';

  /// The registry token an amount should be rendered in, or null when the
  /// currency cannot be identified.
  ///
  /// Resolved from the canonical [tokenByMint] registry (`mallow_tokens.dart`)
  /// so every supported token (SMORES, LSP, etc.) formats with the correct
  /// decimals and symbol.
  ///
  /// An **absent** mint means "this chain's native currency" — [chain]'s
  /// [baseTokenForChain], defaulting to SOL exactly as the webapp does
  /// (`PriceDisplay` `price?.currencyMint ?? SOL`).
  ///
  /// A **present but unregistered** mint returns null: its decimals and symbol
  /// are unknown, so any rendering is a guess. The native currency is
  /// deliberately NOT a fallback here — falling through to SOL's 9 decimals
  /// turned 5,000 WEN into `0.5 SOL`, a wrong number under a wrong ticker,
  /// which is worse than admitting the currency is unknown. The same holds for
  /// EVM/Tezos: an unkeyed ERC-20 is not ETH just because the event says
  /// `ethereum`. The callers below render [kUnknownTokenLabel] instead; the
  /// webapp drops the slot entirely (`PriceDisplay`), but mobile
  /// callers paint the returned string into a fixed row, so an empty string is
  /// a blank where a price belongs rather than an absent row.
  ///
  /// The real resolution path for an unkeyed mint is `TokenMetadataService`,
  /// which publishes DAS-resolved entries into the registry overlay — so this
  /// returns the right token as soon as the lookup lands.
  static MallowToken? _token(String? mint, {String? chain}) =>
      (mint == null || mint.isEmpty)
      ? (baseTokenForChain(chain) ?? tokenByMint(solMint))
      : tokenByMint(mint);

  /// Whether [display] should enter the abbreviation path.
  ///
  /// Matches React: `Big(shortAmount).round(0, Big.roundUp).div(1000).round().gt(0)`
  /// i.e. ceil(abs) / 1000, rounded to nearest integer, > 0.
  static bool _shouldAbbreviate(double display) {
    final ceiled = display.abs().ceil();
    return (ceiled / 1000).round() > 0;
  }

  /// Abbreviate a display-unit amount matching React `abbreviateAmount` exactly.
  ///
  /// Steps: ceil → divide by 1000 → classify tier → round with roundUp. Each
  /// tier's number is thousands-grouped, matching the `.toLocaleString()` the
  /// webapp applies to every branch (`tokens`).
  static String abbreviateAmount(double amount, {int decimalPlaces = 2}) {
    final ceiled = amount.abs().ceil().toDouble() * amount.sign;
    final thousands = double.parse(
      (ceiled / 1000).toStringAsFixed(decimalPlaces),
    );
    final absThousands = thousands.abs();

    String tier(double value, String suffix) =>
        groupThousands(
          stripTrailingZeros(value.toStringAsFixed(decimalPlaces)),
        ) +
        suffix;

    if (absThousands >= 1000000) {
      final ct = thousands.abs().ceil().toDouble() * thousands.sign;
      return tier(_roundUp(ct / 1000000, decimalPlaces), 'B');
    }
    if (absThousands >= 1000) {
      final ct = thousands.abs().ceil().toDouble() * thousands.sign;
      return tier(_roundUp(ct / 1000, decimalPlaces), 'M');
    }
    if (absThousands >= 1) {
      return tier(_roundUp(thousands, decimalPlaces), 'K');
    }
    // Sub-K but still in the abbreviated path (500–999 range)
    return tier(_roundUp(amount, decimalPlaces), '');
  }

  /// Round away from zero (matches Big.roundUp behavior).
  static double _roundUp(double value, int decimals) {
    final factor = pow(10, decimals).toDouble();
    if (value >= 0) {
      return (value * factor).ceilToDouble() / factor;
    } else {
      return (value * factor).floorToDouble() / factor;
    }
  }

  /// Format a raw (lamport-level) token price to a display string.
  ///
  /// Divides by 10^onChainDecimals, rounds down to displayDecimals,
  /// and abbreviates if the value is ≥ 1,000.
  ///
  /// Returns "0" if [rawAmount] is null or zero, and [kUnknownTokenLabel] when
  /// [currencyMint] is a mint the registry doesn't key (see [_token]).
  ///
  /// Pass [chain] (a marketplace event's wire chain value) so an **absent**
  /// [currencyMint] resolves to that chain's native currency instead of
  /// defaulting to SOL. It does not rescue an unregistered mint — see [_token].
  static String formatRawAmount(
    double? rawAmount,
    String? currencyMint, {
    String? chain,
  }) {
    final token = _token(currencyMint, chain: chain);
    if (token == null) return kUnknownTokenLabel;
    if (rawAmount == null || rawAmount == 0) return '0';

    final display = rawAmount / pow(10, token.decimals);

    // Abbreviate if threshold met (matches React formatPrice logic)
    if (_shouldAbbreviate(display)) {
      return abbreviateAmount(display);
    }

    // Truncate (round down) to displayDecimals — matches Big.roundDown default
    return groupThousands(_truncate(display, token.inputDecimals));
  }

  /// Same as [formatRawAmount] but appends the token symbol.
  ///
  /// Returns empty string if [rawAmount] is null, and [kUnknownTokenLabel] —
  /// with no symbol to append — when the currency is unknown.
  static String formatRawAmountWithSymbol(
    double? rawAmount,
    String? currencyMint, {
    String? chain,
  }) {
    if (rawAmount == null) return '';
    final token = _token(currencyMint, chain: chain);
    if (token == null) return kUnknownTokenLabel;
    return '${formatRawAmount(rawAmount, currencyMint, chain: chain)} '
        '${token.symbol}';
  }

  /// Format an amount that is **already in display units** (not raw base
  /// units) — the webapp's `formatPrice({ isShortAmount: true })`. The
  /// collection floor arrives this way.
  ///
  /// [kUnknownTokenLabel] for an unresolvable currency, matching
  /// [formatRawAmount].
  static String formatDisplayAmount(
    double? amount,
    String? currencyMint, {
    String? chain,
  }) {
    final token = _token(currencyMint, chain: chain);
    if (token == null) return kUnknownTokenLabel;
    if (amount == null || amount == 0) return '0';
    if (_shouldAbbreviate(amount)) return abbreviateAmount(amount);
    return groupThousands(_truncate(amount, token.inputDecimals));
  }

  /// The word that replaces a listing price, or null when there is a real
  /// amount to render. See [formatListingPrice] for the cases and their
  /// webapp source.
  static String? listingPriceWord(
    double? rawAmount, {
    bool buyerSetsPrice = false,
    bool showZero = false,
  }) {
    if (buyerSetsPrice) return 'Set your own price';
    if (rawAmount == null) return 'Not listed';
    if (rawAmount == 0 && !showZero) return 'Free';
    return null;
  }

  /// The webapp's `PriceDisplay` copy for a listing-price slot
  /// (`PriceDisplay`), which replaces
  /// the number with a word in three cases:
  ///
  /// * [buyerSetsPrice] — a SYOP listing's on-chain price is 0, so the number
  ///   carries no information (webapp passes `amount: -1` and renders
  ///   "Set your own price" wherever `fullSYOP` is set, which every card is).
  /// * [rawAmount] null — "Not listed".
  /// * [rawAmount] zero — "Free" (a free mint), unless [showZero].
  ///
  /// Callers that hide the whole price row when there is no listing keep doing
  /// so; this is for slots that always render something. A widget that needs
  /// to *know* it is showing a word — to drop a token icon or a USD estimate
  /// that would be meaningless beside it — should call [listingPriceWord].
  static String formatListingPrice(
    double? rawAmount,
    String? currencyMint, {
    String? chain,
    bool buyerSetsPrice = false,
    bool showZero = false,
    bool withSymbol = true,
  }) {
    final word = listingPriceWord(
      rawAmount,
      buyerSetsPrice: buyerSetsPrice,
      showZero: showZero,
    );
    if (word != null) return word;
    return withSymbol
        ? formatRawAmountWithSymbol(rawAmount, currencyMint, chain: chain)
        : formatRawAmount(rawAmount, currencyMint, chain: chain);
  }

  /// Like [formatRawAmount] but renders at the token's full on-chain precision
  /// (trailing zeros stripped) instead of its coarser display/input precision.
  ///
  /// Use for fee / proceeds breakdowns where amounts are fractions of a unit:
  /// a 2% fee on a token whose `inputDecimals` is 0 (whole-number listings,
  /// e.g. SMORES) would otherwise truncate to "0". Large values still
  /// abbreviate, matching [formatRawAmount].
  ///
  /// [chain] is the artwork/activity's wire chain value. Pass it wherever the
  /// caller knows it: without it a price carrying no [currencyMint] defaults to
  /// SOL rather than to the chain's own native currency.
  static String formatRawAmountPrecise(
    double? rawAmount,
    String? currencyMint, {
    String? chain,
  }) {
    final token = _token(currencyMint, chain: chain);
    if (token == null) return kUnknownTokenLabel;
    if (rawAmount == null || rawAmount == 0) return '0';
    final display = rawAmount / pow(10, token.decimals);
    if (_shouldAbbreviate(display)) return abbreviateAmount(display);
    return groupThousands(_truncate(display, token.decimals));
  }

  /// [formatRawAmountPrecise] with the token symbol appended. Empty string
  /// when [rawAmount] is null, [kUnknownTokenLabel] when the currency is
  /// unknown.
  static String formatRawAmountPreciseWithSymbol(
    double? rawAmount,
    String? currencyMint, {
    String? chain,
  }) {
    if (rawAmount == null) return '';
    final token = _token(currencyMint, chain: chain);
    if (token == null) return kUnknownTokenLabel;
    final amount = formatRawAmountPrecise(
      rawAmount,
      currencyMint,
      chain: chain,
    );
    return '$amount ${token.symbol}';
  }

  /// Lamports-to-SOL renderer for confirmation-sheet fee/total rows.
  ///
  /// Network fees and rent deltas are small (often a few thousand lamports),
  /// so [formatRawAmount]'s 3-decimal SOL cap rounds them to "0 SOL". This
  /// path uses 6-decimal precision instead so dust-level amounts stay
  /// visible. Zero stays "0 SOL".
  static String formatFeeLamports(int lamports, {String sign = ''}) {
    if (lamports == 0) return '0 SOL';
    final sol = lamports.abs() / 1e9;
    final effectiveSign = lamports < 0 ? '-' : sign;
    return '$effectiveSign${stripTrailingZeros(sol.toStringAsFixed(6))} SOL';
  }

  /// Truncate (floor toward zero) [value] to [decimals] decimal places.
  /// Strips trailing zeros after the decimal point.
  static String _truncate(double value, int decimals) {
    if (decimals == 0) return value.truncate().toString();
    final factor = pow(10, decimals).toDouble();
    final truncated = (value * factor).truncateToDouble() / factor;
    return stripTrailingZeros(truncated.toStringAsFixed(decimals));
  }

  /// Compact display-amount token formatting with M/K abbreviation.
  ///
  /// [amount] is in display units (not raw). [decimals] is the token's
  /// native decimals; the value is clamped per magnitude tier so 1.2M
  /// reads cleaner than 1.234567M. Tighter list contexts can pass
  /// [maxBaseDecimals] / [maxSubDecimals] to shrink the caps further.
  static String formatCompactAmount(
    double amount,
    int decimals, {
    int maxBaseDecimals = 4,
    int maxSubDecimals = 6,
  }) {
    if (amount >= 1000000) {
      return '${(amount / 1000000).toStringAsFixed(decimals.clamp(0, 2))}M';
    }
    if (amount >= 1000) {
      return '${(amount / 1000).toStringAsFixed(decimals.clamp(0, 2))}K';
    }
    if (amount >= 1) {
      return amount.toStringAsFixed(decimals.clamp(0, maxBaseDecimals));
    }
    return amount.toStringAsFixed(decimals.clamp(0, maxSubDecimals));
  }

  /// Compact activity-price formatting: K above 1000, otherwise 4 decimals
  /// with trailing zeros stripped. Suited to marketplace prices already in
  /// display units (e.g. SOL).
  static String formatCompactPrice(double price) {
    if (price >= 1000) {
      return '${(price / 1000).toStringAsFixed(1)}K';
    }
    return stripTrailingZeros(price.toStringAsFixed(4));
  }

  /// Magnitude-tiered spot-price formatting for USD-style values.
  ///
  /// >= 1000  → "1.2K"        (1 decimal)
  /// >= 1     → "12.34"       (2 decimals)
  /// >= 0.001 → "0.1234"      (4 decimals)
  /// else     → "0.00000123"  (8 decimals)
  static String formatSpotPrice(double price) {
    if (price >= 1000) return '${(price / 1000).toStringAsFixed(1)}K';
    if (price >= 1) return price.toStringAsFixed(2);
    if (price >= 0.001) return price.toStringAsFixed(4);
    return price.toStringAsFixed(8);
  }

  /// Compact fiat/value formatting with M/K abbreviation and 2-decimal
  /// precision. Used for market cap and volume figures.
  static String formatCompactValue(double value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(2)}K';
    return value.toStringAsFixed(2);
  }
}
