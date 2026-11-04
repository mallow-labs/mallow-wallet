import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_ethereum/ledger_ethereum.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus_dart.dart';
import 'package:mallow_wallet/core/crypto/eip712.dart';

const _cow = '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826';
const _bob = '0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB';

Map<String, Object?> _mail() => {
  'types': {
    'EIP712Domain': [
      {'name': 'name', 'type': 'string'},
      {'name': 'version', 'type': 'string'},
      {'name': 'chainId', 'type': 'uint256'},
      {'name': 'verifyingContract', 'type': 'address'},
    ],
    'Person': [
      {'name': 'name', 'type': 'string'},
      {'name': 'wallet', 'type': 'address'},
    ],
    'Mail': [
      {'name': 'from', 'type': 'Person'},
      {'name': 'to', 'type': 'Person'},
      {'name': 'contents', 'type': 'string'},
    ],
  },
  'primaryType': 'Mail',
  'domain': {
    'name': 'Ether Mail',
    'version': '1',
    'chainId': 1,
    'verifyingContract': '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC',
  },
  'message': {
    'from': {'name': 'Cow', 'wallet': _cow},
    'to': {'name': 'Bob', 'wallet': _bob},
    'contents': 'Hello, Bob!',
  },
};

/// A one-struct payload whose `Note` type has [fields] and [values].
Map<String, Object?> _note(
  List<Map<String, String>> fields,
  Map<String, Object?> values,
) => {
  'types': {
    'EIP712Domain': [
      {'name': 'chainId', 'type': 'uint256'},
    ],
    'Note': fields,
  },
  'primaryType': 'Note',
  'domain': {'chainId': 1},
  'message': values,
};

Eip712LedgerMessage _ledger(Eip712TypedData data) => Eip712LedgerMessage(
  types: {
    for (final entry in data.types.entries)
      entry.key: [
        for (final field in entry.value)
          Eip712LedgerField(field.name, field.type),
      ],
  },
  primaryType: data.primaryType,
  domain: data.canonicalDomain,
  message: data.canonicalMessage,
);

final _path = const EthereumDerivationPath().toBytes();

List<EthereumApduFrame> _frames(Map<String, Object?> raw) =>
    eip712LedgerFrames(_ledger(Eip712TypedData.parse(raw)), _path);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _line(EthereumApduFrame f) =>
    '${_hex([f.ins, f.p1, f.p2])} ${_hex(f.data)}';

/// The value frames of the primary type, after its root-name frame.
List<EthereumApduFrame> _messageValues(List<EthereumApduFrame> frames) {
  final roots = [
    for (var i = 0; i < frames.length; i++)
      if (frames[i].ins == EthereumApdu.insEip712StructImplementation &&
          frames[i].p2 == EthereumApdu.p2Eip712Name)
        i,
  ];
  return frames.sublist(roots.last + 1, frames.length - 1);
}

