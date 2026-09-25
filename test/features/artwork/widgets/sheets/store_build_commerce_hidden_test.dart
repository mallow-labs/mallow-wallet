import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart'
    show MallowApiClient, OfferRender, OfferType;
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_buy_edition_sheet.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_buy_sheet.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_external_link_sheet.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_funding_source.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_owner_sheet.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_raffle_sheet.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_sheet_frame.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_unlisted_viewer_sheet.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/highest_offer_panel.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/no_verified_list_database.dart';

// The iOS App Store build hides NFT commerce (Guideline 3.1.1) and ships a
// view-only marketplace. These are the per-sheet consequences: every purchase
// CTA and every outlink that lands on a purchase page is not rendered — not
// disabled, not relabelled — while the price, the status and every escape
// hatch (cancel an offer, claim a prize, send the artwork) stay exactly as
// they were. `kShowNftCommerce` is compile-time and `true` under
// `flutter test`; the override drives the hidden branch.

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockAuthService extends Mock implements AuthService {}

class _MockDio extends Mock implements Dio {}

const _sol = 'So11111111111111111111111111111111111111112';

ArtworkDetails _artwork({
  ListingType listingType = ListingType.buyNow,
  RaffleMetadata? raffle,
}) => ArtworkDetails(
  mintAccount: 'mint1',
  title: 'T',
  imageUrl: '',
  description: null,
  artistName: 'A',
  artistAddress: 'artist1',
  price: 1000000000,
  currency: _sol,
  listingType: listingType,
  raffleMetadata: raffle,
);

const _offer = OfferRender(
  offerType: OfferType.nft,
  buyerAddress: 'buyer1',
  asset: 'mint1',
  currencyMint: _sol,
  price: 500000000,
);

RaffleMetadata _raffle({int sold = 10}) => RaffleMetadata(
  mintAccount: 'mint1',
  creator: 'artist1',
  raffleAccount: 'raffle1',
  entrantsAccount: 'entrants1',
  priceRaw: 100000000,
  currencyMint: _sol,
  supply: 10,
  sold: sold,
);

/// A live raffle a non-owner still has room to enter — the one combination
/// that reaches the in-app buy CTA.
ArtworkRaffleSheet _sellingRaffleSheet(RaffleMetadata raffle) =>
    ArtworkRaffleSheet(
      artwork: _artwork(listingType: ListingType.raffle, raffle: raffle),
      role: RaffleRole.buyer,
      subState: RaffleSubState.selling,
      raffle: raffle,
      gate: const RaffleGate(canBuyTickets: true, walletLimit: 5),
      onBuyTickets: () {},
      onCancelRaffle: () {},
      onClaimNft: () {},
      onClaimProceeds: () {},
    );

