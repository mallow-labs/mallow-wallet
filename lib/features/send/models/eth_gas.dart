import 'package:flutter/foundation.dart';

import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/services/preferences_service.dart';

/// EIP-1559 fee tier the user can pick on the Edit Gas Fee sheet. [low] and
/// [market] are the two presets from Infura's `suggestedGasFees` (its `low` /
/// `medium`); [custom] is the Advanced path where the user sets the knobs.
enum EthGasMode {
  low,
  market,
  custom;

  /// Parse the persisted fee-tier string (`'low'` / `'market'` / `'custom'`).
  /// Returns null for null/unrecognised input, so the confirm step falls back to
  /// the Market tier. The single mode-parsing helper shared by both EVM transfer
  /// flows (send + artwork) — previously copy-pasted as a private `switch` in
  /// each bloc.
  static EthGasMode? fromString(String? value) => switch (value) {
    'low' => EthGasMode.low,
    'market' => EthGasMode.market,
    'custom' => EthGasMode.custom,
    _ => null,
  };
}

/// Format a wait-time estimate (ms) as a short "N sec" / "N min" label.
String _formatWait(int ms) {
  final secs = (ms / 1000).round();
  if (secs < 60) return '$secs sec';
  return '${(secs / 60).round()} min';
}

/// Format a min–max wait range in seconds, sharing the unit (e.g. "15 - 30
/// sec"). Kept in seconds so the two ends always share a unit — Infura's
/// preset tier waits are sub-few-minutes, so seconds stay readable.
String _formatWaitRange(int minMs, int maxMs) =>
    '${(minMs / 1000).round()} - ${(maxMs / 1000).round()} sec';

/// One of the two preset fee tiers (Low / Market) shown on the Edit Gas Fee
/// sheet, mapped from Infura's `suggestedGasFees` `low` / `medium` objects. The
/// caps ([maxFeePerGas] / [maxPriorityFeePerGas]) are Infura's suggestions; the
/// *expected* fee shown to the user is recomputed against the live base fee at
/// display time (see [EthGasSelection.effectiveGasPrice]).
@immutable
class EthGasTier {
  const EthGasTier({
    required this.mode,
    required this.maxFeePerGas,
    required this.maxPriorityFeePerGas,
    required this.minWaitMs,
    required this.maxWaitMs,
  });

  /// Always [EthGasMode.low] or [EthGasMode.market] — never [EthGasMode.custom].
  final EthGasMode mode;
  final BigInt maxFeePerGas;
  final BigInt maxPriorityFeePerGas;

  /// Infura's min/max time-to-confirmation estimate for this tier, in ms.
  final int minWaitMs;
  final int maxWaitMs;

  String get label => mode == EthGasMode.low ? 'Low' : 'Market';

  /// Range label for the sheet's tier row (e.g. "15 - 30 sec").
  String get speedRangeLabel => _formatWaitRange(minWaitMs, maxWaitMs);

  /// Single conservative ETA for the confirm-screen Speed pill (e.g. "~30 sec")
  /// — the tier's upper wait bound.
  String get etaLabel => '~${_formatWait(maxWaitMs)}';
}

/// The live Ethereum fee market for the confirm / Edit-Gas-Fee screens, from a
/// single Infura `suggestedGasFees` call: next-block base fee, the two preset
/// tiers (with real wait estimates), the current priority-fee range, network
/// congestion, and the historical (≈12 h) fee ranges Infura reports.
@immutable
class EthGasMarket {
  const EthGasMarket({
    required this.baseFeeWei,
    required this.priorityLowWei,
    required this.priorityHighWei,
    required this.congestion,
    required this.historicalBaseFeeMinWei,
    required this.historicalBaseFeeMaxWei,
    required this.historicalPriorityMinWei,
    required this.historicalPriorityMaxWei,
    required this.low,
    required this.market,
  });

