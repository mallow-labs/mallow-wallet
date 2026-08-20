import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
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

class _MockSolanaRpcService extends Mock implements SolanaRpcService {}

class _FakeActionFlowSink extends Fake
    implements ActionFlowSink<StakePrep, StakeSuccessData> {}

const _fallbackFlowKey = FlowKey.solana(AppFlow.stakeNative);

const _sol = 1000000000;
const _address = 'addr';

/// What the user reported: stake 2 SOL, watch it confirm, and the Activating
/// cell never appears. Same for unstake never flipping to a claim countdown
/// and claim never clearing the claimable cell.
///
/// The cause is that `/v1/staking` computes `userData.nativeStake` from a live
/// `getProgramAccounts` on the backend's own RPC node, so it keeps returning
/// the pre-transaction figures until *that* node reaches our slot — and the
/// only refresh trigger the feature had (`onIndexedAck`) acks a completely
/// different system, mallow's transaction index.
///
/// These drive the whole bloc, not the journal in isolation, because the bug
/// only shows up in the seam: the reload fires, the payload is stale, and the
/// question is what the cells end up rendering.
void main() {
  setUpAll(() {
    registerFallbackValue(_FakeActionFlowSink());
    registerFallbackValue(_fallbackFlowKey);
  });

  late _MockStakingRepository repository;
  late _MockStakingTxBuilder txBuilder;
  late _MockMarketplaceActionFlow flow;
  late StakeMutationJournal journal;
  late TxLandedSlots landedSlots;
  late StakingBloc bloc;

  /// Whatever the (possibly stale) server payload currently reports.
  late NativeStakeBreakdown served;

  StakingDataResponse payload() => StakingDataResponse(
    nativeApy: 0.0574,
    liquidApy: 0.0559,
    solPerMallowSol: 1.0,
    totalSolStakedLamports: '0',
    totalStakers: 0,
    totalSeasonPoints: 0,
    userData: StakingUserData(
      spPerDay: 0,
      nativeStake: served,
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

  /// Stand in for a signed, broadcast, chain-confirmed transaction: drive the
  /// sink the way [MarketplaceActionFlow.execute] does on the happy path.
  void succeedWith(String signature) {
    when(
      () => flow.execute<StakePrep, StakeSuccessData>(
        sink: any(named: 'sink'),
        txsBase64: any(named: 'txsBase64'),
        usdValue: any(named: 'usdValue'),
        flow: any(named: 'flow'),
        toSuccess: any(named: 'toSuccess'),
        isClosed: any(named: 'isClosed'),
        onIndexedAck: any(named: 'onIndexedAck'),
        additionalSigners: any(named: 'additionalSigners'),
        stageFor: any(named: 'stageFor'),
        useLedger: any(named: 'useLedger'),
        failurePrefix: any(named: 'failurePrefix'),
        rpcOverride: any(named: 'rpcOverride'),
      ),
    ).thenAnswer((invocation) async {
      final sink =
          invocation.namedArguments[#sink]
              as ActionFlowSink<StakePrep, StakeSuccessData>;
      final toSuccess =
          invocation.namedArguments[#toSuccess]
              as StakeSuccessData Function(String);
      sink.onSuccess(signature, toSuccess(signature));
    });
  }

  setUp(() {
    served = breakdown(active: 10 * _sol);
    repository = _MockStakingRepository();
    txBuilder = _MockStakingTxBuilder();
    flow = _MockMarketplaceActionFlow();
    journal = StakeMutationJournal();
    landedSlots = TxLandedSlots();

    when(repository.getStakingData).thenAnswer((_) async => payload());
    when(() => txBuilder.rpcService).thenReturn(_MockSolanaRpcService());
    when(txBuilder.getEpochProgress).thenAnswer(
      (_) async => const EpochProgress(
        epoch: 700,
        slotIndex: 1000,
        slotsInEpoch: 432000,
      ),
    );
    when(
      () => txBuilder.fetchClaimableCompressedBalance(mint: any(named: 'mint')),
    ).thenAnswer((_) async => 0);
    // The default: the user's own RPC is behind too, so the guarded re-read
    // refuses to answer. Nothing may fall back to the stale payload.
    when(
      () => txBuilder.fetchNativeStakeBreakdown(
        validatorVoteAddress: any(named: 'validatorVoteAddress'),
        minContextSlot: any(named: 'minContextSlot'),
      ),
    ).thenThrow(StateError('Minimum context slot has not been reached'));

    final walletManager = _MockWalletManager();
    when(walletManager.getAddress).thenAnswer((_) async => _address);
    when(walletManager.isLocalSigner).thenAnswer((_) async => true);
    when(() => walletManager.getAddress()).thenAnswer((_) async => _address);

    final priceService = _MockTokenPriceService();
    when(() => priceService.usdValueOfRaw(any(), any())).thenReturn(0);

    bloc = StakingBloc(
      repository,
      txBuilder,
      flow,
      priceService,
      walletManager,
      journal,
      landedSlots,
    );
  });

  tearDown(() => bloc.close());

  Future<void> send(StakingEvent event) async {
    bloc.add(event);
    await pumpEventQueue();
  }

  /// Fill the form for a native action of [sol] SOL on [tab].
  Future<void> prepare({required StakeTab tab, required String sol}) async {
    await send(const StakingEvent.loadData());
    await send(StakingEvent.setTab(tab));
    await send(const StakingEvent.setStakeType(StakeType.native));
    await send(
      StakingEvent.balancesUpdated(
        solLamports: 100 * _sol,
        mallowSolLamports: 0,
      ),
    );
    await send(StakingEvent.setAmount(sol));
  }

  test(
    'a confirmed stake shows as activating against a stale payload',
    () async {
      when(
        () => txBuilder.buildNativeStakeTx(
          stakeLamports: any(named: 'stakeLamports'),
          validatorVoteAddress: any(named: 'validatorVoteAddress'),
          feeAccountAddress: any(named: 'feeAccountAddress'),
        ),
      ).thenAnswer(
        (_) async => const BuiltStakeTx(
          txBase64: 'tx',
          delta: NativeStakeDelta(activatingLamports: 2 * _sol),
        ),
      );
      succeedWith('sig-stake');
      landedSlots.record('sig-stake', 900);

      await prepare(tab: StakeTab.stake, sol: '2');
      await send(const StakingEvent.submit());

      // The payload still describes the world before the stake — that is the
      // whole point. The cell must exist anyway.
      expect(bloc.state.data!.userData.nativeStake.activatingLamports, 0);
      expect(bloc.state.nativeStake!.activatingLamports, 2 * _sol);
      expect(bloc.state.nativeStake!.activeLamports, 10 * _sol);

      // And the guarded re-read was asked for at the slot the tx landed in, so a
      // node that had not reached it could not answer at all.
      verify(
        () => txBuilder.fetchNativeStakeBreakdown(
          validatorVoteAddress: any(named: 'validatorVoteAddress'),
          minContextSlot: 900,
        ),
      ).called(greaterThan(0));
    },
  );

  test(
    'the optimistic cell survives every stale refresh, then hands over',
    () async {
      when(
        () => txBuilder.buildNativeStakeTx(
          stakeLamports: any(named: 'stakeLamports'),
          validatorVoteAddress: any(named: 'validatorVoteAddress'),
          feeAccountAddress: any(named: 'feeAccountAddress'),
        ),
      ).thenAnswer(
        (_) async => const BuiltStakeTx(
          txBase64: 'tx',
          delta: NativeStakeDelta(activatingLamports: 2 * _sol),
        ),
      );
      succeedWith('sig-stake');
      landedSlots.record('sig-stake', 900);

      await prepare(tab: StakeTab.stake, sol: '2');
      await send(const StakingEvent.submit());

      // The indexer acks — but the indexer is not the node the payload comes
      // from, so the reload it triggers is still stale. Before the journal this
      // is the moment the cell vanished again.
      await send(
        const StakingEvent.indexedAck(signature: 'sig-stake', ok: true),
      );
      expect(bloc.state.nativeStake!.activatingLamports, 2 * _sol);

      // The backend's node finally catches up: the overlay must stand down
      // rather than double-count, and the payload takes back over.
      served = breakdown(active: 10 * _sol, activating: 2 * _sol);
      await send(const StakingEvent.loadData());

      expect(bloc.state.nativeStakeOverride, isNull);
      expect(bloc.state.nativeStake!.activatingLamports, 2 * _sol);
    },
  );

  test(
    'a claim empties the claimable cell before the payload agrees',
    () async {
      served = breakdown(active: 10 * _sol, inactive: 4 * _sol);
      when(
        () => txBuilder.buildWithdrawStakeTx(
          validatorVoteAddress: any(named: 'validatorVoteAddress'),
        ),
      ).thenAnswer(
        (_) async => const BuiltStakeTx(
          txBase64: 'tx',
          delta: NativeStakeDelta(inactiveLamports: -4 * _sol),
        ),
      );
      succeedWith('sig-claim');
      landedSlots.record('sig-claim', 950);

      await send(const StakingEvent.loadData());
      expect(bloc.state.nativeStake!.inactiveLamports, 4 * _sol);

      await send(const StakingEvent.claim());

      // The Claim button sat over funds that were already gone — tapping it
      // again builds a second withdraw for nothing.
      expect(bloc.state.nativeStake!.inactiveLamports, 0);
    },
  );

  test('a slot-verified read outranks the estimate', () async {
    // The re-read cleared the guard, so it provably post-dates our tx: it wins
    // over the delta the builder projected. Here the epoch rolled between
    // build and read, so the stake is already active rather than activating.
    when(
      () => txBuilder.fetchNativeStakeBreakdown(
        validatorVoteAddress: any(named: 'validatorVoteAddress'),
        minContextSlot: any(named: 'minContextSlot'),
      ),
    ).thenAnswer((_) async => breakdown(active: 12 * _sol));
    when(
      () => txBuilder.buildNativeStakeTx(
        stakeLamports: any(named: 'stakeLamports'),
        validatorVoteAddress: any(named: 'validatorVoteAddress'),
        feeAccountAddress: any(named: 'feeAccountAddress'),
      ),
    ).thenAnswer(
      (_) async => const BuiltStakeTx(
        txBase64: 'tx',
        delta: NativeStakeDelta(activatingLamports: 2 * _sol),
      ),
    );
    succeedWith('sig-stake');
    landedSlots.record('sig-stake', 900);

    await prepare(tab: StakeTab.stake, sol: '2');
    await send(const StakingEvent.submit());
    await send(const StakingEvent.indexedAck(signature: 'sig-stake', ok: true));

    expect(bloc.state.nativeStake!.activeLamports, 12 * _sol);
    expect(bloc.state.nativeStake!.activatingLamports, 0);
  });

  test(
    'a liquid stake journals nothing — it touches no stake account',
    () async {
      when(
        () => txBuilder.getQuote(
          inputMint: any(named: 'inputMint'),
          outputMint: any(named: 'outputMint'),
          amount: any(named: 'amount'),
        ),
      ).thenThrow(StateError('unused'));

      await send(const StakingEvent.loadData());
      await send(
        StakingEvent.balancesUpdated(
          solLamports: 100 * _sol,
          mallowSolLamports: 0,
        ),
      );
      await send(StakingEvent.setAmount('2'));
      await send(const StakingEvent.submit());

      expect(journal.hasPending(_address), isFalse);
      expect(bloc.state.nativeStakeOverride, isNull);
    },
  );

  test('the other bloc sees a mutation this one never made', () async {
    // The stake sheet owns one StakingBloc and the tokens portfolio owns
    // another; the sheet's dies on dismissal. Without the shared journal the
    // portfolio kept rendering the pre-stake world after the sheet closed.
    await send(const StakingEvent.loadData());

    journal.record(
      address: _address,
      signature: 'sig-from-the-sheet',
      landedSlot: 900,
      baseline: served,
      delta: const NativeStakeDelta(activatingLamports: 3 * _sol),
    );
    await pumpEventQueue();

    expect(bloc.state.nativeStake!.activatingLamports, 3 * _sol);
  });
}
