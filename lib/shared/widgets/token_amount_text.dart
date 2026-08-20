import 'package:flutter/material.dart';

import '../../core/data/mallow_tokens.dart';
import '../../core/services/token_metadata_service.dart';
import '../../core/utils/price_formatter.dart';
import '../../di.dart';
import 'loading_indicator.dart';

/// A price in a currency that may not be in the static token registry.
///
/// Registry mints (and non-Solana chains, which resolve through
/// `baseTokenForChain`) render synchronously as a plain [Text] — byte-identical
/// to calling [PriceFormatter] directly, with no shimmer and no extra frame.
/// Everything else goes through [TokenMetadataService]:
///
///   * lookup in flight → [ShimmerBox] placeholder;
///   * resolved → the full scaled amount, with the real symbol;
///   * failed → [kUnknownTokenLabel].
///
/// The three states exist because the alternative degradations are both
/// dishonest: with no `chain` the amount silently vanished, and with one it
/// was reformatted at the native token's decimals — a 5,000 WEN sale rendered
/// "0.5 SOL".
class TokenAmountText extends StatefulWidget {
  const TokenAmountText({
    required this.rawAmount,
    required this.currencyMint,
    this.chain,
    this.style,
    this.withSymbol = true,
    this.precise = false,
    this.shimmerWidth = 72,
    this.textAlign,
    super.key,
  });

  /// Atomic (smallest-unit) amount, as it arrives from the API.
  final double? rawAmount;
  final String? currencyMint;

  /// The artwork / market event's wire chain value, when the caller knows it.
  final String? chain;

  final TextStyle? style;
  final bool withSymbol;

  /// Render at the token's full on-chain precision
  /// ([PriceFormatter.formatRawAmountPrecise]) instead of its display
  /// precision — for fee / proceeds rows.
  final bool precise;

  final double shimmerWidth;
  final TextAlign? textAlign;

  @override
  State<TokenAmountText> createState() => _TokenAmountTextState();
}

class _TokenAmountTextState extends State<TokenAmountText> {
  /// Non-null only while this row is waiting on a lookup. Held in state (not
  /// created in `build`) so a rebuild doesn't restart the request.
  Future<MallowToken?>? _lookup;

  @override
  void initState() {
    super.initState();
    _kickLookup();
  }

  @override
  void didUpdateWidget(TokenAmountText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currencyMint != widget.currencyMint ||
        oldWidget.chain != widget.chain) {
      _kickLookup();
    }
  }

  void _kickLookup() {
    final service = sl<TokenMetadataService>();
    if (!service.needsLookup(widget.currencyMint, chain: widget.chain)) {
      _lookup = null;
      return;
    }
    _lookup = service.resolve(widget.currencyMint, chain: widget.chain);
  }

  String get _formatted {
    final amount = widget.rawAmount;
    final mint = widget.currencyMint;
    final chain = widget.chain;
    if (widget.precise) {
      return widget.withSymbol
          ? PriceFormatter.formatRawAmountPreciseWithSymbol(
              amount,
              mint,
              chain: chain,
            )
          : PriceFormatter.formatRawAmountPrecise(amount, mint, chain: chain);
    }
    return widget.withSymbol
        ? PriceFormatter.formatRawAmountWithSymbol(amount, mint, chain: chain)
        : PriceFormatter.formatRawAmount(amount, mint, chain: chain);
  }

  Widget _text(String value) =>
      Text(value, style: widget.style, textAlign: widget.textAlign);

  @override
  Widget build(BuildContext context) {
    final lookup = _lookup;
    if (lookup == null) return _text(_formatted);
    return FutureBuilder<MallowToken?>(
      future: lookup,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return ShimmerBox(
            width: widget.shimmerWidth,
            height: (widget.style?.fontSize ?? 14) * 1.2,
          );
        }
        if (snapshot.data == null) return _text(kUnknownTokenLabel);
        return _text(_formatted);
      },
    );
  }
}
