// The fake binding and the `options:` argument are SDK-internal seams.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports, depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/observability/sentry_privacy_transport.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/sentry_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry/src/platform/mock_platform.dart';
import 'package:sentry/src/platform/platform.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sentry_flutter/src/native/native_app_start.dart';
import 'package:sentry_flutter/src/native/sentry_native_binding.dart';
import 'package:sentry_flutter/src/replay/replay_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Runs the real [SentryFlutter.init] with the production options callback.
///
/// Only the platform edge is replaced: a fake native binding stands in for the
/// iOS/Android SDK, so the SDK selects its production `FileSystemTransport`
/// and every envelope it would hand to the native layer lands in
/// [_FakeNative.envelopes]. No platform channel or network request is made.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Synthetic values only; the DSN host cannot resolve.
  const dsn = 'https://public@o0.ingest.example.invalid/1';
  final hexSecret = List.filled(64, 'c').join();
  const shortSecret = 'short synthetic sensitive input';
  final phrase = [...List.filled(11, 'abandon'), 'about'];

  late _FakeNative native;
  late List<SentryFlutterOptions> initialized;
  late FlutterExceptionHandler? originalFlutterOnError;

  Future<void> setOptOut(bool optOut) async {
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
    await sl<PreferencesService>().setAnalyticsOptOut(optOut);
  }

  setUp(() async {
    originalFlutterOnError = FlutterError.onError;
    await sl.reset();
    PackageInfo.setMockInitialValues(
      appName: 'wallet',
      packageName: 'test.wallet',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    Config.debugOverrides['SENTRY_DSN'] = dsn;
    native = _FakeNative();
    initialized = [];
    SentryService.debugSdkInit = (configure, {appRunner}) {
      final options = SentryFlutterOptions(
        // Not creating a binding lets the fake below stand in for it.
        platform: MockPlatform(
          operatingSystem: OperatingSystem.android,
          supportsNativeIntegration: false,
        ),
      );
      initialized.add(options);
      SentryFlutter.native = native;
      return SentryFlutter.init(
        configure,
        appRunner: appRunner,
        options: options,
      );
    };
  });

  tearDown(() async {
    // The production opt-out path closes the hub and resets the service.
    await setOptOut(true);
    await SentryService.applyAnalyticsPreference();
    await Sentry.close();
    SentryFlutter.native = null;
    SentryService.debugSdkInit = SentryFlutter.init;
    Config.debugOverrides.clear();
    FlutterError.onError = originalFlutterOnError;
    await sl.reset();
  });

  /// Produces one error event, one message event and one transaction, each
  /// carrying synthetic secrets through every channel the SDK attaches after
  /// beforeSend: scope contexts, tags, attachments, spans and trace baggage.
  Future<void> emitEverything() async {
    await Sentry.configureScope((scope) async {
      await scope.setContexts('late', {'privateKey': shortSecret});
      await scope.setTag('detail', hexSecret);
      await scope.setUser(SentryUser(email: 'person@example.invalid'));
      scope.addAttachment(
        SentryAttachment.fromIntList(
          utf8.encode('synthetic attachment'),
          'secret.txt',
          addToTransactions: true,
        ),
      );
    });
    await Sentry.addBreadcrumb(Breadcrumb(message: 'crumb $hexSecret'));
    // Sampled explicitly: the production rate is 0.1 in this environment.
    final tracer = Sentry.startTransactionWithContext(
      SentryTransactionContext(
        'route $hexSecret',
        'ui.load',
        samplingDecision: SentryTracesSamplingDecision(true),
      ),
      bindToScope: true,
    );
    tracer.setData('privateKey', shortSecret);
    final child = tracer.startChild('sign', description: hexSecret);
    child.setData('words', phrase);
    child.setData('object', _UnsafeObject());
    await child.finish();
    await SentryService.captureException(
      StateError('failure $hexSecret'),
      stackTrace: StackTrace.current,
      message: 'context $hexSecret',
      extras: {'note': phrase.join(' '), 'tokenMint': 'kept-out'},
    );
    await SentryService.captureMessage(
      'message $hexSecret',
      extras: {'authority': shortSecret},
    );
    await tracer.finish();
  }

  void expectClean(List<_Envelope> envelopes) {
    for (final envelope in envelopes) {
      expect(envelope.header.containsKey('trace'), isFalse);
      for (final item in envelope.items) {
        expect(const {
          'event',
          'transaction',
          'client_report',
        }, contains(item.type));
      }
      final wire = envelope.raw;
      expect(wire, isNot(contains(hexSecret)));
      expect(wire, isNot(contains(shortSecret)));
      expect(wire, isNot(contains('abandon')));
      expect(wire, isNot(contains('synthetic attachment')));
      expect(wire, isNot(contains('person@example.invalid')));
      expect(wire, isNot(contains('kept-out')));
    }
  }

  test('boot init installs the privacy wrapper outermost on the native '
      'delivery path and filters every envelope', () async {
    await setOptOut(false);
    var ranApp = false;
    await SentryService.init(appRunner: () => ranApp = true);

    expect(ranApp, isTrue);
    expect(SentryService.isEnabled, isTrue);
    expect(initialized, hasLength(1));
    expect(native.initCount, 1);
    final options = initialized.single;
    expect(options.transport, isA<SentryPrivacyTransport>());
    expect(
      options.integrations.whereType<SentryPrivacyIntegration>(),
      hasLength(1),
    );

    await emitEverything();

    final envelopes = native.envelopes.map(_Envelope.parse).toList();
    final types = [
      for (final e in envelopes)
        for (final i in e.items) i.type,
    ];
    expect(types.where((t) => t == 'event'), hasLength(2));
    expect(types.where((t) => t == 'transaction'), hasLength(1));
    expectClean(envelopes);

    final error = envelopes
        .expand((e) => e.items)
        .map((i) => i.json)
        .firstWhere((j) => j['exception'] != null);
    final exception = (error['exception'] as Map)['values'] as List;
    expect((exception.single as Map)['type'], 'StateError');
    expect(
      ((exception.single as Map)['stacktrace'] as Map)['frames'],
      isNotEmpty,
    );

    final transaction = envelopes
        .expand((e) => e.items)
        .firstWhere((i) => i.type == 'transaction')
        .json;
    expect(transaction['spans'], hasLength(1));
    expect(transaction['start_timestamp'], isNotNull);
    expect(transaction['timestamp'], isNotNull);
  });

  test('native receives the trace ids and nothing from the scope', () async {
    await setOptOut(false);
    await SentryService.init(appRunner: () {});

    // Trace sync: the Dart propagation context was pushed to native at init.
    expect(native.traces, isNotEmpty);
    final syncedTrace = native.traces.last.traceId.toString();

    await emitEverything();

    // Scope sync stays off: contexts, tags, user and breadcrumbs set above
    // never reach the native scope, which native crash reports serialize
    // without passing through the Dart filters.
    expect(native.scopeCalls, isEmpty);

    // The delivered transaction carries the same trace id, so a native crash
    // and the Dart transaction it interrupted correlate.
    final transaction = native.envelopes
        .map(_Envelope.parse)
        .expand((e) => e.items)
        .firstWhere((i) => i.type == 'transaction')
        .json;
    final trace = (transaction['contexts'] as Map)['trace'] as Map;
    expect(trace['trace_id'], syncedTrace);
  });

  test('opt-out at boot never starts the SDK, even with a DSN', () async {
    await setOptOut(true);
    var ranApp = false;
    await SentryService.init(appRunner: () => ranApp = true);

    expect(ranApp, isTrue);
    expect(initialized, isEmpty);
    expect(native.initCount, 0);
    expect(SentryService.isEnabled, isFalse);
  });

  test('repeated opt-out and opt-in closes, re-initialises and keeps '
      'filtering on every generation', () async {
    await setOptOut(false);
    await SentryService.init(appRunner: () {});

    for (var cycle = 1; cycle <= 2; cycle++) {
      await setOptOut(true);
      await SentryService.applyAnalyticsPreference();
      expect(SentryService.isEnabled, isFalse);
      expect(Sentry.isEnabled, isFalse);
      expect(native.closeCount, cycle);

      // Nothing leaves the device while opted out.
      final before = native.envelopes.length;
      await SentryService.captureException(StateError('off $hexSecret'));
      await SentryService.captureMessage('off');
      expect(native.envelopes, hasLength(before));

      await setOptOut(false);
      await SentryService.applyAnalyticsPreference();
      expect(SentryService.isEnabled, isTrue);
      expect(initialized, hasLength(cycle + 1));
      expect(native.initCount, cycle + 1);

      // Each generation gets fresh options with exactly one wrapper, in the
      // live delivery path rather than on a discarded options object.
      final options = initialized.last;
      expect(Sentry.currentHub.options, same(options));
      expect(options.transport, isA<SentryPrivacyTransport>());
      expect(
        options.integrations.whereType<SentryPrivacyIntegration>(),
        hasLength(1),
      );
      expect(options.enableScopeSync, isFalse);

      native.envelopes.clear();
      native.scopeCalls.clear();
      await emitEverything();
      final envelopes = native.envelopes.map(_Envelope.parse).toList();
      expect(envelopes, isNotEmpty);
      expectClean(envelopes);
      expect(native.scopeCalls, isEmpty);
    }
  });
}

