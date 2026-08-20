import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/staking/data/staking_tx_builder.dart';
import 'package:mallow_wallet/features/staking/services/stake_mutation_journal.dart';

const _sol = 1000000000;
const _addr = 'Staker1111111111111111111111111111111111111';

NativeStakeBreakdown breakdown({
  int active = 0,
  int activating = 0,
  int deactivating = 0,
  int inactive = 0,
}) => NativeStakeBreakdown(
  activeLamports: active,
  activatingLamports: activating,
  deactivatingLamports: deactivating,
  inactiveLamports: inactive,
);

/// `/v1/staking` computes `userData.nativeStake` from a live
/// `getProgramAccounts` on the backend's own node, so the read that follows a
/// confirmed stake/unstake/claim keeps returning the *pre-transaction* world
/// until that node reaches our transaction's slot. Nothing in the flow closes
/// that gap: `onIndexedAck` acks mallow's transaction index, which is a
/// different system entirely.
///
/// So the cells sat wrong for the whole window — a stake that produced no
/// Activating cell, an unstake that never flipped to a claim countdown, a
/// claim that left the claimable cell sitting there with nothing behind it.
/// These pin the three properties that fix it: the overlay is applied, it
/// cannot be reverted by a stale payload, and it does not outlive its welcome.
void main() {
  late StakeMutationJournal journal;

  setUp(() => journal = StakeMutationJournal());

  void recordStake({
    required NativeStakeBreakdown baseline,
    int lamports = 5 * _sol,
    String signature = 'sig-1',
    int landedSlot = 500,
  }) => journal.record(
    address: _addr,
    signature: signature,
    landedSlot: landedSlot,
    baseline: baseline,
    delta: NativeStakeDelta(activatingLamports: lamports),
  );

  group('applying a mutation', () {
    test('a confirmed stake shows as activating before the server sees it', () {
      final server = breakdown(active: 10 * _sol);
      recordStake(baseline: server);

      // The card the user just created some stake for has to exist now, not
      // whenever the backend's node catches up.
      expect(journal.overlay(_addr, server).activatingLamports, 5 * _sol);
      expect(journal.overlay(_addr, server).activeLamports, 10 * _sol);
    });

    test('an unstake of activating stake lands straight in claimable', () {
      // `deactivationEpoch == activationEpoch` is Solana's "no stake at all"
      // short-circuit: the funds are withdrawable the moment the tx lands, so
      // the cell must be the one with the Claim button, not a countdown.
      final server = breakdown(activating: 3 * _sol);
      journal.record(
        address: _addr,
        signature: 'sig-unstake',
        landedSlot: 500,
        baseline: server,
        delta: const NativeStakeDelta(
          activatingLamports: -3 * _sol,
          inactiveLamports: 3 * _sol,
        ),
      );

      final overlaid = journal.overlay(_addr, server);
      expect(overlaid.activatingLamports, 0);
      expect(overlaid.inactiveLamports, 3 * _sol);
    });

    test('a claim empties the claimable cell', () {
      final server = breakdown(inactive: 4 * _sol);
      journal.record(
        address: _addr,
        signature: 'sig-claim',
        landedSlot: 500,
        baseline: server,
        delta: const NativeStakeDelta(inactiveLamports: -4 * _sol),
      );

      expect(journal.overlay(_addr, server).inactiveLamports, 0);
    });

    test('a bucket can never be driven negative', () {
      // The delta is sized from the accounts the builder saw; a server figure
      // that has since moved the other way would otherwise render "-1 SOL".
      final baseline = breakdown(inactive: 4 * _sol);
      journal.record(
        address: _addr,
        signature: 'sig-claim',
        landedSlot: 500,
        baseline: baseline,
        delta: const NativeStakeDelta(inactiveLamports: -9 * _sol),
      );

      expect(journal.overlay(_addr, baseline).inactiveLamports, 0);
    });

    test('a second mutation composes onto the first', () {
      final server = breakdown(active: 10 * _sol);
      recordStake(baseline: server, lamports: 5 * _sol);
      journal.record(
        address: _addr,
        signature: 'sig-2',
        landedSlot: 600,
        baseline: server,
        delta: const NativeStakeDelta(activatingLamports: 2 * _sol),
      );

      expect(journal.overlay(_addr, server).activatingLamports, 7 * _sol);
      // The floor is the newest landed slot — an older one would let a read
      // that predates the second transaction contradict it.
      expect(journal.floorSlot(_addr), 600);
    });

    test('another wallet is unaffected', () {
      final server = breakdown(active: 10 * _sol);
      recordStake(baseline: server);

      expect(journal.overlay('OtherWallet', server).activatingLamports, 0);
      expect(journal.hasPending('OtherWallet'), isFalse);
    });
  });

  group('surviving a stale payload', () {
    test('a pre-transaction payload cannot revert the overlay', () {
      final server = breakdown(active: 10 * _sol);
      recordStake(baseline: server);

      // Exactly what the lagging node keeps returning: the world before the
      // stake. Reconciling against it must change nothing.
      journal.reconcile(_addr, server);

      expect(journal.hasPending(_addr), isTrue);
      expect(journal.overlay(_addr, server).activatingLamports, 5 * _sol);
    });

    test('the overlay drops once the payload reflects the mutation', () {
      final before = breakdown(active: 10 * _sol);
      recordStake(baseline: before);

      final after = breakdown(active: 10 * _sol, activating: 5 * _sol);
      journal.reconcile(_addr, after);

      expect(journal.hasPending(_addr), isFalse);
      expect(journal.overlay(_addr, after), same(after));
    });

    test('unrelated movement does not hold the overlay open', () {
      // Only the buckets the mutation actually moved are constrained, so a
      // second stake account maturing elsewhere still lets this one settle.
      final before = breakdown(active: 10 * _sol);
      recordStake(baseline: before);

      journal.reconcile(
        _addr,
        breakdown(active: 12 * _sol, activating: 5 * _sol),
      );

      expect(journal.hasPending(_addr), isFalse);
    });

    test('a payload that overshoots still settles it', () {
      // Two stakes, one of them made on another device: the server reports
      // more activating than we asked for, which is still "it has seen ours".
      final before = breakdown();
      recordStake(baseline: before);

      journal.reconcile(_addr, breakdown(activating: 9 * _sol));

      expect(journal.hasPending(_addr), isFalse);
    });

    test('a payload that never catches up is given up on, not pinned', () {
      // Backstop for the unreachable case — an epoch boundary or an
      // out-of-app stake account moving a bucket the other way means the
      // "moved this far" test can never pass, and a permanent overlay would
      // be a permanently wrong figure.
      final before = breakdown(active: 10 * _sol);
      recordStake(baseline: before);

      for (var i = 0; i < 12; i++) {
        journal.reconcile(_addr, before);
      }

      expect(journal.hasPending(_addr), isFalse);
    });
  });

  group('slot-verified on-chain truth', () {
    test('a guarded read replaces the estimate', () {
      // `fetchNativeStakeBreakdown(minContextSlot: landedSlot)` cannot be
      // answered from a view older than our transaction, so when it returns
      // it outranks the delta we estimated at build time — here the epoch
      // rolled and the previous activating stake went active.
      final server = breakdown(active: 10 * _sol);
      recordStake(baseline: server);

      journal.adoptChainTruth(
        _addr,
        breakdown(active: 12 * _sol, activating: 5 * _sol),
      );

      final overlaid = journal.overlay(_addr, server);
      expect(overlaid.activeLamports, 12 * _sol);
      expect(overlaid.activatingLamports, 5 * _sol);
    });

    test('on-chain truth does not by itself drop the overlay', () {
      // The cells render the *payload*. Dropping here would hand them straight
      // back to the stale figures the on-chain read just contradicted.
      final server = breakdown(active: 10 * _sol);
      recordStake(baseline: server);

      journal.adoptChainTruth(
        _addr,
        breakdown(active: 10 * _sol, activating: 5 * _sol),
      );

      expect(journal.hasPending(_addr), isTrue);
    });

    test('an unpinned read is ignored', () {
      // Nothing pending means nothing ordered this read against a transaction
      // of ours, so it must not become an overlay of its own.
      final server = breakdown(active: 10 * _sol);
      journal.adoptChainTruth(_addr, breakdown(active: 999 * _sol));

      expect(journal.hasPending(_addr), isFalse);
      expect(journal.overlay(_addr, server), same(server));
    });
  });

  test('every change is broadcast so both blocs re-render', () async {
    // The stake sheet and the tokens portfolio each own a StakingBloc; a
    // mutation made in one has to reach the other's cells, which is the whole
    // reason this is a singleton.
    final seen = <void>[];
    final sub = journal.changes.listen(seen.add);

    final server = breakdown(active: 10 * _sol);
    recordStake(baseline: server);
    journal.adoptChainTruth(
      _addr,
      breakdown(active: 10 * _sol, activating: 6 * _sol),
    );
    journal.reconcile(
      _addr,
      breakdown(active: 10 * _sol, activating: 6 * _sol),
    );
    await Future<void>.delayed(Duration.zero);

    expect(seen.length, 3);
    await sub.cancel();
  });
}
