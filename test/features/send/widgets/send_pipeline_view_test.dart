import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/priority_fee_service.dart';
import 'package:mallow_wallet/features/portfolio/models/token_balance.dart';
import 'package:mallow_wallet/features/send/services/send_bloc.dart';
import 'package:mallow_wallet/features/send/widgets/send_pipeline_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart' show Chain;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockSendBloc extends MockBloc<SendEvent, SendState>
    implements SendBloc {}

/// The pipeline's "Done" early exit is a *safety* affordance, not a cosmetic
/// one: tapping it pops the send sheet, which disposes the [SendBloc] hosting
/// this view. From that moment no error can reach the user.
///
/// So the invariant every test here defends: Done may only be offered once the
/// broadcast has been accepted by the node AND handed to the pending-tx tracker
/// (`SendBroadcasting.pendingRegistered`). Offered any earlier — the state is
/// entered *before* `sendRawTransaction` runs — a failing broadcast would emit
/// its error into a disposed bloc: no error shown, no Pending entry, and a user
/// convinced a transaction that never left is in flight.
void main() {
  // `any()` on SendEvent needs a fallback instance registered.
  setUpAll(() => registerFallbackValue(const SendEvent.reset()));

  const ethToken = TokenBalance(
    mint: TokenBalance.evmNativeSentinel,
    symbol: 'ETH',
    name: 'Ethereum',
    decimals: 18,
    rawBalance: 0,
    uiBalance: 0,
    chain: Chain.ethereum,
  );
  const solToken = TokenBalance(
    mint: 'So11111111111111111111111111111111111111112',
    symbol: 'SOL',
    name: 'Solana',
    decimals: 9,
    rawBalance: 0,
    uiBalance: 0,
  );

  late _MockSendBloc bloc;
  late PriorityFeeService priorityFee;

  setUp(() async {
    bloc = _MockSendBloc();
    // The error body asks the global priority-fee setting whether there is
    // still headroom to offer an "Increase priority fee" link.
    SharedPreferences.setMockInitialValues({});
    priorityFee = PriorityFeeService(await PreferencesService.create());
    if (GetIt.I.isRegistered<PriorityFeeService>()) {
      await GetIt.I.unregister<PriorityFeeService>();
    }
    GetIt.I.registerSingleton<PriorityFeeService>(priorityFee);
  });

  tearDown(() async {
    if (GetIt.I.isRegistered<PriorityFeeService>()) {
      await GetIt.I.unregister<PriorityFeeService>();
    }
  });

  Future<void> pump(
    WidgetTester tester,
    SendState state, {
    required TokenBalance? token,
    Chain chain = Chain.solana,
  }) async {
    whenListen(bloc, const Stream<SendState>.empty(), initialState: state);
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: BlocProvider<SendBloc>.value(
          value: bloc,
          child: Scaffold(
            body: SendPipelineView(
              token: token,
              chain: chain,
              onResetToInput: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('withholds Done while the broadcast is still in flight', (
    tester,
  ) async {
    // SendBroadcasting is entered after signing but *before* the raw tx is on
    // the wire — the window where a throwing RPC still needs somewhere to
    // surface.
    await pump(
      tester,
      const SendState.broadcasting(),
      token: ethToken,
      chain: Chain.ethereum,
    );

    expect(find.text('Confirming transaction…'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('offers Done once the pending tracker owns the transaction', (
    tester,
  ) async {
    await pump(
      tester,
      const SendState.broadcasting(pendingRegistered: true),
      token: ethToken,
      chain: Chain.ethereum,
    );

    expect(find.text('Done'), findsOneWidget);
  });

  // WHY: a *native* selection reaches the pipeline as a null token — SendBloc
  // collapses the native/wrapped distinction onto the no-token path — so gating
  // the early exit on the token withheld Done from native ETH, the one send the
  // pending-tx tracker exists for, and labelled it "Sending SOL…" on Ethereum.
  testWidgets('offers Done on a native ETH send', (tester) async {
    await pump(
      tester,
      const SendState.broadcasting(pendingRegistered: true),
      token: null,
      chain: Chain.ethereum,
    );

    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('names the chain\'s native coin, not SOL', (tester) async {
    await pump(
      tester,
      const SendState.input(),
      token: null,
      chain: Chain.ethereum,
    );

    expect(find.text('Sending ETH…'), findsOneWidget);
    expect(find.text('Sending SOL…'), findsNothing);
  });

  testWidgets('never offers Done off EVM, tracked or not', (tester) async {
    // Solana/Tezos have no pending-tx tracker, so the 60 s wait *is* the only
    // confirmation the user gets — leaving early would drop it.
    await pump(
      tester,
      const SendState.broadcasting(pendingRegistered: true),
      token: solToken,
    );

    expect(find.text('Done'), findsNothing);
  });

  testWidgets('withholds Done while signing', (tester) async {
    await pump(
      tester,
      const SendState.signing(),
      token: ethToken,
      chain: Chain.ethereum,
    );

    expect(find.text('Done'), findsNothing);
  });

  testWidgets('shows local approval copy for a non-Ledger signer', (
    tester,
  ) async {
    await pump(tester, const SendState.signing(), token: solToken);

    expect(find.text('Approving transaction…'), findsOneWidget);
    expect(find.text('One moment please'), findsOneWidget);
    expect(find.text('Approve the transaction to continue'), findsNothing);
  });

  testWidgets('keeps the Ledger approval prompt', (tester) async {
    await pump(
      tester,
      const SendState.signing(onLedger: true),
      token: solToken,
    );

    expect(find.text('Awaiting approval…'), findsOneWidget);
    expect(find.text('Approve the transaction on your Ledger'), findsOneWidget);
    expect(find.text('Approving transaction…'), findsNothing);
  });

  testWidgets('uses the external-wallet fallback for social signers', (
    tester,
  ) async {
    await pump(
      tester,
      const SendState.signing(isLocal: false),
      token: solToken,
    );

    expect(find.text('Awaiting approval…'), findsOneWidget);
    expect(find.text('Approve the transaction in your wallet'), findsOneWidget);
    expect(find.text('Approving transaction…'), findsNothing);
  });

  // An on-chain failure is terminal and unambiguous — nothing moved, so
  // retrying is safe and the headline may say "failed".
  testWidgets('a real failure keeps the failure headline and offers a retry', (
    tester,
  ) async {
    await pump(
      tester,
      const SendState.error(message: 'Instruction 2 failed: Custom error 6003'),
      token: solToken,
    );

    expect(find.text('Transaction failed'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    verify(() => bloc.add(const SendEvent.reset())).called(1);
  });

  // The indeterminate end state. "Transaction failed" would be a lie — the tx
  // may still land — and an enabled "Try again" is the double-send trap the
  // whole fix exists to close.
  testWidgets('an unconfirmed broadcast is not framed as a failure and cannot '
      'be retried', (tester) async {
    await pump(
      tester,
      const SendState.error(
        message:
            'This transaction may still land. Check Activity or the '
            'explorer before sending again.',
        unconfirmed: true,
      ),
      token: solToken,
    );

    expect(find.text('Transaction failed'), findsNothing);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    expect(find.textContaining('may still land'), findsOneWidget);

    await tester.tap(find.text('Try again'), warnIfMissed: false);
    await tester.pump();
    verifyNever(() => bloc.add(any()));
  });

  // Retrying a transaction that expired unlanded at the same priority fee
  // reproduces the expiry — the fee is the variable, so the recovery the user
  // needs is the setting, not the button. Mirrors the webapp's
  // "Try increasing your Transaction Priority fee" on the same error class.
  testWidgets('an unconfirmed broadcast offers a route to raise the fee', (
    tester,
  ) async {
    await pump(
      tester,
      const SendState.error(message: 'expired', unconfirmed: true),
      token: solToken,
    );

    expect(find.text('Increase priority fee'), findsOneWidget);
  });

  testWidgets('an unconfirmed Tezos broadcast offers no Solana fee link', (
    tester,
  ) async {
    await pump(
      tester,
      const SendState.error(message: 'expired', unconfirmed: true),
      token: null,
      chain: Chain.tezos,
    );

    expect(find.text('Increase priority fee'), findsNothing);
  });

  testWidgets('a real failure offers no fee link — the fee is not the cause', (
    tester,
  ) async {
    await pump(
      tester,
      const SendState.error(message: 'Insufficient funds'),
      token: solToken,
    );

    expect(find.text('Increase priority fee'), findsNothing);
  });

  testWidgets('at Turbo there is nothing left to raise, so no link', (
    tester,
  ) async {
    await priorityFee.set(PriorityFeeTier.turbo.lamports);
    await pump(
      tester,
      const SendState.error(message: 'expired', unconfirmed: true),
      token: solToken,
    );

    expect(find.text('Increase priority fee'), findsNothing);
  });
}
