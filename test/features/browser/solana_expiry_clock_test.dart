import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/solana_expiry_clock.dart';
import 'package:mallow_wallet/features/browser/services/solana_slot_time.dart';
import 'package:mallow_wallet/shared/widgets/transaction_expiry.dart';
import 'package:solana/base58.dart' show base58encode;
import 'package:solana/solana.dart' show Ed25519HDPublicKey;

const _systemProgram = '11111111111111111111111111111111';

/// The blockhash a test transaction carries: 32 bytes of [n].
String _hash(int n) => base58encode(List.filled(32, n));

/// An unsigned one-signer System call with blockhash [n]. With [nonce] its
/// only instruction is AdvanceNonceAccount, which makes it durable.
Uint8List _tx(int n, {bool nonce = false}) {
  final signer = Ed25519HDPublicKey(List.filled(32, 1));
  final other = Ed25519HDPublicKey(List.filled(32, 2));
  final system = Ed25519HDPublicKey.fromBase58(_systemProgram);
  final data = nonce ? [4, 0, 0, 0] : <int>[];
  return Uint8List.fromList([
    1,
    ...List.filled(64, 0),
    1,
    0,
    1,
    3,
    ...signer.bytes,
    ...other.bytes,
    ...system.bytes,
    ...List.filled(32, n),
    1,
    2,
    2,
    0,
    1,
    data.length,
    ...data,
  ]);
}

/// A `getAccountInfo` result for the RecentBlockhashes sysvar listing
/// [hashes] newest first.
Map<String, Object?> _sysvar(List<int> hashes) {
  final bytes = BytesBuilder()
    ..add(
      (ByteData(
        8,
      )..setUint64(0, hashes.length, Endian.little)).buffer.asUint8List(),
    );
  for (final n in hashes) {
    bytes
      ..add(List.filled(32, n))
      ..add(List.filled(8, 0));
  }
  return {
    'context': {'slot': 1},
    'value': {
      'data': [base64Encode(bytes.toBytes()), 'base64'],
    },
  };
}

/// A sysvar in which blockhash [n] is [age] blocks old.
Map<String, Object?> _aged(int n, int age) =>
    _sysvar([for (var i = 0; i < age; i++) 200 + i % 50, n]);

class _Chain {
  Object? Function() sysvar = () => throw StateError('no sysvar');
  final valid = <String, bool>{};
  int sysvarReads = 0;

  Future<Object?> call(
    String chain,
    String method,
    List<Object?> params,
  ) async {
    switch (method) {
      case 'getAccountInfo':
        sysvarReads++;
        return sysvar();
      case 'isBlockhashValid':
        final hash = params.first as String;
        final value = valid[hash];
        if (value == null) throw StateError('unreachable');
        return {'value': value};
    }
    throw StateError('unexpected $method');
  }
}

