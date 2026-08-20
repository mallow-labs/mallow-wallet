import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart'
    show SolanaTransactionUnconfirmedException;
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/widgets/burn_artwork_flow.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockMarketBloc extends MockBloc<MarketEvent, MarketState>
    implements MarketBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _MockRemoteConfig extends Fake implements RemoteConfigService {
  @override
  final ValueListenable<RemoteConfig> config = ValueNotifier(
    RemoteConfig.permissive,
  );

  @override
  Future<void> refreshIfStale() async {}
}

const _mint = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

/// The artwork burn pipeline's "Try again" dispatches `MarketEvent.reset()`,
/// which drops the flow back to idle so the user can burn again. When the
/// broadcast outcome is *unknown* — `SolanaTransactionUnconfirmedException`:
/// the blockhash expired before the transaction was ever observed landing —
/// "Burn failed" asserts the artwork survived, which we do not know. A user who
/// believes that acts on it (re-lists, re-buys, files a support ticket) over an
/// asset that may already be destroyed. Determinate failures keep the retry:
/// nothing was broadcast, so re-burning is safe.
void main() {
  late _MockMarketBloc bloc;
  late StreamController<MarketState> states;

  final artwork = PortfolioArtwork(
    mintAccount: _mint,
    title: 'Test NFT',
    imageUrl: '',
    artistName: 'Artist',
  );

  final ready = TxFlowReady<MarketPrepData, MarketSuccessData>(
    MarketPrepData(
      transactionsBase64: ['TX'],
      mintAccount: _mint,
      actionType: 'burn',
      flow: AppFlow.nftBurn,
      totalCost: MarketPrice.zero(),
      estimatedFeeLamports: 5000,
    ),
  );

  setUp(() async {
    bloc = _MockMarketBloc();
    states = StreamController<MarketState>.broadcast();
    whenListen(bloc, states.stream, initialState: ready);

    if (!sl.isRegistered<AnalyticsService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(
          Dio(),
          await PreferencesService.create(),
          const FlutterSecureStorage(),
        ),
      );
    }

    void register<T extends Object>(T instance) {
      if (sl.isRegistered<T>()) sl.unregister<T>();
      sl.registerFactory<T>(() => instance);
    }

    register<MarketBloc>(bloc);
    register<RemoteConfigService>(_MockRemoteConfig());

    final balances = _MockTokenBalanceBloc();
    whenListen(
      balances,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );
    register<TokenBalanceBloc>(balances);
  });

  tearDown(() async {
    await states.close();
    for (final drop in [
      () => sl.unregister<MarketBloc>(),
      () => sl.unregister<RemoteConfigService>(),
      () => sl.unregister<TokenBalanceBloc>(),
    ]) {
      drop();
    }
  });

  /// The sheet's CTA animates indefinitely, so `pumpAndSettle` never returns.
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Confirms the burn, morphs to the pipeline step, then lands [failure].
  Future<void> burnUntilError(WidgetTester tester, AppFailure failure) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => runBurnArtworkFlow(context, artwork: artwork),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await flush(tester);

    await tester.tap(find.text('Burn Artwork').last);
    await flush(tester);

    // Only *after* the morph settles: the flow sheet's own listener pops the
    // whole route on a failure seen before the confirm step is gone (that is
    // the prepare-failure case), so an instantly-failing burn would never
    // render the pipeline body under test.
    states.add(TxFlowFailure<MarketPrepData, MarketSuccessData>(failure));
    await flush(tester);
  }

  testWidgets('a determinate failure keeps the failure headline and offers a '
      'retry', (tester) async {
    await burnUntilError(
      tester,
      const AppFailure.rpc('Instruction 1 failed: Custom error 6003'),
    );

    expect(find.text('Burn failed'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    verify(() => bloc.add(const MarketEvent.reset())).called(1);
  });

  testWidgets('an unconfirmed broadcast is not framed as a failure and cannot '
      'be retried', (tester) async {
    await burnUntilError(
      tester,
      AppFailure.from(
        const SolanaTransactionUnconfirmedException('sigSTUCK'),
      ).prefixedWith('Burn failed'),
    );

    expect(find.text('Burn failed'), findsNothing);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    // The exception's own copy points the user at Activity / the explorer and
    // must survive the bloc's prefixing verbatim.
    expect(find.textContaining('may still land'), findsOneWidget);

    // The button is still laid out (the sheet keeps a fixed footprint) but is
    // inert.
    await tester.tap(find.text('Try again'), warnIfMissed: false);
    await tester.pump();
    verifyNever(() => bloc.add(const MarketEvent.reset()));

    // …and the user is never stranded: Back still resets the flow, which pops
    // the sheet.
    await tester.tap(find.text('Back'));
    await tester.pump();
    verify(() => bloc.add(const MarketEvent.reset())).called(1);
  });
}
