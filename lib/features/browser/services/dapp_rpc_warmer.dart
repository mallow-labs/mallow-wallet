import 'dart:async';

import '../../../core/network/kept_alive_http.dart';
import 'ethereum_dapp_adapter.dart';
import 'solana_dapp_adapter.dart';

/// Keeps open the connections a transaction review reads through while a
/// website is using the wallet, so the review does not begin with a TCP and
/// TLS handshake: two round trips to a distant endpoint, before any call.
///
/// A site's activity (connect, an account poll, a read) marks its namespace in
/// use. Its connections are opened then, and again every [interval] for
/// [window] after its last activity, while the app is in the foreground. A
/// user who reads a page for minutes before swapping still finds them ready.
class DappRpcWarmer {
  DappRpcWarmer({
    Map<String, Future<void> Function()>? warmers,
    this.interval = const Duration(seconds: 45),
    this.window = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : assert(interval < keptAliveIdleTimeout),
       _warmers =
           warmers ??
           {
             'solana': SolanaDappAdapter.warmConnections,
             'eip155': EthereumDappAdapter.warmConnections,
           },
       _now = now ?? DateTime.now;

  static final instance = DappRpcWarmer();

  /// How often connections are reopened; below [keptAliveIdleTimeout], so the
  /// pool never drops them in between.
  final Duration interval;

  /// How long after a namespace's last activity it is kept warm.
  final Duration window;

  final Map<String, Future<void> Function()> _warmers;
  final DateTime Function() _now;
  final _activity = <String, DateTime>{};
  final _warmed = <String, DateTime>{};
  Timer? _timer;
  bool _foreground = true;

  /// A site used [namespace] (`solana`, `eip155`); others are ignored.
  void touch(String namespace) {
    if (!_warmers.containsKey(namespace)) return;
    _activity[namespace] = _now();
    if (_foreground) {
      _warm(namespace);
      _schedule();
    }
  }

  /// The app came to the foreground or went to the background. Connections
  /// do not survive the background, so a return opens them again at once.
  void setForeground(bool foreground) {
    if (foreground == _foreground) return;
    _foreground = foreground;
    _warmed.clear();
    if (!foreground) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _tick();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _schedule() => _timer ??= Timer.periodic(interval, (_) => _tick());

  void _tick() {
    final now = _now();
    _activity.removeWhere((_, at) => now.difference(at) > window);
    if (_activity.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _activity.keys.forEach(_warm);
    _schedule();
  }

  void _warm(String namespace) {
    final now = _now();
    final last = _warmed[namespace];
    // A tick that lands just after a touch's warm-up would only repeat it.
    if (last != null && now.difference(last) < interval ~/ 2) return;
    _warmed[namespace] = now;
    unawaited(_warmers[namespace]!().then<void>((_) {}, onError: (_) {}));
  }
}
