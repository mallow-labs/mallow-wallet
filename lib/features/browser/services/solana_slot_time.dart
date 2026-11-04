import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart' show MallowApiV2Client;

/// The time per Solana slot, which turns a blockhash's remaining blocks into
/// seconds. The backend measures it at most once a day; this keeps one copy
/// for the same 24 hours, so a review costs no request once it is loaded.
class SolanaSlotTimeSource {
  SolanaSlotTimeSource({
    Future<int> Function()? fetch,
    DateTime Function()? now,
  }) : _fetch = fetch ?? _fetchFromApi,
       _now = now ?? DateTime.now;

  static final instance = SolanaSlotTimeSource();

  /// Used until the backend answers, and when it cannot. Below the measured
  /// rate (about 218 ms in October 2026), so a countdown built on it runs out
  /// early rather than late. A slot the leader skips makes no block, which
  /// errs the same way.
  static const fallback = Duration(milliseconds: 200);

  static const _keepFor = Duration(hours: 24);
  static const _retryAfter = Duration(minutes: 5);

  final Future<int> Function() _fetch;
  final DateTime Function() _now;

  Duration? _value;
  DateTime? _fetchedAt;
  DateTime? _failedAt;
  Future<Duration>? _inFlight;

  /// The cached value, or [fallback] while there is none. Starts a refresh
  /// when the copy is a day old, without waiting for it.
  Duration get current {
    _refreshIfDue();
    return _value ?? fallback;
  }

  /// Waits for the first value, falling back on failure. Never throws.
  Future<Duration> load() async {
    _refreshIfDue();
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    return _value ?? fallback;
  }

  void _refreshIfDue() {
    if (_inFlight != null) return;
    final now = _now();
    final fetchedAt = _fetchedAt;
    if (fetchedAt != null && now.difference(fetchedAt) < _keepFor) return;
    final failedAt = _failedAt;
    if (failedAt != null && now.difference(failedAt) < _retryAfter) return;
    _inFlight = _refresh().whenComplete(() => _inFlight = null);
  }

  Future<Duration> _refresh() async {
    try {
      final ms = await _fetch();
      // The backend refuses anything outside this range itself; a client
      // that trusted a wild value would show a wrong countdown for a day.
      if (ms < 50 || ms > 2000) throw RangeError.range(ms, 50, 2000);
      _value = Duration(milliseconds: ms);
      _fetchedAt = _now();
      _failedAt = null;
    } catch (_) {
      _failedAt = _now();
    }
    return _value ?? fallback;
  }

  static Future<int> _fetchFromApi() async {
    final response = await GetIt.I<MallowApiV2Client>().getSolanaSlotTime();
    return response.result.slotTimeMs;
  }
}