  /// Build the market from an Infura `suggestedGasFees` response. Fee values are
  /// gwei-decimal strings; wait times are ms; `networkCongestion` is 0..1.
  factory EthGasMarket.fromSuggestedGasFees(Map<String, dynamic> json) {
    final priority = (json['latestPriorityFeeRange'] as List?) ?? const [];
    final histBase = (json['historicalBaseFeeRange'] as List?) ?? const [];
    final histPriority =
        (json['historicalPriorityFeeRange'] as List?) ?? const [];

    BigInt gweiAt(List<dynamic> l, int i) =>
        gweiToWei(i < l.length ? _toDouble(l[i]) : 0);

    return EthGasMarket(
      baseFeeWei: gweiToWei(_toDouble(json['estimatedBaseFee'])),
      priorityLowWei: gweiAt(priority, 0),
      priorityHighWei: gweiAt(priority, 1),
      congestion: _toDouble(json['networkCongestion']).clamp(0.0, 1.0),
      historicalBaseFeeMinWei: gweiAt(histBase, 0),
      historicalBaseFeeMaxWei: gweiAt(histBase, 1),
      historicalPriorityMinWei: gweiAt(histPriority, 0),
      historicalPriorityMaxWei: gweiAt(histPriority, 1),
      low: _tierFrom(EthGasMode.low, json['low']),
      market: _tierFrom(EthGasMode.market, json['medium']),
    );
  }

  /// Fetch and parse the live fee market in one call — the single gas-market
  /// entry point the send and artwork EVM transfer services share (each service
  /// exposes a thin `gasMarket()` delegating here, replacing the verbatim
  /// `EthGasMarket.fromSuggestedGasFees(await _rpc.getSuggestedGasFees())` both
  /// used to carry).
  static Future<EthGasMarket> fetch(EthereumRpcService rpc) async =>
      EthGasMarket.fromSuggestedGasFees(await rpc.getSuggestedGasFees());

  /// Infura's `estimatedBaseFee` (next-block base fee), in wei.
  final BigInt baseFeeWei;

  /// Current priority-fee range (`latestPriorityFeeRange` low/high), in wei —
  /// drives the "0 - 2 GWEI" priority readout.
  final BigInt priorityLowWei;
  final BigInt priorityHighWei;

  /// Infura's `networkCongestion`, 0..1 — the congestion bar fraction and
  /// Busy/Stable label.
  final double congestion;

  /// Infura's `historicalBaseFeeRange` / `historicalPriorityFeeRange` (min/max
  /// over its ≈12-hour window), in wei — the Advanced sheet's "12 hr" ranges.
  final BigInt historicalBaseFeeMinWei;
  final BigInt historicalBaseFeeMaxWei;
  final BigInt historicalPriorityMinWei;
  final BigInt historicalPriorityMaxWei;

  final EthGasTier low;
  final EthGasTier market;

  bool get isBusy => congestion >= _busyThreshold;
  String get statusLabel => isBusy ? 'Busy' : 'Stable';

  EthGasTier tierFor(EthGasMode mode) => mode == EthGasMode.low ? low : market;

  /// Congestion at/above this fraction reads as "Busy".
  static const double _busyThreshold = 0.66;

  static final BigInt _weiPerGwei = BigInt.from(1000000000);

  static BigInt gweiToWei(double gwei) => BigInt.from((gwei * 1e9).round());

  static double weiToGwei(BigInt wei) => wei / _weiPerGwei;

  static EthGasTier _tierFrom(EthGasMode mode, Object? tier) {
    final t = (tier as Map?) ?? const {};
    return EthGasTier(
      mode: mode,
      maxFeePerGas: gweiToWei(_toDouble(t['suggestedMaxFeePerGas'])),
      maxPriorityFeePerGas: gweiToWei(
        _toDouble(t['suggestedMaxPriorityFeePerGas']),
      ),
      minWaitMs: _toInt(t['minWaitTimeEstimate']),
      maxWaitMs: _toInt(t['maxWaitTimeEstimate']),
    );
  }

  static double _toDouble(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  static int _toInt(Object? v) =>
      v is num ? v.toInt() : int.tryParse('$v') ?? 0;
}

/// A fully-resolved fee choice: concrete EIP-1559 caps and a gas limit ready to
/// sign, plus the mode it came from and the ETA to show. Produced by the Edit
/// Gas Fee sheet (from a tier or the Advanced inputs) and by [resolve] (from
/// persisted prefs), stored on `SendReady`, and threaded into the broadcast as
/// the fee override.
@immutable
class EthGasSelection {
  const EthGasSelection({
    required this.mode,
    required this.maxFeePerGas,
    required this.maxPriorityFeePerGas,
    required this.gasLimit,
    this.speedEta = '—',
  });

