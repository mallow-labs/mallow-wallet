import 'dart:math';

/// Render a token-amount [value] for display, stripping trailing zeros and
/// capping at 6 decimal places. Whole numbers render without a decimal point.
String displayDecimal(double value) {
  if (value == value.truncateToDouble()) return value.toInt().toString();
  final s = value.toStringAsFixed(min(6, _significantDecimals(value)));
  return stripTrailingZeros(s);
}

/// Render a wallet balance for a "Balance: X SYM" line: 2 dp for amounts of 1
/// or more, 6 dp for dust, abbreviated past a million. Distinct from
/// [displayDecimal], which keeps a token amount's own precision — a balance is
/// a glanceable figure, not an amount the user is about to commit to.
String formatBalance(double value) {
  if (value == 0) return '0';
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
  final digits = value >= 1 ? 2 : 6;
  return stripTrailingZeros(value.toStringAsFixed(digits));
}

/// Render a USD amount for display: `'$1,234.56'` — always two decimals,
/// always thousands-grouped, matching how the webapp renders every USD figure.
///
/// Rounds to whole cents **before** splitting the dollars from the cents.
/// Truncating first and rounding the remainder independently lets the cents
/// reach 100, which `padLeft(2)` leaves as `"100"` — $9.999 rendered as
/// `"$9.100"`. Carrying a single total-cents integer is the only way the two
/// halves stay consistent.
///
/// Negatives render as `-$1,234.56` (sign outside the symbol); `-0.004`
/// rounds to a signless `$0.00` rather than `-$0.00`.
String formatUsd(double value) {
  final cents = (value.abs() * 100).round();
  final sign = value.isNegative && cents != 0 ? '-' : '';
  final dollars = groupThousands((cents ~/ 100).toString());
  return '$sign\$$dollars.${(cents % 100).toString().padLeft(2, '0')}';
}

final _numberParts = RegExp(r'^([+-]?)(\d+)(.*)$');

/// Insert a `,` every three digits into the integer part of an already
/// formatted number string.
///
/// The webapp groups every number it renders through JS
/// `Number.toLocaleString()` — prices (`PriceDisplay`), counts
/// (`ArtworkCardMetadata`), collection volume
/// (`CollectionPageDetails`) and each abbreviated tier
/// (`tokens`). Without it a returning webapp
/// user reads `$1234567` where they used to read `$1,234,567`.
///
/// Leading sign, fractional part and any trailing suffix (`K` / `M` / `B`,
/// a currency symbol) are preserved untouched.
String groupThousands(String s) {
  final match = _numberParts.firstMatch(s);
  if (match == null) return s;
  final digits = match.group(2)!;
  if (digits.length <= 3) return s;
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${match.group(1)}$buffer${match.group(3)}';
}

/// [groupThousands] for a plain integer count — `1234` → `1,234`.
String formatCount(int value) => groupThousands(value.toString());

final _trailingZeros = RegExp(r'0+$');

/// Strip trailing zeros and a dangling decimal point from a decimal string.
String stripTrailingZeros(String s) {
  if (!s.contains('.')) return s;
  s = s.replaceAll(_trailingZeros, '');
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

int _significantDecimals(double value) {
  final s = value.toString();
  final dot = s.indexOf('.');
  if (dot < 0) return 0;
  return s.length - dot - 1;
}
