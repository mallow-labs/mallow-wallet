/// Constants for the swap feature.
class SwapConstants {
  const SwapConstants._();

  /// mallow's integrator fee on every swap — 50 bps = 0.5%. Sent to Jupiter
  /// as `referralFee` together with the referral account from config.
  static const int referralFeeBps = 50;

  /// Lamports the Max button leaves untouched when selling native SOL
  /// (fees + rent headroom) — same reserve as staking's Max.
  static const int maxReserveLamports = 4000000;

  /// How long a quote stays fresh before the sheet re-fetches it.
  static const Duration quoteRefreshInterval = Duration(seconds: 5);
}
