import 'package:flutter/services.dart';

/// Restricts a text field to a non-negative decimal number whose fractional
/// part is no longer than the token's [decimals].
///
/// Without this, the field accepts more fractional digits than the token can
/// represent on-chain; [TokenAmount.parseTokenAmount] then silently truncates
/// the excess, so the value sent differs from what the user typed. Capping at
/// the input layer keeps the displayed amount and the signed amount identical.
class DecimalInputFormatter extends TextInputFormatter {
  DecimalInputFormatter(this.decimals) : assert(decimals >= 0);

  /// Maximum number of fractional digits the token supports.
  final int decimals;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;

    // Digits only when the token has no fractional precision.
    final pattern = decimals == 0
        ? RegExp(r'^\d*$')
        : RegExp('^\\d*\\.?\\d{0,$decimals}\$');
    if (!pattern.hasMatch(text)) return oldValue;

    return newValue;
  }
}
