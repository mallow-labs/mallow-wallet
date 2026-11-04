import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_events.dart';
import 'package:mallow_wallet/core/analytics/transaction_ledger.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

import '../../support/recording_analytics.dart';

/// The ledger is what the usage export counts, so an event must carry
/// everything a row needs on its own, and reporting must never be able to
/// break or slow the flow that signed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(RecordingAnalytics.uninstall);

  test(
    'reports chain, flow cell, signature, signer and confirmation',
    () async {
      final analytics = await RecordingAnalytics.install();

      recordSubmittedTransaction(
        chain: Chain.ethereum,
        flow: AppFlow.tokenSend,
        signature: '0xhash',
        walletAddress: () => '0xWallet',
        confirmation: TxConfirmation.pending,
        replacement: 'speedup',
      );
      await pumpEventQueue();

      final event = analytics.submitted.single;
      expect(event[AnalyticsProp.chain], 'ethereum');
      expect(event[AnalyticsProp.flow], 'ethereum:token-send');
      expect(event[AnalyticsProp.signature], '0xhash');
      expect(event[AnalyticsProp.walletAddress], '0xWallet');
      expect(event[AnalyticsProp.confirmation], 'pending');
      expect(event[AnalyticsProp.replacement], 'speedup');
      // Kept off so dashboards counting `is_onchain_tx` on the per-flow
      // `* Completed` events do not count these transactions twice.
      expect(event.containsKey(AnalyticsProp.isOnchainTx), isFalse);
    },
  );

  test('a network override replaces the build network', () async {
    final analytics = await RecordingAnalytics.install();

    recordSubmittedTransaction(
      chain: Chain.solana,
      flow: AppFlow.browserTransaction,
      signature: 'sig',
      walletAddress: () => 'addr',
      confirmation: TxConfirmation.dapp,
      network: 'devnet',
    );
    await pumpEventQueue();

    expect(analytics.submitted.single[AnalyticsProp.network], 'devnet');
  });

  test('an unresolvable signer still reports the transaction', () async {
    final analytics = await RecordingAnalytics.install();

    recordSubmittedTransaction(
      chain: Chain.solana,
      flow: AppFlow.nftMint,
      signature: 'sig',
      walletAddress: () => throw StateError('no wallet'),
      confirmation: TxConfirmation.confirmed,
    );
    await pumpEventQueue();

    final event = analytics.submitted.single;
    expect(event[AnalyticsProp.signature], 'sig');
    expect(event.containsKey(AnalyticsProp.walletAddress), isTrue);
    expect(event[AnalyticsProp.walletAddress], isNull);
  });

  test('opted out: nothing is sent and the wallet store is not read', () async {
    final analytics = await RecordingAnalytics.install(optOut: true);
    var resolved = false;

    recordSubmittedTransaction(
      chain: Chain.solana,
      flow: AppFlow.nativeSend,
      signature: 'sig',
      walletAddress: () {
        resolved = true;
        return 'addr';
      },
      confirmation: TxConfirmation.confirmed,
    );
    await pumpEventQueue();

    expect(analytics.events, isEmpty);
    expect(resolved, isFalse);
  });

  test('no analytics registered: a no-op, not a throw', () async {
    expect(
      () => recordSubmittedTransaction(
        chain: Chain.tezos,
        flow: AppFlow.nativeSend,
        signature: 'oo',
        walletAddress: () => 'tz1',
        confirmation: TxConfirmation.confirmed,
      ),
      returnsNormally,
    );
  });

  test('an empty signature is not a transaction', () async {
    final analytics = await RecordingAnalytics.install();

    recordSubmittedTransaction(
      chain: Chain.solana,
      flow: AppFlow.tokenSwap,
      signature: '',
      walletAddress: () => 'addr',
      confirmation: TxConfirmation.confirmed,
    );
    await pumpEventQueue();

    expect(analytics.events, isEmpty);
  });
}
