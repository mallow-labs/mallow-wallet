import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/decimal_input_formatter.dart';

/// Simulates a user typing [next] into a field currently showing [old].
TextEditingValue _apply(
  DecimalInputFormatter formatter,
  String old,
  String next,
) {
  return formatter.formatEditUpdate(
    TextEditingValue(text: old),
    TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    ),
  );
}

void main() {
  group('DecimalInputFormatter', () {
    test('allows fractional digits up to the token decimals', () {
      final f = DecimalInputFormatter(6);
      expect(_apply(f, '1.23456', '1.234567').text, '1.234567');
    });

    test('rejects a digit that exceeds the token decimals', () {
      // WHY: typing past the precision the token can hold would otherwise be
      // silently truncated at parse time, sending a different amount than shown.
      final f = DecimalInputFormatter(6);
      expect(_apply(f, '1.234567', '1.2345678').text, '1.234567');
    });

    test('rejects the decimal point entirely for a 0-decimal token', () {
      final f = DecimalInputFormatter(0);
      expect(_apply(f, '5', '5.').text, '5');
    });

    test('allows whole numbers and a bare leading decimal', () {
      final f = DecimalInputFormatter(9);
      expect(_apply(f, '', '0').text, '0');
      expect(_apply(f, '0', '0.').text, '0.');
      expect(_apply(f, '0.', '0.5').text, '0.5');
    });

    test('rejects non-numeric and multiple decimal points', () {
      final f = DecimalInputFormatter(9);
      expect(_apply(f, '1.2', '1.2a').text, '1.2');
      expect(_apply(f, '1.2', '1.2.').text, '1.2');
    });

    test('keeps an empty field clearable', () {
      final f = DecimalInputFormatter(6);
      expect(_apply(f, '1.5', '').text, '');
    });
  });
}
