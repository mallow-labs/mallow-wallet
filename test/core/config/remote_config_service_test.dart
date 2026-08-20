import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockApiV2 extends Mock implements MallowApiV2Client {}

ApiResponse<MobileConfigResponse> _resp(List<Map<String, String>> disabled) {
  return ApiResponse(
    result: MobileConfigResponse.fromJson({
      'minimumVersion': null,
      'updateRequired': false,
      'updateMessage': null,
      'disabledFlows': disabled,
    }),
  );
}

const _ethSendKilled = [
  {'chain': 'ethereum', 'flow': 'native-send', 'message': 'ETH sends paused'},
];

/// Lets pending fetch futures complete before we assert.
Future<void> _settle() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
}

void main() {
  late _MockApiV2 api;
  late RemoteConfigService service;

  /// The service's TTL and failure-cooldown windows run off an injected
  /// monotonic clock (same seam as `MarketplaceConfigService`). Tests advance
  /// this instead of sleeping — the real windows are 5 minutes and 30 seconds.
  late Duration fakeElapsed;

  /// The production failure cooldown; kept local so these tests fail loudly if
  /// the service's `_retryGap` is ever shortened without revisiting them.
  const retryGap = Duration(seconds: 30);

  RemoteConfigService serviceWith(Duration ttl) =>
      RemoteConfigService.withTtl(api, ttl, elapsed: () => fakeElapsed);

  setUp(() {
    api = _MockApiV2();
    fakeElapsed = Duration.zero;
  });

  tearDown(() {
    service.dispose();
  });

  group('cold start', () {
    test('is permissive before any fetch', () {
      service = RemoteConfigService(api);

      // Fail-open: until the backend says otherwise, nothing is killed. A
      // tap in the first second of launch must not be blocked.
      expect(service.config.value, RemoteConfig.permissive);
      verifyNever(() => api.getMobileConfig());
    });

    test('stays permissive when the very first fetch fails', () async {
      when(() => api.getMobileConfig()).thenThrow(Exception('backend down'));
      service = RemoteConfigService(api);

      service.start();
      await _settle();

      // A backend outage must not brick the app — the accepted tradeoff of
      // fail-open is that a killed flow returns if we never heard about it.
      expect(service.config.value, RemoteConfig.permissive);
      expect(
        service.config.value.isFlowAvailable(
          Chain.ethereum,
          AppFlow.nativeSend,
        ),
        isTrue,
      );
    });

    test('publishes the fetched config and start() is idempotent', () async {
      when(
        () => api.getMobileConfig(),
      ).thenAnswer((_) async => _resp(_ethSendKilled));
      service = RemoteConfigService(api);

      service.start();
      service.start();
      service.start();
      await _settle();

      expect(
        service.config.value.disabledMessage(
          Chain.ethereum,
          AppFlow.nativeSend,
        ),
        'ETH sends paused',
      );
      verify(() => api.getMobileConfig()).called(1);
    });
  });

  group('failure after a success', () {
    test('retains the last-known-good config', () async {
      var calls = 0;
      when(() => api.getMobileConfig()).thenAnswer((_) async {
        calls++;
        if (calls == 1) return _resp(_ethSendKilled);
        throw Exception('backend flapping');
      });
      service = serviceWith(Duration.zero);

      service.start();
      await _settle();
      expect(
        service.config.value.disabledMessage(
          Chain.ethereum,
          AppFlow.nativeSend,
        ),
        'ETH sends paused',
      );

      fakeElapsed += retryGap;
      await service.refreshIfStale();

      // WHY this matters more than the happy path: resetting to permissive on
      // a failed refresh would let a flapping backend re-open a flow we just
      // closed during an incident. The kill has to survive the outage.
      expect(calls, 2);
      expect(
        service.config.value.disabledMessage(
          Chain.ethereum,
          AppFlow.nativeSend,
        ),
        'ETH sends paused',
      );
    });

    test('retries once the cooldown elapses, without waiting out the '
        'TTL', () async {
      var calls = 0;
      when(() => api.getMobileConfig()).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw Exception('transient');
        return _resp(_ethSendKilled);
      });
      // A long TTL: only an untouched _lastSuccessAt can let the retry through.
      service = serviceWith(const Duration(hours: 1));

      service.start();
      await _settle();
      expect(calls, 1);
      expect(service.config.value, RemoteConfig.permissive);

      // A failed attempt must not start the staleness clock, or one dropped
      // request on launch would blind the app for a full TTL — the retry has
      // to get through on the cooldown, not on the TTL.
      fakeElapsed += retryGap;
      await service.refreshIfStale();

      expect(calls, 2);
      expect(
        service.config.value.disabledMessage(
          Chain.ethereum,
          AppFlow.nativeSend,
        ),
        'ETH sends paused',
      );
    });
  });

  // Before this, refreshIfStale consulted only _lastSuccessAt,
  // which a failed fetch deliberately leaves untouched — so during a backend
  // outage every trigger (launch, foreground, each gated tap and screen entry)
  // fired another doomed round trip. Fail-open is the design's centrepiece, so
  // the outage path is the *expected* path, and it must not become a per-device
  // retry storm against a backend that is trying to come back up.
  group('failure cooldown', () {
    test('a failed fetch blocks re-fetches inside the cooldown', () async {
      when(() => api.getMobileConfig()).thenThrow(Exception('backend down'));
      // TTL zero: nothing but the cooldown can hold these triggers back.
      service = serviceWith(Duration.zero);

      service.start();
      await _settle();
      verify(() => api.getMobileConfig()).called(1);

      // Stand in for a user navigating during the outage: several triggers,
      // all inside the 30s window, right up to its final instant.
      await service.refreshIfStale();
      fakeElapsed += const Duration(seconds: 5);
      await service.refreshIfStale();
      fakeElapsed = retryGap - const Duration(milliseconds: 1);
      await service.refreshIfStale();

      verifyNever(() => api.getMobileConfig());
    });

    test('allows a re-fetch as soon as the cooldown expires', () async {
      when(() => api.getMobileConfig()).thenThrow(Exception('backend down'));
      service = serviceWith(Duration.zero);

      service.start();
      await _settle();
      verify(() => api.getMobileConfig()).called(1);

      // The cap is a delay, not a circuit breaker: an outage must still be
      // polled (~2 req/min/device) so the kill switch works again the moment
      // the backend recovers.
      fakeElapsed = retryGap;
      await service.refreshIfStale();

      verify(() => api.getMobileConfig()).called(1);
    });

    test(
      'a success is still gated by the full TTL, not the cooldown',
      () async {
        when(
          () => api.getMobileConfig(),
        ).thenAnswer((_) async => _resp(const []));
        service = serviceWith(const Duration(minutes: 5));

        service.start();
        await _settle();
        verify(() => api.getMobileConfig()).called(1);

        // The cooldown is a floor on the request rate, never a ceiling on
        // freshness: past 30s the 5-minute TTL still holds, and only past the
        // TTL does a trigger fetch.
        fakeElapsed = const Duration(seconds: 31);
        await service.refreshIfStale();
        fakeElapsed = const Duration(minutes: 4, seconds: 59);
        await service.refreshIfStale();
        verifyNever(() => api.getMobileConfig());

        fakeElapsed = const Duration(minutes: 5);
        await service.refreshIfStale();
        verify(() => api.getMobileConfig()).called(1);
      },
    );
  });

  group('refreshIfStale', () {
    test('no-ops while the last success is inside the TTL', () async {
      when(
        () => api.getMobileConfig(),
      ).thenAnswer((_) async => _resp(const []));
      service = serviceWith(const Duration(hours: 1));

      service.start();
      await _settle();

      // Foreground/flow-entry triggers are frequent; without the TTL guard a
      // few tab flips would hammer the endpoint. Past the failure cooldown, so
      // it is the TTL doing the work here and not F6's 30s window.
      fakeElapsed += retryGap;
      await service.refreshIfStale();
      await service.refreshIfStale();

      verify(() => api.getMobileConfig()).called(1);
    });

    test('fetches once the last success is older than the TTL', () async {
      when(
        () => api.getMobileConfig(),
      ).thenAnswer((_) async => _resp(const []));
      service = serviceWith(const Duration(minutes: 5));

      service.start();
      await _settle();

      fakeElapsed += const Duration(minutes: 6);
      await service.refreshIfStale();

      verify(() => api.getMobileConfig()).called(2);
    });

    test('a trigger joins the in-flight request instead of stacking a '
        'second', () async {
      final gate = Completer<ApiResponse<MobileConfigResponse>>();
      when(() => api.getMobileConfig()).thenAnswer((_) => gate.future);
      service = serviceWith(Duration.zero);

      // A launch fetch still hanging when a flow-entry gate triggers past the
      // cooldown: neither the TTL (no success yet) nor the cooldown holds the
      // second trigger back, so only the in-flight dedupe can stop it from
      // stacking a round trip on a backend that is already slow.
      service.start();
      fakeElapsed += retryGap;
      final joined = service.refreshIfStale();
      gate.complete(_resp(_ethSendKilled));
      await joined;

      verify(() => api.getMobileConfig()).called(1);
      expect(
        service.config.value.disabledMessage(
          Chain.ethereum,
          AppFlow.nativeSend,
        ),
        'ETH sends paused',
      );
    });
  });
}
