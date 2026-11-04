import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart'
    hide LedgerOperation;
// LedgerConnection uses this type; the public barrel exports a different one.
import 'package:ledger_flutter_plus/src/operations/ledger_operations.dart'
    show LedgerOperation;
import 'package:ledger_tezos/ledger_tezos.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mallow_wallet/core/services/ledger_open_app.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';

class _Connection extends Fake implements LedgerConnection {
  String appName = 'Tezos Wallet';
  final packets = <TezosSignOperation>[];
  final publicKey = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final signature = Uint8List.fromList(List.generate(64, (i) => i + 1));
  Completer<Uint8List>? pendingSignature;
  Completer<Uint8List>? pendingKey;
  void Function(TezosSignOperation)? onPacket;
  bool disconnected = false;
  @override
  bool get isDisconnected => disconnected;
  @override
  Future<void> disconnect() async {
    disconnected = true;
  }

  @override
  Future<T> sendOperation<T>(
    LedgerOperation<T> operation, {
    LedgerTransformer? transformer,
  }) async {
    if (operation is LedgerGetAppAndVersionOperation) {
      return LedgerAppInfo(name: appName, version: '3.0.0') as T;
    }
    if (operation is TezosGetPublicKeyOperation)
      return await (pendingKey?.future ?? Future.value(publicKey)) as T;
    final packet = operation as TezosSignOperation;
    packets.add(packet);
    onPacket?.call(packet);
    return (packet.expectSignature
            ? await (pendingSignature?.future ?? Future.value(signature))
            : Uint8List(0))
        as T;
  }
}

void main() {
  test(
    'Given a multi-packet operation, the exact forged group has one watermark and the stored account path',
    () async {
      final connection = _Connection();
      final forged = Uint8List.fromList(List.generate(520, (i) => i % 256));
      final signature = await const TezosLedgerApp().signOperation(
        connection,
        operation: forged,
        account: 3,
      );
      expect(signature, connection.signature);
      expect(
        connection.packets.first.payload,
        const TezosDerivationPath(account: 3).toBytes(),
      );
      expect(connection.packets.map((p) => p.p1), [0, 1, 1, 0x81]);
      expect(connection.packets.skip(1).expand((p) => p.payload), [
        3,
        ...forged,
      ]);
      expect(
        connection.packets.skip(1).every((p) => p.payload.length <= 230),
        true,
      );
    },
  );
  test(
    'Given cancellation after the path packet, no payload packet reaches the device',
    () async {
      final connection = _Connection();
      var active = true;
      connection.onPacket = (_) {
        active = false;
      };
      await expectLater(
        const TezosLedgerApp().signOperation(
          connection,
          operation: Uint8List(100),
          ensureActive: () {
            if (!active) throw StateError('Cancelled');
          },
        ),
        throwsStateError,
      );
      expect(connection.packets, hasLength(1));
    },
  );
  test(
    'Given mutation during the path wait, the streamed bytes remain frozen',
    () async {
      final connection = _Connection();
      final message = Uint8List.fromList([5, 1, 0, 0, 0, 1, 65]);
      connection.onPacket = (_) {
        message.fillRange(0, message.length, 9);
      };
      await const TezosLedgerApp().signMessage(connection, message: message);
      expect(connection.packets.last.payload, [5, 1, 0, 0, 0, 1, 65]);
    },
  );
  for (final name in ['Tezos Baking', 'Ethereum', 'BOLOS']) {
    test('Given $name is open, service refuses before signing', () async {
      final connection = _Connection()..appName = name;
      final service = LedgerService.forConnection(connection);
      addTearDown(service.dispose);
      await expectLater(
        service.signTezosOperation(Uint8List(100)),
        throwsA(
          isA<LedgerDeviceException>().having(
            (e) => e.errorCode,
            'code',
            0x6e00,
          ),
        ),
      );
      expect(connection.packets, isEmpty);
    });
  }
  test(
    'Given Tezos Wallet, operation and message streams retain their distinct watermark bytes',
    () async {
      final connection = _Connection();
      final service = LedgerService.forConnection(connection);
      addTearDown(service.dispose);
      expect(await service.getTezosPublicKey(account: 2), connection.publicKey);
      await service.signTezosOperation(Uint8List(100), account: 2);
      expect(connection.packets[1].payload.first, 3);
      connection.packets.clear();
      await service.signTezosMessage(
        Uint8List.fromList([5, 1, 0, 0, 0, 0]),
        account: 2,
      );
      expect(connection.packets[1].payload.first, 5);
    },
  );
  for (final operation in [false, true]) {
    test(
      'Given cancellation during ${operation ? 'operation' : 'message'} approval, BLE tears down and a late signature is discarded',
      () async {
        final connection = _Connection()..pendingSignature = Completer();
        final service = LedgerService.forConnection(connection);
        addTearDown(service.dispose);
        final cancelled = Completer<void>();
        final reached = Completer<void>();
        connection.onPacket = (packet) {
          if (packet.expectSignature) reached.complete();
        };
        final future = operation
            ? service.signTezosOperation(
                Uint8List(100),
                cancelled: cancelled.future,
              )
            : service.signTezosMessage(
                Uint8List.fromList([5, 1, 0, 0, 0, 0]),
                cancelled: cancelled.future,
              );
        final assertion = expectLater(
          future,
          throwsA(isA<LedgerSigningCancelledException>()),
        );
        await reached.future;
        cancelled.complete();
        await assertion;
        expect(connection.disconnected, true);
        expect(service.isConnected, false);
        connection.pendingSignature!.complete(connection.signature);
        await Future<void>.value();
      },
    );
  }
  test(
    'Given cancellation during public-key lookup, BLE tears down before a stale key returns',
    () async {
      final connection = _Connection()..pendingKey = Completer();
      final service = LedgerService.forConnection(connection);
      addTearDown(service.dispose);
      final cancelled = Completer<void>();
      final future = service.getTezosPublicKey(cancelled: cancelled.future);
      final assertion = expectLater(
        future,
        throwsA(isA<LedgerSigningCancelledException>()),
      );
      await Future<void>.delayed(Duration.zero);
      cancelled.complete();
      await assertion;
      expect(connection.disconnected, true);
      connection.pendingKey!.complete(connection.publicKey);
    },
  );
}
