import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import 'models/market_invalidation.dart';
import 'realtime_socket.dart';

export 'realtime_socket.dart' show WebSocketChannelFactory;

/// Realtime push of marketplace invalidation events from the backend.
///
/// Binds [RealtimeSocket] to the `<api-v2-base>/ws/invalidations` endpoint:
/// multiplexes per-mint subscriptions across consumers and surfaces
/// [MarketInvalidation] events. See [RealtimeSocket] for the connection /
/// reconnect / lifecycle contract.
@lazySingleton
class MarketRealtimeService extends RealtimeSocket<MarketInvalidation> {
  MarketRealtimeService();

  /// Test-only constructor. Lets unit tests inject a fake WebSocket channel
  /// factory and a deterministic [Random] so backoff timings are predictable.
  @visibleForTesting
  MarketRealtimeService.test({
    required WebSocketChannelFactory super.channelFactory,
    super.wsUrlOverride,
    super.random,
  });

  @override
  String get wsPathSuffix => '/ws/invalidations';

  @override
  String get subscribeKeyField => 'mints';

  @override
  String get debugLabel => 'MarketRealtimeService';

  @override
  KeyedEvent<MarketInvalidation>? parseFrame(Map<String, dynamic> json) {
    if (json['type'] != 'invalidate') return null;
    final event = MarketInvalidation.fromJson(json);
    return (key: event.mint, event: event);
  }

  @override
  MarketInvalidation syntheticReconnectEvent(String key) => MarketInvalidation(
    mint: key,
    signature: '',
    slot: 0,
    programs: const ['__synthetic_reconnect__'],
  );

  /// Subscribe to invalidation events for [mintAccount].
  Stream<MarketInvalidation> watchMint(String mintAccount) =>
      watch(mintAccount);

  /// Inject a synthetic invalidation for [mintAccount] — used by transaction
  /// pipelines (listing, auction create, etc.) to drive a refresh the moment
  /// our own `checkTx` poll confirms the indexer has caught up.
  ///
  /// [programs] should include the on-chain program(s) the consuming screens
  /// key off (e.g. `kMallowMarketProgramId`). Pass the tx's landed [slot]
  /// when known (via `TxLandedSlots`) so consumers can raise their chain
  /// floor — an on-chain read whose view predates the slot must not be
  /// trusted to contradict the action; 0 means "unknown".
  void publishLocal({
    required String mintAccount,
    required String signature,
    required List<String> programs,
    int slot = 0,
  }) {
    publishLocalRaw(
      mintAccount,
      MarketInvalidation(
        mint: mintAccount,
        signature: signature,
        slot: slot,
        programs: programs,
      ),
    );
  }

  @disposeMethod
  @override
  void dispose() => super.dispose();
}
