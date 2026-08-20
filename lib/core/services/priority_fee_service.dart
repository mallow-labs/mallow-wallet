import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../../di.dart';
import '../../shared/utils/price_format.dart';
import 'fee_config.dart';
import 'preferences_service.dart';

/// Auto's priority-fee ceiling, in lamports for the whole transaction.
/// The webapp's `DEFAULT_MAX_PRIORITY_FEE_LAMPORTS`.
const int kAutoPriorityFeeLamports = 50000;

/// The floor every client-built Solana transaction bids, in lamports for the
/// whole transaction (the webapp's `MIN_PRIORITY_FEE_LAMPORTS`).
///
/// It is also a hard *lower bound on the ceiling*:
/// `SolanaRpcService.computeBudgetIxs` clamps the network's recommendation
/// into `[floor, ceiling]`, and `num.clamp` **throws ArgumentError** when the
/// bounds are inverted. A user who types 0.00001 SOL into the manual field
/// would otherwise break every Solana transaction the app builds, so the
/// resolve path in [PriorityFeeService] floors the value on read.
const int kMinPriorityFeeLamports = 15000;

/// Hard upper bound on a manually-entered fee: 1 SOL. The webapp clamps its
/// manual field to the same value — a fat-fingered extra zero on a priority
/// fee is money that is simply gone.
const int kMaxPriorityFeeLamports = 1000000000;

/// The preset priority-fee ceilings offered in Settings → Priority Fee, in
/// **lamports of priority fee for the whole transaction** (not microLamports
/// per compute unit — the conversion to a per-CU unit price happens in
/// `SolanaRpcService.computeBudgetIxs`, which needs the simulated compute
/// budget to do it).
///
/// Same three tiers, same numbers, same labels as the webapp's Transaction
/// Priority modal (`TransactionPriorityModal`): Auto 50 000, High 20×,
/// Turbo 200×.
enum PriorityFeeTier {
  auto('Auto', kAutoPriorityFeeLamports),
  high('High', 1000000),
  turbo('Turbo', 10000000);

  const PriorityFeeTier(this.label, this.lamports);

  final String label;
  final int lamports;
}

/// Explainer copy shared by every surface that edits the priority fee, so the
/// swap sheet and the settings page can't drift into describing it differently.
/// Paraphrases the webapp's Transaction Priority modal body.
const String kPriorityFeeExplainer =
    'Transactions can fail when the Solana network is congested. A higher '
    'priority fee makes validators more likely to include yours. Auto picks a '
    'fee from live network conditions.';

/// Hint under the manual field, naming the 1 SOL clamp.
const String kPriorityFeeMaxHint = 'Max. 1 SOL';

/// The general priority-fee ceiling in force right now, or Auto's default when
/// the app's DI container isn't up — unit tests and the `.mainnet`
/// [PriorityFeeService]-less service instances both read fees outside it.
int get activePriorityFeeCeilingLamports =>
    sl.isRegistered<PriorityFeeService>()
    ? sl<PriorityFeeService>().ceilingLamports
    : kAutoPriorityFeeLamports;

/// Lamports added on top of the ceiling to absorb the two roundings between a
/// whole-transaction lamport ceiling and the per-compute-unit price a
/// transaction actually bids: `computeBudgetIxs` rounds the price *up* to a
/// whole micro-lamport, and the runtime then rounds the resulting fee *up* to a
/// whole lamport. Together they can land a lamport or two above the ceiling, so
/// without this the "worst case" below would not be one.
const int _priorityFeeRoundingLamports = 10;

/// An **upper bound** on what a client-built, single-signature Solana
/// transaction can cost the sender: the validator's per-signature base fee plus
/// the priority fee it is allowed to bid, which
/// `SolanaRpcService.computeBudgetIxs` clamps to
/// [activePriorityFeeCeilingLamports], plus [_priorityFeeRoundingLamports] of
/// rounding slack.
///
/// A bound, not the fee. It answers "can this wallet afford to transact at
/// all?" — the source-wallet picker's floor, and the headroom a *partial* send
/// has to leave on top of the rent-exempt minimum. It tracks the user's
/// Settings → Priority Fee selection because a flat number is both too generous
/// on Auto and too thin on Turbo, whose 10 000 000-lamport ceiling alone
/// exceeds the 0.008 SOL constant this replaced.
///
/// A Max deliberately does **not** use it: emptying an account requires the
/// exact fee (`SolanaRpcService.planSolTransferFee`), because the gap between a
/// bound and the real charge is precisely the dust the runtime rejects as
/// rent-paying — see [kSolRentExemptMinimumLamports].
///
/// It does not cover account rent the transaction may fund (an SPL destination
/// ATA is ~0.00204 SOL); a native-SOL transfer creates no such account, and the
/// token paths quote rent separately.
int get worstCaseSolTxFeeLamports =>
    kBaseSolanaTxFeeLamports +
    activePriorityFeeCeilingLamports +
    _priorityFeeRoundingLamports;

/// A ceiling as a bare SOL amount, e.g. `0.001`. Trailing zeros are stripped
/// because the presets are round numbers that would otherwise render as
/// `0.001000000`.
String formatPriorityFeeSol(int lamports) =>
    stripTrailingZeros((lamports / 1e9).toStringAsFixed(9));

