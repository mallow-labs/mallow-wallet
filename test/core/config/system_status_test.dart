import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/config/system_status.dart';
import 'package:mallow_wallet/core/config/system_status_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/shared/widgets/system_status_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves each feed URL from a per-test script, so the failure modes that
/// matter (5xx, unreachable, unpublished) go through real Dio error handling
/// rather than a hand-rolled exception.
class _ScriptedAdapter implements HttpClientAdapter {
  final Map<String, ResponseBody Function()> routes = {};
  final Map<String, int> calls = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    calls[url] = (calls[url] ?? 0) + 1;
    final route = routes[url];
    if (route == null) throw StateError('unstubbed feed: $url');
    return route();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _body(Object? json, int status) => ResponseBody.fromString(
  json == null ? '' : jsonEncode(json),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// The whole point of the maintenance feed is *notice*: a mobile tester who
/// hits a planned outage with no warning reads it as the app being broken,
/// which is exactly the report this beta does not need. So these tests pin the
/// window semantics — when the warning starts, when it stops, and what a
/// dismissal does and does not suppress — rather than the rendering.
void main() {
  final start = DateTime(2026, 8, 8, 14);
  final window = MaintenanceWindow(
    startsAt: start,
    endsAt: start.add(const Duration(hours: 2)),
  );

  SystemBanner? resolve(
    DateTime now, {
    SystemStatus? status,
    String? dismissedMaintenance,
    String? dismissedNotice,
  }) => resolveSystemBanner(
    status: status ?? SystemStatus(maintenance: window),
    now: now,
    dismissedMaintenanceKey: dismissedMaintenance,
    dismissedNoticeKey: dismissedNotice,
  );

  group('maintenance window', () {
    test('warns from two days out, matching the webapp lead time', () {
      expect(resolve(start.subtract(const Duration(days: 3))), isNull);
      expect(
        resolve(start.subtract(const Duration(hours: 47))),
        isA<MaintenanceBanner>(),
      );
    });

    test('stops warning once the window has opened', () {
      // Past startsAt the announcement is no longer a warning — a banner that
      // still says "will be down" while the site is down is worse than none.
      expect(resolve(start.add(const Duration(minutes: 1))), isNull);
    });

    test(
      'a dismissal is scoped to the window, not to maintenance in general',
      () {
        final now = start.subtract(const Duration(hours: 1));
        expect(resolve(now, dismissedMaintenance: window.dismissKey), isNull);
        // Next week's window has a different startsAt, so it shows again.
        expect(
          resolve(now, dismissedMaintenance: '2026-01-01T00:00:00.000'),
          isA<MaintenanceBanner>(),
        );
      },
    );

    test('outranks an operator notice — only one banner ever shows', () {
      final banner = resolve(
        start.subtract(const Duration(hours: 1)),
        status: SystemStatus(
          maintenance: window,
          notice: const OperatorNotice(id: 7, message: 'hello'),
        ),
      );
      expect(banner, isA<MaintenanceBanner>());
    });
  });

  group('operator notice', () {
    const notice = OperatorNotice(id: 7, message: 'Withdrawals are delayed.');

    test('shows immediately — it carries no start time', () {
      expect(
        resolve(DateTime(2026), status: const SystemStatus(notice: notice)),
        isA<NoticeBanner>(),
      );
    });

    test('stops at endsAt', () {
      final expiring = OperatorNotice(
        id: 7,
        message: 'x',
        endsAt: DateTime(2026, 8),
      );
      expect(
        resolve(DateTime(2026, 8, 2), status: SystemStatus(notice: expiring)),
        isNull,
      );
    });

    test('a bumped id re-shows a notice the user dismissed', () {
      expect(
        resolve(
          DateTime(2026),
          status: const SystemStatus(notice: notice),
          dismissedNotice: '7',
        ),
        isNull,
      );
      expect(
        resolve(
          DateTime(2026),
          status: const SystemStatus(notice: notice),
          dismissedNotice: '6',
        ),
        isA<NoticeBanner>(),
      );
    });
  });

  group('parsing', () {
    test('drops a half-specified window rather than rendering a hole', () {
      expect(
        MaintenanceWindow.fromJson({
          'maintenance': {'startsAt': '2026-08-08T14:00:00Z'},
        }),
        isNull,
      );
    });

    test('drops a notice with no message', () {
      expect(OperatorNotice.fromJson({'id': 1, 'message': '  '}), isNull);
    });

    test('splits markdown links out of the notice body', () {
      expect(parseNoticeSpans('See [status](https://s.io) for more.'), [
        const NoticeSpan('See '),
        const NoticeSpan('status', 'https://s.io'),
        const NoticeSpan(' for more.'),
      ]);
    });

    test('leaves non-link markup as literal text', () {
      expect(parseNoticeSpans('**bold** [x]'), [
        const NoticeSpan('**bold** [x]'),
      ]);
    });
  });

  group('copy', () {
    test('rounds the outage to hours, which is how users plan', () {
      expect(maintenanceDurationText(window), '2 hours');
      expect(
        maintenanceDurationText(
          MaintenanceWindow(
            startsAt: start,
            endsAt: start.add(const Duration(hours: 1)),
          ),
        ),
        '1 hour',
      );
      expect(
        maintenanceDurationText(
          MaintenanceWindow(
            startsAt: start,
            endsAt: start.add(const Duration(minutes: 10)),
          ),
        ),
        'a short maintenance period',
      );
    });

    test('names the day, the time and the duration', () {
      expect(
        maintenanceBannerText(window),
        'mallow will be down for maintenance on Sat, Aug 8 at 2:00 PM for '
        '2 hours.',
      );
    });
  });

  // The CDN is least likely to answer during the very outage it is announcing,
  // so a failed fetch must hold the last-good value instead of overwriting it
  // with the empty parse — the same "hold the line" rule RemoteConfigService
  // follows. Before this, one 503 cleared a live maintenance banner for a full
  // TTL per attempt.
  group('fetch failure handling', () {
    late _ScriptedAdapter adapter;
    late SystemStatusService service;
    late DateTime clock;

    final windowJson = {
      'maintenance': {
        'startsAt': start.toIso8601String(),
        'endsAt': start.add(const Duration(hours: 2)).toIso8601String(),
      },
    };

    setUp(() async {
      // The feed URLs are derived from the asset CDN, so without one they are
      // both the empty string and the route map collapses onto a single key.
      Config.debugOverrides['ASSET_CDN_BASE_URL'] = 'https://cdn.example.com';
      addTearDown(Config.debugOverrides.clear);
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      clock = start.subtract(const Duration(hours: 1));
      adapter = _ScriptedAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      service = SystemStatusService.withSeams(
        await PreferencesService.create(),
        dio: dio,
        now: () => clock,
      );
      adapter.routes[kNoticeFeedUrl] = () => _body(<String, dynamic>{}, 200);
    });

    /// Land a live maintenance window, then move past the 5-minute TTL.
    Future<void> announceThenAge() async {
      adapter.routes[kStatusFeedUrl] = () => _body(windowJson, 200);
      await service.refreshIfStale();
      expect(service.banner.value, isA<MaintenanceBanner>());
      clock = clock.add(const Duration(minutes: 10));
    }

    test('a 503 leaves the live maintenance window in place', () async {
      await announceThenAge();
      adapter.routes[kStatusFeedUrl] = () => _body(null, 503);

      await service.refreshIfStale();

      expect(service.status.maintenance, isNotNull);
      expect(service.banner.value, isA<MaintenanceBanner>());
    });

    test('an unreachable feed leaves it in place too', () async {
      await announceThenAge();
      adapter.routes[kStatusFeedUrl] = () => throw const _TransportFailure();

      await service.refreshIfStale();

      expect(service.banner.value, isA<MaintenanceBanner>());
    });

    // The other half: a 404 is the CDN answering, and it is how an operator
    // unpublishes. Holding the line on that would pin a stale banner until the
    // next cold start.
    test('a 404 is an answer, so an unpublished feed does clear it', () async {
      await announceThenAge();
      adapter.routes[kStatusFeedUrl] = () => _body(null, 404);

      await service.refreshIfStale();

      expect(service.status.maintenance, isNull);
      expect(service.banner.value, isNull);
    });

    test('a failed round does not start the TTL, so it retries', () async {
      adapter.routes[kStatusFeedUrl] = () => _body(null, 503);
      await service.refreshIfStale();
      // Well inside the 5-minute TTL: a stamped TTL would skip this entirely.
      clock = clock.add(const Duration(seconds: 30));
      await service.refreshIfStale();

      expect(adapter.calls[kStatusFeedUrl], 2);
    });
  });

  // An unset ASSET_CDN_BASE_URL is the documented "off" switch, and the default
  // for a build with no feed of its own. Off has to mean *silent*: the empty
  // URL used to be fetched anyway, and because only a fully successful round
  // stamps the TTL, the 5-minute throttle never engaged — so every launch and
  // every foreground paid two doomed requests and two error logs, forever.
  group('no asset CDN configured', () {
    late _ScriptedAdapter adapter;
    late SystemStatusService service;
    late List<String?> logs;
    late DateTime clock;

    setUp(() async {
      Config.debugOverrides['ASSET_CDN_BASE_URL'] = '';
      addTearDown(Config.debugOverrides.clear);
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      // The failure log is the symptom users' logs actually show, so capture it
      // rather than infer it: the adapter alone can't see an attempt that dies
      // before the transport.
      final previousDebugPrint = debugPrint;
      logs = <String?>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message);
      };
      addTearDown(() => debugPrint = previousDebugPrint);
      clock = start;
      adapter = _ScriptedAdapter();
      service = SystemStatusService.withSeams(
        await PreferencesService.create(),
        dio: Dio()..httpClientAdapter = adapter,
        now: () => clock,
      );
    });

    test('the launch fetch is skipped, not attempted and failed', () async {
      service.start();
      // Joins whatever `start` put in flight, so an attempt it began is
      // finished — and counted — before we assert.
      await service.refreshIfStale();

      expect(adapter.calls, isEmpty);
      expect(logs, isEmpty);
      expect(service.banner.value, isNull);
    });

    test('every later foreground stays silent too', () async {
      for (var i = 0; i < 3; i++) {
        await service.refreshIfStale();
        clock = clock.add(const Duration(minutes: 10));
      }

      expect(adapter.calls, isEmpty);
      expect(logs, isEmpty);
    });
  });
}

/// A transport failure with no response at all — the case a status code can't
/// describe. [SystemStatusService] must read it as "the CDN did not answer".
class _TransportFailure implements Exception {
  const _TransportFailure();
}
