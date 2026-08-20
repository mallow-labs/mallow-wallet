import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import 'models/account_update.dart';
import 'realtime_socket.dart';

export 'models/account_update.dart' show AccountUpdate;

/// Realtime push of parsed on-chain account state from the backend over the
/// `<api-v2-base>/ws/accounts` WebSocket.
///
/// Where [MarketRealtimeService] keys by mint and only signals "something
/// changed", this keys by **account pubkey** (an AuctionConfig / Listing PDA)
/// and delivers the decoded account itself — `highestBidAmount`,
/// `highestBidder`, `endTime`, … — driven server-side by the listener's
/// LaserStream feed. That lets the artwork screen reflect a bid the instant the
/// on-chain account is written, without a client RPC subscription or an indexer
/// round-trip. See [RealtimeSocket] for the connection/reconnect contract.
@lazySingleton
class AccountRealtimeService extends RealtimeSocket<AccountUpdate> {
  AccountRealtimeService();

  /// Test-only constructor mirroring [MarketRealtimeService.test].
  @visibleForTesting
  AccountRealtimeService.test({
    required WebSocketChannelFactory super.channelFactory,
    super.wsUrlOverride,
    super.random,
  });

  @override
  String get wsPathSuffix => '/ws/accounts';

  @override
  String get subscribeKeyField => 'keys';

  @override
  String get debugLabel => 'AccountRealtimeService';

  /// On reconnect, emit a synthetic frame per still-watched account so the
  /// overlay re-fetches state that may have changed during the outage —
  /// resumed subscriptions only push on the NEXT on-chain write. Mirrors
  /// [MarketRealtimeService.syntheticReconnectEvent].
  @override
  AccountUpdate syntheticReconnectEvent(String key) =>
      AccountUpdate.syntheticReconnect(key);

  @override
  KeyedEvent<AccountUpdate>? parseFrame(Map<String, dynamic> json) {
    // Account frames carry no `type` (that's reserved for ack/error, handled
    // upstream); they self-describe via `accountType` + `pubkey`.
    final pubkey = json['pubkey'];
    if (pubkey is! String || pubkey.isEmpty) return null;
    return (key: pubkey, event: AccountUpdate.fromJson(json));
  }

  /// Subscribe to decoded updates for the account at [pubkey] (a PDA).
  Stream<AccountUpdate> watchAccount(String pubkey) => watch(pubkey);

  @disposeMethod
  @override
  void dispose() => super.dispose();
}