void main() {
  late _MockTokenBalanceBloc balances;

  setUpAll(() async {
    // Price rows resolve their currency through these; SOL is registry-priced
    // so nothing leaves the process. The avatar on the highest-offer panel is
    // a generated identicon.
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
    final auth = _MockAuthService();
    when(() => auth.currentAddress).thenReturn(null);
    if (!sl.isRegistered<AuthService>()) {
      sl.registerSingleton<AuthService>(auth);
    }
    // The highest-offer panel draws the buyer's avatar; an unstubbed Dio
    // fails every fetch, so it falls back to the generated identicon.
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
    }
  });

  setUp(() {
    debugShowNftCommerceOverride = false;
    balances = _MockTokenBalanceBloc();
    when(() => balances.state).thenReturn(const TokenBalanceState.initial());
  });
  tearDown(() => debugShowNftCommerceOverride = null);

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

  group('buy sheet', () {
    testWidgets('keeps the price, drops Buy and Make offer', (tester) async {
      await pump(
        tester,
        ArtworkBuySheet(
          artwork: _artwork(),
          onBuy: () {},
          onMakeOffer: () {},
          onCancelOffer: () {},
        ),
      );
      expect(find.byType(ArtworkSheetPriceRow), findsOneWidget);
      expect(find.text('Buy'), findsNothing);
      expect(find.text('Make offer'), findsNothing);
    });

    testWidgets('a live offer of your own can still be cancelled', (
      tester,
    ) async {
      await pump(
        tester,
        ArtworkBuySheet(
          artwork: _artwork(),
          userOwnOffer: true,
          onBuy: () {},
          onMakeOffer: () {},
          onCancelOffer: () {},
        ),
      );
      expect(find.text('Cancel offer'), findsOneWidget);
      expect(find.text('Update offer'), findsNothing);
      expect(find.text('Buy'), findsNothing);
    });

    testWidgets('with commerce shown the CTAs are back', (tester) async {
      debugShowNftCommerceOverride = true;
      await pump(
        tester,
        ArtworkBuySheet(
          artwork: _artwork(),
          onBuy: () {},
          onMakeOffer: () {},
          onCancelOffer: () {},
        ),
      );
      expect(find.text('Buy'), findsOneWidget);
      expect(find.text('Make offer'), findsOneWidget);
    });
  });

  testWidgets('buy-edition sheet keeps the price, drops Buy edition', (
    tester,
  ) async {
    await pump(
      tester,
      ArtworkBuyEditionSheet(
        artwork: _artwork(),
        onBuyEdition: () {},
        onMakeOffer: () {},
      ),
    );
    expect(find.byType(ArtworkSheetPriceRow), findsOneWidget);
    expect(find.text('Buy edition'), findsNothing);
  });

  group('unlisted viewer sheet', () {
    testWidgets('keeps the offer status, drops Make offer', (tester) async {
      await pump(
        tester,
        ArtworkUnlistedViewerSheet(
          artwork: _artwork(listingType: ListingType.unlisted),
          onMakeOffer: () {},
          onCancelOffer: () {},
        ),
      );
      expect(find.text('No active offers yet.'), findsOneWidget);
      expect(find.text('Make offer'), findsNothing);
    });

    testWidgets('your own offer stays cancellable', (tester) async {
      await pump(
        tester,
        ArtworkUnlistedViewerSheet(
          artwork: _artwork(listingType: ListingType.unlisted),
          userOwnOffer: true,
          onMakeOffer: () {},
          onCancelOffer: () {},
        ),
      );
      expect(find.text('Cancel offer'), findsOneWidget);
      expect(find.text('Update offer'), findsNothing);
    });
  });

  testWidgets('owner sheet still shows the highest offer but does not offer '
      'to accept it; Send stays', (tester) async {
    await pump(
      tester,
      ArtworkOwnerSheet(
        artwork: _artwork(listingType: ListingType.unlisted),
        canList: false,
        highestOffer: _offer,
        onList: () {},
        onSend: () {},
        onAcceptOffer: (_) {},
      ),
    );
    expect(find.byType(HighestOfferPanel), findsOneWidget);
    expect(find.text('Accept Offer'), findsNothing);
    expect(find.text('Send artwork'), findsOneWidget);
  });

  testWidgets('external-listing sheet keeps the explanation, drops the '
      'outlink to the sale page', (tester) async {
    await pump(
      tester,
      const ArtworkExternalLinkSheet(listingType: ListingType.gumball),
    );
    expect(find.text('Gumball drop'), findsOneWidget);
    expect(find.text('This sale runs on the mallow web app.'), findsOneWidget);
    expect(find.text('View on mallow web'), findsNothing);
  });

  group('raffle sheet', () {
    testWidgets('a sold-out raffle shows its status and no outlink', (
      tester,
    ) async {
      final raffle = _raffle();
      await pump(
        tester,
        ArtworkRaffleSheet(
          artwork: _artwork(listingType: ListingType.raffle, raffle: raffle),
          role: RaffleRole.buyer,
          subState: RaffleSubState.selling,
          raffle: raffle,
          gate: const RaffleGate(isSoldOut: true),
          onBuyTickets: () {},
          onCancelRaffle: () {},
          onClaimNft: () {},
          onClaimProceeds: () {},
        ),
      );
      // The status line and the disabled "Sold out" slot stay…
      expect(find.text('Sold out'), findsWidgets);
      // …the outlink to the artwork's purchase page does not.
      expect(find.text('View on mallow.art'), findsNothing);
      expect(find.text('Buy tickets'), findsNothing);
    });

    testWidgets('a raffle you could still enter offers no way to buy in', (
      tester,
    ) async {
      // `kShowRaffleEntry` is `kDebugMode`-derived, so it is true under
      // `flutter test` and in every debug run — including the
      // `--dart-define=SHOW_NFT_COMMERCE=false` run used to check this build by
      // hand. That pairing used to fall straight through to the in-app CTA:
      // the ticket-count sheet opened and only the signing backstop refused,
      // which also files the miss in Sentry as a bug in the entry gates.
      await pump(tester, _sellingRaffleSheet(_raffle(sold: 1)));

      expect(find.text('Buy tickets'), findsNothing);
      // The switcher exists only to choose which wallet pays for tickets.
      expect(find.byType(ArtworkFundingSource), findsNothing);
      // The outlink is not a substitute here — it lands on the purchase page.
      expect(find.text('View on mallow.art'), findsNothing);
      // …and the status line must not invite a purchase the sheet then offers
      // no way to make.
      expect(find.text('Buy tickets for a chance to win'), findsNothing);
      expect(find.text('Raffle in progress'), findsOneWidget);
      // Nothing left in the button slot means the gap above it goes too,
      // otherwise every live raffle in this build ends in a dangling spacer.
      expect(
        find.descendant(
          of: find.byType(ArtworkRaffleSheet),
          matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.height == MallowTheme.spacingMd,
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('with commerce shown the buy CTA and its funding switch are '
        'back', (tester) async {
      debugShowNftCommerceOverride = true;
      await pump(tester, _sellingRaffleSheet(_raffle(sold: 1)));

      expect(find.text('Buy tickets'), findsOneWidget);
      expect(find.byType(ArtworkFundingSource), findsOneWidget);
    });

    testWidgets('the winner can still claim the prize', (tester) async {
      final raffle = _raffle();
      await pump(
        tester,
        ArtworkRaffleSheet(
          artwork: _artwork(listingType: ListingType.raffle, raffle: raffle),
          role: RaffleRole.winner,
          subState: RaffleSubState.drawnUnclaimed,
          raffle: raffle,
          onBuyTickets: () {},
          onCancelRaffle: () {},
          onClaimNft: () {},
          onClaimProceeds: () {},
        ),
      );
      expect(find.text('Claim NFT'), findsOneWidget);
    });
  });
}
