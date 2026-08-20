/// Utilities for safe token amount conversions using BigInt.
///
/// All on-chain token amounts MUST go through these methods to avoid
/// floating-point precision loss. The critical invariant:
///   user-input string -> BigInt (never through double)
class TokenAmount {
  const TokenAmount._();

  static const _solDecimals = 9;

  /// Parse a user-input amount string into raw BigInt (smallest unit).
  ///
  /// Example: parseTokenAmount("0.1", 9) == BigInt.from(100000000)
  ///
  /// Handles trailing decimals, no decimals, and truncates excess precision.
  static BigInt parseTokenAmount(String userInput, int decimals) {
    final trimmed = userInput.trim();
    if (trimmed.isEmpty) return BigInt.zero;

    final parts = trimmed.split('.');
    if (parts.length > 2) return BigInt.zero;

    final wholePart = parts[0].isEmpty ? '0' : parts[0];
    var fracPart = parts.length > 1 ? parts[1] : '';

    // Truncate excess decimal places (don't round — user typed this)
    if (fracPart.length > decimals) {
      fracPart = fracPart.substring(0, decimals);
    }

    // Pad fractional part to full decimal width
    fracPart = fracPart.padRight(decimals, '0');

    // Combine: "1" + "230000000" for 1.23 SOL
    final combined = '$wholePart$fracPart';
    return BigInt.parse(combined);
  }

  /// Format a raw BigInt amount into a display string.
  ///
  /// Example: formatTokenAmount(BigInt.from(100000000), 9) == "0.1"
  static String formatTokenAmount(BigInt rawAmount, int decimals) {
    if (decimals == 0) return rawAmount.toString();

    final str = rawAmount.toString().padLeft(decimals + 1, '0');
    final wholeStr = str.substring(0, str.length - decimals);
    var fracStr = str.substring(str.length - decimals);

    // Trim trailing zeros
    fracStr = fracStr.replaceAll(RegExp(r'0+$'), '');
    if (fracStr.isEmpty) return wholeStr;
    return '$wholeStr.$fracStr';
  }

  /// Convert a SOL amount string to lamports.
  static BigInt solToLamports(String sol) =>
      parseTokenAmount(sol, _solDecimals);

  /// Convert lamports to a SOL display string.
  static String lamportsToSol(BigInt lamports) =>
      formatTokenAmount(lamports, _solDecimals);

  /// Safely convert BigInt to int with overflow check.
  ///
  /// Throws [StateError] if the value exceeds int range.
  static int toInt(BigInt value) {
    if (value > BigInt.from(0x7FFFFFFFFFFFFFFF) ||
        value < BigInt.from(-0x8000000000000000)) {
      throw StateError('Token amount $value overflows int range');
    }
    return value.toInt();
  }
}
