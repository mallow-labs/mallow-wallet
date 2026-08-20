import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/services/marketplace_action_flow.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/tx_landed_slots.dart';
import 'package:mallow_wallet/features/staking/data/staking_repository.dart';
import 'package:mallow_wallet/features/staking/data/staking_tx_builder.dart';
import 'package:mallow_wallet/features/staking/services/stake_mutation_journal.dart';
import 'package:mallow_wallet/features/staking/services/staking_bloc.dart';
import 'package:mallow_wallet/features/staking/staking_constants.dart';
import 'package:mocktail/mocktail.dart';

class _MockStakingRepository extends Mock implements StakingRepository {}

class _MockStakingTxBuilder extends Mock implements StakingTxBuilder {}

class _MockMarketplaceActionFlow extends Mock
    implements MarketplaceActionFlow {}

class _MockTokenPriceService extends Mock implements TokenPriceService {}

class _MockWalletManager extends Mock implements WalletManager {}

/// The amount field is the one input that can build a transaction guaranteed to
/// fail: a native stake sends `typed + rent` on top of the network fee, so
/// "stake everything" — the most obvious thing a user does — used to submit
/// more SOL than the wallet holds. These tests pin the clamp: the typed value
/// can never exceed the same reserve-adjusted maximum the Max button uses.
void main() {
  late StakingBloc bloc;

  setUp(() {
    bloc = StakingBloc(
      _MockStakingRepository(),
      _MockStakingTxBuilder(),
      _MockMarketplaceActionFlow(),
      _MockTokenPriceService(),
      _MockWalletManager(),
      StakeMutationJournal(),
      TxLandedSlots(),
    );
  });

  tearDown(() => bloc.close());

  /// Types [input] and returns what the form ends up holding.
  Future<String> type(String input) async {
    bloc.add(StakingEvent.setAmount(input));
    await pumpEventQueue();
    return bloc.state.amount;
  }

  Future<void> fund({required int sol, int mallowSol = 0}) async {
    bloc.add(
      StakingEvent.balancesUpdated(
        solLamports: sol,
        mallowSolLamports: mallowSol,
      ),
    );
    await pumpEventQueue();
  }

  group('stake tab (SOL, reserve applies)', () {
    // 5 SOL balance → 4.996 SOL spendable after the 0.004 SOL reserve.
    setUp(() => fund(sol: 5000000000));

    test(
      'typing the whole balance clamps to balance minus the reserve',
      () async {
        expect(await type('5'), '4.996');
      },
    );

    test(
      'the clamped amount is submittable — the tx it builds can land',
      () async {
        await type('5');
        expect(bloc.state.canSubmit, isTrue);
        expect(
          bloc.state.submitLamports,
          5000000000 - StakingConstants.maxReserveLamports,
        );
      },
    );

    test('an amount inside the reserve is left exactly as typed', () async {
      // No silent rewriting of valid input — the clamp stays invisible until
      // the user actually crosses the maximum.
      expect(await type('1.23456789'), '1.23456789');
    });

    test('a trailing decimal point survives the clamp', () async {
      // Mid-typing state: "1." must stay typeable or the field fights the user.
      expect(await type('1.'), '1.');
    });

    test('typing far above the balance still lands on the max', () async {
      expect(await type('999'), '4.996');
    });
  });

  test('liquid unstake clamps against mallowSOL, with no reserve', () async {
    // Token-denominated: nothing is held back, because no rent is paid out of
    // the swapped amount.
    bloc
      ..add(const StakingEvent.setTab(StakeTab.unstake))
      ..add(const StakingEvent.setStakeType(StakeType.liquid));
    await fund(sol: 5000000000, mallowSol: 2500000000);

    expect(await type('4'), '2.5');
    expect(await type('2.5'), '2.5');
  });

  group('before a maximum is known', () {
    // `solLamports` starts at 0 and only fills in when the sheet's
    // fire-and-forget balance fetch pushes [StakingBalancesUpdated] — which
    // returns silently on a cold cache or a thrown read. Clamping against that
    // zero rewrote every keystroke to "0", and the form mirrors `state.amount`
    // back into the controller, so the field silently refused all input.
    test('typing is left alone while balances have not landed', () async {
      expect(await type('2.5'), '2.5');
      expect(await type('0.0001'), '0.0001');
    });

    test('the un-clamped amount still cannot be submitted', () async {
      await type('2.5');
      expect(bloc.state.canSubmit, isFalse);
    });

    test(
      'native unstake accepts input until the staking payload loads',
      () async {
        // Nothing is unstakable until `/v1/staking` lands, and that is not the
        // same fact as "you have nothing staked" — so the field must not fight
        // the user in the meantime. `canSubmit` is the real gate.
        bloc.add(const StakingEvent.setTab(StakeTab.unstake));
        await fund(sol: 5000000000);

        expect(await type('3'), '3');
        expect(bloc.state.canSubmit, isFalse);
      },
    );

    test('the clamp comes back as soon as a real maximum exists', () async {
      expect(await type('999'), '999');
      await fund(sol: 5000000000);
      expect(await type('999'), '4.996');
    });
  });

  test('canSubmit refuses an amount that eats into the reserve', () {
    // Belt-and-braces behind the clamp: even a value that reaches the state by
    // another route (Half, a restored draft) must not submit a native stake
    // whose `typed + rent` exceeds the balance.
    const overspend = StakingState(amount: '2', solLamports: 2000000000);
    expect(overspend.canSubmit, isFalse);
    const withinReserve = StakingState(amount: '1.99', solLamports: 2000000000);
    expect(withinReserve.canSubmit, isTrue);
  });
}
