import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/eip712.dart';

String _hex(List<int> bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

const _domainType = [
  {'name': 'name', 'type': 'string'},
  {'name': 'version', 'type': 'string'},
  {'name': 'chainId', 'type': 'uint256'},
  {'name': 'verifyingContract', 'type': 'address'},
];

Map<String, Object?> _mail() => {
  'types': {
    'EIP712Domain': _domainType,
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
    'from': {
      'name': 'Cow',
      'wallet': '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826',
    },
    'to': {
      'name': 'Bob',
      'wallet': '0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB',
    },
    'contents': 'Hello, Bob!',
  },
};

void main() {
  // Expected digests are viem's `hashTypedData` for the same payloads; the
  // Mail digest is also the worked example in the EIP-712 specification.
  // A Keystone is sent JSON and hashes it on the device. The JSON must be
  // rebuilt from the parsed payload (never the website's string) and hash to
  // the reviewed digest — including when the payload omitted EIP712Domain.
  test('json re-serializes to the same digest', () {
    final withoutDomainType = _mail();
    (withoutDomainType['types']! as Map).remove('EIP712Domain');
    for (final payload in [_mail(), withoutDomainType]) {
      final data = Eip712TypedData.parse(jsonEncode(payload));
      final reparsed = Eip712TypedData.parse(data.json);
      expect(reparsed.digest, data.digest);
      expect((jsonDecode(data.json) as Map)['types'], contains('EIP712Domain'));
    }
  });

  test('json writes canonical values, whatever the JSON numbers were', () {
    final data = Eip712TypedData.parse({
      'types': {
        'Order': [
          {'name': 'amount', 'type': 'uint256'},
          {'name': 'delta', 'type': 'int64'},
          {'name': 'big', 'type': 'uint256'},
          {'name': 'salt', 'type': 'bytes32'},
          {'name': 'maker', 'type': 'address'},
          {'name': 'ids', 'type': 'uint8[]'},
        ],
      },
      'primaryType': 'Order',
      'domain': {'name': 'x', 'chainId': 1.0},
      'message': {
        'amount': 1.0,
        'delta': -5,
        'big': '123456789012345678901234567890',
        'salt': '0x${'ab' * 32}',
        'maker': '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC',
        'ids': [1, 2.0, '3'],
      },
    });

    final json = jsonDecode(data.json) as Map;
    expect(json['domain'], {'name': 'x', 'chainId': '1'});
    expect(json['message'], {
      'amount': '1',
      'delta': '-5',
      'big': '123456789012345678901234567890',
      'salt': '0x${'ab' * 32}',
      'maker': '0xcccccccccccccccccccccccccccccccccccccccc',
      'ids': ['1', '2', '3'],
    });
    expect(Eip712TypedData.parse(data.json).digest, data.digest);
  });

  test('hashes the specification example', () {
    final data = Eip712TypedData.parse(jsonEncode(_mail()));
    expect(
      _hex(data.digest),
      '0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2',
    );
    expect(data.chainId, BigInt.one);
    expect(
      data.verifyingContract,
      '0xcccccccccccccccccccccccccccccccccccccccc',
    );
  });

  test('hashes v4 arrays, nested struct arrays, signed ints and bytes', () {
    final data = Eip712TypedData.parse({
      'types': {
        'Person': [
          {'name': 'name', 'type': 'string'},
          {'name': 'wallets', 'type': 'address[]'},
        ],
        'Mail': [
          {'name': 'from', 'type': 'Person'},
          {'name': 'to', 'type': 'Person[]'},
          {'name': 'contents', 'type': 'string'},
          {'name': 'tags', 'type': 'bytes32[2]'},
          {'name': 'delta', 'type': 'int64'},
          {'name': 'payload', 'type': 'bytes'},
          {'name': 'ok', 'type': 'bool'},
          {'name': 'small', 'type': 'bytes4'},
        ],
      },
      'primaryType': 'Mail',
      // No EIP712Domain definition: it is derived from the keys present.
      'domain': {
        'name': 'Ether Mail',
        'version': '1',
        'chainId': 1,
        'verifyingContract': '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC',
        'salt': '0x${'11' * 32}',
      },
      'message': {
        'from': {
          'name': 'Cow',
          'wallets': [
            '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826',
            '0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF',
          ],
        },
        'to': [
          {
            'name': 'Bob',
            'wallets': ['0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB'],
          },
          {'name': 'Alice', 'wallets': <String>[]},
        ],
        'contents': 'Hello, Bob!',
        'tags': ['0x${'aa' * 32}', '0x${'bb' * 32}'],
        'delta': -42,
        'payload': '0xdeadbeef',
        'ok': true,
        'small': '0x01020304',
      },
    });
    expect(
      _hex(data.digest),
      '0x8294055cd9dd6d591d36a85a6e2c96e3d9ec85205362843d57f19d3b6f38bbe7',
    );
  });

  test('hashes an unlimited permit given as a decimal string', () {
    final data = Eip712TypedData.parse({
      'types': {
        'EIP712Domain': _domainType,
        'Permit': [
          {'name': 'owner', 'type': 'address'},
          {'name': 'spender', 'type': 'address'},
          {'name': 'value', 'type': 'uint256'},
          {'name': 'nonce', 'type': 'uint256'},
          {'name': 'deadline', 'type': 'uint256'},
        ],
      },
      'primaryType': 'Permit',
      'domain': {
        'name': 'USD Coin',
        'version': '2',
        'chainId': '0x1',
        'verifyingContract': '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      },
      'message': {
        'owner': '0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826',
        'spender': '0x000000000022D473030F116dDEE9F6B43aC78BA3',
        'value': ((BigInt.one << 256) - BigInt.one).toString(),
        'nonce': '0',
        'deadline': 1893456000,
      },
    });
    expect(
      _hex(data.digest),
      '0xb14d75e4757b83d6c0c7a2a045fce5497f7ff1a017714189ccc4a39d3068c163',
    );
  });

  test('a domain-only payload signs the domain separator alone', () {
    final data = Eip712TypedData.parse({
      'types': {
        'EIP712Domain': [
          {'name': 'name', 'type': 'string'},
          {'name': 'chainId', 'type': 'uint256'},
        ],
      },
      'primaryType': 'EIP712Domain',
      'domain': {'name': 'X', 'chainId': 1},
      'message': <String, Object?>{},
    });
    expect(
      _hex(data.digest),
      '0x5512d42737fcce7fed0f2b3311d2feb7daed9a3ba0219d451c5cc3d848b87ae1',
    );
  });

  test('canonical values are the ones the digest hashed, in field order', () {
    final data = Eip712TypedData.parse({
      'types': {
        'EIP712Domain': [
          {'name': 'chainId', 'type': 'uint256'},
          {'name': 'verifyingContract', 'type': 'address'},
        ],
        'Item': [
          {'name': 'id', 'type': 'uint256'},
          {'name': 'ok', 'type': 'bool'},
        ],
        'Order': [
          {'name': 'delta', 'type': 'int8'},
          {'name': 'items', 'type': 'Item[]'},
          {'name': 'tag', 'type': 'bytes4'},
          {'name': 'note', 'type': 'string'},
        ],
      },
      'primaryType': 'Order',
      'domain': {
        'verifyingContract': '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC',
        'chainId': '0x89',
      },
      'message': {
        'note': 'hi',
        'tag': '0x01020304',
        'items': [
          {'ok': true, 'id': '7'},
        ],
        'delta': -3,
      },
    });
    expect(data.canonicalDomain.keys, ['chainId', 'verifyingContract']);
    expect(data.canonicalDomain['chainId'], BigInt.from(137));
    expect(data.canonicalDomain['verifyingContract'], List.filled(20, 0xcc));
    final message = data.canonicalMessage;
    expect(message.keys, ['delta', 'items', 'tag', 'note']);
    expect(message['delta'], BigInt.from(-3));
    expect(message['items'], [
      {'id': BigInt.from(7), 'ok': true},
    ]);
    expect((message['items']! as List).single.keys, ['id', 'ok']);
    expect(message['tag'], [1, 2, 3, 4]);
    expect(message['note'], 'hi');
  });

  test('a domain-only payload has an empty canonical message', () {
    final data = Eip712TypedData.parse({
      'types': {
        'EIP712Domain': [
          {'name': 'chainId', 'type': 'uint256'},
        ],
      },
      'primaryType': 'EIP712Domain',
      'domain': {'chainId': 1},
      'message': <String, Object?>{},
    });
    expect(data.canonicalMessage, isEmpty);
  });

  group('refuses', () {
    void refuses(void Function(Map<String, Object?> data) mutate) {
      final data = _mail();
      mutate(data);
      expect(
        () => Eip712TypedData.parse(data),
        throwsA(isA<Eip712Exception>()),
      );
    }

    test('a missing field', () {
      refuses((d) => (d['message']! as Map).remove('contents'));
    });

    test('an undeclared field, which would be shown but not signed', () {
      refuses((d) => (d['message']! as Map)['extra'] = 'hidden');
    });

    test('an undeclared domain field', () {
      refuses((d) => (d['domain']! as Map)['salt'] = '0x${'00' * 32}');
    });

    test('an unknown type', () {
      refuses(
        (d) => ((d['types']! as Map)['Mail'] as List).add({
          'name': 'x',
          'type': 'Unknown',
        }),
      );
    });

    test('an address that is not 20 bytes', () {
      refuses(
        (d) => ((d['message']! as Map)['from'] as Map)['wallet'] = '0x1234',
      );
    });

    test('an unsafe JSON number', () {
      refuses((d) => (d['domain']! as Map)['chainId'] = 9007199254740993);
    });

    test('an integer outside its declared width', () {
      final data = {
        'types': {
          'T': [
            {'name': 'v', 'type': 'uint8'},
          ],
        },
        'primaryType': 'T',
        'domain': <String, Object?>{},
        'message': {'v': 256},
      };
      expect(
        () => Eip712TypedData.parse(data),
        throwsA(isA<Eip712Exception>()),
      );
    });

    test('a non-standard domain field type', () {
      refuses(
        (d) => (d['types']! as Map)['EIP712Domain'] = [
          {'name': 'name', 'type': 'bytes32'},
          {'name': 'version', 'type': 'string'},
          {'name': 'chainId', 'type': 'uint256'},
          {'name': 'verifyingContract', 'type': 'address'},
        ],
      );
    });
  });
}
