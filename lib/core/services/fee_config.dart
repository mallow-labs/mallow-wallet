import 'package:injectable/injectable.dart';

/// Default priority fee applied client-side when the user has no
/// per-account override. Kept as a top-level constant so pure data /
/// state classes that can't take DI (freezed states, value-class
/// `toRequest` builders, etc.) read the same canonical value as the
/// injected [FeeConfig].
const kDefaultPriorityFeeLamports = 50000;

/// Base Solana transaction fee — 5000 lamports per signature, fixed by
/// the validator. Used for UI fee estimates only; the on-chain fee is
/// computed by the network.
const kBaseSolanaTxFeeLamports = 5000;

/// Lamports a zero-data account (a plain wallet) must hold to be rent-exempt:
/// 128 bytes of account overhead × 3480 lamports per byte-year × 2 years.
///
/// This is a **hard runtime rule, not a cushion**. Solana rejects any
/// transaction that leaves a writable account holding more than nothing but
/// less than this — `InsufficientFundsForRent`, raised at preflight, i.e. after
/// the user has signed. Verified against mainnet: a residue of 890 879 lamports
/// is rejected; 890 880 and 0 are both accepted.
///
/// So a partial send must leave at least this much behind, and a send that
/// empties the account must leave *exactly* nothing. There is no third option —
/// which is why the send flow prices a Max off the transaction's exact fee
/// rather than off a worst-case reserve.
const kSolRentExemptMinimumLamports = 890880;

/// Centralized fee + tx-cost configuration.
///
/// Single source for "what priority fee should we ask the backend to
/// embed in compiled transactions right now?" Devnet/mainnet tuning is
/// a one-line change here.
///
/// Designed to grow into dynamic priority-fee fetching (Helius/Triton
/// recent-fees endpoint, per-route overrides, etc.) without rippling
/// through every BLoC and repo — callers consume the getters and stay
/// agnostic about whether the value is static or live.
@lazySingleton
class FeeConfig {
  const FeeConfig();

  /// Default priority fee in lamports applied to every server-built tx.
  int get priorityFeeLamports => kDefaultPriorityFeeLamports;

  /// Validator-set base tx fee per signature, in lamports.
  int get baseTxFeeLamports => kBaseSolanaTxFeeLamports;

  /// Combined estimate shown as "Solana tx fee" in cost-breakdown UI:
  /// base validator fee + priority fee.
  int get totalDefaultTxFeeLamports => baseTxFeeLamports + priorityFeeLamports;
}