class _Item {
  _Item(this.type, this.json);
  final String type;
  final Map<String, dynamic> json;
}

/// Parses the newline-delimited envelope the SDK writes for the native layer.
class _Envelope {
  _Envelope(this.raw, this.header, this.items);

  factory _Envelope.parse(Uint8List bytes) {
    final raw = utf8.decode(bytes);
    final lines = const LineSplitter().convert(raw);
    final header = jsonDecode(lines.first) as Map<String, dynamic>;
    final items = <_Item>[];
    for (var i = 1; i + 1 < lines.length; i += 2) {
      final itemHeader = jsonDecode(lines[i]) as Map<String, dynamic>;
      items.add(
        _Item(
          itemHeader['type'] as String,
          jsonDecode(lines[i + 1]) as Map<String, dynamic>,
        ),
      );
    }
    return _Envelope(raw, header, items);
  }

  final String raw;
  final Map<String, dynamic> header;
  final List<_Item> items;
}

class _TraceCall {
  _TraceCall(this.traceId, this.spanId);
  final SentryId traceId;
  final SpanId spanId;
}

/// Stands in for the iOS/Android SDK. Records what Dart hands it.
class _FakeNative implements SentryNativeBinding {
  final envelopes = <Uint8List>[];
  final traces = <_TraceCall>[];
  final scopeCalls = <String>[];
  var initCount = 0;
  var closeCount = 0;

