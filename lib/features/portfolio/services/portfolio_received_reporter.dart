import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/observability/app_logger.dart';
import '../../../di.dart';
import 'portfolio_refresh_signal.dart';

/// Tells the backend that a transaction the wallet sent has landed, so the
/// tokens it delivered reach the portfolio in seconds.
///
/// The backend has no listener for every chain the wallet signs on: none for
/// Tezos, and on Ethereum only for collections it already tracks. Without
/// this, a purchase made in the in-app browser stays out of the My Art tab
/// until the next login import, hours later. The backend verifies the
/// transaction against the chain itself and refreshes only the tokens it moved
/// to the given address, so a report is safe to send for any transaction.
///
/// The refresh it queues is asynchronous and waits for marketplace data to
/// catch up, so the portfolio is refetched a few times over the backend's
/// retry window instead of once.
@lazySingleton
class PortfolioReceivedReporter {
  PortfolioReceivedReporter(this._api)
    : _delay = Future<void>.delayed,
      _refresh = notifyPortfolioRefresh;

  /// Test seam: [delay] replaces the real waits, [refresh] the portfolio signal.
  PortfolioReceivedReporter.test(
    this._api, {
    required Future<void> Function(Duration) delay,
    required void Function() refresh,
  }) : _delay = delay,
       _refresh = refresh;

  final api.MallowApiV2Client _api;
  final Future<void> Function(Duration) _delay;
  final void Function() _refresh;

  /// Waits before asking again while the backend cannot see the transaction.
  static const pendingBackoff = [
    Duration(seconds: 3),
    Duration(seconds: 6),
    Duration(seconds: 12),
  ];

  /// When to refetch the portfolio after the backend queued a refresh,
  /// measured from the previous refetch. Spans the backend's retry window of
  /// about three minutes.
  static const refreshSchedule = [
    Duration(seconds: 4),
    Duration(seconds: 15),
    Duration(seconds: 40),
    Duration(seconds: 120),
  ];

  static const _tag = 'PortfolioReceived';

  /// Reports a Tezos operation that landed applied. Never throws: a failed
  /// report leaves the purchase to the next login import, as before.
  Future<void> reportTezos({required String opHash, required String address}) =>
      _report(api.PortfolioReceivedChain.tezos, opHash, address);

  /// Reports an Ethereum mainnet transaction that mined successfully and
  /// moved an NFT to [address]. Never throws, like [reportTezos].
  Future<void> reportEthereum({
    required String txHash,
    required String address,
  }) => _report(api.PortfolioReceivedChain.ethereum, txHash, address);

  Future<void> _report(
    api.PortfolioReceivedChain chain,
    String txHash,
    String address,
  ) async {
    final request = api.PortfolioReceivedRequest(
      chain: chain,
      txHash: txHash,
      address: address,
    );
    try {
      for (var attempt = 0; ; attempt++) {
        final result = (await _api.postPortfolioReceived(request)).result;
        switch (result.status) {
          case api.PortfolioReceivedStatus.queued:
            for (final wait in refreshSchedule) {
              await _delay(wait);
              _refresh();
            }
            return;
          case api.PortfolioReceivedStatus.pending:
            if (attempt >= pendingBackoff.length) return;
            await _delay(pendingBackoff[attempt]);
          case api.PortfolioReceivedStatus.none:
          case api.PortfolioReceivedStatus.swaggerGeneratedUnknown:
            return;
        }
      }
    } catch (error) {
      AppLogger.warn(_tag, 'report failed: $error');
    }
  }
}

/// Fire-and-forget [PortfolioReceivedReporter.reportTezos], safe to call from
/// anywhere. No-ops when DI isn't configured (unit tests that don't bootstrap
/// GetIt), like [notifyPortfolioRefresh].
void reportTezosReceived({required String opHash, required String address}) {
  if (!sl.isRegistered<PortfolioReceivedReporter>()) return;
  unawaited(
    sl<PortfolioReceivedReporter>().reportTezos(
      opHash: opHash,
      address: address,
    ),
  );
}

/// Fire-and-forget [PortfolioReceivedReporter.reportEthereum], with the same
/// no-DI behavior as [reportTezosReceived].
void reportEthereumReceived({required String txHash, required String address}) {
  if (!sl.isRegistered<PortfolioReceivedReporter>()) return;
  unawaited(
    sl<PortfolioReceivedReporter>().reportEthereum(
      txHash: txHash,
      address: address,
    ),
  );
}
