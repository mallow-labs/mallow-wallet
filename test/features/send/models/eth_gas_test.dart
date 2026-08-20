import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// gwei → wei for terse assertions.
BigInt _g(num gwei) => EthGasMarket.gweiToWei(gwei.toDouble());

/// A [PreferencesService] backed by mocked SharedPreferences seeded with the
/// persisted Ethereum-gas keys — the exact store `resolveFromPrefs` reads.
Future<PreferencesService> _prefsWith({
  String? mode,
  double? maxBaseFeeGwei,
  double? priorityFeeGwei,
  int? gasLimit,
}) async {
  SharedPreferences.setMockInitialValues({
    'pref_eth_gas_mode': ?mode,
    'pref_eth_gas_max_base_fee_gwei': ?maxBaseFeeGwei,
    'pref_eth_gas_priority_fee_gwei': ?priorityFeeGwei,
    'pref_eth_gas_limit': ?gasLimit,
  });
  return PreferencesService.create();
}

/// A representative Infura `suggestedGasFees` payload (fee values are
/// gwei-decimal strings; wait times are ms; congestion is 0..1).
Map<String, dynamic> _sample({num congestion = 0.8}) => {
  'low': {
    'suggestedMaxPriorityFeePerGas': '1',
    'suggestedMaxFeePerGas': '20',
    'minWaitTimeEstimate': 30000,
    'maxWaitTimeEstimate': 60000,
  },
  'medium': {
    'suggestedMaxPriorityFeePerGas': '2',
    'suggestedMaxFeePerGas': '24',
    'minWaitTimeEstimate': 15000,
    'maxWaitTimeEstimate': 30000,
  },
  'high': {
    'suggestedMaxPriorityFeePerGas': '3',
    'suggestedMaxFeePerGas': '30',
    'minWaitTimeEstimate': 15000,
    'maxWaitTimeEstimate': 15000,
  },
  'estimatedBaseFee': '11',
  'networkCongestion': congestion,
  'latestPriorityFeeRange': ['1', '3'],
  'historicalPriorityFeeRange': ['0.5', '12'],
  'historicalBaseFeeRange': ['10', '25'],
  'priorityFeeTrend': 'up',
  'baseFeeTrend': 'down',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EthGasMarket.fromSuggestedGasFees', () {
    late EthGasMarket market;

    setUp(() => market = EthGasMarket.fromSuggestedGasFees(_sample()));

    test('maps estimatedBaseFee (gwei string) to the base fee', () {
      expect(market.baseFeeWei, _g(11));
    });

    test('Low ← low, Market ← medium (caps + priority tips)', () {
      expect(market.low.maxFeePerGas, _g(20));
      expect(market.low.maxPriorityFeePerGas, _g(1));
      expect(market.market.maxFeePerGas, _g(24));
      expect(market.market.maxPriorityFeePerGas, _g(2));
    });

    test('tier speed labels come from the real wait estimates', () {
      // medium: 15000–30000 ms → range "15 - 30 sec"; ETA = upper bound.
      expect(market.market.speedRangeLabel, '15 - 30 sec');
      expect(market.market.etaLabel, '~30 sec');
      expect(market.low.speedRangeLabel, '30 - 60 sec');
    });

    test('priority range comes from latestPriorityFeeRange', () {
      expect(market.priorityLowWei, _g(1));
      expect(market.priorityHighWei, _g(3));
    });

    test('congestion + Busy/Stable come from networkCongestion', () {
      expect(market.congestion, closeTo(0.8, 1e-9));
      expect(market.isBusy, isTrue); // 0.8 >= 0.66
      expect(market.statusLabel, 'Busy');

      final calm = EthGasMarket.fromSuggestedGasFees(_sample(congestion: 0.2));
      expect(calm.isBusy, isFalse);
      expect(calm.statusLabel, 'Stable');
    });

    test('historical (12 hr) ranges come from the historical* fields', () {
      expect(market.historicalBaseFeeMinWei, _g(10));
      expect(market.historicalBaseFeeMaxWei, _g(25));
      expect(market.historicalPriorityMinWei, _g(0.5));
      expect(market.historicalPriorityMaxWei, _g(12));
    });

    test('degrades gracefully on an empty/partial payload', () {
      final empty = EthGasMarket.fromSuggestedGasFees(const {});
      expect(empty.baseFeeWei, BigInt.zero);
      expect(empty.congestion, 0.0);
      expect(empty.isBusy, isFalse);
      expect(empty.market.maxFeePerGas, BigInt.zero);
    });
  });

  group('EthGasMode.fromString', () {
    test('maps the persisted tier strings', () {
      expect(EthGasMode.fromString('low'), EthGasMode.low);
      expect(EthGasMode.fromString('market'), EthGasMode.market);
      expect(EthGasMode.fromString('custom'), EthGasMode.custom);
    });

    test('null / unrecognised → null (confirm step defaults to Market)', () {
      expect(EthGasMode.fromString(null), isNull);
      expect(EthGasMode.fromString(''), isNull);
      expect(EthGasMode.fromString('advanced'), isNull);
    });
  });

  group('EthGasSelection.resolveFromPrefs', () {
    final market = EthGasMarket.fromSuggestedGasFees(_sample());

    test('defaults to the Market tier when no mode is persisted', () async {
      final s = EthGasSelection.resolveFromPrefs(
        prefs: await _prefsWith(),
        market: market,
        defaultGasLimit: 21000,
      );
      expect(s.mode, EthGasMode.market);
      expect(s.maxPriorityFeePerGas, market.market.maxPriorityFeePerGas);
      expect(s.gasLimit, 21000);
      // Preset selection carries the tier's ETA for the confirm Speed pill.
      expect(s.speedEta, market.market.etaLabel);
    });

    test('honors persisted custom fee CAPS', () async {
      final s = EthGasSelection.resolveFromPrefs(
        prefs: await _prefsWith(
          mode: 'custom',
          maxBaseFeeGwei: 50,
          priorityFeeGwei: 2,
        ),
        market: market,
        defaultGasLimit: 21000,
      );
      expect(s.mode, EthGasMode.custom);
      // maxFeePerGas = maxBaseFee + priority = 52 gwei.
      expect(s.maxFeePerGas, _g(52));
      expect(s.maxPriorityFeePerGas, _g(2));
      expect(s.speedEta, '—'); // no measured ETA for a hand-tuned fee
    });

    // WHY (FINDING 1, funds loss): a gas limit is per-transaction. A limit
    // persisted by a plain-ETH send (~25 200) must NEVER be replayed onto an
    // artwork transfer (~90 000-gas safeTransferFrom) — signing 25 200 mines an
    // out-of-gas revert, burning the fee and stranding the NFT. resolveFromPrefs
    // reads NO persisted gas limit: it always takes this transfer's fresh padded
    // estimate, so the stale value below is ignored and the estimate wins.
    test('never applies a stale persisted gas limit — the fresh estimate '
        'wins', () async {
      final s = EthGasSelection.resolveFromPrefs(
        prefs: await _prefsWith(
          mode: 'custom',
          maxBaseFeeGwei: 50,
          priorityFeeGwei: 2,
          gasLimit: 25200, // stale limit saved by another (native-send) flow
        ),
        market: market,
        defaultGasLimit: 90000, // this artwork transfer's fresh padded estimate
      );
      expect(s.mode, EthGasMode.custom);
      expect(
        s.gasLimit,
        90000,
        reason: 'fresh estimate must win over the stale persisted limit',
      );
    });

    test('falls back to Market when custom mode lacks saved knobs', () async {
      // Custom mode but no persisted caps → falls back to Market.
      final s = EthGasSelection.resolveFromPrefs(
        prefs: await _prefsWith(mode: 'custom'),
        market: market,
        defaultGasLimit: 21000,
      );
      expect(s.mode, EthGasMode.market);
    });
  });

  group('EthGasSelection', () {
    final market = EthGasMarket.fromSuggestedGasFees(_sample());

    test('effectiveGasPrice = base + tip, capped at maxFeePerGas', () {
      final marketSel = EthGasSelection.fromTier(
        market.market,
        gasLimit: 21000,
      );
      // Uncapped: base 11 + tip 2 = 13 < maxFee 24.
      expect(marketSel.effectiveGasPrice(_g(11)), _g(13));

      // Capped: a tight custom maxFee below base+tip pins to the cap.
      final tight = EthGasSelection.custom(
        maxBaseFeeGwei: 10, // maxFee = 10 + 2 = 12 gwei
        priorityFeeGwei: 2,
        gasLimit: 21000,
      );
      expect(tight.effectiveGasPrice(_g(11)), _g(12));
    });

    test('maxBaseFeeGwei/priorityFeeGwei round-trip the Advanced fields', () {
      final s = EthGasSelection.custom(
        maxBaseFeeGwei: 42,
        priorityFeeGwei: 1.5,
        gasLimit: 21000,
      );
      expect(s.maxBaseFeeGwei, closeTo(42, 1e-6));
      expect(s.priorityFeeGwei, closeTo(1.5, 1e-6));
    });
  });
}
