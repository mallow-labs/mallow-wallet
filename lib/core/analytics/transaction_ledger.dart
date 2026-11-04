import 'dart:async';

import '../../di.dart';
import '../../shared/utils/chain.dart';
import '../config/remote_config.dart';
import 'analytics_events.dart';
import 'analytics_service.dart';

/// Report one transaction the wallet signed and submitted, as
/// [AnalyticsEvent.transactionSubmitted].
///
/// Called from the signing primitives — the Solana pipeline, the EVM transfer
/// funnel, the Tezos transfer service, the purchase services and the dApp
/// browser — once per signature, so every flow built on them is counted
/// without its own instrumentation. A flow that signs outside those primitives
/// must call this itself; that is the only way a transaction goes missing from
/// the ledger.
///
/// [flow] is the kill-switch cell the transaction was authorized under. It is
/// null only for an EVM replacement whose original was not sent by a known
/// flow; [replacement] then says what it is.
///
/// [walletAddress] is resolved lazily, after the gates below, so a disabled
/// pipeline never touches the wallet store. A failure to resolve it sends the
/// event without one rather than dropping it.
///
/// [network] overrides the build's network for a transaction sent to another
/// cluster — a website on devnet in a mainnet build.
///
/// Fire-and-forget: never throws, never blocks the caller, and no-ops when
/// analytics is unregistered, uninitialized or opted out.
void recordSubmittedTransaction({
  required Chain chain,
  required AppFlow? flow,
  required String signature,
  required FutureOr<String?> Function() walletAddress,
  required TxConfirmation confirmation,
  String? network,
  String? replacement,
}) {
  if (signature.isEmpty) return;
  final AnalyticsService analytics;
  try {
    if (!sl.isRegistered<AnalyticsService>()) return;
    analytics = sl<AnalyticsService>();
    if (!analytics.isRecording) return;
  } catch (_) {
    // A transaction is already on the wire; nothing here may throw into it.
    return;
  }
  unawaited(() async {
    String? address;
    try {
      address = await walletAddress();
    } catch (_) {
      // Report the transaction without its signer rather than lose it; the
      // export can recover the signer from the chain.
    }
    try {
      await analytics.track(
        AnalyticsEvent.transactionSubmitted,
        properties: {
          AnalyticsProp.chain: AnalyticsChain.fromChain(chain).wire,
          AnalyticsProp.flow: flow == null
              ? null
              : FlowKey(chain, flow).toString(),
          AnalyticsProp.signature: signature,
          AnalyticsProp.walletAddress: address,
          AnalyticsProp.confirmation: confirmation.wire,
          AnalyticsProp.network: ?network,
          AnalyticsProp.replacement: ?replacement,
        },
      );
    } catch (_) {
      // Analytics must never surface into a signing flow.
    }
  }());
}
