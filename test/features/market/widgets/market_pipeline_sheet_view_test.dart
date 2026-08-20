import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart'
    show SolanaTransactionUnconfirmedException;
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/market/widgets/market_pipeline_sheet_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockMarketBloc extends MockBloc<MarketEvent, MarketState>
    implements MarketBloc {}

/// "Try again" on a market pipeline is not a UI nicety — it re-runs the whole
/// action, and a market retry is a *fresh* backend-built purchase (new
/// blockhash, and for editions a new ephemeral print-mint signer). So when the
/// broadcast outcome is unknown — `SolanaTransactionUnconfirmedException`, the
/// blockhash expired before we ever observed the transaction land — an enabled
/// retry is a double-payment trap: if the original does land, both settle and
/// the buyer pays twice.
///
/// The invariant defended here: an unconfirmed failure is never framed as a
/// failure and can never be retried from this sheet. Determinate failures keep
/// their retry, because nothing moved and re-sending is safe.
void main() {
  setUpAll(() => registerFallbackValue(const MarketEvent.reset()));

  late _MockMarketBloc bloc;

  setUp(() => bloc = _MockMarketBloc());

  Future<void> pump(WidgetTester tester, MarketState state) async {
    whenListen(bloc, const Stream<MarketState>.empty(), initialState: state);
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: BlocProvider<MarketBloc>.value(
          value: bloc,
          child: const Scaffold(
            body: MarketPipelineSheetView(actionType: 'buy'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a determinate failure keeps the failure headline and offers a '
      'retry', (tester) async {
    await pump(
      tester,
      const TxFlowFailure<MarketPrepData, MarketSuccessData>(
        AppFailure.rpc('Instruction 2 failed: Custom error 6003'),
      ),
    );

    expect(find.text('Transaction failed'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    verify(() => bloc.add(const MarketEvent.reset())).called(1);
  });

  testWidgets('an unconfirmed broadcast is not framed as a failure and cannot '
      'be retried', (tester) async {
    final failure = AppFailure.from(
      const SolanaTransactionUnconfirmedException('sigSTUCK'),
    ).prefixedWith('Buy failed');

    await pump(
      tester,
      TxFlowFailure<MarketPrepData, MarketSuccessData>(failure),
    );

    expect(find.text('Transaction failed'), findsNothing);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    // The exception's own copy points the user at Activity / the explorer and
    // must survive the bloc's "Buy failed: " prefixing verbatim.
    expect(find.textContaining('may still land'), findsOneWidget);
    expect(find.textContaining('Buy failed'), findsNothing);

    // The button is still laid out (the sheet keeps a fixed footprint) but is
    // inert — tapping it must not re-enter the flow.
    await tester.tap(find.text('Try again'), warnIfMissed: false);
    await tester.pump();
    verifyNever(() => bloc.add(any()));
  });
}
