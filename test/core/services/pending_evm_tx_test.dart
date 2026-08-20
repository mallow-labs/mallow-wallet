import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx.dart';

/// Pure replace-by-fee arithmetic and replacement shaping.
///
/// These encode the rules a node enforces, so getting them wrong doesn't
/// produce a wrong number on screen — it produces a replacement the network
/// rejects, leaving the user's transaction stuck with no way out from the app.
PendingTxCandidate _candidate({
  required String hash,
  required int maxFee,
  required int tip,
  PendingTxCandidateRole role = PendingTxCandidateRole.original,
  int broadcastAt = 0,
}) => PendingTxCandidate(
  hash: hash,
  role: role.name,
  maxFeePerGas: BigInt.from(maxFee),
  maxPriorityFeePerGas: BigInt.from(tip),
  broadcastAt: broadcastAt,
);

PendingEvmTx _entry({
  List<PendingTxCandidate> candidates = const [],
  PendingEvmTxKind kind = PendingEvmTxKind.send,
  PendingEvmTxStatus status = PendingEvmTxStatus.pending,
  int nonce = 7,
  int gasLimit = 90000,
  String data = '0xa9059cbb',
}) => PendingEvmTx(
  walletAddress: '0x1111111111111111111111111111111111111111',
  nonce: nonce,
  chainId: 1,
  kind: kind,
  status: status,
  toAddress: '0x2222222222222222222222222222222222222222',
  valueWei: BigInt.from(5),
  data: data,
  gasLimit: gasLimit,
  metadata: const PendingTxMetadata(title: 'Send'),
  candidates: candidates,
  createdAt: 1700000000,
);

