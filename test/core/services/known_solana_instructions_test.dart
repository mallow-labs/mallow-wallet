import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/program_label_service.dart';

const _metadata = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';
const _core = 'CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d';
const _token2022 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
const _associatedToken = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';

String? _name(String program, List<int> data) =>
    ProgramInstructions.builtIn.nameOf(program, Uint8List.fromList(data));

void main() {
  test('public NFT tags identify legacy and versioned operations', () {
    expect(_name(_metadata, [27]), 'ThawDelegatedAccount');
    expect(_name(_metadata, [44, 5, 99]), 'DelegateStakingV1');
    expect(_name(_metadata, [47, 0]), 'UnlockV1');
    expect(_name(_metadata, [49, 0]), 'TransferV1');
    expect(_name(_core, [14]), 'TransferV1');
    expect(_name(_core, [8]), 'ApprovePluginAuthorityV1');
    expect(
      _name('auth9SigNpDKz4sJJ1DfCTuZrZNSAgh9sFD3rboVmgg', [1]),
      'Validate',
    );
  });

  test('Token-2022 extension tags include their nested variants', () {
    expect(_name(_token2022, [26, 1, 99]), 'TransferCheckedWithFee');
    expect(_name(_token2022, [26, 5]), 'SetTransferFee');
    expect(_name(_token2022, [39, 1]), 'UpdateMetadataPointer');
    expect(_name(_token2022, [44, 1]), 'Pause');
    expect(_name(_token2022, [44, 2]), 'Resume');
    expect(
      _name(_token2022, [210, 225, 30, 162, 88, 184, 77, 141]),
      'InitializeTokenMetadata',
    );
    expect(_name(_token2022, [26]), isNull);
    expect(_name(_token2022, [26, 255]), isNull);
  });

  test(
    'associated account, lookup table and stake tags are program scoped',
    () {
      expect(_name(_associatedToken, [0]), 'Create');
      expect(_name(_associatedToken, [1]), 'CreateIdempotent');
      expect(_name(_associatedToken, [2]), 'RecoverNested');
      expect(
        _name('AddressLookupTab1e1111111111111111111111111', [2, 0, 0, 0]),
        'ExtendLookupTable',
      );
      expect(
        _name('Stake11111111111111111111111111111111111111', [2, 0, 0, 0]),
        'DelegateStake',
      );
      expect(_name(_core, [2, 0, 0, 0]), 'AddPluginV1');
      expect(_name('Stake11111111111111111111111111111111111111', [2]), isNull);
    },
  );

  test(
    'public swap and mint discriminators decode without simulation logs',
    () {
      final examples = <(String, List<int>, String)>[
        (
          'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4',
          [229, 23, 203, 151, 122, 227, 173, 42],
          'Route',
        ),
        (
          'whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc',
          [43, 4, 237, 11, 26, 201, 30, 98],
          'SwapV2',
        ),
        (
          'whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc',
          [41, 36, 216, 245, 27, 85, 103, 67],
          'CloseBundledPosition',
        ),
        (
          'CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK',
          [248, 198, 158, 145, 225, 117, 135, 200],
          'Swap',
        ),
        (
          'CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C',
          [143, 190, 90, 218, 196, 30, 51, 222],
          'SwapBaseInput',
        ),
        (
          'BGUMAp9Gq7iTEuizy4pqaxsTyUCBK68MDfK752saRPUY',
          [120, 121, 23, 146, 173, 110, 199, 205],
          'MintV2',
        ),
        (
          'CndyV3LdqHUfDLmE5naZjVN8rBZz4tqhdefbAnjHG3JR',
          [120, 121, 23, 146, 173, 110, 199, 205],
          'MintV2',
        ),
      ];
      for (final (program, data, expected) in examples) {
        expect(_name(program, data), expected, reason: program);
        expect(_name(program, [...data, 99, 99]), expected);
        expect(_name(program, data.sublist(0, 7)), isNull);
        expect(_name('UnknownProgram', data), isNull);
      }
    },
  );

  test('unknown tags do not inherit a catch-all name', () {
    expect(_name(_associatedToken, [255]), isNull);
    expect(_name(_core, [255]), isNull);
    expect(_name(_metadata, [255]), isNull);
    expect(_name(_token2022, [254]), isNull);
    expect(_name(_associatedToken, []), isNull);
  });

  test('published tables cannot rename a public name, even with a longer '
      'tag', () {
    final tables = ProgramInstructions({
      _metadata: {
        '2c': 'PublishedDelegate',
        '2c05': 'PublishedStaking',
        '2c0e': 'PublishedVariant',
        'ff': 'PublishedNew',
      },
    }).beneath(ProgramInstructions.builtIn);
    expect(
      tables.nameOf(_metadata, Uint8List.fromList([44, 5])),
      'DelegateStakingV1',
    );
    expect(
      tables.nameOf(_metadata, Uint8List.fromList([44, 6])),
      'DelegateStandardV1',
    );
    // '2c0e' extends the public '2c' tag, so the public name stands.
    expect(tables.nameOf(_metadata, Uint8List.fromList([44, 14])), 'Delegate');
    // A tag the public tables leave unnamed takes the published name.
    expect(tables.nameOf(_metadata, Uint8List.fromList([255])), 'PublishedNew');
  });
}
