import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/realtime/account_realtime_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeChannel extends Fake implements WebSocketChannel {
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
  late AccountRealtimeService service;

  setUp(() {
    created = [];
    service = AccountRealtimeService.test(
      channelFactory: (uri) {
        final ch = _FakeChannel();
        created.add(ch);
        return ch;
      },
      wsUrlOverride: () => 'ws://test/v2/ws/accounts',
      random: Random(0),
    );
  });

  tearDown(() => service.dispose());

  Map<String, dynamic> decode(String s) =>
      jsonDecode(s) as Map<String, dynamic>;

  test('subscribes by account key (not mint)', () async {
    service.watchAccount('PDA1').listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(created, hasLength(1));
    final msg = decode(created.first.sent.first);
    expect(msg['action'], 'subscribe');
    // The accounts socket keys by `keys`, distinguishing it from the
    // invalidations socket which keys by `mints`.
    expect(msg['keys'], ['PDA1']);
  });

  test(
    'routes an auctionConfig frame to the matching account, parsed',
    () async {
      final pda1 = <AccountUpdate>[];
      final pda2 = <AccountUpdate>[];
      service.watchAccount('PDA1').listen(pda1.add);
      service.watchAccount('PDA2').listen(pda2.add);
      await Future<void>.delayed(Duration.zero);

      created.first.serverPush({
        'accountType': 'auctionConfig',
        'highestBidAmount': 2500000000,
        'highestBidder': 'Bidder111',
        'endTime': 1893456000, // 2030-01-01T00:00:00Z
        'pubkey': 'PDA1',
        'program': 'mallow-auction',
        'slot': 42,
      });
      await Future<void>.delayed(Duration.zero);

      expect(pda2, isEmpty);
      expect(pda1, hasLength(1));
      final update = pda1.first;
      expect(update.isAuctionConfig, isTrue);
      expect(update.highestBidAmount, 2500000000);
      expect(update.highestBidder, 'Bidder111');
      expect(update.endTime, isNotNull);
    },
  );

  test('normalizes a no-bid auction (zero amount / system bidder) to null', () {
    final update = AccountUpdate.fromJson({
      'accountType': 'auctionConfig',
      'highestBidAmount': 0,
      'highestBidder': '11111111111111111111111111111111',
      'endTime': 0,
      'pubkey': 'PDA1',
    });

    expect(update.highestBidAmount, isNull);
    expect(update.highestBidder, isNull);
    expect(update.endTime, isNull);
  });
}
