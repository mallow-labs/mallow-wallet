import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:mallow_wallet/core/models/simulation_review.dart'
    show kUntracedDelegations;
import 'package:mallow_wallet/core/services/program_label_service.dart';
import 'package:mallow_wallet/features/browser/services/solana_asset_instructions.dart';
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
                parsed: null,
              ),
              (
                program: solanaSystemProgram,
                instruction: null,
                name: 'CreateAccount',
                depth: 2,
                parsed: null,
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

  group('solanaDelegationOrigins', () {
    const app = 'App1111111111111111111111111111111111111111';
    final keys = [
      'wallet',
      'token-account',
      'mint',
      'delegate',
      solanaTokenProgram,
      app,
      _tokenMetadata,
    ];
    CompiledInstruction approve({bool checked = false}) => CompiledInstruction(
      programIdIndex: 4,
      accountKeyIndexes: checked ? const [1, 2, 3, 0] : const [1, 3, 0],
      data: ByteArray([
        checked ? 13 : 4,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        if (checked) 0,
      ]),
    );
    CompiledInstruction call(int program) => CompiledInstruction(
      programIdIndex: program,
      accountKeyIndexes: const [1, 3, 0],
      data: ByteArray([9]),
    );

    test('a direct approval names the token program', () {
      expect(solanaDelegationOrigins([approve()], keys, const {}), {
        'token-account': {solanaTokenProgram},
      });
    });

    test('an approval reached through other programs names the top-level '
        'one', () {
      expect(
        solanaDelegationOrigins(
          [call(5)],
          keys,
          {
            0: [
              (
                program: _tokenMetadata,
                instruction: call(6),
                name: null,
                depth: 2,
                parsed: null,
              ),
              (
                program: solanaTokenProgram,
                instruction: approve(checked: true),
                name: null,
                depth: 3,
                parsed: null,
              ),
            ],
          },
        ),
        {
          'token-account': {app},
        },
      );
    });

    test('an approval the node parsed joins every traced account', () {
      expect(
        solanaDelegationOrigins(
          [call(5), call(6)],
          keys,
          {
            0: [
              (
                program: solanaTokenProgram,
                instruction: approve(),
                name: null,
                depth: 2,
                parsed: null,
              ),
            ],
            1: [
              (
                program: solanaTokenProgram,
                instruction: null,
                name: 'Approve',
                depth: 2,
                parsed: null,
              ),
            ],
          },
        ),
        {
          'token-account': {app, _tokenMetadata},
          // Kept apart too, for the other transactions of a batch.
          kUntracedDelegations: {_tokenMetadata},
        },
      );
    });

    test('an approval the node parsed, as a real node reports every token '
        'call a program makes, is traced by the account it names', () {
      final approval = parseSimulationInnerInstruction({
        'parsed': {
          'info': {
            'amount': '1',
            'delegate': 'delegate',
            'owner': 'wallet',
            'source': 'token-account',
          },
          'type': 'approve',
        },
        'program': 'spl-token',
        'programId': solanaTokenProgram,
        'stackHeight': 2,
      }, keys)!;
      expect(approval.instruction, isNull);
      expect(approval.name, 'Approve');
      expect(
        solanaDelegationOrigins(
          [call(5)],
          keys,
          {
            0: [approval],
          },
        ),
        {
          'token-account': {app},
        },
      );
      // Checked, and reached through Token Metadata from the website's own
      // instruction: the origin is the program the website called.
      final checked = parseSimulationInnerInstruction({
        'parsed': {
          'info': {
            'delegate': 'delegate',
            'mint': 'mint',
            'owner': 'wallet',
            'source': 'token-account',
            'tokenAmount': {'amount': '1', 'decimals': 0},
          },
          'type': 'approveChecked',
        },
        'programId': solanaTokenProgram,
        'stackHeight': 3,
      }, keys)!;
      expect(
        solanaDelegationOrigins(
          [call(6)],
          keys,
          {
            0: [checked],
          },
        ),
        {
          'token-account': {_tokenMetadata},
        },
      );
    });

    test('a parsed approval that names no account stays untraced', () {
      final nameless = parseSimulationInnerInstruction({
        'parsed': {
          'info': {'delegate': 'delegate'},
          'type': 'approve',
        },
        'programId': solanaTokenProgram,
        'stackHeight': 2,
      }, keys)!;
      // On its own it traces no account, so the account's delegation reads
      // as one nobody vouched for.
      expect(
        solanaDelegationOrigins(
          [call(5)],
          keys,
          {
            0: [nameless],
          },
        ),
        {
          kUntracedDelegations: {app},
        },
      );
    });

    test('other token calls are not approvals', () {
      final transfer = CompiledInstruction(
        programIdIndex: 4,
        accountKeyIndexes: const [1, 3, 0],
        data: ByteArray([3, 1, 0, 0, 0, 0, 0, 0, 0]),
      );
      expect(solanaDelegationOrigins([transfer], keys, const {}), isEmpty);
    });

    test('a token instruction with no name, and a batch of them, may hide '
        'an approval: each counts against every account', () {
      CompiledInstruction token2022(List<int> data) => CompiledInstruction(
        programIdIndex: 7,
        accountKeyIndexes: const [1, 3, 0],
        data: ByteArray(data),
      );
      final keys2022 = [...keys, solanaToken2022Program];
      for (final data in [
        // A batch runs other token instructions inside itself.
        const [255, 1, 2, 3],
        const [200, 1, 2, 3],
      ]) {
        expect(
          solanaDelegationOrigins(
            [call(5), token2022(data)],
            keys2022,
            {
              0: [
                (
                  program: solanaTokenProgram,
                  instruction: approve(),
                  name: null,
                  depth: 2,
                  parsed: null,
                ),
              ],
            },
          ),
          {
            'token-account': {app, solanaToken2022Program},
            kUntracedDelegations: {solanaToken2022Program},
          },
          reason: '$data',
        );
      }
      // One that is named and sets no delegate does not.
      expect(
        solanaDelegationOrigins(
          [
            token2022(const [44, 1]),
          ],
          keys2022,
          const {},
        ),
        isEmpty,
      );
    });

    group('a change of authority is traced like an approval', () {
      final holder = List.filled(32, 7);
      final keys = [
        'wallet',
        'account',
        'other',
        'sysvar',
        solanaTokenProgram,
        app,
        solanaSystemProgram,
        solanaStakeProgram,
        solanaCoreProgram,
        solanaUpgradeableLoaderProgram,
        solanaNameServiceProgram,
      ];
      // An instruction of the program at key index [program] over
      // [accounts], made by the application at index 5.
      Map<String, Set<String>> traced(
        int program,
        List<int> accounts,
        List<int> data,
      ) => solanaDelegationOrigins(
        [
          CompiledInstruction(
            programIdIndex: 5,
            accountKeyIndexes: const [0],
            data: ByteArray([9]),
          ),
        ],
        keys,
        {
          0: [
            (
              program: keys[program],
              instruction: CompiledInstruction(
                programIdIndex: program,
                accountKeyIndexes: accounts,
                data: ByteArray(data),
              ),
              name: null,
              depth: 2,
              parsed: null,
            ),
          ],
        },
      );
      const byApp = {
        'account': {app},
      };

      test('a token account\'s authority, under the token account', () {
        expect(traced(4, const [1, 0], [6, 2, 1, ...holder]), byApp);
        // Called by the website itself, it names the token program.
        expect(
          solanaDelegationOrigins(
            [
              CompiledInstruction(
                programIdIndex: 4,
                accountKeyIndexes: const [1, 0],
                data: ByteArray([6, 2, 1, ...holder]),
              ),
            ],
            keys,
            const {},
          ),
          {
            'account': {solanaTokenProgram},
          },
        );
      });

      test('an account assigned to a program, and a nonce account handed '
          'on, under the account', () {
        for (final data in [
          // Assign, AuthorizeNonceAccount.
          [1, 0, 0, 0, ...holder],
          [7, 0, 0, 0, ...holder],
          // AllocateWithSeed and AssignWithSeed: only the tag is read here.
          [9, 0, 0, 0],
          [10, 0, 0, 0],
        ]) {
          expect(traced(6, const [1, 0], data), byApp, reason: '$data');
        }
        // A transfer and a new account hand nothing on.
        for (final data in [
          [2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0],
          [0, 0, 0, 0],
        ]) {
          expect(traced(6, const [1, 0], data), isEmpty, reason: '$data');
        }
      });

      test('a stake authority, an upgrade authority and a name, under the '
          'account that changes hands', () {
        // Stake Authorize: [stake, clock, authority]; new authority, kind.
        expect(
          traced(7, const [1, 3, 0], [1, 0, 0, 0, ...holder, 1, 0, 0, 0]),
          byApp,
        );
        // Loader SetAuthority: [account, current authority, new authority].
        expect(traced(9, const [1, 0, 2], const [4, 0, 0, 0]), byApp);
        // Name Service Transfer: [name account, owner]; new owner.
        expect(traced(10, const [1, 0], [2, ...holder]), byApp);
        // A stake instruction that hands nothing on traces nothing.
        expect(traced(7, const [1, 3, 0], const [5, 0, 0, 0]), isEmpty);
      });

      test('a Core NFT\'s delegate, under its asset id', () {
        // ApprovePluginAuthorityV1 of the transfer delegate, to an address:
        // [asset, collection, payer, authority].
        expect(traced(8, const [1, 8, 0, 0], [0x08, 3, 3, ...holder]), byApp);
        // A plugin that stays with the owner is no delegation.
        expect(traced(8, const [1, 8, 0, 0], const [0x08, 3, 1]), isEmpty);
        // One that could not be read may be one, on an account this cannot
        // name: it counts against every account.
        expect(traced(8, const [1, 8, 0, 0], const [0x1f, 1, 2]), {
          kUntracedDelegations: {app},
        });
      });

      test('one the node parsed, with no accounts to read, joins every '
          'traced account', () {
        SolanaInnerInstruction parsed(String program, String type) =>
            parseSimulationInnerInstruction({
              'parsed': {
                'info': {'account': 'account'},
                'type': type,
              },
              'programId': program,
              'stackHeight': 2,
            }, keys)!;
        for (final (program, type) in [
          (solanaTokenProgram, 'setAuthority'),
          (solanaSystemProgram, 'assign'),
          (solanaSystemProgram, 'assignWithSeed'),
          (solanaSystemProgram, 'authorizeNonce'),
          (solanaStakeProgram, 'authorize'),
          (solanaUpgradeableLoaderProgram, 'setAuthority'),
        ]) {
          expect(
            solanaDelegationOrigins(
              [
                // The application approves, then a second program makes
                // the call the node parsed.
                CompiledInstruction(
                  programIdIndex: 5,
                  accountKeyIndexes: const [0],
                  data: ByteArray([9]),
                ),
                CompiledInstruction(
                  programIdIndex: 2,
                  accountKeyIndexes: const [0],
                  data: ByteArray([9]),
                ),
              ],
              keys,
              {
                0: [
                  (
                    program: solanaTokenProgram,
                    instruction: CompiledInstruction(
                      programIdIndex: 4,
                      accountKeyIndexes: const [1, 3, 0],
                      data: ByteArray([4, 1, 0, 0, 0, 0, 0, 0, 0]),
                    ),
                    name: null,
                    depth: 2,
                    parsed: null,
                  ),
                ],
                1: [parsed(program, type)],
              },
            ),
            {
              'account': {app, 'other'},
              kUntracedDelegations: {'other'},
            },
            reason: '$program $type',
          );
        }
        // A parsed transfer is none of these.
        expect(
          solanaDelegationOrigins(
            [
              CompiledInstruction(
                programIdIndex: 2,
                accountKeyIndexes: const [0],
                data: ByteArray([9]),
              ),
            ],
            keys,
            {
              0: [parsed(solanaSystemProgram, 'transfer')],
            },
          ),
          isEmpty,
        );
      });
    });
  });
}
