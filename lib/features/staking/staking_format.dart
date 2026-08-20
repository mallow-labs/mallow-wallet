import '../../shared/utils/price_format.dart';

/// Number formatting for the staking sheet, mirroring the webapp's
/// `lamportsToSol` / `abbreviateAmount` (tokens).
class StakingFormat {
  const StakingFormat._();

  static const int _lamportsPerSol = 1000000000;

  /// Lamports → SOL as a double.
  static double lamportsToSol(int lamports) => lamports / _lamportsPerSol;

  /// SOL display: 4 dp when small (< 0.1), else 2 dp, trailing zeros trimmed.
  static String sol(double amount) {
    final s = amount < 0.1
        ? amount.toStringAsFixed(4)
        : amount.toStringAsFixed(2);
    return stripTrailingZeros(s);
  }

  /// Lamports → SOL display string.
  static String lamportsSol(int lamports) => sol(lamportsToSol(lamports));

  /// USD display: `~$1,234.56`.
  static String usd(double value) => '~\$${withCommas(value, decimals: 2)}';

  /// Thousands-separated, fixed decimals, trailing zeros trimmed.
  static String withCommas(num value, {int decimals = 0}) {
    final fixed = value.toStringAsFixed(decimals);
    final parts = fixed.split('.');
    final intPart = parts[0];
    final neg = intPart.startsWith('-');
    final digits = neg ? intPart.substring(1) : intPart;
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    var out = '${neg ? '-' : ''}$buf';
    if (parts.length > 1) {
      final frac = parts[1].replaceAll(RegExp(r'0+$'), '');
      if (frac.isNotEmpty) out = '$out.$frac';
    }
    return out;
  }

  /// Abbreviated amount: `125k`, `273.4k`, `33.3k`, `1.2M`, `3B`. Values under
  /// 1,000 are shown plain (with commas).
  static String abbreviate(num value, {int decimals = 1}) {
    final abs = value.abs();
    String scaled(num divisor, String suffix) =>
        '${stripTrailingZeros((value / divisor).toStringAsFixed(decimals))}$suffix';
    if (abs >= 1000000000) return scaled(1000000000, 'B');
    if (abs >= 1000000) return scaled(1000000, 'M');
    if (abs >= 1000) return scaled(1000, 'k');
    return withCommas(value);
  }

  /// Staking points: abbreviated (`281`, `6.5k`, `273.4k`).
  static String sp(num value) => abbreviate(value);

  /// A swap quote's `outAmount` in whole tokens: 3 dp with a `< 0.01` floor —
  /// the webapp's rounding for the receive line (`StakingSection`).
  ///
  /// Takes the quote's raw lamports **string** so the unparseable-quote
  /// fallback lives here too. Shared rather than duplicated: the form's Receive
  /// row and the confirm sheet's "You'll receive" describe the same trade, so a
  /// rounding rule that drifted between them would show the user two different
  /// outputs for one swap.
  static String receiveAmount(String outLamports) {
    final out = lamportsToSol(int.tryParse(outLamports) ?? 0);
    if (out <= 0) return '0';
    if (out < 0.01) return '< 0.01';
    return withCommas(out, decimals: 3);
  }

  /// APY fraction → percentage string, e.g. `0.0574` → `5.74%`.
  static String apy(double fraction) =>
      '${stripTrailingZeros((fraction * 100).toStringAsFixed(2))}%';

  /// Coarse countdown, e.g. `1d 5h`, `23h 51m`, `42m`, `<1m`. Used for the
  /// unstake epoch / claim-countdown cards.
  static String countdown(Duration d) {
    if (d <= Duration.zero) return '<1m';
    final days = d.inDays;
    final hours = d.inHours % 24;
    final minutes = d.inMinutes % 60;
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m';
    return '<1m';
  }

  /// Epoch progress percentage, one decimal place, e.g. `49.8%`.
  static String epochPercent(double fraction) =>
      '${(fraction * 100).toStringAsFixed(1)}%';

  /// `endsAt` (minus one day, matching the webapp's inclusive last day) as an
  /// ordinal date, e.g. `30th June`.
  static String seasonEnd(DateTime? endsAt) {
    if (endsAt == null) return '—';
    final d = endsAt.subtract(const Duration(days: 1));
    return '${_ordinal(d.day)} ${_months[d.month - 1]}';
  }

  static String _ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    switch (day % 10) {
      case 1:
        return '${day}st';
      case 2:
        return '${day}nd';
      case 3:
        return '${day}rd';
      default:
        return '${day}th';
    }
  }

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
}
