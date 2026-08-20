import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/services/marketplace_action_flow.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/tx_landed_slots.dart';
import 'package:mallow_wallet/features/staking/data/epoch_progress.dart';
import 'package:mallow_wallet/features/staking/data/staking_repository.dart';
import 'package:mallow_wallet/features/staking/data/staking_tx_builder.dart';
import 'package:mallow_wallet/features/staking/services/stake_mutation_journal.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockStakingRepository extends Mock implements StakingRepository {}

class _MockStakingTxBuilder extends Mock implements StakingTxBuilder {}

class _MockMarketplaceActionFlow extends Mock
    implements MarketplaceActionFlow {}

class _MockTokenPriceService extends Mock implements TokenPriceService {}

class _MockWalletManager extends Mock implements WalletManager {}

/// Why the indexer ack has to drive a reload.
///
/// `MarketplaceActionFlow.execute` returns as soon as the tx confirms on chain
/// — the indexer poll it kicks off is deliberately not awaited. So the
/// `loadData` the bloc fires at the end of submit/claim reads the
/// *pre-transaction* snapshot: the stake sheet stays on the old stake balances
/// and status cards after a successful stake/unstake, with nothing scheduled
/// to correct it.
///
/// The ack is the first signal that the payload is worth re-reading, and it
/// must not be gated on the success body still being up: the pipeline sheet
/// resets the flow to idle ~1.4s after success, while the ack polls on a 1s
/// cycle for up to 10 attempts.
///
/// It is not *sufficient*, though — it acks mallow's transaction index, while
/// `userData.nativeStake` comes from a live `getProgramAccounts` on a
/// separately-lagging node. Closing that remaining gap is
/// `staking_bloc_optimistic_test.dart`'s subject.
void main() {
  late _MockStakingRepository repository;
  late _MockStakingTxBuilder txBuilder;
  late StakingBloc bloc;
  late int reads;

  StakingDataResponse dataWith({required int activatingLamports}) =>
      StakingDataResponse(
        nativeApy: 0.0574,
        liquidApy: 0.0559,
        solPerMallowSol: 1.0,
        totalSolStakedLamports: '0',
        totalStakers: 0,
        totalSeasonPoints: 0,
        userData: StakingUserData(
          spPerDay: 0,
          nativeStake: NativeStakeBreakdown(
            activeLamports: 0,
            inactiveLamports: 0,
            activatingLamports: activatingLamports,
            deactivatingLamports: 0,
          ),
          liquidStakeLamports: 0,
        ),
        currentSeason: const StakingSeason(
          season: 3,
          label: 'Season 3',
          endsAt: null,
          rewardPool: 0,
          rewardsSentAt: null,
        ),
        leaderboard: const [],
      );

  setUp(() {
    reads = 0;
    repository = _MockStakingRepository();
    txBuilder = _MockStakingTxBuilder();
    // Read 1 is the post-submit reload that races the indexer and sees nothing
    // activating; every later read is the indexer having caught up on a 2 SOL
    // stake.
    when(repository.getStakingData).thenAnswer((_) async {
      reads++;
      return dataWith(activatingLamports: reads == 1 ? 0 : 2000000000);
    });
    when(txBuilder.getEpochProgress).thenAnswer(
      (_) async => const EpochProgress(
        epoch: 700,
        slotIndex: 1000,
        slotsInEpoch: 432000,
      ),
    );
    final walletManager = _MockWalletManager();
    when(walletManager.getAddress).thenAnswer((_) async => 'addr');
    bloc = StakingBloc(
      repository,
      txBuilder,
      _MockMarketplaceActionFlow(),
      _MockTokenPriceService(),
      walletManager,
      StakeMutationJournal(),
      TxLandedSlots(),
    );
  });

  tearDown(() => bloc.close());

  Future<void> send(StakingEvent event) async {
    bloc.add(event);
    await pumpEventQueue();
  }

  int activating() =>
      bloc.state.data?.userData.nativeStake.activatingLamports ?? -1;

  test('an indexer ack re-reads the staking payload', () async {
    await send(const StakingEvent.loadData());
    // The stake landed on chain but the server hasn't indexed it — this is the
    // stale snapshot the user is left staring at today.
    expect(activating(), 0);

    await send(const StakingEvent.indexedAck(signature: 'sig-1', ok: true));

    expect(activating(), 2000000000);
    expect(reads, 2);
  });

  test('the ack refreshes even after the success body is gone', () async {
    await send(const StakingEvent.loadData());
    // The pipeline sheet pops and resets ~1.4s after success, so an ack that
    // takes a couple of poll cycles arrives with the flow already idle. Gating
    // the refresh on `TxFlowSuccess` drops it in exactly the common case.
    expect(bloc.state.flow, isA<TxFlowIdle<StakePrep, StakeSuccessData>>());

    await send(const StakingEvent.indexedAck(signature: 'sig-1', ok: true));

    expect(activating(), 2000000000);
  });

  test('an ack that timed out still refreshes', () async {
    await send(const StakingEvent.loadData());
    // `checkTransaction` returns false after 10 attempts, but its contract says
    // callers should refresh anyway — the indexer may have caught up between
    // the last poll and now, and a stale sheet is the worse failure.
    await send(const StakingEvent.indexedAck(signature: 'sig-1', ok: false));

    expect(activating(), 2000000000);
  });
}
