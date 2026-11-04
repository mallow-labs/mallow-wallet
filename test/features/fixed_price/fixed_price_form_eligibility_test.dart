import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show MallowApiClient;
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/fixed_price/screens/fixed_price_form_screen.dart';
import 'package:mallow_wallet/features/fixed_price/services/fixed_price_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mallow_wallet/features/sell/services/trade_eligibility.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';

class MockFixedPriceBloc extends MockBloc<FixedPriceEvent, FixedPriceState>
    implements FixedPriceBloc {}

/// [TokenPriceService] only hits the network in `start()`, which nothing here
/// calls, so the pricing step's USD estimate stays hidden.
class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

void main() {
  late MockFixedPriceBloc mockBloc;
  late MockTokenBalanceBloc mockTokenBalanceBloc;
  late StreamController<FixedPriceState> stateController;

  final testArtwork = PortfolioArtwork(
    mintAccount: '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM',
    title: 'Test NFT',
    imageUrl: '',
    artistName: 'Artist',
  );

  // A valid review-step state entered from the artwork detail screen, so the
  // form can mount every step without fetching an artwork.
  FixedPriceState reviewState({required FixedPriceFlowState flow}) =>
      FixedPriceState(
        step: FixedPriceStep.review,
        entryFromArtworkDetail: true,
        selectedArtwork: testArtwork,
        price: 1000000000,
        flow: flow,
      );

  setUp(() async {
    mockBloc = MockFixedPriceBloc();
    mockTokenBalanceBloc = MockTokenBalanceBloc();
    stateController = StreamController<FixedPriceState>.broadcast();

    // The form fires Listing analytics on the flow's terminal states. Register
    // an uninitialized AnalyticsService — track() no-ops (never calls init), so
    // it satisfies the sl<AnalyticsService>() lookup without network/config.
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

    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }

    final initial = reviewState(flow: const TxFlowIdle());
    whenListen(mockBloc, stateController.stream, initialState: initial);
    whenListen(
      mockTokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );

    if (sl.isRegistered<FixedPriceBloc>()) sl.unregister<FixedPriceBloc>();
    if (sl.isRegistered<TokenBalanceBloc>()) sl.unregister<TokenBalanceBloc>();
    sl.registerFactory<FixedPriceBloc>(() => mockBloc);
    sl.registerFactory<TokenBalanceBloc>(() => mockTokenBalanceBloc);
  });

  tearDown(() async {
    await stateController.close();
    if (sl.isRegistered<FixedPriceBloc>()) sl.unregister<FixedPriceBloc>();
    if (sl.isRegistered<TokenBalanceBloc>()) sl.unregister<TokenBalanceBloc>();
  });

  testWidgets(
    'eligibility feedback updates inline and retry keeps the pipeline closed',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: FixedPriceFormScreen(mintAccount: testArtwork.mintAccount),
        ),
      );
      await tester.pumpAndSettle();
      stateController.add(
        reviewState(
          flow: const TxFlowIdle(),
        ).copyWith(listingEligibilityError: verifyingArtworkEligibility),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text(verifyingArtworkEligibility), findsOneWidget);
      expect(find.byType(MallowLoader), findsOneWidget);
      stateController.add(
        reviewState(flow: const TxFlowIdle()).copyWith(
          listingEligibilityError: TradeEligibility.unverified.message,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(TradeEligibility.unverified.message!), findsOneWidget);
      expect(find.text('Listing failed'), findsNothing);
      await tester.tap(find.text('Try again'));
      verify(
        () => mockBloc.add(const FixedPriceEvent.retryEligibility()),
      ).called(1);
    },
  );
}
