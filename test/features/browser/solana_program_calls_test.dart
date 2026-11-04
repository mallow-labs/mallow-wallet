import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:mallow_wallet/core/services/program_label_service.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';

const _tokenMetadata = 'metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s';
const _computeBudget = 'ComputeBudget111111111111111111111111111111';

/// The slice of the published tables these tests read.
final _tables = ProgramInstructions({
  solanaSystemProgram: {'02000000': 'Transfer'},
  _computeBudget: {'02': 'SetComputeUnitLimit'},
  solanaTokenProgram: {
    '05': 'Revoke',
    '0b': 'ThawAccount',
    '0c': 'TransferChecked',
  },
  _tokenMetadata: {'1b': 'ThawDelegatedAccount'},
});

Uint8List _bytes(List<int> data) => Uint8List.fromList(data);

SolanaInvocation _call(String program, List<int> data, [int? depth = 1]) =>
    (program: program, data: _bytes(data), name: null, depth: depth);

void main() {
  test('call data names the calls the logs leave unnamed', () {
    final calls = parseSimulationProgramCalls(
      [
        'Program Staking invoke [1]',
        'Program log: Instruction: Unstake',
        'Program $_tokenMetadata invoke [2]',
        'Program log: IX: Thaw Delegated Account',
        'Program $solanaTokenProgram invoke [3]',
        'Program log: Instruction: ThawAccount',
        'Program $solanaTokenProgram success',
        'Program $_tokenMetadata success',
        'Program $solanaTokenProgram invoke [2]',
        'Program log: Instruction: Revoke',
        'Program $solanaTokenProgram success',
        'Program Staking success',
      ],
      invocations: [
        // Compute budget instructions may run without a log line.
        _call(_computeBudget, [2, 0, 0, 0, 0]),
        _call('Staking', [9, 9, 9, 9, 9, 9, 9, 9]),
        _call(_tokenMetadata, [27], 2),
        _call(solanaTokenProgram, [11], 3),
        _call(solanaTokenProgram, [5], 2),
      ],
      instructions: _tables,
    );
    expect(calls.map((c) => (c.program, c.instruction)).toList(), [
      (_computeBudget, 'SetComputeUnitLimit'),
      ('Staking', 'Unstake'),
      (_tokenMetadata, 'ThawDelegatedAccount'),
      (solanaTokenProgram, 'ThawAccount'),
      (solanaTokenProgram, 'Revoke'),
    ]);
  });

  test('silent repeated calls retain their data names and order', () {
    final calls = parseSimulationProgramCalls(
      [
        'Program $solanaTokenProgram invoke [1]',
        'Program log: Instruction: TransferChecked',
        'Program $solanaTokenProgram success',
      ],
      invocations: [
        _call(_computeBudget, [2, 0, 0, 0, 0]),
        _call(solanaTokenProgram, [12, 1]),
        _call(solanaTokenProgram, [5]),
        _call(solanaTokenProgram, [11]),
      ],
      instructions: _tables,
    );
    expect(calls.map((c) => c.instruction), [
      'SetComputeUnitLimit',
      'TransferChecked',
      'Revoke',
      'ThawAccount',
    ]);
  });

  test('core instructions are named without a published list', () {
    final calls = solanaProgramCalls([
      _call(_computeBudget, [2, 0, 0, 0, 0]),
      _call(_computeBudget, [3, 1, 0, 0, 0, 0, 0, 0, 0]),
      _call(solanaTokenProgram, [12, 1]),
      _call(solanaToken2022Program, [17]),
      _call(solanaSystemProgram, [2, 0, 0, 0, 1]),
      _call('Unknown', [12]),
      _call(solanaTokenProgram, [255]),
      _call(_computeBudget, []),
      _call(solanaSystemProgram, [2]),
    ]);
    expect(calls.map((c) => c.instruction), [
      'SetComputeUnitLimit',
      'SetComputeUnitPrice',
      'TransferChecked',
      'SyncNative',
      'Transfer',
      null,
      null,
      null,
      null,
    ]);
  });

  test('a program\'s own log line wins over its decoded data', () {
    final calls = parseSimulationProgramCalls(
      [
        'Program $solanaTokenProgram invoke [1]',
        'Program log: Instruction: TransferChecked',
        'Program $solanaTokenProgram success',
        'Program $solanaSystemProgram invoke [1]',
        'Program $solanaSystemProgram success',
      ],
      invocations: [
        _call(solanaTokenProgram, [5]),
        _call(solanaSystemProgram, [2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]),
      ],
      instructions: _tables,
    );
    expect(calls.map((c) => c.instruction), ['TransferChecked', 'Transfer']);
  });

  test('a logged name that is not a bare identifier names nothing', () {
    final calls = parseSimulationProgramCalls(
      [
        'Program Staking invoke [1]',
        // A right-to-left override, a look-alike letter, a sentence, and a
        // name far past any real identifier.
        'Program log: Instruction: Refund\u202Edesu',
        'Program log: Instruction: Tr\u0430nsfer',
        'Program log: Instruction: Refund ✓ safe',
        'Program log: Instruction: ${'A' * 65}',
        'Program Staking success',
        'Program $solanaTokenProgram invoke [1]',
        'Program log: Instruction: Refund\u202Edesu',
        'Program $solanaTokenProgram success',
      ],
      invocations: [
        _call('Staking', [9]),
        _call(solanaTokenProgram, [12, 1]),
      ],
      instructions: _tables,
    );
    // No extra rows, and the call keeps the name its data gives it.
    expect(calls.map((c) => (c.program, c.instruction)).toList(), [
      ('Staking', null),
      (solanaTokenProgram, 'TransferChecked'),
    ]);
  });

  test('without logs, top-level calls are named from their data alone', () {
    final calls = solanaProgramCalls([
      _call(solanaTokenProgram, [12, 1]),
      _call('Unknown', [12]),
    ], _tables);
    expect(calls.map((c) => c.instruction), ['TransferChecked', null]);
  });

  group('simulation inner instructions', () {
    const ata = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';
    const payer = '3JF3sEqM796hk5WFqA6EtmEwJQ9quALszsfJyvXNQKy3';
    const keys = [payer, ata, solanaTokenProgram, solanaSystemProgram];

    test('the parsed form carries the node\'s name and no data', () {
      final call = parseSimulationInnerInstruction({
        'parsed': {
          'info': {'lamports': 1488440},
          'type': 'createAccount',
        },
        'program': 'system',
        'programId': solanaSystemProgram,
        'stackHeight': 2,
      }, keys)!;
      expect(call.program, solanaSystemProgram);
      expect(call.name, 'CreateAccount');
      expect(call.instruction, isNull);
      expect(call.depth, 2);
    });

    test('a parsed type that is not a bare identifier names nothing', () {
      final memo = parseSimulationInnerInstruction({
        'parsed': 'gm',
        'program': 'spl-memo',
        'programId': 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr',
        'stackHeight': 2,
      }, keys)!;
      expect(memo.name, isNull);
      final spoof = parseSimulationInnerInstruction({
        'parsed': {'type': 'transfer \u202E'},
        'programId': solanaTokenProgram,
      }, keys)!;
      expect(spoof.name, isNull);
    });

    test('the partially decoded form maps addresses to key indexes', () {
      final call = parseSimulationInnerInstruction({
        'accounts': [payer, solanaTokenProgram],
        'data': base58encode([1]),
        'programId': ata,
        'stackHeight': 3,
      }, keys)!;
      expect(call.instruction!.programIdIndex, 1);
      expect(call.instruction!.accountKeyIndexes, [0, 2]);
      expect(call.depth, 3);
      // An address outside the keys leaves it named but not decodable.
      final outside = parseSimulationInnerInstruction({
        'accounts': ['Elsewhere1111111111111111111111111111111111'],
        'data': base58encode([1]),
        'programId': ata,
      }, keys)!;
      expect(outside.instruction, isNull);
    });

    test('the compiled form is still read, and bad indexes dropped', () {
      final call = parseSimulationInnerInstruction({
        'programIdIndex': 2,
        'accounts': [0],
        'data': base58encode([12, 1]),
        'stackHeight': 2,
      }, keys)!;
      expect(call.program, solanaTokenProgram);
      expect(call.instruction!.data.toList(), [12, 1]);
      expect(
        parseSimulationInnerInstruction({
          'programIdIndex': 9,
          'accounts': <int>[],
          'data': '',
        }, keys),
        isNull,
      );
      expect(parseSimulationInnerInstruction({'data': 'x'}, keys), isNull);
    });

    test('silent token and system CPIs take the node\'s names', () {
      // The Token Program no longer logs its instruction names, and System
      // never did, so a nested call is named only by what the node parsed.
      final calls = parseSimulationProgramCalls(
        [
          'Program $ata invoke [1]',
          'Program log: CreateIdempotent',
          'Program $solanaTokenProgram invoke [2]',
          'Program $solanaTokenProgram success',
          'Program $solanaSystemProgram invoke [2]',
          'Program $solanaSystemProgram success',
          'Program $ata success',
        ],
        invocations: solanaInvocations(
          [
            CompiledInstruction(
              programIdIndex: 1,
              accountKeyIndexes: const [0],
              data: ByteArray([1]),
            ),
          ],
          keys,
          {
            0: [
              (
                program: solanaTokenProgram,
                instruction: null,
                name: 'GetAccountDataSize',
                depth: 2,
              ),
              (
                program: solanaSystemProgram,
                instruction: null,
                name: 'CreateAccount',
                depth: 2,
              ),
            ],
          },
        ),
      );
      expect(calls.map((c) => (c.program, c.instruction)).toList(), [
        (ata, 'CreateIdempotent'),
        (solanaTokenProgram, 'GetAccountDataSize'),
        (solanaSystemProgram, 'CreateAccount'),
      ]);
    });
  });
}
