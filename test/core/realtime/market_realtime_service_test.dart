import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/realtime/market_realtime_service.dart';
import 'package:mallow_wallet/core/realtime/models/market_invalidation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeChannel extends Fake implements WebSocketChannel {
  _FakeChannel();

  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  bool sinkClosed = false;

  // ignore: close_sinks — test double; _FakeSink holds no real resource.
  late final WebSocketSink _sink = _FakeSink(this);

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  int? get closeCode => sinkClosed ? 1000 : null;

  void serverPush(Map<String, dynamic> message) =>
      _incoming.add(jsonEncode(message));

  void serverDisconnect() => _incoming.close();
}

class _FakeSink extends Fake implements WebSocketSink {
  _FakeSink(this._channel);
  final _FakeChannel _channel;

  @override
  void add(dynamic data) {
    if (data is String) _channel.sent.add(data);
  }

  @override
  Future<dynamic> close([int? closeCode, String? closeReason]) async {
    _channel.sinkClosed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<_FakeChannel> created;
  late MarketRealtimeService service;

  setUp(() {
    created = [];
    service = MarketRealtimeService.test(
      channelFactory: (uri) {
        final ch = _FakeChannel();
        created.add(ch);
        return ch;
      },
      wsUrlOverride: () => 'ws://test/v2/ws/invalidations',
      // Deterministic backoff (no jitter randomness in expectations).
      random: Random(0),
    );
  });

  tearDown(() {
    service.dispose();
  });

  Map<String, dynamic> decode(String s) =>
      jsonDecode(s) as Map<String, dynamic>;

  test('first watcher opens channel and sends subscribe', () async {
    service.watchMint('A').listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(created, hasLength(1));
    expect(created.first.sent, hasLength(1));
    final msg = decode(created.first.sent.first);
    expect(msg['action'], 'subscribe');
    expect(msg['mints'], ['A']);
  });

  test('second watcher on same mint does not re-subscribe', () async {
    service.watchMint('A').listen((_) {});
    service.watchMint('A').listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(created, hasLength(1));
    expect(created.first.sent, hasLength(1)); // only the first subscribe
  });

  test('cancelling last watcher sends unsubscribe immediately', () async {
    final sub = service.watchMint('A').listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(created.first.sent, hasLength(1));

    await sub.cancel();
    await Future<void>.delayed(Duration.zero);

    expect(created.first.sent, hasLength(2));
    final unsub = decode(created.first.sent.last);
    expect(unsub['action'], 'unsubscribe');
    expect(unsub['mints'], ['A']);
  });

  test('invalidate frame routes only to matching mint', () async {
    final aEvents = <MarketInvalidation>[];
    final bEvents = <MarketInvalidation>[];
    service.watchMint('A').listen(aEvents.add);
    service.watchMint('B').listen(bEvents.add);
    await Future<void>.delayed(Duration.zero);

    created.first.serverPush({
      'type': 'invalidate',
      'mint': 'A',
      'signature': 'sig-A',
      'slot': 42,
      'programs': ['MMA7'],
    });
    await Future<void>.delayed(Duration.zero);

    expect(aEvents, hasLength(1));
    expect(aEvents.first.signature, 'sig-A');
    expect(bEvents, isEmpty);
  });

  test('ack and error frames are not surfaced to watchers', () async {
    final events = <MarketInvalidation>[];
    service.watchMint('A').listen(events.add);
    await Future<void>.delayed(Duration.zero);

    created.first
      ..serverPush({
        'type': 'ack',
        'subscribed': ['A'],
      })
      ..serverPush({'type': 'error', 'message': 'something'});
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
  });

  test('reconnect re-subscribes and emits synthetic invalidation', () async {
    final events = <MarketInvalidation>[];
    service.watchMint('A').listen(events.add);
    await Future<void>.delayed(Duration.zero);
    expect(created, hasLength(1));

    // Simulate the channel dropping. Service waits ~1s before reconnecting.
    created.first.serverDisconnect();
    // Long enough for the first reconnect attempt (1s ± 20% jitter).
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    expect(
      created,
      hasLength(2),
      reason: 'service should have reopened the channel',
    );

    final reconMsg = decode(created.last.sent.first);
    expect(reconMsg['action'], 'subscribe');
    expect(reconMsg['mints'], ['A']);

    // Synthetic invalidation lets consumers refetch and close the gap.
    expect(events, hasLength(1));
    expect(events.first.programs, contains('__synthetic_reconnect__'));
    expect(events.first.signature, '');
  });

  test(
    'paused lifecycle closes channel; resumed reopens with subs intact',
    () async {
      service.watchMint('A').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(created, hasLength(1));

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(created.first.sinkClosed, isTrue);

      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(
        created,
        hasLength(2),
        reason: 'resume should reconnect when mints are still watched',
      );
      final msg = decode(created.last.sent.first);
      expect(msg['mints'], ['A']);
    },
  );

  test('malformed JSON frames are tolerated', () async {
    final events = <MarketInvalidation>[];
    service.watchMint('A').listen(events.add);
    await Future<void>.delayed(Duration.zero);

    // Push raw garbage straight into the stream controller (bypassing
    // serverPush so we can send invalid JSON).
    created.first._incoming.add('not-json');
    created.first.serverPush({'type': 'invalidate', 'malformed': true});
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
  });
}
