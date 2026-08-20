import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
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

/// The form's two selectors are *how* to stake, not *what* to stake. Both used to
/// wipe the amount, so comparing Native against Liquid — the whole point of
/// showing two APYs side by side — meant retyping the amount for each, and the
/// stake type had to be re-picked after every tab switch. These tests pin what
/// survives each selector and what must not: a quote priced for the path the user
/// just left, and a carried amount above the new path's balance.
void main() {
  late _MockStakingRepository repository;
  late _MockStakingTxBuilder txBuilder;
  late StakingBloc bloc;

  StakingDataResponse dataWith({required int activeLamports}) =>
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
            activeLamports: activeLamports,
            inactiveLamports: 0,
            activatingLamports: 0,
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

  /// 1 SOL in, 0.95 mallowSOL out.
  JupiterClassicQuote quote() => const JupiterClassicQuote({
    'inAmount': '1000000000',
    'outAmount': '950000000',
    'slippageBps': 50,
  });

  setUp(() {
    repository = _MockStakingRepository();
    txBuilder = _MockStakingTxBuilder();
    when(txBuilder.getEpochProgress).thenAnswer(
      (_) async => const EpochProgress(
        epoch: 700,
        slotIndex: 1000,
        slotsInEpoch: 432000,
      ),
    );
    bloc = StakingBloc(
      repository,
      txBuilder,
      _MockMarketplaceActionFlow(),
      _MockTokenPriceService(),
      _MockWalletManager(),
      StakeMutationJournal(),
      TxLandedSlots(),
    );
  });

  tearDown(() => bloc.close());

  Future<void> fund({int sol = 0, int mallowSol = 0}) async {
    bloc.add(
      StakingEvent.balancesUpdated(
        solLamports: sol,
        mallowSolLamports: mallowSol,
      ),
    );
    await pumpEventQueue();
  }

  Future<void> send(StakingEvent event) async {
    bloc.add(event);
    await pumpEventQueue();
  }

  test('the stake type survives a Stake ↔ Unstake tab switch', () async {
    await send(const StakingEvent.setStakeType(StakeType.liquid));
    await send(const StakingEvent.setTab(StakeTab.unstake));

    // The tab picks the direction, not the mechanism — a user unstaking what
    // they just staked is still on the same path.
    expect(bloc.state.stakeType, StakeType.liquid);

    await send(const StakingEvent.setTab(StakeTab.stake));
    expect(bloc.state.stakeType, StakeType.liquid);
  });

  test('switching tab still clears the amount', () async {
    // Deliberately *not* carried: the stake and unstake fields are bounded by
    // different balances, so a stake amount is meaningless as an unstake amount.
    await fund(sol: 5000000000);
    await send(const StakingEvent.setAmount('1.5'));
    await send(const StakingEvent.setTab(StakeTab.unstake));

    expect(bloc.state.amount, '');
  });

  test('the typed amount survives the Native ↔ Liquid toggle', () async {
    await fund(sol: 5000000000);
    await send(const StakingEvent.setAmount('1.5'));
    await send(const StakingEvent.setStakeType(StakeType.liquid));

    // Both stake paths spend SOL, so the same 1.5 is what the other APY applies
    // to — the user compares the two by toggling, not by retyping.
    expect(bloc.state.amount, '1.5');
    expect(bloc.state.canSubmit, isTrue);

    await send(const StakingEvent.setStakeType(StakeType.native));
    expect(bloc.state.amount, '1.5');
  });

  test("the carried amount is clamped to the new path's balance", () async {
    // Unstake is where the toggle changes the asset: native spends the 3 SOL
    // staked, liquid spends the 2.5 mallowSOL held. Carrying 3 across would
    // leave an unsubmittable amount on screen with nothing explaining it, so it
    // is rewritten exactly as typing 3 into the liquid field would be.
    when(
      repository.getStakingData,
    ).thenAnswer((_) async => dataWith(activeLamports: 3000000000));
    await send(const StakingEvent.loadData());
    await fund(sol: 5000000000, mallowSol: 2500000000);
    await send(const StakingEvent.setTab(StakeTab.unstake));
    // Off the sheet's default path first — the carry only changes the asset
    // when the toggle actually moves.
    await send(const StakingEvent.setStakeType(StakeType.native));
    await send(const StakingEvent.setAmount('3'));
    expect(bloc.state.amount, '3');

    await send(const StakingEvent.setStakeType(StakeType.liquid));
    expect(bloc.state.amount, '2.5');
  });

  test("the toggle drops the other path's quote", () async {
    when(
      () => txBuilder.getQuote(
        inputMint: any(named: 'inputMint'),
        outputMint: any(named: 'outputMint'),
        amount: any(named: 'amount'),
      ),
    ).thenAnswer((_) async => quote());
    await fund(sol: 5000000000);
    await send(const StakingEvent.setStakeType(StakeType.liquid));
    await send(const StakingEvent.setAmount('1'));
    await send(const StakingEvent.refreshLiquidQuote());
    expect(bloc.state.liquidQuote, isNotNull);

    // The quote priced SOL → mallowSOL. Native sends no swap, and toggling back
    // must re-quote rather than reuse it.
    await send(const StakingEvent.setStakeType(StakeType.native));
    expect(bloc.state.liquidQuote, isNull);
    expect(bloc.state.amount, '1');
  });

  test('re-tapping the selected stake type keeps the quote', () async {
    when(
      () => txBuilder.getQuote(
        inputMint: any(named: 'inputMint'),
        outputMint: any(named: 'outputMint'),
        amount: any(named: 'amount'),
      ),
    ).thenAnswer((_) async => quote());
    await fund(sol: 5000000000);
    await send(const StakingEvent.setStakeType(StakeType.liquid));
    await send(const StakingEvent.setAmount('1'));
    await send(const StakingEvent.refreshLiquidQuote());

    // Tapping the row you are already on is not an edit: dropping the quote here
    // would blank the receive line and refetch for no reason.
    await send(const StakingEvent.setStakeType(StakeType.liquid));
    expect(bloc.state.liquidQuote, isNotNull);
  });

  test(
    'an in-flight quote is discarded if the user leaves the liquid path',
    () async {
      // The quote outlives the toggle now that the amount does: without the
      // stake-type bail it lands in a native state, priced for a swap the user is
      // no longer making.
      final gate = Completer<JupiterClassicQuote>();
      when(
        () => txBuilder.getQuote(
          inputMint: any(named: 'inputMint'),
          outputMint: any(named: 'outputMint'),
          amount: any(named: 'amount'),
        ),
      ).thenAnswer((_) => gate.future);
      await fund(sol: 5000000000);
      await send(const StakingEvent.setStakeType(StakeType.liquid));
      await send(const StakingEvent.setAmount('1'));
      bloc.add(const StakingEvent.refreshLiquidQuote());
      await pumpEventQueue();

      await send(const StakingEvent.setStakeType(StakeType.native));
      gate.complete(quote());
      await pumpEventQueue();

      expect(bloc.state.liquidQuote, isNull);
    },
  );

  test('leaving the liquid path mid-quote clears the quoting flag', () async {
    // The bail above discards the result; it must also unlatch [isQuoting], or
    // the flag stays true for the rest of the sheet's life — until some later
    // liquid quote happens to resolve. Anything bound to it (a spinner on the
    // receive line) would then be stuck on over a native form that is not
    // quoting anything.
    final gate = Completer<JupiterClassicQuote>();
    when(
      () => txBuilder.getQuote(
        inputMint: any(named: 'inputMint'),
        outputMint: any(named: 'outputMint'),
        amount: any(named: 'amount'),
      ),
    ).thenAnswer((_) => gate.future);
    await fund(sol: 5000000000);
    await send(const StakingEvent.setStakeType(StakeType.liquid));
    await send(const StakingEvent.setAmount('1'));
    bloc.add(const StakingEvent.refreshLiquidQuote());
    await pumpEventQueue();
    expect(bloc.state.isQuoting, isTrue);

    await send(const StakingEvent.setStakeType(StakeType.native));
    gate.complete(quote());
    await pumpEventQueue();

    expect(bloc.state.isQuoting, isFalse);
  });
}
