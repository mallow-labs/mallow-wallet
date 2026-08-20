import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show MallowApiClient;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_action_state.dart'
    show ArtworkBuyBlock;
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_buy_edition_sheet.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_buy_sheet.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/no_verified_list_database.dart';

// A blocked listing must read as "you can't buy this right now, here's why",
// not as an enabled Buy that fails after the biometric prompt. Two of these
// states are unreachable-by-design rather than transient: a pre-start or ended
// sale reverts on-chain (no backend validates the window), and a non-SOL 1/1
// gets a flat `400 "Non-native currency listing: swapQuote is required"` from
// the v2 single-tx builder, which mobile cannot satisfy.

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockAuthService extends Mock implements AuthService {}

const _usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

ArtworkDetails _artwork({String? currency}) => ArtworkDetails(
  mintAccount: 'mint1',
  title: 'T',
  imageUrl: '',
  description: null,
  artistName: 'A',
  artistAddress: 'artist1',
  price: 1000000000,
  currency: currency,
  listingType: ListingType.buyNow,
);

void main() {
  late _MockTokenBalanceBloc balances;

  setUpAll(() async {
    // Every price row on these sheets resolves its currency through this
    // service. The fixtures are all registry-priced, so it short-circuits on
    // the static table and never issues a DAS request — it only has to exist.
    SharedPreferences.setMockInitialValues({});
    if (!sl.isRegistered<TokenMetadataService>()) {
      final prefs = await PreferencesService.create();
      sl.registerLazySingleton<TokenMetadataService>(
        () => TokenMetadataService(
          DasApiService(),
          prefs,
          NoVerifiedListDatabase(),
        ),
      );
    }
    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }
    // `ArtworkFundingSource` reads the signer to decide whether to draw the
    // "switch wallet" line. Null keeps the line off — irrelevant here, the CTA
    // itself is what's under test.
    final auth = _MockAuthService();
    when(() => auth.currentAddress).thenReturn(null);
    if (!sl.isRegistered<AuthService>()) {
      sl.registerSingleton<AuthService>(auth);
    }
  });

  setUp(() {
    balances = _MockTokenBalanceBloc();
    when(() => balances.state).thenReturn(const TokenBalanceState.initial());
  });

  Future<void> pump(WidgetTester tester, Widget sheet) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<TokenBalanceBloc>.value(
            value: balances,
            child: sheet,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Widget buySheet({ArtworkBuyBlock? block, String? currency}) =>
      ArtworkBuySheet(
        artwork: _artwork(currency: currency),
        onBuy: () {},
        onMakeOffer: () {},
        onCancelOffer: () {},
        block: block,
      );

  testWidgets('an unblocked 1/1 renders the normal Buy CTA', (tester) async {
    await pump(tester, buySheet());
    expect(find.text('Buy'), findsOneWidget);
  });

  testWidgets('a pre-start sale replaces Buy with an explanation', (
    tester,
  ) async {
    await pump(tester, buySheet(block: ArtworkBuyBlock.notStarted));
    expect(find.text('Buy'), findsNothing);
    expect(find.text('Sale not started'), findsOneWidget);
    expect(find.textContaining('has not started'), findsOneWidget);
  });

  testWidgets('an ended sale replaces Buy with an explanation', (tester) async {
    await pump(tester, buySheet(block: ArtworkBuyBlock.ended));
    expect(find.text('Buy'), findsNothing);
    expect(find.text('Sale ended'), findsOneWidget);
    expect(find.textContaining('has ended'), findsOneWidget);
  });

  // A USDC listing is bought by spending the buyer's USDC, so the sheet must
  // offer a live Buy. This used to render "Unavailable in app" over copy
  // telling the user to finish on the web app.
  testWidgets('a USDC-priced 1/1 offers a live Buy', (tester) async {
    await pump(tester, buySheet(currency: _usdcMint));
    expect(find.text('Buy'), findsOneWidget);
    expect(find.text('Unavailable in app'), findsNothing);
    expect(find.textContaining('not supported'), findsNothing);
  });

  testWidgets('the edition sheet applies the same window gate', (tester) async {
    await pump(
      tester,
      ArtworkBuyEditionSheet(
        artwork: _artwork(),
        onBuyEdition: () {},
        onMakeOffer: () {},
        block: ArtworkBuyBlock.notStarted,
      ),
    );
    expect(find.text('Buy edition'), findsNothing);
    expect(find.text('Sale not started'), findsOneWidget);
  });

  // The price above an `unknownCurrency` CTA is a shimmer or "Unknown token",
  // so the button must not be pressable — otherwise the user signs for an
  // amount they were never shown. Unlike the other blocks this one is
  // transient, so the label stays the normal call to action rather than
  // announcing a problem that is about to disappear.
  group('unresolved currency', () {
    testWidgets('the 1/1 Buy CTA renders disabled with no scare copy', (
      tester,
    ) async {
      await pump(tester, buySheet(block: ArtworkBuyBlock.unknownCurrency));

      expect(find.text('Buy'), findsOneWidget);
      expect(
        tester.widget<MallowButton>(find.byType(MallowButton).first).enabled,
        isFalse,
      );
      expect(find.textContaining('not supported'), findsNothing);
    });

    testWidgets('the edition CTA is blocked too — the old gap', (tester) async {
      // The removed `unsupportedCurrency` gate never reached the edition
      // sheet, so an edition listed in a deleted memecoin kept a live Buy over
      // a blank price. `unknownCurrency` is what closes that.
      await pump(
        tester,
        ArtworkBuyEditionSheet(
          artwork: _artwork(),
          onBuyEdition: () {},
          onMakeOffer: () {},
          block: ArtworkBuyBlock.unknownCurrency,
        ),
      );

      expect(
        tester
            .widget<MallowButton>(
              find.widgetWithText(MallowButton, 'Buy edition'),
            )
            .enabled,
        isFalse,
      );
    });

    testWidgets('a resolved currency leaves the CTA live', (tester) async {
      await pump(tester, buySheet());

      expect(
        tester.widget<MallowButton>(find.byType(MallowButton).first).enabled,
        isTrue,
      );
    });
  });
}
