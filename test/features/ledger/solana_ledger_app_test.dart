import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart'
    show LedgerConnection;
import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';
import 'package:ledger_solana/ledger_solana.dart';

/// Stands in for a connected device: records every APDU frame the app writes
/// and feeds back one canned response per frame.
///
/// It asserts one frame per device exchange because that is the constraint the
/// whole chunking design exists to satisfy — `LedgerGattGateway` registers a
/// single pending operation per exchange and completes it on the FIRST device
/// response, so a `write()` that emits several frames resolves against the
/// non-final frame's `0x9000` ack instead of the signature.
///
/// It also counts `sendOperation` calls ([queuedOperations]) separately from
/// frames: a chunked signature must occupy exactly ONE queue entry, or another
/// caller's APDU can interleave between frames and wipe the device's signing
/// buffer.
class _FakeConnection implements LedgerConnection {
  _FakeConnection(this.responses);

  /// Device responses, in the order the frames are sent.
  final List<List<int>> responses;

  /// The raw APDU frames written, in send order.
  final List<Uint8List> frames = [];

  /// How many operations were handed to the connection's request queue.
  int queuedOperations = 0;

  @override
  Future<T> sendOperation<T>(
    dynamic operation, {
    LedgerTransformer? transformer,
  }) async {
    queuedOperations++;
    if (operation is LedgerComplexOperation<T>) {
      return operation.invoke(_exchange);
    }
    return _exchange(operation as LedgerRawOperation<T>);
  }