/// The glanceable summary of a selection — `Auto`, or the ceiling in SOL —
/// shared by the Preferences row and the Priority Fee screen so the two can
/// never describe the same selection differently.
String priorityFeeLabel(int? lamports) =>
    lamports == null ? 'Auto' : '${formatPriorityFeeSol(lamports)} SOL';

/// The user's Solana priority-fee ceilings: one general, one swap-specific.
///
/// **They are ceilings, not the fee.** `SolanaRpcService.computeBudgetIxs`
/// asks Helius what the network currently wants and clamps that recommendation
/// into the `[15 000, ceiling]` lamport window before converting it to a
/// `setComputeUnitPrice`. Raising the ceiling therefore lets a congested
/// network charge more, it does not unconditionally spend more — exactly the
/// webapp's `getComputePriceIx` behaviour.
///
/// **Two prefs, one resolve point.** Settings → Priority Fee writes the
/// general value ([set]); the swap settings sheet writes a swap-only override
/// ([setSwap]) that predates it. Swaps resolve `swap → general → Auto`;
/// everything else reads the general value and never consults the swap key.
/// Both resolved values are floored at [kMinPriorityFeeLamports] — see that
/// constant for the ArgumentError this prevents.
///
/// The selections are [ValueListenable]s so the settings page and any fee
/// display stay in sync without re-reading `SharedPreferences`, and so a value
/// read from a transaction builder is always the current one.
@lazySingleton
class PriorityFeeService {
  PriorityFeeService(this._prefs)
    : _lamports = ValueNotifier<int?>(_prefs.priorityFeeLamports),
      _swapLamports = ValueNotifier<int?>(_prefs.swapPriorityFeeLamports) {
    _prefs.clearGeneration.addListener(_reseed);
  }

  final PreferencesService _prefs;
  final ValueNotifier<int?> _lamports;
  final ValueNotifier<int?> _swapLamports;

  /// The persisted general selection; `null` means Auto.
  ValueListenable<int?> get selection => _lamports;

  /// The persisted swap-specific override; `null` means "no override", which
  /// resolves to [selection] — not to Auto.
  ValueListenable<int?> get swapSelection => _swapLamports;

  /// The ceiling to apply to a client-built transaction, with Auto resolved to
  /// its numeric value and the floor applied. This is what transaction
  /// builders want. Swaps use [routerLamports] instead.
  int get ceilingLamports =>
      _floor(_lamports.value ?? kAutoPriorityFeeLamports);

  /// Whether the general selection is Auto (as opposed to a preset or custom
  /// value that happens to equal Auto's number).
  bool get isAuto => _lamports.value == null;

  /// The value to hand a third-party router that does its own fee estimation
  /// (Jupiter), resolved `swap override → general → Auto`: `null` on Auto so
  /// the router picks, the explicit floored ceiling otherwise. Auto must stay
  /// `null` rather than 50 000 — pinning a number would strip Jupiter of the
  /// real-time estimation Auto exists to use.
  int? get routerLamports {
    final resolved = _swapLamports.value ?? _lamports.value;
    return resolved == null ? null : _floor(resolved);
  }

  /// Persist a new general selection (Settings → Priority Fee). `null` = Auto.
  Future<void> set(int? lamports) async {
    final next = _normalize(lamports);
    if (next == _lamports.value) return;
    _lamports.value = next;
    await _prefs.setPriorityFeeLamports(next);
  }

  /// Persist a new swap-specific override (the swap settings sheet).
  /// `null` clears the override, falling back to the general selection.
  Future<void> setSwap(int? lamports) async {
    final next = _normalize(lamports);
    if (next == _swapLamports.value) return;
    _swapLamports.value = next;
    await _prefs.setSwapPriorityFeeLamports(next);
  }

  /// Re-read both keys after Settings → "Reset app" wipes the preference
  /// store. Both values were cached into the notifiers at construction, so
  /// without this every Solana transaction keeps bidding the pre-reset ceiling
  /// and Settings keeps displaying it — and because [set] early-returns on
  /// equality, re-picking that same value is a no-op, so the pref could never
  /// be re-persisted for the rest of the session.
  void _reseed() {
    _lamports.value = _prefs.priorityFeeLamports;
    _swapLamports.value = _prefs.swapPriorityFeeLamports;
  }

  /// Stored form of a user entry: clamped into `(0, kMaxPriorityFeeLamports]`,
  /// with a non-positive value folding back to Auto rather than pinning a zero
  /// ceiling. A too-low positive value is stored as entered and floored on
  /// read, so the number the user typed is the number the UI shows back.
  static int? _normalize(int? lamports) => lamports == null || lamports <= 0
      ? null
      : math.min(lamports, kMaxPriorityFeeLamports);

  /// The floor applied to whichever key resolved. Without it a pref below
  /// 15 000 inverts `computeBudgetIxs`' clamp bounds and throws.
  static int _floor(int lamports) =>
      math.max(lamports, kMinPriorityFeeLamports);
}
