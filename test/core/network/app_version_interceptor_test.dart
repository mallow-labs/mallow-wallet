import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/app_version_interceptor.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The channel `PackageInfo.fromPlatform()` talks to. Counting calls on it is
/// the only way to see the platform round trips the interceptor is supposed to
/// collapse — `PackageInfo` itself hides them behind a static cache.
const MethodChannel _packageInfoChannel = MethodChannel(
  'dev.fluttercommunity.plus/package_info',
);

const Map<String, dynamic> _platformPackageInfo = <String, dynamic>{
  'appName': 'mallow',
  'packageName': 'com.mallow.wallet',
  'version': '0.10.0',
  'buildNumber': '13',
  'buildSignature': '',
};

/// Captures the outgoing request so the test can assert on the headers the
/// interceptor attached, without hitting the network.
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode({'ok': true}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_CapturingAdapter adapter) => Dio()
  ..httpClientAdapter = adapter
  ..interceptors.add(
    AppVersionInterceptor(mallowHosts: const {'api.example.com'}),
  );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The two platform-round-trip tests below must run before anything resolves
  // the version, because `PackageInfo` memoises the result in a process-wide
  // static (`setMockInitialValues` populates that same static). If they are
  // reordered the channel is never reached and the call counts read 0 — the
  // expectations fail loudly rather than passing vacuously.
  group('platform lookup', () {
    late int calls;

    void mockChannel(Future<Map<String, dynamic>> Function() respond) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_packageInfoChannel, (call) async {
            calls++;
            return respond();
          });
    }

    setUp(() => calls = 0);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_packageInfoChannel, null);
    });

    test('retries after a failed lookup instead of caching the error', () async {
      // Sharing the future must not turn one transient platform failure into a
      // permanently poisoned cache — that would strip the header from every
      // mallow request for the rest of the process. The request itself must
      // still go out (unheadered): an error escaping `onRequest` leaves Dio's
      // handler uncalled, which hangs the request forever rather than failing.
      mockChannel(() async => throw PlatformException(code: 'unavailable'));

      final adapter = _CapturingAdapter();
      final dio = _dioWith(adapter);
      await dio.get<dynamic>('https://api.example.com/v2/portfolio');
      expect(adapter.lastRequest!.headers.containsKey('App-Version'), isFalse);

      await dio.get<dynamic>('https://api.example.com/v2/portfolio');

      expect(calls, 2);
    });

    test('resolves once for a burst of parallel cold-start requests', () async {
      // Portfolio, offers, activity and home all fire before any of them
      // returns. Memoising only the resolved *value* would leave every one of
      // them looking at a null cache and starting its own platform lookup, so
      // launch would pay four MethodChannel round trips on the hot path.
      final gate = Completer<void>();
      mockChannel(() async {
        await gate.future;
        return _platformPackageInfo;
      });

      final adapter = _CapturingAdapter();
      final dio = _dioWith(adapter);
      final inFlight = [
        dio.get<dynamic>('https://api.example.com/v2/portfolio'),
        dio.get<dynamic>('https://api.example.com/v2/offers/inbox'),
        dio.get<dynamic>('https://api.example.com/v2/activity'),
        dio.get<dynamic>('https://api.example.com/v2/home'),
      ];
      // Let all four reach the interceptor while the lookup is still pending.
      await pumpEventQueue();
      gate.complete();
      await Future.wait(inFlight);

      expect(calls, 1);
      expect(adapter.lastRequest!.headers['App-Version'], '0.10.0');
    });
  });

  group('header attachment', () {
    late _CapturingAdapter adapter;
    late Dio dio;

    setUp(() {
      // The interceptor must send the plain semver (no `+build` suffix) so the
      // backend can parse it as a version — mirror a realistic pubspec value.
      PackageInfo.setMockInitialValues(
        appName: 'mallow',
        packageName: 'com.mallow.wallet',
        version: '0.10.0',
        buildNumber: '13',
        buildSignature: '',
      );
      adapter = _CapturingAdapter();
      dio = _dioWith(adapter);
    });

    test(
      'attaches the App-Version header from PackageInfo on every request',
      () async {
        await dio.get<dynamic>('https://api.example.com/v2/portfolio');

        expect(adapter.lastRequest!.headers['App-Version'], '0.10.0');
      },
    );

    test('does not attach the header to non-mallow hosts', () async {
      // The shared Dio also carries third-party traffic (CDN reads,
      // request-level URL overrides). Leaking a custom header to a CORS-strict
      // third party can break those requests, so anything outside
      // [mallowHosts] must be untouched.
      await dio.get<dynamic>('https://cdn.mallow-thirdparty.example/asset.png');

      expect(adapter.lastRequest!.headers.containsKey('App-Version'), isFalse);
    });

    test(
      'the header carries the semver only, never the +build suffix',
      () async {
        await dio.get<dynamic>('https://api.example.com/v1/explore');

        // A `0.10.0+13` value would fail server-side semver parsing (the nodejs
        // version gate does `compareVersions(...)`), so the build number must be
        // stripped.
        expect(
          adapter.lastRequest!.headers['App-Version'],
          isNot(contains('+')),
        );
        expect(adapter.lastRequest!.headers['App-Version'], '0.10.0');
      },
    );
  });
}
