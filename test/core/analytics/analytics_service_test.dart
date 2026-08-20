import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_events.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockDio extends Mock implements Dio {}

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// These tests encode the taxonomy's non-negotiable guarantees: analytics MUST
/// be silent when the user opts out (privacy), every event MUST carry the
/// global context needed to count unique users + OS, the device id MUST be
/// stable (unique-user key), and the offline queue MUST stay bounded.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockDio dio;
  late _MockSecureStorage secureStorage;
  late Map<String, String> secureStore;
  late List<Map<String, dynamic>> posted;

  setUpAll(() {
    registerFallbackValue(Options());
  });

  setUp(() async {
    // Config.analyticsEnabled defaults to true with no --dart-define, which is
    // the state this group exercises.
    dio = _MockDio();
    secureStorage = _MockSecureStorage();
    secureStore = {};
    posted = [];

    when(() => secureStorage.read(key: any(named: 'key'))).thenAnswer(
      (inv) async => secureStore[inv.namedArguments[#key] as String],
    );
    when(
      () => secureStorage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((inv) async {
      secureStore[inv.namedArguments[#key] as String] =
          inv.namedArguments[#value] as String;
    });

    when(
      () => dio.post<void>(
        any(),
        data: any(named: 'data'),
        options: any(named: 'options'),
      ),
    ).thenAnswer((inv) async {
      posted.add(
        inv.positionalArguments.isNotEmpty
            ? (inv.namedArguments[#data] as Map<String, dynamic>)
            : const {},
      );
      return Response<void>(
        requestOptions: RequestOptions(path: '/v1/analytics'),
        statusCode: 200,
      );
    });
  });

  Future<AnalyticsService> build({bool optOut = false}) async {
    SharedPreferences.setMockInitialValues({'pref_analytics_opt_out': optOut});
    final prefs = await PreferencesService.create();
    final service = AnalyticsService(dio, prefs, secureStorage);
    await service.init();
    return service;
  }

  Map<String, dynamic> propsOf(Map<String, dynamic> envelope) =>
      (envelope['event'] as Map<String, dynamic>)['properties']
          as Map<String, dynamic>;

  test('opted-out users send nothing', () async {
    final service = await build(optOut: true);
    await service.track(AnalyticsEvent.appOpened);
    expect(posted, isEmpty);
  });

  test(
    'an event carries the global context needed for unique-user + OS counts',
    () async {
      final service = await build();
      await service.track(
        AnalyticsEvent.swapCompleted,
        properties: {AnalyticsProp.usdValue: null},
        isOnchainTx: true,
      );

      expect(posted, hasLength(1));
      final envelope = posted.single;
      expect((envelope['event'] as Map)['event'], AnalyticsEvent.swapCompleted);
      final props = propsOf(envelope);
      // Identity / OS / session context every event must carry.
      expect(props[AnalyticsProp.platform], isNotNull);
      expect(props[AnalyticsProp.osVersion], isNotNull);
      expect(props[AnalyticsProp.sessionId], isNotNull);
      expect(props[AnalyticsProp.network], anyOf('mainnet', 'devnet'));
      expect(props['time'], isA<int>());
      expect(props[r'$insert_id'], isNotNull);
      // Conditional globals + null usd_value passthrough (not stripped).
      expect(props[AnalyticsProp.isOnchainTx], isTrue);
      expect(props.containsKey(AnalyticsProp.usdValue), isTrue);
      expect(props[AnalyticsProp.usdValue], isNull);
    },
  );

  test('device id is generated once and reused across restarts', () async {
    await build();
    final first = secureStore['mallow_analytics_device_id'];
    expect(first, isNotNull);

    // A fresh service instance over the same storage must reuse the id — it is
    // the unique-user key and must survive an app restart.
    final second = AnalyticsService(
      dio,
      await PreferencesService.create(),
      secureStorage,
    );
    await second.init();
    expect(secureStore['mallow_analytics_device_id'], first);
  });

  test('offline queue stays capped when the backend is unreachable', () async {
    when(
      () => dio.post<void>(
        any(),
        data: any(named: 'data'),
        options: any(named: 'options'),
      ),
    ).thenThrow(DioException(requestOptions: RequestOptions()));

    final service = await build();
    for (var i = 0; i < 520; i++) {
      await service.track(AnalyticsEvent.appOpened);
    }
    // Nothing left the device; queue is bounded at 500 (oldest-out).
    expect(posted, isEmpty);
    final raw = SharedPreferences.getInstance();
    final prefs = await raw;
    final json = prefs.getString('pref_analytics_queue')!;
    // 520 enqueued, capped at 500.
    expect(RegExp(r'"App Opened"').allMatches(json).length, 500);
  });

  group('transaction events', () {
    // The product question analytics exists to answer is "which transactions
    // did users send, and which on-chain tx was each one" — so the type and the
    // signature are not optional decoration, they are the event.
    test('carry the tx type and the signature', () async {
      final service = await build();
      await service.trackTransaction(
        AnalyticsEvent.purchaseCompleted,
        txType: TxType.buyArtwork,
        signature: 'sig-abc',
        properties: {AnalyticsProp.collectionId: 'coll-1'},
        entryPoint: EntryPoint.artworkDetail,
      );

      final props = propsOf(posted.single);
      expect(props[AnalyticsProp.txType], TxType.buyArtwork.wire);
      expect(props[AnalyticsProp.signature], 'sig-abc');
      // The transaction helper implies an on-chain row.
      expect(props[AnalyticsProp.isOnchainTx], isTrue);
      expect(props[AnalyticsProp.collectionId], 'coll-1');
      expect(props[AnalyticsProp.entryPoint], EntryPoint.artworkDetail.wire);
    });

    test(
      'a pre-broadcast failure keeps the type and reports no signature',
      () async {
        final service = await build();
        await service.trackTransaction(
          AnalyticsEvent.swapFailed,
          txType: TxType.swap,
          isOnchainTx: false,
          properties: {AnalyticsProp.reason: FailureReason.userRejected.wire},
        );

        final props = propsOf(posted.single);
        expect(props[AnalyticsProp.txType], TxType.swap.wire);
        // Present-but-null, not absent: "no tx landed" must be distinguishable
        // from "we forgot to record one".
        expect(props.containsKey(AnalyticsProp.signature), isTrue);
        expect(props[AnalyticsProp.signature], isNull);
        expect(props.containsKey(AnalyticsProp.isOnchainTx), isFalse);
      },
    );
  });

  group('Logged In throttle', () {
    // `/v0/login` runs on every cold start, wallet switch and session refresh.
    // Without the throttle those all count as logins, which is what made the
    // event useless — runs of identical events minutes apart.
    test('a second login inside the window sends nothing', () async {
      final service = await build();
      await service.trackLogin();
      await service.trackLogin();
      await service.trackLogin();

      expect(posted, hasLength(1));
      expect((posted.single['event'] as Map)['event'], AnalyticsEvent.loggedIn);
    });

    test('a login after the window sends again', () async {
      final service = await build();
      await service.trackLogin();

      // Age the persisted stamp past the throttle.
      final prefs = await PreferencesService.create();
      await prefs.setLastLoggedInTrackedAt(
        DateTime.now().subtract(
          AnalyticsService.loginThrottle + const Duration(minutes: 1),
        ),
      );
      await service.trackLogin();

      expect(posted, hasLength(2));
    });

    test('the throttle survives a restart', () async {
      final service = await build();
      await service.trackLogin();

      // A fresh service over the same prefs — the stamp is persisted precisely
      // so a force-quit-and-relaunch loop can't re-emit on every launch.
      final restarted = AnalyticsService(
        dio,
        await PreferencesService.create(),
        secureStorage,
      );
      await restarted.init();
      await restarted.trackLogin();

      expect(posted, hasLength(1));
    });
  });
}
