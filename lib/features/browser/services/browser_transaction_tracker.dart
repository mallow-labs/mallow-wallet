import 'dart:async';
import 'package:flutter/foundation.dart';

enum BrowserTransactionStatus { pending, confirmed, failed, uncertain }

class BrowserTransactionRecord {
  const BrowserTransactionRecord({
    required this.signature,
    required this.chain,
    required this.status,
    required this.createdAt,
    this.slot,
  });
  final String signature;
  final String chain;
  final BrowserTransactionStatus status;
  final DateTime createdAt;
  final int? slot;
}

typedef BrowserStatusLookup =
    Future<Object?> Function(String chain, String signature);

/// Bounded, memory-only broadcast receipts outlive browser screens. Polling is
/// read-only: an ambiguous submission is never retried by the wallet.
class BrowserTransactionTracker extends ChangeNotifier {
  BrowserTransactionTracker({
    this.interval = const Duration(seconds: 3),
    this.maxPolls = 40,
  });
  static final instance = BrowserTransactionTracker();
  static const _ethereumInterval = Duration(seconds: 12);
  static const _ethereumMaxPolls = 300;
  final Duration interval;
  final int maxPolls;
  final _records = <String, BrowserTransactionRecord>{};
  final _timers = <String, Timer>{};
  final _tokens = <String, Object>{};
  final _presented = <String>{};
  List<BrowserTransactionRecord> get records =>
      List.unmodifiable(_records.values.toList().reversed);
  String _key(String chain, String signature) => '$chain:$signature';

  BrowserTransactionRecord? recordFor(String chain, String signature) =>
      _records[_key(chain, signature)];

  /// Whether a foreground sheet is showing this transaction's progress, so the
  /// status toast stays out of its way.
  bool isPresented(BrowserTransactionRecord record) =>
      _presented.contains(_key(record.chain, record.signature));

  /// Claims the transaction for a foreground sheet. Called before the
  /// broadcast, so the toast never sees it pending unclaimed.
  void present(String chain, String signature) {
    if (_presented.add(_key(chain, signature))) notifyListeners();
  }

  /// Hands the transaction back to the toast, which picks it up only while it
  /// is still pending: an outcome the sheet already showed is not repeated.
  void release(String chain, String signature) {
    if (_presented.remove(_key(chain, signature))) notifyListeners();
  }

  /// A transaction the wallet broadcast itself: listed at once as pending.
  void start({
    required String signature,
    required String chain,
    required BrowserStatusLookup lookup,
  }) => _track(signature, chain, lookup, listed: true);

  /// A transaction the wallet only signed; the website may broadcast it, or
  /// never. It is listed only once the network reports it, and a signature
  /// never seen within [maxPolls] is dropped without a trace: a sign-only
  /// request that was never sent is not a transaction the user made.
  void watchSigned({
    required String signature,
    required String chain,
    required BrowserStatusLookup lookup,
  }) {
    final key = _key(chain, signature);
    if (_records.containsKey(key) || _tokens.containsKey(key)) return;
    _track(signature, chain, lookup, listed: false);
  }

  void _track(
    String signature,
    String chain,
    BrowserStatusLookup lookup, {
    required bool listed,
  }) {
    // Low-fee Ethereum broadcasts can remain pending beyond a Solana blockhash
    // lifetime. Allow an hour of receipt polling, then stop to bound RPC work.
    final ethereumBroadcast = listed && chain == 'eip155:1';
    final pollInterval = ethereumBroadcast ? _ethereumInterval : interval;
    final pollLimit = ethereumBroadcast ? _ethereumMaxPolls : maxPolls;
    final key = _key(chain, signature);
    _timers.remove(key)?.cancel();
    final token = Object();
    _tokens[key] = token;
    if (listed) _list(key, signature, chain);
    var attempts = 0;
    Future<void> poll() async {
      if (_tokens[key] != token) return;
      attempts++;
      try {
        final result = await lookup(chain, signature);
        if (_tokens[key] != token) return;
        final value = result is Map ? result['value'] : null;
        final status = value is List && value.isNotEmpty && value.first is Map
            ? value.first as Map
            : null;
        if (status != null && !_records.containsKey(key)) {
          _list(key, signature, chain);
        }
        if (status != null && status['err'] != null) {
          _update(key, BrowserTransactionStatus.failed, status['slot'] as int?);
          _tokens.remove(key);
          _timers.remove(key);
          return;
        }
        if (status != null &&
            const [
              'confirmed',
              'finalized',
            ].contains(status['confirmationStatus'])) {
          _update(
            key,
            BrowserTransactionStatus.confirmed,
            status['slot'] as int?,
          );
          _tokens.remove(key);
          _timers.remove(key);
          return;
        }
      } catch (_) {
        // An unavailable status endpoint is not evidence of transaction failure.
      }
      if (_tokens[key] != token) return;
      if (attempts >= pollLimit) {
        // Only a listed record becomes uncertain; an unseen watch just ends.
        _update(key, BrowserTransactionStatus.uncertain, null);
        _tokens.remove(key);
        _timers.remove(key);
        return;
      }
      _timers[key] = Timer(pollInterval, () => unawaited(poll()));
    }

    _timers[key] = Timer(pollInterval, () => unawaited(poll()));
  }

  void _list(String key, String signature, String chain) {
    if (_records.length >= 50 && !_records.containsKey(key)) {
      final oldest = _records.keys.first;
      _records.remove(oldest);
      _timers.remove(oldest)?.cancel();
      _tokens.remove(oldest);
      _presented.remove(oldest);
    }
    _records[key] = BrowserTransactionRecord(
      signature: signature,
      chain: chain,
      status: BrowserTransactionStatus.pending,
      createdAt: DateTime.now().toUtc(),
    );
    notifyListeners();
  }

  /// The RPC explicitly rejected this submission before enqueueing it.
  void markRejected(String chain, String signature) {
    final key = _key(chain, signature);
    _timers.remove(key)?.cancel();
    _tokens.remove(key);
    _update(key, BrowserTransactionStatus.failed, null);
  }

  void markUncertain(String chain, String signature) {
    final key = _key(chain, signature);
    final status = _records[key]?.status;
    if (status == BrowserTransactionStatus.pending)
      _update(key, BrowserTransactionStatus.uncertain, null);
  }

  void _update(String key, BrowserTransactionStatus status, int? slot) {
    final old = _records[key];
    if (old == null) return;
    _records[key] = BrowserTransactionRecord(
      signature: old.signature,
      chain: old.chain,
      status: status,
      createdAt: old.createdAt,
      slot: slot,
    );
    notifyListeners();
  }

  void clear() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _tokens.clear();
    _presented.clear();
    _records.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    clear();
    super.dispose();
  }
}