void main() {
  late DateTime now;
  late _Chain chain;
  late SolanaSlotTimeSource slotTime;

  setUp(() {
    now = DateTime.utc(2026, 10, 20, 12);
    chain = _Chain();
    slotTime = SolanaSlotTimeSource(fetch: () async => 200, now: () => now);
  });

  SolanaExpiryClock clock(List<Uint8List> payloads) => SolanaExpiryClock(
    payloads: payloads,
    chain: 'solana:mainnet',
    rpc: chain.call,
    slotTime: slotTime,
    now: () => now,
  );

  Future<void> advance(WidgetTester tester, Duration by) async {
    now = now.add(by);
    await tester.pump(by);
  }

  Duration remaining(SolanaExpiryClock c) =>
      (c.state.value as ExpiryCountdown).remaining;

  testWidgets('counts down from the blockhash age at the slot time', (
    tester,
  ) async {
    chain.sysvar = () => _aged(7, 10);
    final c = clock([_tx(7)])..start();
    expect(c.state.value, isA<ExpiryChecking>());
    await tester.pump();

    // (150 - 10 - 4) blocks × 200 ms.
    expect(remaining(c), const Duration(milliseconds: 27200));
    await advance(tester, const Duration(seconds: 2));
    expect(remaining(c), const Duration(milliseconds: 25200));
    c.stop();
  });

  testWidgets('a re-read corrects the countdown', (tester) async {
    chain.sysvar = () => _aged(7, 10);
    final c = clock([_tx(7)])..start();
    await tester.pump();

    chain.sysvar = () => _aged(7, 60);
    await advance(tester, SolanaExpiryClock.resyncEvery);
    expect(chain.sysvarReads, 2);
    // (150 - 60 - 4) × 200 ms, from the second read.
    expect(remaining(c), const Duration(milliseconds: 17200));
    c.stop();
  });

  testWidgets('expires once the blockhash leaves the list and is invalid', (
    tester,
  ) async {
    chain.sysvar = () => _aged(7, 140);
    final c = clock([_tx(7)])..start();
    await tester.pump();
    expect(remaining(c), const Duration(milliseconds: 1200));

    chain.sysvar = () => _sysvar([200, 201]);
    chain.valid[_hash(7)] = false;
    await advance(tester, const Duration(seconds: 2));
    expect(c.state.value, isA<ExpiryPassed>());
    expect(c.expired, isTrue);
  });

  testWidgets('no blocks left is expired without asking again', (tester) async {
    chain.sysvar = () => _aged(7, 146);
    final c = clock([_tx(7)])..start();
    await tester.pump();
    expect(c.state.value, isA<ExpiryPassed>());
  });

  testWidgets('a blockhash newer than the read is valid but unmeasured', (
    tester,
  ) async {
    chain.sysvar = () => _sysvar([200, 201]);
    chain.valid[_hash(7)] = true;
    final c = clock([_tx(7)])..start();
    await tester.pump();
    expect(
      c.state.value,
      isA<ExpiryUnmeasured>().having(
        (e) => e.atMost,
        'atMost',
        const Duration(milliseconds: 29200),
      ),
    );

    chain.sysvar = () => _aged(7, 3);
    await advance(tester, SolanaExpiryClock.resyncEvery);
    expect(remaining(c), const Duration(milliseconds: 28600));
    c.stop();
  });

  testWidgets('without the sysvar it waits on isBlockhashValid', (
    tester,
  ) async {
    chain.valid[_hash(7)] = true;
    final c = clock([_tx(7)])..start();
    await tester.pump();
    expect(c.state.value, isA<ExpiryUnmeasured>());

    chain.valid[_hash(7)] = false;
    await advance(tester, SolanaExpiryClock.resyncEvery);
    expect(c.state.value, isA<ExpiryPassed>());
  });

  testWidgets('a countdown that reaches zero unchecked fails closed', (
    tester,
  ) async {
    chain.sysvar = () => _aged(7, 141);
    final c = clock([_tx(7)])..start();
    await tester.pump();
    expect(remaining(c), const Duration(milliseconds: 1000));

    // Neither check can be made any more.
    chain.sysvar = () => throw StateError('node down');
    await advance(tester, const Duration(seconds: 1));
    expect(c.state.value, isA<ExpiryPassed>());
  });

  testWidgets('a batch counts down to its first expiry', (tester) async {
    chain.sysvar = () => _sysvar([
      for (var i = 0; i < 40; i++) i == 5 ? 8 : (i == 30 ? 7 : 200),
    ]);
    final c = clock([_tx(8), _tx(7)])..start();
    await tester.pump();
    // The older blockhash, 30 blocks old: (150 - 30 - 4) × 200 ms.
    expect(remaining(c), const Duration(milliseconds: 23200));
    c.stop();
  });

  testWidgets('a durable nonce never expires; its review window does', (
    tester,
  ) async {
    final c = clock([_tx(7, nonce: true)])..start();
    expect(c.state.value, isA<ExpiryNever>());
    expect(chain.sysvarReads, 0);

    c.reviewed(now);
    expect(
      (c.state.value as ExpiryNever).reviewRemaining,
      SolanaExpiryClock.reviewWindow,
    );
    await advance(tester, const Duration(seconds: 12));
    expect(
      (c.state.value as ExpiryNever).reviewRemaining,
      const Duration(minutes: 1, seconds: 48),
    );
    await advance(tester, const Duration(minutes: 2));
    expect(c.state.value, isA<ExpiryPassed>());
  });

  testWidgets('stop freezes the state and the reads', (tester) async {
    chain.sysvar = () => _aged(7, 10);
    final c = clock([_tx(7)])..start();
    await tester.pump();
    c.stop();
    final frozen = c.state.value;
    await advance(tester, const Duration(seconds: 20));
    expect(c.state.value, same(frozen));
    expect(chain.sysvarReads, 1);
  });

  test('the sysvar decoder refuses a truncated account', () {
    final full = _sysvar([1, 2, 3]);
    expect(SolanaExpiryClock.decodeRecentBlockhashes(full), [
      _hash(1),
      _hash(2),
      _hash(3),
    ]);
    final data = base64Decode(
      ((full['value']! as Map)['data'] as List).first as String,
    );
    final truncated = {
      'value': {
        'data': [base64Encode(data.sublist(0, data.length - 1)), 'base64'],
      },
    };
    expect(SolanaExpiryClock.decodeRecentBlockhashes(truncated), isNull);
    expect(SolanaExpiryClock.decodeRecentBlockhashes({'value': null}), isNull);
  });
}