  @override
  FutureOr<void> init(Hub hub) => initCount++;

  @override
  FutureOr<void> close() => closeCount++;

  @override
  bool get supportsCaptureEnvelope => true;

  @override
  FutureOr<void> captureEnvelope(
    Uint8List envelopeData,
    bool containsUnhandledException,
  ) {
    envelopes.add(envelopeData);
  }

  @override
  FutureOr<void> captureStructuredEnvelope(SentryEnvelope envelope) =>
      throw UnsupportedError('not used on mobile');

  @override
  bool get supportsTraceSync => true;

  @override
  FutureOr<void> setTrace(SentryId traceId, SpanId spanId) {
    traces.add(_TraceCall(traceId, spanId));
  }

  @override
  FutureOr<void> setUser(SentryUser? user) {
    scopeCalls.add('setUser');
  }

  @override
  FutureOr<void> addBreadcrumb(Breadcrumb breadcrumb) {
    scopeCalls.add('addBreadcrumb');
  }

  @override
  FutureOr<void> clearBreadcrumbs() {
    scopeCalls.add('clearBreadcrumbs');
  }

  @override
  FutureOr<void> setContexts(String key, dynamic value) {
    scopeCalls.add('setContexts');
  }

  @override
  FutureOr<void> removeContexts(String key) {
    scopeCalls.add('removeContexts');
  }

  @override
  FutureOr<void> setExtra(String key, dynamic value) {
    scopeCalls.add('setExtra');
  }

  @override
  FutureOr<void> removeExtra(String key) {
    scopeCalls.add('removeExtra');
  }

  @override
  FutureOr<void> setTag(String key, String value) {
    scopeCalls.add('setTag');
  }

  @override
  FutureOr<void> removeTag(String key) {
    scopeCalls.add('removeTag');
  }

  @override
  bool get supportsLoadContexts => false;

  @override
  FutureOr<Map<String, dynamic>?> loadContexts() => null;

  @override
  FutureOr<NativeAppStart?> fetchNativeAppStart() => null;

  @override
  int? startProfiler(SentryId traceId) => null;

  @override
  FutureOr<void> discardProfiler(SentryId traceId) {}

  @override
  FutureOr<int?> displayRefreshRate() => null;

  @override
  FutureOr<Map<String, dynamic>?> collectProfile(
    SentryId traceId,
    int startTimeNs,
    int endTimeNs,
  ) => null;

  @override
  FutureOr<List<DebugImage>?> loadDebugImages(SentryStackTrace stackTrace) =>
      null;

  @override
  FutureOr<void> pauseAppHangTracking() {}

  @override
  FutureOr<void> resumeAppHangTracking() {}

  @override
  FutureOr<void> nativeCrash() {}

  @override
  bool get supportsReplay => false;

  @override
  SentryId? get replayId => null;

  @override
  FutureOr<void> setReplayConfig(ReplayConfig config) {}

  @override
  FutureOr<SentryId> captureReplay() => const SentryId.empty();

  @override
  FutureOr<void> startSession({bool ignoreDuration = false}) {}

  @override
  FutureOr<Map<dynamic, dynamic>?> getSession() => null;

  @override
  FutureOr<void> updateSession({int? errors, String? status}) {}

  @override
  FutureOr<void> captureSession() {}
}

class _UnsafeObject {
  Object toJson() => throw StateError('must not serialize');
}
