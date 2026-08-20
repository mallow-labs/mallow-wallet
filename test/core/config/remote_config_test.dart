import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/config/remote_config.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

api.MobileConfigResponse _wire(List<Map<String, String>> disabled) {
  return api.MobileConfigResponse.fromJson({
    'minimumVersion': '0.11.0',
    'updateRequired': false,
    'updateMessage': null,
    'disabledFlows': disabled,
  });
}

void main() {
  group('AppFlow', () {
    test('its wire strings are exactly the contract\'s MobileFlow cells', () {
      // The flow axis is a shared contract: the operator types these strings
      // into Mongo and the client looks them up. A cell present on one side
      // only is a kill switch that silently does nothing, so pin both
      // directions rather than trusting the two lists to be hand-synced.
      final contract = api.MobileFlow.values
          .map((v) => v.value)
          .whereType<String>()
          .toSet();

      final clientWires = AppFlow.values.map((f) => f.wire).toSet();
      expect(clientWires, contract);
      expect(AppFlow.values, hasLength(contract.length));
    });

    test('only native-send, token-send and nft-transfer are multi-chain', () {
      // The (chain, flow) support matrix, as an assertion. Every other cell is
      // Solana-only *by construction* — if one of them ever gains a chain,
      // the UI permission gate and this set have to move together.
      final multiChain = {
        for (final f in AppFlow.values)
          if (f.chains.length > 1) f.wire: f.chains,
      };

      expect(multiChain, {
        'native-send': {Chain.solana, Chain.ethereum, Chain.tezos},
        'token-send': {Chain.solana, Chain.ethereum, Chain.tezos},
        'nft-transfer': {Chain.solana, Chain.ethereum},
      });
      expect(
        AppFlow.values.where((f) => f.chains.length == 1),
        everyElement(
          predicate<AppFlow>((f) => f.chains.single == Chain.solana),
        ),
      );
    });

    test('isImplemented covers both Tezos send cells', () {
      // The reason the send cell was split in two: XTZ and FA moved on
      // different schedules, and a single coarse `send` cell could not express
      // "one is live, the other is not". Both ship now, but they stay separate
      // cells so an operator can still kill FA sends without stranding XTZ.
      expect(AppFlow.nativeSend.isImplemented(Chain.tezos), isTrue);
      expect(AppFlow.tokenSend.isImplemented(Chain.tezos), isTrue);
      // The split is only meaningful while the two are independently killable.
      expect(AppFlow.nativeSend, isNot(AppFlow.tokenSend));
    });
  });

  group('RemoteConfig.permissive', () {
    test('kills nothing and requires no update', () {
      const config = RemoteConfig.permissive;

      expect(config.disabledMessages, isEmpty);
      expect(config.updateRequired, isFalse);
      expect(config.disabledMessage(Chain.solana, AppFlow.nativeSend), isNull);
      expect(config.isFlowAvailable(Chain.solana, AppFlow.nativeSend), isTrue);
    });
  });

  group('RemoteConfig.fromWire', () {
    test('folds disabledFlows into a chain-scoped map', () {
      final config = RemoteConfig.fromWire(
        _wire([
          {'chain': 'ethereum', 'flow': 'native-send', 'message': 'ETH paused'},
        ]),
      );

      // The whole point of the per-chain axis: killing EVM send must leave
      // Solana send alone.
      expect(
        config.disabledMessage(Chain.ethereum, AppFlow.nativeSend),
        'ETH paused',
      );
      expect(config.disabledMessage(Chain.solana, AppFlow.nativeSend), isNull);
      expect(config.minimumVersion, '0.11.0');
    });

    test('killing a create cell leaves its escape-hatch twin reachable', () {
      // Escape hatches exist so a user can always get assets back out. If
      // killing broken listing-creation also killed delisting, every listed
      // asset would be stranded — the failure per-cell granularity prevents.
      final config = RemoteConfig.fromWire(
        _wire([
          {
            'chain': 'solana',
            'flow': 'fixed-price-create',
            'message': 'Listing paused',
          },
        ]),
      );

      expect(
        config.isFlowAvailable(Chain.solana, AppFlow.fixedPriceCreate),
        isFalse,
      );
      expect(
        config.isFlowAvailable(Chain.solana, AppFlow.fixedPriceCancel),
        isTrue,
      );
    });

    test('drops entries naming a chain or flow this build does not know', () {
      // A newer server may kill a cell this build has never heard of. It must
      // be ignored, not coerced — `Chain.fromDbString` would fold an unknown
      // chain onto Solana and kill a live Solana flow.
      final config = RemoteConfig.fromWire(
        _wire([
          {'chain': 'bitcoin', 'flow': 'native-send', 'message': 'nope'},
          {'chain': 'solana', 'flow': 'teleport-nft', 'message': 'nope'},
        ]),
      );

      expect(config.disabledMessages, isEmpty);
      expect(config.isFlowAvailable(Chain.solana, AppFlow.nativeSend), isTrue);
    });

    test('isFlowAvailable is false for a cell this build cannot do', () {
      const config = RemoteConfig.permissive;

      // Nothing is killed, but Tezos NFT transfer was never implemented.
      expect(config.isFlowAvailable(Chain.tezos, AppFlow.nftTransfer), isFalse);
      expect(config.disabledMessage(Chain.tezos, AppFlow.nftTransfer), isNull);
    });
  });
}