void main() {
  group('replacement floor', () {
    test('is ceil(1.1x) per field, not a shared multiplier', () {
      // 101 x 1.1 = 111.1 -> 112: truncating to 111 would sign a wei under the
      // node's bump requirement and be rejected as underpriced.
      final floor = replacementFloorFor([
        _candidate(hash: '0x1', maxFee: 101, tip: 5),
      ]);
      expect(floor!.maxFeePerGas, BigInt.from(112));
      expect(floor.maxPriorityFeePerGas, BigInt.from(6));
    });

    test('references the highest-fee candidate, not the newest', () {
      // A second speed-up must out-bid the first speed-up. Flooring against
      // the newest candidate would let a *lower* second bid through, which the
      // node rejects.
      final floor = replacementFloorFor([
        _candidate(hash: '0x1', maxFee: 100, tip: 10, broadcastAt: 1),
        _candidate(
          hash: '0x2',
          maxFee: 200,
          tip: 20,
          role: PendingTxCandidateRole.speedup,
          broadcastAt: 2,
        ),
        _candidate(
          hash: '0x3',
          maxFee: 150,
          tip: 15,
          role: PendingTxCandidateRole.speedup,
          broadcastAt: 3,
        ),
      ]);
      expect(floor!.maxFeePerGas, BigInt.from(220));
      expect(floor.maxPriorityFeePerGas, BigInt.from(22));
    });

    test(
      'is null with no candidates (external entry has nothing to out-bid)',
      () {
        expect(replacementFloorFor(const []), isNull);
      },
    );

    test('raises each field independently', () {
      // A tier above the floor on max fee but below it on the tip is still
      // rejected — both fields must clear the bump, so both are raised.
      final floored = applyReplacementFloor(
        (maxFeePerGas: BigInt.from(500), maxPriorityFeePerGas: BigInt.from(1)),
        (maxFeePerGas: BigInt.from(220), maxPriorityFeePerGas: BigInt.from(22)),
      );
      expect(floored.maxFeePerGas, BigInt.from(500));
      expect(floored.maxPriorityFeePerGas, BigInt.from(22));
    });

    test('passes caps through untouched when there is no floor', () {
      final caps = (
        maxFeePerGas: BigInt.from(7),
        maxPriorityFeePerGas: BigInt.from(3),
      );
      expect(applyReplacementFloor(caps, null), caps);
    });
  });

  group('replacement construction', () {
    test('a speed-up replays the stored payload on the same nonce', () {
      final plan = buildReplacementPlan(_entry(), asCancel: false);
      expect(
        plan.nonce,
        7,
        reason: 'the nonce is the identity — never reallocated',
      );
      expect(plan.to, '0x2222222222222222222222222222222222222222');
      expect(plan.value, BigInt.from(5));
      expect(plan.data, '0xa9059cbb');
      // Raising the limit would invalidate the estimate the original passed its
      // simulation gate with.
      expect(plan.gasLimit, 90000);
      expect(plan.role, PendingTxCandidateRole.speedup);
    });

    test('a cancel is a 0-ETH self-send at 21000 gas', () {
      final plan = buildReplacementPlan(_entry(), asCancel: true);
      expect(plan.nonce, 7);
      expect(plan.to, '0x1111111111111111111111111111111111111111');
      expect(plan.value, BigInt.zero);
      expect(plan.data, isEmpty, reason: 'calldata would make it not a no-op');
      expect(plan.gasLimit, kCancelGasLimit);
      expect(plan.role, PendingTxCandidateRole.cancel);
    });
  });

  group('blind-cancel escalation', () {
    test('grows both caps x1.25 per underpriced rejection', () async {
      final attempts = <EvmFeeCaps>[];
      await broadcastWithEscalation(
        caps: (
          maxFeePerGas: BigInt.from(100),
          maxPriorityFeePerGas: BigInt.from(40),
        ),
        isUnderpriced: (_) => true,
        broadcast: (caps) async {
          attempts.add(caps);
          if (attempts.length < 3) throw StateError('underpriced');
          return '0xok';
        },
      );
      expect(attempts.map((c) => c.maxFeePerGas.toInt()), [100, 125, 157]);
      expect(attempts.map((c) => c.maxPriorityFeePerGas.toInt()), [40, 50, 63]);
    });

    test('gives up after 5 attempts and rethrows the last failure', () async {
      // Each attempt is a fresh signature (up to 5 Ledger prompts) — an
      // unbounded ladder would prompt forever and drain the wallet's fee
      // headroom.
      var calls = 0;
      await expectLater(
        broadcastWithEscalation(
          caps: (
            maxFeePerGas: BigInt.from(100),
            maxPriorityFeePerGas: BigInt.from(40),
          ),
          isUnderpriced: (_) => true,
          broadcast: (_) async {
            calls++;
            throw StateError('replacement transaction underpriced');
          },
        ),
        throwsStateError,
      );
      expect(calls, kBlindCancelMaxAttempts);
    });

    test(
      'does not retry an error that is not an underpriced rejection',
      () async {
        // "insufficient funds" never becomes affordable by bidding higher.
        var calls = 0;
        await expectLater(
          broadcastWithEscalation(
            caps: (
              maxFeePerGas: BigInt.from(100),
              maxPriorityFeePerGas: BigInt.from(40),
            ),
            isUnderpriced: (_) => false,
            broadcast: (_) async {
              calls++;
              throw StateError('insufficient funds');
            },
          ),
          throwsStateError,
        );
        expect(calls, 1);
      },
    );
  });

  group('serialization', () {
    test('candidates round-trip, keeping BigInt caps exact', () {
      // Wei values overflow int64 in practice; a lossy round-trip here would
      // silently lower the floor a replacement is computed against.
      final candidates = [
        PendingTxCandidate(
          hash: '0xabc',
          role: PendingTxCandidateRole.speedup.name,
          maxFeePerGas: BigInt.parse('123456789012345678901234567890'),
          maxPriorityFeePerGas: BigInt.from(1500000000),
          broadcastAt: 1753840000,
        ),
      ];
      final decoded = PendingTxCandidate.decodeList(
        PendingTxCandidate.encodeList(candidates),
      );
      expect(decoded.single.hash, '0xabc');
      expect(decoded.single.role, 'speedup');
      expect(
        decoded.single.maxFeePerGas,
        BigInt.parse('123456789012345678901234567890'),
      );
      expect(decoded.single.broadcastAt, 1753840000);
    });

    test('a malformed candidate list degrades to empty, never throws', () {
      // The watcher decodes this on every pass, *before* it can delete the row.
      // Throwing here would abort the pass, so a single corrupted row would
      // stall resolution for every pending transaction, forever.
      expect(PendingTxCandidate.decodeList('[{"hash": "0xab'), isEmpty);
      expect(PendingTxCandidate.decodeList('not json'), isEmpty);
      // Valid JSON, wrong types: a cast in `fromJson` throws just as fatally.
      expect(PendingTxCandidate.decodeList('[{"hash": 7}]'), isEmpty);
      expect(PendingTxCandidate.decodeList('{"hash": "0xabc"}'), isEmpty);
    });

    test('malformed metadata degrades to a generic title, never throws', () {
      // A display string must not be able to hide an actionable entry.
      final metadata = PendingTxMetadata.decode('not json');
      expect(metadata.title, 'Transaction');
    });

    test('an unknown kind decodes to `other` rather than throwing', () {
      expect(PendingEvmTxKind.fromWire('bridge'), PendingEvmTxKind.other);
      expect(
        PendingEvmTxKind.fromWire('nftTransfer'),
        PendingEvmTxKind.nftTransfer,
      );
    });
  });
}
