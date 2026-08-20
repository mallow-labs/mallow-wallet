import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

import '../data/staking_tx_builder.dart';

/// Durable optimistic overlay for the native-stake status cells.
///
/// `/v1/staking` derives `userData.nativeStake` from a live
/// `getProgramAccounts` against the backend's own RPC node
/// (`mallowSolHelper.fetchStakeAccountBalancesByStatus`) — no database, no
/// index. So the read that follows a confirmed stake/unstake/claim comes back
/// describing the *pre-transaction* world for as long as that node lags the
/// slot our transaction landed in, and the cells sit unchanged: nothing new
/// appears after a stake, nothing flips to Claim after an unstake, nothing
/// disappears after a claim. Waiting for the indexer ack does not fix it —
/// `checkTransaction` acks mallow's transaction index, which says nothing
/// about the node the staking payload is computed from.
///
/// This is the same shape `ArtworkBloc`'s pending-mutation journal uses, minus
/// its per-PDA presence evidence:
///
/// 1. **Apply.** The moment a transaction confirms, its
///    [NativeStakeDelta] — computed by the builder, which is the only thing
///    that knows which accounts were touched — is folded over whatever the
///    server last reported.
/// 2. **Verify by slot.** A re-read of the user's own stake accounts guarded
///    by `minContextSlot` = the transaction's landed slot cannot be served
///    from a view older than the transaction, so when it succeeds it replaces
///    the estimate with on-chain truth ([adoptChainTruth]).
/// 3. **Self-drop.** The entry is discarded once a server payload has moved
///    off the baseline as far as the mutation pushed it ([reconcile]) — the
///    server has caught up and the overlay would only be re-asserting what it
///    already says.
///
/// A `@lazySingleton` rather than bloc state because there are two live
/// [StakingBloc]s: the sheet's, which dies when the sheet closes, and the
/// tokens portfolio's [StakeStatusSection]. Holding the journal in either one
/// would leave the other showing the pre-transaction world.
@lazySingleton
class StakeMutationJournal {
  /// Reconciliation attempts a pending entry survives before it is dropped
  /// regardless.
  ///
  /// The backstop for the case the self-drop cannot reach: something moved a
  /// bucket the *other* way (an epoch boundary rolling activating → active,
  /// a stake account managed outside the app), so the "server moved this far"
  /// test can never be satisfied and the overlay would pin a wrong figure for
  /// the rest of the session. Counted in reconciliations rather than seconds
  /// so it is deterministic in tests; both blocs reconcile the same entry, so
  /// the effective number of *refreshes* can be as low as half this.
  static const _maxReconcileAttempts = 12;

  /// Addresses tracked at once. A session switches between a handful of
  /// wallets; anything older than that has long since reconciled.
  static const _maxAddresses = 4;

  final Map<String, _PendingStakeMutation> _pending = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Fires whenever the overlay changes — record, adopt, or drop. Every
  /// [StakingBloc] listens so a mutation made in the stake sheet reaches the
  /// portfolio's cells too.
  Stream<void> get changes => _changes.stream;

  /// Whether [address] has a mutation the server has not confirmed yet.
  bool hasPending(String? address) =>
      address != null && _pending.containsKey(address);

  /// Slot the pending mutation for [address] landed in, or 0 when unknown
  /// (not pending, or the confirmation never reported one). Use as
  /// `minContextSlot` — 0 means "no floor to enforce".
  int floorSlot(String? address) =>
      address == null ? 0 : (_pending[address]?.landedSlot ?? 0);

  /// [base] with any pending mutation for [address] folded over it.
  ///
  /// Every emission of a breakdown must go through this — an emit that skips
  /// it reverts the cells to the stale server figures for one frame, which is
  /// exactly the flicker the journal exists to remove.
  NativeStakeBreakdown overlay(String? address, NativeStakeBreakdown base) {
    if (address == null) return base;
    return _pending[address]?.expected ?? base;
  }

  /// Record that [signature] — confirmed on chain in [landedSlot], 0 when the
  /// slot is unknown — moved [delta] lamports between buckets, against the
  /// [baseline] the server was last reporting.
  ///
  /// A second mutation while one is still pending composes onto it: the
  /// expectation moves again, the baseline stays where the server actually
  /// was, and the newest (highest) landed slot becomes the read floor.
  void record({
    required String address,
    required String signature,
    required int landedSlot,
    required NativeStakeBreakdown baseline,
    required NativeStakeDelta delta,
  }) {
    if (delta.isEmpty) return;
    final existing = _pending[address];
    if (existing != null && existing.signature == signature) return;
    final previousSlot = existing?.landedSlot ?? 0;
    _pending[address] = _PendingStakeMutation(
      signature: signature,
      landedSlot: landedSlot > previousSlot ? landedSlot : previousSlot,
      baseline: existing?.baseline ?? baseline,
      expected: _applyDelta(existing?.expected ?? baseline, delta),
    );
    _evictOldest();
    _changes.add(null);
  }

