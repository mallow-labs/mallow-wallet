import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_ethereum/ledger_ethereum.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/features/browser/services/browser_signing_service.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

LedgerDeviceException _status(int code) => LedgerDeviceException(
  errorCode: code,
  message: 'status',
  connectionType: ConnectionType.ble,
);

void main() {
  group('ledgerSigningFailure', () {
    test('a device rejection says nothing was signed', () {
      for (final code in [0x6985, 0x6982]) {
        expect(ledgerSigningFailure(_status(code)), contains('You rejected'));
      }
    });

    test('a refusal for missing settings names both settings', () {
      final text = ledgerSigningFailure(_status(0x6A80));
      expect(text, contains('Raw messages'));
      expect(text, contains('Blind signing'));
    });

    test('too large, wrong app and unstreamable payloads are explained', () {
      expect(ledgerSigningFailure(_status(0x6A84)), contains('too large'));
      expect(ledgerSigningFailure(_status(0x6D00)), contains('Ethereum app'));
      expect(ledgerSigningFailure(_status(0x6E00)), contains('Ethereum app'));
      expect(
        ledgerSigningFailure(
          const Eip712LedgerException('Type a[2][] is not supported.'),
        ),
        'Type a[2][] is not supported. Nothing was signed.',
      );
    });

    test('anything else falls back to a generic retry hint', () {
      expect(ledgerSigningFailure(StateError('x')), contains('unlocked'));
    });

    test('a Solana failure names the Solana app and its settings', () {
      String solana(Object error) =>
          ledgerSigningFailure(error, chain: Chain.solana);
      expect(solana(_status(0x6985)), contains('You rejected'));
      expect(solana(_status(0x6A80)), contains('Blind signing'));
      expect(solana(_status(0x6A80)), isNot(contains('Raw messages')));
      expect(solana(_status(0x6E00)), contains('Solana app'));
      expect(solana(StateError('x')), contains('Solana app open'));
      expect(solana(StateError('x')), isNot(contains('Ethereum')));
    });
  });

  group('ledgerEthereumHashesTypedData', () {
    test('1.9.19 and later stream the message to the device', () {
      for (final version in ['1.9.19', '1.10.0', '1.22.5', '2.0.0-rc1']) {
        expect(ledgerEthereumHashesTypedData(version), isTrue, reason: version);
      }
    });

    test('older apps sign host-computed hashes', () {
      for (final version in ['1.9.18', '1.8.0', '0.99.99']) {
        expect(
          ledgerEthereumHashesTypedData(version),
          isFalse,
          reason: version,
        );
      }
    });

    test('an unparseable version tries the device first', () {
      expect(ledgerEthereumHashesTypedData(''), isTrue);
      expect(ledgerEthereumHashesTypedData('unknown'), isTrue);
    });
  });

  group('signLedgerTypedData', () {
    final streamed = Uint8List.fromList([1]);
    final hashed = Uint8List.fromList([2]);

    test('streams first and does not touch the hashes path', () async {
      var hashCalls = 0;
      final result = await signLedgerTypedData(
        streamFirst: true,
        stream: () async => streamed,
        hashes: () async {
          hashCalls++;
          return hashed;
        },
      );
      expect(result, streamed);
      expect(hashCalls, 0);
    });

    test('an app without streaming falls back to hashes', () async {
      expect(
        await signLedgerTypedData(
          streamFirst: true,
          stream: () async => throw _status(0x6D00),
          hashes: () async => hashed,
        ),
        hashed,
      );
    });

    test('a rejection or settings refusal does not fall back', () async {
      for (final code in [0x6985, 0x6A80]) {
        await expectLater(
          signLedgerTypedData(
            streamFirst: true,
            stream: () async => throw _status(code),
            hashes: () async =>
                fail('fell back after 0x${code.toRadixString(16)}'),
          ),
          throwsA(
            isA<LedgerDeviceException>().having(
              (e) => e.errorCode,
              'code',
              code,
            ),
          ),
        );
      }
    });

    test('an old app goes straight to hashes', () async {
      expect(
        await signLedgerTypedData(
          streamFirst: false,
          stream: () async => fail('streamed to an old app'),
          hashes: () async => hashed,
        ),
        hashed,
      );
    });

    test('a Solana off-chain message names the app version it needs', () {
      final text = ledgerSigningFailure(
        _status(0x6A81),
        chain: Chain.solana,
        offchainMessage: true,
      );
      expect(text, contains('1.14'));
      expect(
        ledgerSigningFailure(
          _status(0x6A83),
          chain: Chain.solana,
          offchainMessage: true,
        ),
        contains('too large'),
      );
      // Rejection and app errors read as for any other Solana request.
      expect(
        ledgerSigningFailure(
          _status(0x6985),
          chain: Chain.solana,
          offchainMessage: true,
        ),
        contains('You rejected'),
      );
      expect(
        ledgerSigningFailure(_status(0x6A81), chain: Chain.solana),
        isNot(contains('1.14')),
      );
    });
  });
}