void main() {
  group('eip712LedgerFrames', () {
    test('streams the EIP-712 Mail example as the Ethereum app expects', () {
      // The struct-definition bytes match the worked example in the app's
      // EIP-712 protocol documentation; the whole stream was signed by the
      // app in an emulator and the signature recovered over this digest.
      expect(_frames(_mail()).map(_line), [
        '1a0000 454950373132446f6d61696e',
        '1a00ff 05046e616d65',
        '1a00ff 050776657273696f6e',
        '1a00ff 422007636861696e4964',
        '1a00ff 0311766572696679696e67436f6e7472616374',
        '1a0000 4d61696c',
        '1a00ff 0006506572736f6e0466726f6d',
        '1a00ff 0006506572736f6e02746f',
        '1a00ff 0508636f6e74656e7473',
        '1a0000 506572736f6e',
        '1a00ff 05046e616d65',
        '1a00ff 030677616c6c6574',
        '1c0000 454950373132446f6d61696e',
        '1c00ff 000a4574686572204d61696c',
        '1c00ff 000131',
        '1c00ff 000101',
        '1c00ff 0014cccccccccccccccccccccccccccccccccccccccc',
        '1c0000 4d61696c',
        '1c00ff 0003436f77',
        '1c00ff 0014cd2a3d9f938e13cd947ec05abc7fe734df8dd826',
        '1c00ff 0003426f62',
        '1c00ff 0014bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        '1c00ff 000b48656c6c6f2c20426f6221',
        '0c0001 ${_hex(_path)}',
      ]);
    });

    test('only the final sign frame returns a signature', () {
      final frames = _frames(_mail());
      expect(frames.last.returnsSignature, isTrue);
      expect(
        frames.take(frames.length - 1).any((f) => f.returnsSignature),
        isFalse,
      );
    });

    test('defines struct types in alphabetical order', () {
      final names = [
        for (final f in _frames(_mail()))
          if (f.ins == EthereumApdu.insEip712StructDefinition &&
              f.p2 == EthereumApdu.p2Eip712Name)
            String.fromCharCodes(f.data),
      ];
      expect(names, ['EIP712Domain', 'Mail', 'Person']);
    });

    test('encodes field definitions for arrays, sized types and bytes', () {
      final frames = _frames(
        _note(
          [
            {'name': 'a', 'type': 'address[]'},
            {'name': 'b', 'type': 'bytes32[2]'},
            {'name': 'c', 'type': 'int64'},
            {'name': 'd', 'type': 'bytes'},
            {'name': 'e', 'type': 'bool'},
          ],
          {
            'a': <String>[],
            'b': ['0x${'aa' * 32}', '0x${'bb' * 32}'],
            'c': 0,
            'd': '0x',
            'e': false,
          },
        ),
      );
      final note = frames.indexWhere(
        (f) =>
            f.ins == EthereumApdu.insEip712StructDefinition &&
            String.fromCharCodes(f.data) == 'Note',
      );
      expect(frames.sublist(note + 1, note + 6).map((f) => _hex(f.data)), [
        '83'
            '01'
            '00'
            '0161', // address, array, 1 level, dynamic
        'c6'
            '20'
            '01'
            '0102'
            '0162', // bytes32, array, 1 level, fixed 2
        '41'
            '08'
            '0163', // int, size 8
        '07'
            '0164', // dynamic bytes
        '04'
            '0165', // bool
      ]);
    });

    test('sends an array as its length, then each element', () {
      final values = _messageValues(
        _frames(
          _note(
            [
              {'name': 'a', 'type': 'uint8[]'},
            ],
            {
              'a': [1, 2],
            },
          ),
        ),
      );
      expect(values.map(_line), [
        '1c000f 02',
        '1c00ff 000101',
        '1c00ff 000102',
      ]);
    });

    test(
      'integers: unsigned minimal, negative full-width two\'s complement',
      () {
        final values = _messageValues(
          _frames(
            _note(
              [
                {'name': 'zero', 'type': 'uint256'},
                {'name': 'max', 'type': 'uint256'},
                {'name': 'pos', 'type': 'int16'},
                {'name': 'neg', 'type': 'int8'},
                {'name': 'min', 'type': 'int256'},
              ],
              {
                'zero': 0,
                'max': '${(BigInt.one << 256) - BigInt.one}',
                'pos': 200,
                'neg': -1,
                'min': '${-(BigInt.one << 255)}',
              },
            ),
          ),
        );
        expect(values.map((f) => _hex(f.data)), [
          '000100',
          '0020${'ff' * 32}',
          // Shorter than the type, so the device does not sign-extend it.
          '0001c8',
          '0001ff',
          '002080${'00' * 31}',
        ]);
      },
    );

    test('splits a value over 253 bytes into 255-byte partial frames', () {
      final text = 'mallow ' * 100; // 700 bytes
      final values = _messageValues(
        _frames(
          _note(
            [
              {'name': 'text', 'type': 'string'},
            ],
            {'text': text},
          ),
        ),
      );
      expect(values.map((f) => f.p1), [
        EthereumApdu.p1Eip712Partial,
        EthereumApdu.p1Eip712Partial,
        EthereumApdu.p1Eip712Complete,
      ]);
      expect(values.map((f) => f.data.length), [255, 255, 192]);
      final joined = [for (final f in values) ...f.data];
      expect(joined.take(2), [0x02, 0xbc]); // 700, big-endian
      expect(String.fromCharCodes(joined.skip(2)), text);
    });

    group('refuses what the device cannot review', () {
      void refuses(Map<String, Object?> raw, Matcher message) => expect(
        () => _frames(raw),
        throwsA(
          isA<Eip712LedgerException>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );

      test('a domain-only payload', () {
        refuses({
          'types': {
            'EIP712Domain': [
              {'name': 'chainId', 'type': 'uint256'},
            ],
          },
          'primaryType': 'EIP712Domain',
          'domain': {'chainId': 1},
          'message': <String, Object?>{},
        }, isNotEmpty);
      });

      test('an array of more than 255 items', () {
        refuses(
          _note(
            [
              {'name': 'a', 'type': 'uint8[]'},
            ],
            {'a': List.filled(256, 1)},
          ),
          contains('more items'),
        );
      });

      test('a nested array with a fixed level', () {
        refuses(
          _note(
            [
              {'name': 'a', 'type': 'uint8[2][]'},
            ],
            {
              'a': [
                [1, 2],
              ],
            },
          ),
          contains('uint8[2][]'),
        );
      });
    });

    test('the hashes frame carries path, domain hash and message hash', () {
      final domain = Uint8List.fromList(List.filled(32, 0x11));
      final message = Uint8List.fromList(List.filled(32, 0x22));
      final frame = eip712LedgerHashesFrame(
        _path,
        domainSeparator: domain,
        messageHash: message,
      );
      expect(_line(frame), '0c0000 ${_hex([..._path, ...domain, ...message])}');
      expect(frame.returnsSignature, isTrue);
      expect(
        () => eip712LedgerHashesFrame(
          _path,
          domainSeparator: Uint8List(31),
          messageHash: message,
        ),
        throwsA(isA<Eip712LedgerException>()),
      );
    });
  });

  group('EthereumFrameOperation', () {
    final ack = EthereumApduFrame(
      ins: 0x1A,
      p1: 0x00,
      p2: 0xFF,
      data: Uint8List(0),
    );

    Future<Uint8List> read(EthereumApduFrame frame, List<int> response) =>
        EthereumFrameOperation(
          frame,
        ).read(ByteDataReader()..add(Uint8List.fromList(response)));

    test('writes [CLA, INS, P1, P2, Lc, data]', () async {
      final frame = EthereumApduFrame(
        ins: 0x1C,
        p1: 0x01,
        p2: 0xFF,
        data: Uint8List.fromList([1, 2, 3]),
      );
      final bytes = (await EthereumFrameOperation(
        frame,
      ).write(ByteDataWriter())).single;
      expect(bytes, [0xE0, 0x1C, 0x01, 0xFF, 3, 1, 2, 3]);
    });

    test(
      'a field frame accepts 0x9000 and surfaces any other status',
      () async {
        expect(await read(ack, [0x90, 0x00]), isEmpty);
        await expectLater(
          read(ack, [0x6A, 0x80]),
          throwsA(
            isA<LedgerDeviceException>().having(
              (e) => e.errorCode,
              'code',
              0x6A80,
            ),
          ),
        );
      },
    );

    test('the sign frame returns r‖s‖v with v as 27 or 28', () async {
      final frame = EthereumApduFrame(
        ins: 0x0C,
        p1: 0x00,
        p2: 0x01,
        data: _path,
        returnsSignature: true,
      );
      final r = List.filled(32, 0x01);
      final s = List.filled(32, 0x02);
      expect(await read(frame, [0x01, ...r, ...s, 0x90, 0x00]), [
        ...r,
        ...s,
        28,
      ]);
      expect((await read(frame, [0x1B, ...r, ...s, 0x90, 0x00])).last, 27);
      await expectLater(
        read(frame, [0x69, 0x85]),
        throwsA(
          isA<LedgerDeviceException>().having(
            (e) => e.errorCode,
            'code',
            0x6985,
          ),
        ),
      );
    });
  });
}
