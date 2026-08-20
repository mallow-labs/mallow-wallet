import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_events_repository.dart';
import 'package:mallow_wallet/features/artwork/widgets/history_section.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/no_verified_list_database.dart';

class _MockEventsRepository extends Mock implements ArtworkEventsRepository {}

class _MockDio extends Mock implements Dio {}

// Provenance is a trust surface: every figure on it is read as something that
// actually happened. Two rows were lying by omission because the client model
// dropped fields the endpoint already sends.
//
//  - A "set your own price" sale records the ONE buyer's figure. Printed as a
//    plain amount it reads as an asking price the seller never set.
//  - A buy-now edition sale is written against the print's own mint, so on a
//    master's provenance every sale rendered an identical "collected" with
//    nothing telling edition #2 from edition #200, and no route to the print
//    that actually changed hands.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockEventsRepository repository;

  setUpAll(() async {
    registerFallbackValue(api.EventMode.all);
    // Provenance rows resolve their sale currency through this service. Every
    // fixture below is SOL-priced, so it short-circuits on the static registry
    // and never issues a DAS request — it only has to exist.
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
  });

  setUp(() {
    repository = _MockEventsRepository();
    if (sl.isRegistered<ArtworkEventsRepository>()) {
      sl.unregister<ArtworkEventsRepository>();
    }
    sl.registerSingleton<ArtworkEventsRepository>(repository);
    // The row's avatar resolves AvatarService out of GetIt in `initState`;
    // without it every row builds as an ErrorWidget and the assertions below
    // would pass or fail for the wrong reason.
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
    }
  });

  tearDown(() {
    if (sl.isRegistered<ArtworkEventsRepository>()) {
      sl.unregister<ArtworkEventsRepository>();
    }
  });

  void stub(List<api.MarketActivityEvent> events) {
    when(
      () => repository.fetchEvents(
        mintAccount: any(named: 'mintAccount'),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        mode: any(named: 'mode'),
      ),
    ).thenAnswer((_) async => api.MarketActivityEventsPage(result: events));
  }

  api.MarketActivityEvent event({
    required api.MarketEventType type,
    api.ListingType? listingType,
    double? price,
    bool? buyerSetsPrice,
    api.MarketEventMetadata? metadata,
  }) => api.MarketActivityEvent(
    txId: 'sig1',
    mintAccount: 'PrintMint11111111111111111111111111111111111',
    type: type,
    user: const api.ApiUserRef(username: 'collector'),
    price: price,
    currencyMint: 'So11111111111111111111111111111111111111112',
    date: DateTime.utc(2026, 1, 2, 3, 4),
    listingType: listingType,
    buyerSetsPrice: buyerSetsPrice,
    metadata: metadata,
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HistorySection(
              mintAccount: 'MasterMint1111111111111111111111111111111',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('set your own price', () {
    testWidgets('a SYOP listing prints the word, not a figure', (tester) async {
      stub([
        event(
          type: api.MarketEventType.list,
          listingType: api.ListingType.buyNow,
          price: 1000000000,
          buyerSetsPrice: true,
        ),
      ]);
      await pump(tester);

      // `textContaining`, not `text`: the amount shares one rich-text span
      // with the relative age, so the row's plain text is "SYOP  3d ago".
      expect(find.textContaining('SYOP'), findsOneWidget);
      expect(find.textContaining('SOL'), findsNothing);
    });

    testWidgets('a SYOP sale shows no price block at all', (tester) async {
      // The buyer named this number themselves; rendering it beside "collected"
      // would present one person's offer as the piece's market price.
      stub([
        event(
          type: api.MarketEventType.sale,
          listingType: api.ListingType.buyNow,
          price: 1000000000,
          buyerSetsPrice: true,
        ),
      ]);
      await pump(tester);

      expect(find.textContaining('SYOP'), findsNothing);
      expect(find.textContaining('SOL'), findsNothing);
    });

    testWidgets('an ordinary listing still shows its price', (tester) async {
      // The guard must be the flag, not the listing type — otherwise it would
      // blank every buy-now row on the surface.
      stub([
        event(
          type: api.MarketEventType.list,
          listingType: api.ListingType.buyNow,
          price: 1000000000,
        ),
      ]);
      await pump(tester);

      expect(find.textContaining('SYOP'), findsNothing);
      expect(find.textContaining('SOL'), findsOneWidget);
    });
  });

  group('edition link', () {
    testWidgets('a buy-now edition sale names the print that sold', (
      tester,
    ) async {
      stub([
        event(
          type: api.MarketEventType.sale,
          listingType: api.ListingType.buyNow,
          price: 1000000000,
          metadata: const api.MarketEventMetadata(editionNumber: 12),
        ),
      ]);
      await pump(tester);

      expect(find.textContaining('Edition #12'), findsOneWidget);
    });

    testWidgets('the edition number is thousands-grouped', (tester) async {
      // Large open editions really do run past 1,000; an ungrouped "Edition
      // #12345" is the same digit soup thousands-grouping exists to prevent.
      stub([
        event(
          type: api.MarketEventType.sale,
          listingType: api.ListingType.buyNow,
          price: 1000000000,
          metadata: const api.MarketEventMetadata(editionNumber: 12345),
        ),
      ]);
      await pump(tester);

      expect(find.textContaining('Edition #12,345'), findsOneWidget);
    });

    testWidgets('a 1/1 sale carries no edition tail', (tester) async {
      // Nothing to name: there is exactly one of these, and a stray
      // "Edition #" would invent an edition structure that doesn't exist.
      stub([
        event(
          type: api.MarketEventType.sale,
          listingType: api.ListingType.buyNow,
          price: 1000000000,
        ),
      ]);
      await pump(tester);

      expect(find.textContaining('Edition #'), findsNothing);
    });

    testWidgets('an auction win carries no edition tail', (tester) async {
      // The webapp scopes the link to the buy-now branch; an auction row's
      // sentence is already "won the auction".
      stub([
        event(
          type: api.MarketEventType.sale,
          listingType: api.ListingType.auction,
          price: 1000000000,
          metadata: const api.MarketEventMetadata(editionNumber: 12),
        ),
      ]);
      await pump(tester);

      expect(find.textContaining('Edition #'), findsNothing);
    });
  });
}