  /// One request/response round-trip with the device.
  Future<Y> _exchange<Y>(LedgerRawOperation<Y> op) async {
    final written = await op.write(ByteDataWriter());
    expect(written, hasLength(1), reason: 'one APDU frame per device exchange');
    frames.add(written.single);

    final reader = ByteDataReader()
      ..add(Uint8List.fromList(responses[frames.length - 1]));
    return op.read(reader);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A successful sign response: 64-byte Ed25519 signature + 0x9000 status word.
List<int> _signatureResponse(List<int> signature) => [...signature, 0x90, 0x00];

/// The bare success status word non-final frames ack with.
const _ack = [0x90, 0x00];

void main() {
  const app = SolanaLedgerApp();
  const path = SolanaDerivationPath();
  final signature = List<int>.generate(64, (i) => i + 1);

  // m/44'/501'/0'/0' → [depth][4 components × 4 bytes] = 17 bytes, plus the
  // 1-byte pathsCount prefix. So 18 bytes of every payload is not transaction.
  final pathBytes = path.toBytes();
  final headerLength = 1 + pathBytes.length;

  /// Reassemble the data fields of [frames] — should equal the streamed payload.
  Uint8List dataOf(List<Uint8List> frames) =>
      Uint8List.fromList([for (final f in frames) ...f.sublist(5)]);

  group('SolanaLedgerApp.signTransaction — single frame', () {
    test('writes one APDU with P2=p2Init and returns the signature', () async {
      final tx = Uint8List.fromList(List<int>.generate(100, (i) => i));
      final connection = _FakeConnection([_signatureResponse(signature)]);

      final result = await app.signTransaction(connection, transaction: tx);

      expect(result, signature);
      expect(connection.frames, hasLength(1));

      final frame = connection.frames.single;
      expect(frame[0], 0xE0); // CLA
      expect(frame[1], 0x06); // INS sign transaction
      expect(frame[2], 0x01); // P1 confirm on device
      expect(frame[3], 0x00); // P2 — p2Init, neither MORE nor EXTEND
      expect(frame[4], headerLength + tx.length); // Lc
      expect(frame.sublist(5, 5 + 1), [1], reason: 'pathsCount');
      expect(frame.sublist(6, 6 + pathBytes.length), pathBytes);
      expect(frame.sublist(5 + headerLength), tx);
    });

    test(
      'a 237-byte transaction still fits one frame (payload == 255)',
      () async {
        final tx = Uint8List(SolanaApdu.maxChunkSize - headerLength);
        final connection = _FakeConnection([_signatureResponse(signature)]);

        await app.signTransaction(connection, transaction: tx);

        expect(connection.frames, hasLength(1));
        expect(connection.frames.single[4], SolanaApdu.maxChunkSize);
      },
    );
  });

  group('SolanaLedgerApp.signTransaction — chunked', () {
    // Regression: every frame past the first used to be emitted from a single
    // operation's write(), so the gateway completed that operation against
    // frame 0's bare 0x9000 ack and the caller saw
    // "Transaction signing failed (0x9000)" — success reported as failure.
    test('does not surface the non-final 0x9000 ack as an error', () async {
      final tx = Uint8List.fromList(List<int>.generate(600, (i) => i % 256));
      final connection = _FakeConnection([
        _ack,
        _ack,
        _signatureResponse(signature),
      ]);

      final result = await app.signTransaction(connection, transaction: tx);

      expect(
        result,
        signature,
        reason: 'the final frame carries the signature',
      );
      expect(connection.frames, hasLength(3));
    });

    // The frames must share ONE queue entry. `LedgerConnection` serializes
    // queued requests but does not group them, so a concurrent getAppConfig() /
    // getPublicKey() landing between frame N and N+1 would discard the device's
    // accumulated signing buffer and the next p2Extend frame would arrive with
    // no prior state.
    test('streams every frame inside a single queued operation', () async {
      final tx = Uint8List(600);
      final connection = _FakeConnection([
        _ack,
        _ack,
        _signatureResponse(signature),
      ]);

      await app.signTransaction(connection, transaction: tx);

      expect(connection.frames, hasLength(3));
      expect(connection.queuedOperations, 1);
    });

    test('crossing 255 bytes by one splits into two frames', () async {
      final tx = Uint8List(SolanaApdu.maxChunkSize - headerLength + 1);
      final connection = _FakeConnection([_ack, _signatureResponse(signature)]);

      await app.signTransaction(connection, transaction: tx);

      expect(connection.frames, hasLength(2));
      expect(connection.frames[0][4], SolanaApdu.maxChunkSize);
      expect(connection.frames[1][4], 1, reason: 'the overflowing byte');
    });

    test('sets the hw-app-solana P2 flag sequence', () async {
      final tx = Uint8List(600);
      final connection = _FakeConnection([
        _ack,
        _ack,
        _signatureResponse(signature),
      ]);

      await app.signTransaction(connection, transaction: tx);

      // MORE(0x02) while more follows; EXTEND(0x01) on every frame after the
      // first; the final frame drops MORE.
      expect(connection.frames.map((f) => f[3]), [0x02, 0x03, 0x01]);
      expect(
        connection.frames.map((f) => f[2]),
        everyElement(0x01),
        reason: 'P1 stays p1Confirm on every frame',
      );
    });

    test('streams the payload contiguously across frames', () async {
      final tx = Uint8List.fromList(List<int>.generate(600, (i) => i % 251));
      final connection = _FakeConnection([
        _ack,
        _ack,
        _signatureResponse(signature),
      ]);

      await app.signTransaction(connection, transaction: tx);

      final streamed = dataOf(connection.frames);
      expect(streamed, hasLength(headerLength + tx.length));
      expect(
        streamed[0],
        1,
        reason: 'pathsCount, sent once on the first frame',
      );
      expect(streamed.sublist(1, headerLength), pathBytes);
      expect(streamed.sublist(headerLength), tx);
    });

    test('a device error on the final frame still throws', () async {
      final tx = Uint8List(600);
      final connection = _FakeConnection([
        _ack,
        _ack,
        [0x69, 0x85], // user rejected on device
      ]);

      expect(
        () => app.signTransaction(connection, transaction: tx),
        throwsA(
          isA<LedgerDeviceException>().having(
            (e) => e.errorCode,
            'errorCode',
            0x6985,
          ),
        ),
      );
    });

    test('a device error on a non-final frame aborts the stream', () async {
      final tx = Uint8List(600);
      final connection = _FakeConnection([
        [0x6d, 0x00], // INS not supported — app too old
        _ack,
        _signatureResponse(signature),
      ]);

      await expectLater(
        app.signTransaction(connection, transaction: tx),
        throwsA(
          isA<LedgerDeviceException>().having(
            (e) => e.errorCode,
            'errorCode',
            0x6d00,
          ),
        ),
      );
      expect(
        connection.frames,
        hasLength(1),
        reason: 'no further frames after the device rejects one',
      );
    });
  });

  group('SolanaLedgerApp.signOffChainMessage', () {
    test('uses INS 0x07 and chunks the same way', () async {
      final message = Uint8List(600);
      final connection = _FakeConnection([
        _ack,
        _ack,
        _signatureResponse(signature),
      ]);

      final result = await app.signOffChainMessage(
        connection,
        message: message,
      );

      expect(result, signature);
      expect(connection.frames.map((f) => f[1]), everyElement(0x07));
      expect(connection.frames.map((f) => f[3]), [0x02, 0x03, 0x01]);
    });
  });

  group('frame Lc ceiling', () {
    // Lc is one byte, so a 256-byte payload wraps to 0: the device would parse
    // a zero-length signing frame and the remaining bytes as a stray APDU —
    // a silently wrong signing request instead of an error. The frame classes
    // are public API, so the guard belongs on them, not only on the chunker.
    test('a payload past 255 bytes is rejected, not truncated', () {
      expect(
        () => SolanaSignTransactionOperation(
          p2: SolanaApdu.p2Init,
          payload: Uint8List(SolanaApdu.maxChunkSize + 1),
          expectSignature: true,
        ),
        throwsRangeError,
      );
      expect(
        () => SolanaSignOffChainMessageOperation(
          p2: SolanaApdu.p2Init,
          payload: Uint8List(SolanaApdu.maxChunkSize + 1),
          expectSignature: true,
        ),
        throwsRangeError,
      );
    });

    test('a payload exactly at 255 bytes is allowed', () {
      expect(
        () => SolanaSignTransactionOperation(
          p2: SolanaApdu.p2Init,
          payload: Uint8List(SolanaApdu.maxChunkSize),
          expectSignature: true,
        ),
        returnsNormally,
      );
    });
  });

  group('SolanaSignTransactionOperation.read', () {
    test('non-final frame acks 0x9000 with an empty read', () async {
      final reader = ByteDataReader()..add(Uint8List.fromList(_ack));
      final op = SolanaSignTransactionOperation(
        p2: SolanaApdu.p2More,
        payload: Uint8List(0),
        expectSignature: false,
      );

      expect(await op.read(reader), isEmpty);
    });

    test('non-final frame throws on a real status-word error', () async {
      final reader = ByteDataReader()..add(Uint8List.fromList([0x6a, 0x80]));
      final op = SolanaSignTransactionOperation(
        p2: SolanaApdu.p2More,
        payload: Uint8List(0),
        expectSignature: false,
      );

      expect(
        () => op.read(reader),
        throwsA(
          isA<LedgerDeviceException>().having(
            (e) => e.errorCode,
            'errorCode',
            0x6a80,
          ),
        ),
      );
    });
  });
}
