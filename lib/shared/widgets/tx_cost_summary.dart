import 'package:flutter/material.dart';

import '../../core/utils/price_formatter.dart';
import '../theme/mallow_theme.dart';
import 'generic_confirmation_sheet.dart';
import 'loading_indicator.dart';

/// One row inside a [TxCostSummary]. Use the named constructors so every
/// confirmation sheet formats fees, token amounts, and loaders the same way.
class TxCostLine {
  const TxCostLine._({
    required this.label,
    this.value,
    this.valueChild,
    this.valueColor,
  }) : assert(
         value != null || valueChild != null,
         'Provide either value (String) or valueChild (Widget).',
       );

  /// SOL fee/total row sourced from raw lamports.
  ///
  /// [sign] is prepended to the formatted amount (`'-'` for outgoing,
  /// `'+'` for incoming). Renders via [PriceFormatter.formatFeeLamports],
  /// which uses 6-decimal precision so dust-level fees stay visible
  /// instead of rounding to "0 SOL".
  factory TxCostLine.lamports({
    required String label,
    required int lamports,
    String sign = '',
    Color? valueColor,
  }) {
    return TxCostLine._(
      label: label,
      value: PriceFormatter.formatFeeLamports(lamports, sign: sign),
      valueColor: valueColor,
    );
  }

  /// Token-currency amount row sourced from a raw on-chain amount + mint.
  ///
  /// Used for listing-currency rows (price, offer amount, total) so SOL,
  /// USDC, and the other supported mints all flow through the same
  /// [PriceFormatter.formatRawAmountWithSymbol] pipeline.
  factory TxCostLine.tokenAmount({
    required String label,
    required double rawAmount,
    required String? currencyMint,
    String sign = '',
    Color? valueColor,
  }) {
    return TxCostLine._(
      label: label,
      value:
          '$sign${PriceFormatter.formatRawAmountWithSymbol(rawAmount, currencyMint)}',
      valueColor: valueColor,
    );
  }

  /// Token-currency row rendered at the token's full on-chain precision
  /// (via [PriceFormatter.formatRawAmountPreciseWithSymbol]) rather than its
  /// coarser input precision. Use for fee/proceeds breakdowns where amounts
  /// are fractions of a unit — e.g. a fee on a whole-number-listing token
  /// (SMORES, `inputDecimals: 0`) would otherwise truncate to "0".
  factory TxCostLine.tokenAmountPrecise({
    required String label,
    required double rawAmount,
    required String? currencyMint,
    String sign = '',
    Color? valueColor,
  }) {
    return TxCostLine._(
      label: label,
      value:
          '$sign${PriceFormatter.formatRawAmountPreciseWithSymbol(rawAmount, currencyMint)}',
      valueColor: valueColor,
    );
  }

  /// Shimmer placeholder used while a simulation is in flight.
  factory TxCostLine.shimmer({
    required String label,
    double width = 110,
    double height = 15,
  }) {
    return TxCostLine._(
      label: label,
      valueChild: ShimmerBox(width: width, height: height),
    );
  }

  /// Escape hatch for callers that need a fully custom right-hand side
  /// (e.g. a plain string with no currency symbol).
  factory TxCostLine.text({
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return TxCostLine._(label: label, value: value, valueColor: valueColor);
  }

  final String label;
  final String? value;
  final Widget? valueChild;
  final Color? valueColor;

  ConfirmationDetailRow _toRow({TextStyle? textStyle}) => ConfirmationDetailRow(
    label: label,
    value: value,
    valueChild: valueChild,
    valueColor: valueColor,
    textStyle: textStyle,
  );
}

/// Cost breakdown card shared by all transaction confirmation sheets.
///
/// Lays out [lines] inside a [ConfirmationDetailCard] with a small gap
/// between rows; if [total] is provided it's separated from the lines by
/// a [Divider] so it always reads as the aggregate row. Use [card: false]
/// when the surrounding chrome already provides the bordered container
/// (e.g. mint's `bgSurface` review sheet).
class TxCostSummary extends StatelessWidget {
  const TxCostSummary({
    required this.lines,
    super.key,
    this.total,
    this.card = true,
    this.lineStyle,
  });

  final List<TxCostLine> lines;
  final TxCostLine? total;
  final bool card;

  /// Optional base style applied to every row's label/value. Disclosure
  /// breakdowns pass [MallowTheme.uiCaption] so the rows match their
  /// smaller section header; defaults to [MallowTheme.uiBody].
  final TextStyle? lineStyle;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) children.add(const SizedBox(height: MallowTheme.spacingSm));
      children.add(lines[i]._toRow(textStyle: lineStyle));
    }
    if (total != null) {
      children.add(const Divider(height: MallowTheme.spacing20));
      children.add(total!._toRow(textStyle: lineStyle));
    }
    if (!card) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return ConfirmationDetailCard(children: children);
  }
}
