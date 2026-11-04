import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/solana_slot_time.dart';

void main() {
  late DateTime now;
  late int calls;

  setUp(() {
    now = DateTime.utc(2026, 10, 20, 12);
    calls = 0;
  });

  SolanaSlotTimeSource source(Future<int> Function() answer) =>
      SolanaSlotTimeSource(
        fetch: () {
          calls++;
          return answer();
        },
        now: () => now,
      );

  test('falls back until the backend answers, then keeps its value', () async {
    final s = source(() async => 218);
    expect(s.current, SolanaSlotTimeSource.fallback);
    expect(await s.load(), const Duration(milliseconds: 218));
    expect(s.current, const Duration(milliseconds: 218));
    expect(calls, 1);
  });

  test('refetches only once the value is a day old', () async {
    final s = source(() async => 218);
    await s.load();
    now = now.add(const Duration(hours: 23));
    await s.load();
    expect(calls, 1);
    now = now.add(const Duration(hours: 2));
    await s.load();
    expect(calls, 2);
  });

  test('a failure falls back and waits before retrying', () async {
    final s = source(() async => throw StateError('404'));
    expect(await s.load(), SolanaSlotTimeSource.fallback);
    await s.load();
    expect(calls, 1);
    now = now.add(const Duration(minutes: 6));
    await s.load();
    expect(calls, 2);
  });

  test('an implausible value is not believed', () async {
    final s = source(() async => 5);
    expect(await s.load(), SolanaSlotTimeSource.fallback);
  });

  test('concurrent loads share one request', () async {
    final s = source(() async => 218);
    await Future.wait([s.load(), s.load(), s.load()]);
    expect(calls, 1);
  });
}
