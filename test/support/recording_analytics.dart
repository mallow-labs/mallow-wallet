import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_events.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingDio extends Fake implements Dio {
  _RecordingDio(this._sink);

  final List<Map<String, dynamic>> _sink;

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    final event = (data! as Map<String, dynamic>)['event'] as Map;
    _sink.add({
      'event': event['event'],
      ...(event['properties'] as Map).cast<String, dynamic>(),
    });
    return Response<T>(requestOptions: RequestOptions(path: path));
  }
}

class _MemorySecureStorage extends Fake implements FlutterSecureStorage {
  final _values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) _values[key] = value;
  }
}

/// A real [AnalyticsService], registered in [sl], that records what it would
/// have sent instead of posting it — for tests asserting that a flow reports
/// to the analytics transaction ledger.
///
/// Call [install] in `setUp` and [uninstall] in `tearDown`. Events are
/// fire-and-forget, so let the event queue drain before reading [events].
class RecordingAnalytics {
  RecordingAnalytics._(this.events);

  /// Each sent event as one flat map: `event` plus its properties.
  final List<Map<String, dynamic>> events;

  /// `Transaction Submitted` events only.
  List<Map<String, dynamic>> get submitted => [
    for (final e in events)
      if (e['event'] == AnalyticsEvent.transactionSubmitted) e,
  ];

  static Future<RecordingAnalytics> install({bool optOut = false}) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({'pref_analytics_opt_out': optOut});
    final events = <Map<String, dynamic>>[];
    final service = AnalyticsService(
      _RecordingDio(events),
      await PreferencesService.create(),
      _MemorySecureStorage(),
    );
    await service.init();
    if (sl.isRegistered<AnalyticsService>()) {
      await sl.unregister<AnalyticsService>();
    }
    sl.registerSingleton<AnalyticsService>(service);
    return RecordingAnalytics._(events);
  }

  static Future<void> uninstall() async {
    if (sl.isRegistered<AnalyticsService>()) {
      await sl.unregister<AnalyticsService>();
    }
  }
}
