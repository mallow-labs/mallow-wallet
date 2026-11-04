import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/sell/services/trade_eligibility.dart';

void main() {
  DigitalAsset leaf({int? flags = 0, bool grouped = false}) =>
      DigitalAsset.fromJson({
        'id': 'leaf',
        'interface': 'MplBubblegumV2',
        'compression': {'compressed': true, if (flags != null) 'flags': flags},
        if (grouped)
          'grouping': [
            {'group_key': 'collection', 'group_value': 'parent'},
          ],
      });
  test('unknown standard or v2 without a leaf stays unverified', () {
    for (final standard in [null, 'cnft-v2']) {
      expect(
        resolveTradeEligibility(asset: null, expectedTokenStandard: standard),
        TradeEligibility.unverified,
      );
    }
    expect(
      resolveTradeEligibility(asset: null, expectedTokenStandard: 'cnft'),
      TradeEligibility.eligible,
    );
  });
  test(
    'missing flags are unverified, zero is eligible, set flags are restricted',
    () {
      expect(
        resolveTradeEligibility(asset: leaf(flags: null)),
        TradeEligibility.unverified,
      );
      expect(resolveTradeEligibility(asset: leaf()), TradeEligibility.eligible);
      for (final flags in [1, 2, 4, 8]) {
        expect(
          resolveTradeEligibility(asset: leaf(flags: flags)),
          TradeEligibility.restricted,
        );
      }
    },
  );
  test(
    'collection missing, mismatched or wrong standard remains unverified',
    () {
      for (final collection in [
        null,
        DigitalAsset.fromJson({
          'id': 'other',
          'interface': 'MplCoreCollection',
        }),
        DigitalAsset.fromJson({'id': 'parent', 'interface': 'MplCoreAsset'}),
      ]) {
        expect(
          resolveTradeEligibility(
            asset: leaf(grouped: true),
            collection: collection,
          ),
          TradeEligibility.unverified,
        );
      }
    },
  );
  test(
    'a confirmed leaf restriction is reported even if its collection is unavailable',
    () {
      expect(
        resolveTradeEligibility(asset: leaf(flags: 4, grouped: true)),
        TradeEligibility.restricted,
      );
    },
  );
}