  /// Replace the estimate for [address] with [truth], a breakdown read at or
  /// past the pending mutation's landed slot and therefore provably showing
  /// its effect.
  ///
  /// The entry stays pending: on-chain truth says what is real, but the cells
  /// are still rendered off the server payload, so the overlay has to stand
  /// until *that* agrees. Ignored when nothing is pending — an unguarded read
  /// carries no ordering and must not overwrite anything.
  void adoptChainTruth(String address, NativeStakeBreakdown truth) {
    final pending = _pending[address];
    if (pending == null) return;
    if (_sameBreakdown(pending.expected, truth)) return;
    _pending[address] = pending.withExpected(truth);
    _changes.add(null);
  }

  /// Fold a fresh [server] payload in: drop the pending mutation for [address]
  /// once the payload reflects it, or once it has outlived
  /// [_maxReconcileAttempts] reconciliations.
  void reconcile(String address, NativeStakeBreakdown server) {
    final pending = _pending[address];
    if (pending == null) return;
    if (pending.isReflectedBy(server) ||
        pending.attempts + 1 >= _maxReconcileAttempts) {
      _pending.remove(address);
      _changes.add(null);
      return;
    }
    _pending[address] = pending.withAttempt();
  }

  /// Forget everything. Only for tests — a singleton outlives every bloc, so
  /// leaking one test's overlay into the next would be invisible and
  /// order-dependent.
  @visibleForTesting
  void clear() => _pending.clear();

  void _evictOldest() {
    while (_pending.length > _maxAddresses) {
      _pending.remove(_pending.keys.first);
    }
  }

  static NativeStakeBreakdown _applyDelta(
    NativeStakeBreakdown base,
    NativeStakeDelta delta,
  ) => NativeStakeBreakdown(
    // Clamped at zero: the delta is derived from the accounts the builder saw
    // at build time, so a baseline the server has since revised downwards
    // could otherwise drive a bucket negative and render "-0.5 SOL".
    activeLamports: _atLeastZero(base.activeLamports + delta.activeLamports),
    activatingLamports: _atLeastZero(
      base.activatingLamports + delta.activatingLamports,
    ),
    deactivatingLamports: _atLeastZero(
      base.deactivatingLamports + delta.deactivatingLamports,
    ),
    inactiveLamports: _atLeastZero(
      base.inactiveLamports + delta.inactiveLamports,
    ),
  );

  static int _atLeastZero(int value) => value < 0 ? 0 : value;

  static bool _sameBreakdown(NativeStakeBreakdown a, NativeStakeBreakdown b) =>
      a.activeLamports == b.activeLamports &&
      a.activatingLamports == b.activatingLamports &&
      a.deactivatingLamports == b.deactivatingLamports &&
      a.inactiveLamports == b.inactiveLamports;
}

/// One unconfirmed native-stake mutation.
class _PendingStakeMutation {
  const _PendingStakeMutation({
    required this.signature,
    required this.landedSlot,
    required this.baseline,
    required this.expected,
    this.attempts = 0,
  });

  /// Newest transaction folded into [expected].
  final String signature;

  /// Slot that transaction landed in — the floor a stake-account re-read must
  /// clear before it is allowed to contradict [expected]. 0 when unknown.
  final int landedSlot;

  /// What the server reported before the mutation. Kept so [isReflectedBy]
  /// can tell "the server has caught up" from "the server has always said
  /// this".
  final NativeStakeBreakdown baseline;

  /// What the cells render until the server catches up.
  final NativeStakeBreakdown expected;

  final int attempts;

  _PendingStakeMutation withAttempt() => _PendingStakeMutation(
    signature: signature,
    landedSlot: landedSlot,
    baseline: baseline,
    expected: expected,
    attempts: attempts + 1,
  );

  _PendingStakeMutation withExpected(NativeStakeBreakdown next) =>
      _PendingStakeMutation(
        signature: signature,
        landedSlot: landedSlot,
        baseline: baseline,
        expected: next,
        attempts: attempts,
      );

  /// Whether [server] has moved off [baseline] at least as far as [expected]
  /// in every bucket the mutation touched.
  ///
  /// Per-bucket and directional rather than an equality check, so unrelated
  /// concurrent movement — rewards accruing, a second stake account maturing —
  /// does not hold the overlay open. Buckets the mutation left alone are
  /// unconstrained for the same reason.
  bool isReflectedBy(NativeStakeBreakdown server) =>
      _moved(
        baseline.activeLamports,
        expected.activeLamports,
        server.activeLamports,
      ) &&
      _moved(
        baseline.activatingLamports,
        expected.activatingLamports,
        server.activatingLamports,
      ) &&
      _moved(
        baseline.deactivatingLamports,
        expected.deactivatingLamports,
        server.deactivatingLamports,
      ) &&
      _moved(
        baseline.inactiveLamports,
        expected.inactiveLamports,
        server.inactiveLamports,
      );

  static bool _moved(int baseline, int expected, int server) {
    if (expected > baseline) return server >= expected;
    if (expected < baseline) return server <= expected;
    return true;
  }
}
