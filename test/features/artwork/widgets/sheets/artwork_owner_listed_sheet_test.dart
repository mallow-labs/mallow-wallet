import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart'
    show MallowApiClient, OfferRender, OfferType;
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_owner_listed_sheet.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/no_verified_list_database.dart';

// "Cancel listing" is an escape hatch — how an owner gets a listed asset back.
// It normally lives *inside* the update-listing sheet, behind "Update listing".
// A store build that hides NFT commerce (the iOS App Store build) hides
// "Update listing" (price changes are the paid side), so the sheet must
// surface cancel directly; otherwise the owner's listing is stranded in the
// app. With commerce shown the sheet is exactly what it was.

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

const _sol = 'So11111111111111111111111111111111111111112';

const _artwork = ArtworkDetails(
  mintAccount: 'mint1',
  title: 'T',
  imageUrl: '',
  description: null,
  artistName: 'A',
  artistAddress: 'artist1',
  price: 1000000000,
  currency: _sol,
  listingType: ListingType.buyNow,
);

const _offer = OfferRender(
  offerType: OfferType.nft,
  buyerAddress: 'buyer1',
  asset: 'mint1',
  currencyMint: _sol,
  price: 500000000,
);

void main() {
  setUpAll(() async {
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
  });
  tearDown(() => debugShowNftCommerceOverride = null);

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onUpdateListing,
    VoidCallback? onCancelListing,
    ValueChanged<OfferRender>? onAcceptOffer,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArtworkOwnerListedSheet(
            artwork: _artwork,
            highestOffer: _offer,
            onUpdateListing: onUpdateListing ?? () {},
            onCancelListing: onCancelListing ?? () {},
            onAcceptOffer: onAcceptOffer ?? (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('with commerce shown: Update listing + Accept highest offer, '
      'no direct cancel (it lives inside the update sheet)', (tester) async {
    debugShowNftCommerceOverride = true;
    await pump(tester);
    expect(find.text('Update listing'), findsOneWidget);
    expect(find.text('Accept highest offer'), findsOneWidget);
    expect(find.text('Cancel listing'), findsNothing);
  });

  testWidgets('with commerce hidden: Cancel listing takes the slot; Update '
      'listing and Accept highest offer are not rendered', (tester) async {
    debugShowNftCommerceOverride = false;
    var cancelled = 0;
    var updated = 0;
    await pump(
      tester,
      onCancelListing: () => cancelled++,
      onUpdateListing: () => updated++,
    );

    expect(find.text('Update listing'), findsNothing);
    expect(find.text('Accept highest offer'), findsNothing);
    expect(find.text('Cancel listing'), findsOneWidget);

    await tester.tap(find.text('Cancel listing'));
    await tester.pump();
    expect(cancelled, 1);
    expect(updated, 0);
  });

  testWidgets('the loading state disables Cancel listing like any other CTA', (
    tester,
  ) async {
    debugShowNftCommerceOverride = false;
    var cancelled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArtworkOwnerListedSheet(
            artwork: _artwork,
            isLoading: true,
            onUpdateListing: () {},
            onCancelListing: () => cancelled++,
            onAcceptOffer: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Cancel listing'), warnIfMissed: false);
    await tester.pump();
    expect(cancelled, 0);
  });
}