  EthGasSelection.fromTier(EthGasTier tier, {required this.gasLimit})
    : mode = tier.mode,
      maxFeePerGas = tier.maxFeePerGas,
      maxPriorityFeePerGas = tier.maxPriorityFeePerGas,
      speedEta = tier.etaLabel;

  /// Build a custom selection from the Advanced inputs (all in gwei except the
  /// gas limit). maxFeePerGas = maxBaseFee + priority tip.
  EthGasSelection.custom({
    required double maxBaseFeeGwei,
    required double priorityFeeGwei,
    required this.gasLimit,
  }) : mode = EthGasMode.custom,
       speedEta = '—',
       maxPriorityFeePerGas = EthGasMarket.gweiToWei(priorityFeeGwei),
       maxFeePerGas =
           EthGasMarket.gweiToWei(maxBaseFeeGwei) +
           EthGasMarket.gweiToWei(priorityFeeGwei);

  final EthGasMode mode;
  final BigInt maxFeePerGas;
  final BigInt maxPriorityFeePerGas;
  final int gasLimit;

  /// Short ETA for the confirm-screen Speed pill: the chosen preset tier's
  /// [EthGasTier.etaLabel], or "—" for a hand-tuned custom fee (no estimate).
  final String speedEta;

  String get modeLabel => switch (mode) {
    EthGasMode.low => 'Low',
    EthGasMode.market => 'Market',
    EthGasMode.custom => 'Advanced',
  };

  /// Per-gas price expected to actually be charged at [baseFeeWei]: base fee +
  /// tip, capped at [maxFeePerGas]. Drives the displayed (expected, not
  /// worst-case) fee, recomputed whenever the selection changes.
  BigInt effectiveGasPrice(BigInt baseFeeWei) {
    final expected = baseFeeWei + maxPriorityFeePerGas;
    return expected < maxFeePerGas ? expected : maxFeePerGas;
  }

  /// The user-facing "Max base fee" (gwei) — the base-fee portion of the cap,
  /// i.e. maxFeePerGas − priority tip. Seeds the Advanced sheet's field.
  double get maxBaseFeeGwei =>
      EthGasMarket.weiToGwei(maxFeePerGas - maxPriorityFeePerGas);

  double get priorityFeeGwei => EthGasMarket.weiToGwei(maxPriorityFeePerGas);

  /// Resolve the fee selection auto-applied when entering the confirm step, from
  /// the user's persisted prefs. The persisted fee-tier mode and, for custom, the
  /// persisted FEE CAPS (max base fee + priority tip) are honored, falling back
  /// to the Market tier.
  ///
  /// The gas LIMIT always comes from this transaction's fresh [defaultGasLimit]
  /// (the padded estimate) — a persisted custom gas limit is deliberately NOT
  /// replayed. A custom gas limit is only valid for the transaction whose Edit
  /// Gas Fee sheet set it; replaying it across transactions or flows is unsafe.
  /// A ~25 200-gas native-send limit reused for a ~90 000-gas ERC-721
  /// `safeTransferFrom` would broadcast an out-of-gas transaction that mines a
  /// revert with the fee still charged and the asset unmoved. The sheet still
  /// lets the user set a per-transaction gas limit for the tx they are editing;
  /// that rides through as the selection the user applies, not read back here.
  static EthGasSelection resolveFromPrefs({
    required PreferencesService prefs,
    required EthGasMarket market,
    required int defaultGasLimit,
  }) {
    final mode = EthGasMode.fromString(prefs.ethGasMode);
    final customMaxBaseFeeGwei = prefs.ethGasMaxBaseFeeGwei;
    final customPriorityFeeGwei = prefs.ethGasPriorityFeeGwei;
    if (mode == EthGasMode.custom &&
        customMaxBaseFeeGwei != null &&
        customPriorityFeeGwei != null) {
      return EthGasSelection.custom(
        maxBaseFeeGwei: customMaxBaseFeeGwei,
        priorityFeeGwei: customPriorityFeeGwei,
        gasLimit: defaultGasLimit,
      );
    }
    return EthGasSelection.fromTier(
      market.tierFor(mode ?? EthGasMode.market),
      gasLimit: defaultGasLimit,
    );
  }
}
