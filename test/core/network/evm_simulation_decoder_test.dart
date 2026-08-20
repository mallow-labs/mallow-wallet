import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/network/evm_simulation_decoder.dart';
import 'package:mallow_wallet/core/network/evm_transfer_core.dart';

/// These tests guard the EVM transfer safety gate, not a parser.
///
/// The gate exists because the *backend* builds our EVM calldata
/// (`POST /v2/tx/assets/transfer`). If that calldata were ever wrong — a bug, a
/// compromise — the simulation is the last thing standing between the user and a
/// signature that moves the wrong asset or hands an attacker an approval. The
/// decoder feeds that gate. A decoding hole is therefore a security hole, which
/// is why the malformed-input cases assert a *throw* rather than a skip.
void main() {
  const owner = '0x1111111111111111111111111111111111111111';
  const recipient = '0x2222222222222222222222222222222222222222';
  const token = '0x3333333333333333333333333333333333333333';
  const attacker = '0x4444444444444444444444444444444444444444';
  const zero = '0x0000000000000000000000000000000000000000';

  const transferTopic =
      '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
  const approvalTopic =
      '0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925';
  const approvalForAllTopic =
      '0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31';
  const transferSingleTopic =
      '0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62';
  const transferBatchTopic =
      '0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb';
  const nativeEmitter = '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

  /// A 20-byte address left-padded into a 32-byte indexed topic.
  String addrTopic(String address) =>
      '0x${address.substring(2).padLeft(64, '0')}';

  /// An integer as one 32-byte ABI word (no `0x`).
  String word(int value) => value.toRadixString(16).padLeft(64, '0');

  Map<String, dynamic> log({
    required String emitter,
    required List<String> topics,
    String data = '0x',
  }) => {'address': emitter, 'topics': topics, 'data': data};

  /// A successful `eth_simulateV1` result carrying [logs].
  Object okResult(List<Map<String, dynamic>> logs) => [
    {
      'calls': [
        {
          'status': '0x1',
          'returnData': '0x',
          'gasUsed': '0x5208',
          'logs': logs,
        },
      ],
    },
  ];

  group('decodeSimulateV1 — asset movements', () {
    test('decodes an ERC-20 transfer with the amount from data', () {
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [transferTopic, addrTopic(owner), addrTopic(recipient)],
            data: '0x${word(1500)}',
          ),
        ]),
      );

      expect(result.error, isNull);
      expect(result.changes, hasLength(1));
      final change = result.changes.single;
      expect(change.assetType, 'ERC20');
      expect(change.changeType, 'TRANSFER');
      expect(change.from, owner);
      expect(change.to, recipient);
      expect(change.contractAddress, token);
      expect(change.rawAmount, '1500');
    });

    test('decodes an ERC-721 transfer, reading tokenId from the 4th topic', () {
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              transferTopic,
              addrTopic(owner),
              addrTopic(recipient),
              '0x${word(42)}',
            ],
          ),
        ]),
      );

      final change = result.changes.single;
      expect(change.assetType, 'ERC721');
      expect(change.tokenId, '42');
      expect(change.contractAddress, token);
      // ERC-721 moves exactly one token, so there is no amount to report.
      expect(change.rawAmount, isNull);
    });

    test('decodes an ERC-1155 TransferSingle id and quantity', () {
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              transferSingleTopic,
              addrTopic(recipient), // operator — deliberately not the owner
              addrTopic(owner),
              addrTopic(recipient),
            ],
            data: '0x${word(7)}${word(3)}',
          ),
        ]),
      );

      final change = result.changes.single;
      expect(change.assetType, 'ERC1155');
      // `from` must come from topic 2, not the operator in topic 1 — the gate
      // only inspects changes leaving the owner.
      expect(change.from, owner);
      expect(change.to, recipient);
      expect(change.tokenId, '7');
      expect(change.rawAmount, '3');
    });

    test('decodes a native ETH move from the traceTransfers pseudo-emitter', () {
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: nativeEmitter,
            topics: [transferTopic, addrTopic(owner), addrTopic(recipient)],
            data: '0x${word(1000000000000000000)}',
          ),
        ]),
      );

      final change = result.changes.single;
      expect(change.assetType, 'NATIVE');
      expect(change.rawAmount, '1000000000000000000');
      // Native value has no token contract; the send gate skips the contract
      // check for native and would otherwise compare against a pseudo-address.
      expect(change.contractAddress, isNull);
    });

    test('decodes every pair of an ERC-1155 TransferBatch', () {
      // ABI head: offset(ids)=0x40, offset(values)=0xa0, then each array's
      // length followed by its elements.
      final data =
          '0x${word(64)}${word(160)}'
          '${word(2)}${word(11)}${word(22)}'
          '${word(2)}${word(1)}${word(5)}';

      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              transferBatchTopic,
              addrTopic(owner),
              addrTopic(owner),
              addrTopic(recipient),
            ],
            data: data,
          ),
        ]),
      );

      expect(result.changes, hasLength(2));
      expect(result.changes[0].tokenId, '11');
      expect(result.changes[0].rawAmount, '1');
      expect(result.changes[1].tokenId, '22');
      expect(result.changes[1].rawAmount, '5');
      expect(result.changes.every((c) => c.assetType == 'ERC1155'), isTrue);
    });

    test('throws on a non-Transfer log from the native trace emitter', () {
      // Nothing is deployed at the pseudo-address: every log there is the node's
      // synthetic report of ETH moving. A shape we cannot read is therefore an
      // invisible native outflow — skipping it would let a token send whose own
      // change matches carry the wallet's ETH out unseen.
      expect(
        () => decodeSimulateV1(
          okResult([
            log(
              emitter: nativeEmitter,
              topics: [
                '0x1234567890123456789012345678901234567890123456789012345678901234',
                addrTopic(owner),
                addrTopic(attacker),
              ],
              data: '0x${word(1000000000000000000)}',
            ),
          ]),
        ),
        throwsA(isA<EthereumRpcException>()),
      );
    });

    test('ignores events that are not asset movements', () {
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              '0x1234567890123456789012345678901234567890123456789012345678901234',
              addrTopic(owner),
            ],
            data: '0x${word(1)}',
          ),
        ]),
      );

      expect(result.changes, isEmpty);
    });
  });

  group('decodeSimulateV1 — approvals', () {
    test('reports an ERC-20 approval with owner and spender', () {
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [approvalTopic, addrTopic(owner), addrTopic(attacker)],
            data: '0x${word(999)}',
          ),
        ]),
      );

      final change = result.changes.single;
      expect(change.changeType, 'APPROVE');
      expect(change.isApprove, isTrue);
      expect(change.from, owner);
      expect(change.to, attacker);
    });

    test('reports an ERC-721 single-token approval (4 topics)', () {
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              approvalTopic,
              addrTopic(owner),
              addrTopic(attacker),
              '0x${word(42)}',
            ],
          ),
        ]),
      );

      expect(result.changes.single.isApprove, isTrue);
      expect(result.changes.single.to, attacker);
    });

    test('reports an ApprovalForAll grant against the operator', () {
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              approvalForAllTopic,
              addrTopic(owner),
              addrTopic(attacker),
            ],
            data: '0x${word(1)}',
          ),
        ]),
      );

      final change = result.changes.single;
      expect(change.isApprove, isTrue);
      expect(change.to, attacker);
    });

    test('normalises an ApprovalForAll revocation to the zero address', () {
      // `approved: false` removes rights rather than granting them. Reporting it
      // as a zero-address spender lets the gate's existing revocation carve-out
      // treat it as harmless instead of blocking a safe transfer.
      final result = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              approvalForAllTopic,
              addrTopic(owner),
              addrTopic(attacker),
            ],
            data: '0x${word(0)}',
          ),
        ]),
      );

      expect(result.changes.single.to, zero);
    });
  });

  group('decodeSimulateV1 — reverts and malformed responses', () {
    test('surfaces a revert as an error the gate can block on', () {
      final result = decodeSimulateV1([
        {
          'calls': [
            {
              'status': '0x0',
              'error': {
                'code': 3,
                'message': 'execution reverted: ERC20: burn',
              },
              'logs': <Map<String, dynamic>>[],
            },
          ],
        },
      ]);

      expect(result.error, contains('execution reverted'));
      expect(result.changes, isEmpty);
    });

    test('still reports an error when a revert carries no reason', () {
      // Providers disagree on the failure shape. A null reason would leave the
      // gate reporting "would fail on-chain: null" — block with a real message.
      final result = decodeSimulateV1([
        {
          'calls': [
            {'status': '0x0', 'logs': <Map<String, dynamic>>[]},
          ],
        },
      ]);

      expect(result.error, isNotNull);
      expect(result.error, isNotEmpty);
    });

    test('throws when the response carries no call result', () {
      // Fail closed: an unreadable response must never be mistaken for "no
      // unexpected movements".
      expect(
        () => decodeSimulateV1(null),
        throwsA(isA<EthereumRpcException>()),
      );
      expect(
        () => decodeSimulateV1(<Object>[]),
        throwsA(isA<EthereumRpcException>()),
      );
      expect(
        () => decodeSimulateV1([
          {'calls': <Object>[]},
        ]),
        throwsA(isA<EthereumRpcException>()),
      );
    });

    test('throws when a Transfer log has an unexpected topic count', () {
      expect(
        () => decodeSimulateV1(
          okResult([
            log(
              emitter: token,
              topics: [transferTopic, addrTopic(owner)],
              data: '0x${word(1)}',
            ),
          ]),
        ),
        throwsA(isA<EthereumRpcException>()),
      );
    });

    test('throws when log data is truncated', () {
      expect(
        () => decodeSimulateV1(
          okResult([
            log(
              emitter: token,
              topics: [transferTopic, addrTopic(owner), addrTopic(recipient)],
              data: '0xdeadbeef',
            ),
          ]),
        ),
        throwsA(isA<EthereumRpcException>()),
      );
    });

    test('throws when a TransferBatch has mismatched ids and values', () {
      final data =
          '0x${word(64)}${word(160)}'
          '${word(2)}${word(11)}${word(22)}'
          '${word(1)}${word(1)}';

      expect(
        () => decodeSimulateV1(
          okResult([
            log(
              emitter: token,
              topics: [
                transferBatchTopic,
                addrTopic(owner),
                addrTopic(owner),
                addrTopic(recipient),
              ],
              data: data,
            ),
          ]),
        ),
        throwsA(isA<EthereumRpcException>()),
      );
    });
  });

  group('gate behaviour on decoded logs', () {
    /// The ERC-20 send gate's predicates, mirroring
    /// `EthereumTransferService._assertSimulation`.
    void runErc20Gate(EvmSimulationResult sim, {required BigInt amount}) =>
        assertEvmSimulation(
          sim,
          source: owner,
          // Matches on the contract, not the asset label — the label is a guess
          // for a four-topic Transfer (see the legacy-token test below).
          isIntendedAsset: (c) =>
              c.contractAddress == token &&
              (c.assetType == 'ERC20' ||
                  (c.assetType == 'ERC721' && !c.isApprove)),
          assertAmount: (c) {
            if (BigInt.tryParse(c.rawAmount ?? c.tokenId ?? '') != amount) {
              throw const EvmTransferBlockedException('amount mismatch');
            }
          },
          noMovementMessage: 'no movement',
        );

    /// The NFT gate's predicates, mirroring
    /// `EvmArtworkTransferService._assertSimulation` for tokenId 42.
    void runNftGate(EvmSimulationResult sim) => assertEvmSimulation(
      sim,
      source: owner,
      isIntendedAsset: (c) => c.contractAddress == token && c.tokenId == '42',
      assertAmount: (_) {},
      noMovementMessage: 'no movement',
    );

    test('a clean ERC-20 send passes', () {
      final sim = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [transferTopic, addrTopic(owner), addrTopic(recipient)],
            data: '0x${word(1500)}',
          ),
        ]),
      );

      expect(
        () => runErc20Gate(sim, amount: BigInt.from(1500)),
        returnsNormally,
      );
    });

    test('a legacy ERC-20 that indexes `value` still passes', () {
      // Some pre-standard ERC-20s declare `uint256 indexed value`, so their
      // Transfer carries four topics — byte-identical to an ERC-721's. Nothing
      // in the log says which it is. Classifying by topic count alone and then
      // demanding the ERC20 label blocks *every* send of such a token, so the
      // gate keys on the contract and reads the amount from `tokenId`.
      final sim = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              transferTopic,
              addrTopic(owner),
              addrTopic(recipient),
              '0x${word(1500)}',
            ],
          ),
        ]),
      );

      expect(
        () => runErc20Gate(sim, amount: BigInt.from(1500)),
        returnsNormally,
      );
    });

    test(
      'a legacy indexed-`value` transfer of the wrong amount is blocked',
      () {
        // Accepting the shape must not cost the exact-amount check: the indexed
        // operand is still held to what the user asked to send.
        final sim = decodeSimulateV1(
          okResult([
            log(
              emitter: token,
              topics: [
                transferTopic,
                addrTopic(owner),
                addrTopic(recipient),
                '0x${word(1450)}',
              ],
            ),
          ]),
        );

        expect(
          () => runErc20Gate(sim, amount: BigInt.from(1500)),
          throwsA(isA<EvmTransferBlockedException>()),
        );
      },
    );

    test('a four-topic transfer from another contract is still blocked', () {
      // The widened label match is scoped to the contract the user chose; an
      // outflow from anywhere else remains an unexpected asset.
      final sim = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [transferTopic, addrTopic(owner), addrTopic(recipient)],
            data: '0x${word(1500)}',
          ),
          log(
            emitter: attacker,
            topics: [
              transferTopic,
              addrTopic(owner),
              addrTopic(attacker),
              '0x${word(1500)}',
            ],
          ),
        ]),
      );

      expect(
        () => runErc20Gate(sim, amount: BigInt.from(1500)),
        throwsA(isA<EvmTransferBlockedException>()),
      );
    });

    test('an auxiliary event alongside a clean send does not block it', () {
      // Fee hooks, rebases and bookkeeping events ride along with legitimate
      // transfers. The fail-closed rule on undecodable logs is scoped to the
      // native trace emitter precisely so these keep working.
      final sim = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [transferTopic, addrTopic(owner), addrTopic(recipient)],
            data: '0x${word(1500)}',
          ),
          log(
            emitter: token,
            topics: [
              '0x1234567890123456789012345678901234567890123456789012345678901234',
              addrTopic(owner),
            ],
            data: '0x${word(7)}',
          ),
        ]),
      );

      expect(
        () => runErc20Gate(sim, amount: BigInt.from(1500)),
        returnsNormally,
      );
    });

    test(
      'a fee-on-transfer token that moves less than requested is blocked',
      () {
        // The user would sign a transfer believing the full amount arrives. The
        // gate refuses rather than silently short-changing them.
        final sim = decodeSimulateV1(
          okResult([
            log(
              emitter: token,
              topics: [transferTopic, addrTopic(owner), addrTopic(recipient)],
              data: '0x${word(1450)}',
            ),
          ]),
        );

        expect(
          () => runErc20Gate(sim, amount: BigInt.from(1500)),
          throwsA(isA<EvmTransferBlockedException>()),
        );
      },
    );

    test('a send that smuggles in an ApprovalForAll is blocked', () {
      // This is the drainer pattern: the transfer looks right, and the approval
      // riding along hands the attacker every token in the collection.
      final sim = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [transferTopic, addrTopic(owner), addrTopic(recipient)],
            data: '0x${word(1500)}',
          ),
          log(
            emitter: token,
            topics: [
              approvalForAllTopic,
              addrTopic(owner),
              addrTopic(attacker),
            ],
            data: '0x${word(1)}',
          ),
        ]),
      );

      expect(
        () => runErc20Gate(sim, amount: BigInt.from(1500)),
        throwsA(isA<EvmTransferBlockedException>()),
      );
    });

    test('an ERC-721 transfer that clears its own approval still passes', () {
      // OpenZeppelin v4 emits Approval(owner, 0x0, tokenId) while transferring.
      // Blocking that would break every NFT transfer against those contracts.
      final sim = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              transferTopic,
              addrTopic(owner),
              addrTopic(recipient),
              '0x${word(42)}',
            ],
          ),
          log(
            emitter: token,
            topics: [
              approvalTopic,
              addrTopic(owner),
              addrTopic(zero),
              '0x${word(42)}',
            ],
          ),
        ]),
      );

      expect(() => runNftGate(sim), returnsNormally);
    });

    test('a batch transfer that also moves a second NFT is blocked', () {
      // TransferBatch is not something our own flows emit. If one appears and
      // carries a token the user did not choose, that token is being taken.
      final data =
          '0x${word(64)}${word(160)}'
          '${word(2)}${word(42)}${word(99)}'
          '${word(2)}${word(1)}${word(1)}';

      final sim = decodeSimulateV1(
        okResult([
          log(
            emitter: token,
            topics: [
              transferBatchTopic,
              addrTopic(owner),
              addrTopic(owner),
              addrTopic(recipient),
            ],
            data: data,
          ),
        ]),
      );

      expect(
        () => runNftGate(sim),
        throwsA(isA<EvmTransferBlockedException>()),
      );
    });

    test('a simulation showing nothing leave the wallet is blocked', () {
      // An empty change set is not proof of safety — it means we could not see
      // the movement, so signing is refused.
      final sim = decodeSimulateV1(okResult([]));

      expect(
        () => runErc20Gate(sim, amount: BigInt.from(1500)),
        throwsA(isA<EvmTransferBlockedException>()),
      );
    });
  });
}
