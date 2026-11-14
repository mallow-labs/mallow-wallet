import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/dapp_rpc_warmer.dart';

void main() {
  late DateTime now;
  late Map<String, int> warmed;
  late DappRpcWarmer warmer;

  setUp(() {
    now = DateTime.utc(2026, 10, 26);
    warmed = {'solana': 0, 'eip155': 0};
    warmer = DappRpcWarmer(
      warmers: {
        for (final namespace in warmed.keys)
          namespace: () async => warmed[namespace] = warmed[namespace]! + 1,
      },
      interval: const Duration(milliseconds: 20),
      window: const Duration(seconds: 5),
      now: () => now,
    );
  });

  tearDown(() => warmer.dispose());

  test('a site\'s first request opens its namespace\'s connections', () {
    warmer.touch('solana');
    expect(warmed, {'solana': 1, 'eip155': 0});
  });

  test('a namespace it has no warmer for is ignored', () {
    warmer.touch('tezos');
    expect(warmed.values, everyElement(0));
  });

  test('requests close together warm once', () {
    warmer
      ..touch('solana')
      ..touch('solana');
    now = now.add(const Duration(milliseconds: 5));
    warmer.touch('solana');
    expect(warmed['solana'], 1);
  });

  test('connections are reopened while the site is in use', () async {
    warmer.touch('eip155');
    for (var i = 0; i < 3; i++) {
      now = now.add(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(warmed['eip155'], greaterThanOrEqualTo(3));
    expect(warmed['solana'], 0);
  });

  test('and no longer once the window has passed', () async {
    warmer.touch('solana');
    now = now.add(const Duration(seconds: 6));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final after = warmed['solana'];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(warmed['solana'], after, reason: 'the timer stopped');
    expect(after, 1);
  });

  test('nothing is warmed in the background, and a return warms at once', () {
    warmer
      ..touch('solana')
      ..setForeground(false)
      ..touch('solana');
    expect(warmed['solana'], 1);
    warmer.setForeground(true);
    expect(warmed['solana'], 2, reason: 'sockets do not survive the away');
  });

  test('a return after the window warms nothing', () {
    warmer
      ..touch('solana')
      ..setForeground(false);
    now = now.add(const Duration(seconds: 6));
    warmer.setForeground(true);
    expect(warmed['solana'], 1);
  });

  test('a failing warm-up is swallowed', () async {
    final failing = DappRpcWarmer(
      warmers: {'solana': () => Future.error(StateError('offline'))},
      now: () => now,
    );
    addTearDown(failing.dispose);
    failing.touch('solana');
    await Future<void>.delayed(Duration.zero);
  });
}
