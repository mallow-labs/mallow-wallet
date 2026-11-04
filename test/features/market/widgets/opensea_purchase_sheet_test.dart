import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_action_state.dart';
import 'package:mallow_wallet/features/market/services/opensea_purchase.dart';
import 'package:mallow_wallet/features/market/widgets/opensea_listing_sheet.dart';
import 'package:mallow_wallet/features/market/widgets/opensea_purchase_sheet.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

import '../opensea_fixtures.dart';

class _Service extends Mock implements OpenSeaPurchaseService {}

void main() {
  late _Service service;
  late OpenSeaReview review;
  setUpAll(() {
    registerFallbackValue(
      OpenSeaReview(
        purchaseQuote(),
        mint,
        'wallet',
        BigInt.from(9999),
        BigInt.from(240),
      ),
    );
    registerFallbackValue(artwork);
    registerFallbackValue(
      PendingOpenSeaPurchase(purchaseQuote(), mint, '0x${'ab' * 32}', 3),
    );
  });
  setUp(() {
    service = _Service();
    review = OpenSeaReview(
      purchaseQuote(),
      mint,
      'wallet',
      BigInt.from(9999),
      BigInt.from(240),
    );
    when(() => service.pending()).thenAnswer((_) async => null);
    when(() => service.review(any())).thenAnswer((_) async => review);
  });
  tearDown(() => debugShowNftCommerceOverride = null);

  Future<void> pump(WidgetTester tester, {Widget? child}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body:
              child ?? OpenSeaPurchaseSheet(artwork: artwork, service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder button(String label) => find.widgetWithText(MallowButton, label);

  testWidgets('review shows wallet, itemized fees and maximum total', (
    tester,
  ) async {
    await pump(tester);
    for (final label in [
      'Seller proceeds',
      'OpenSea fees',
      'Creator fees',
      'Maximum network fee',
      'Maximum total',
      buyer,
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('0.00000000000000124 ETH'), findsOneWidget);
    expect(button('Buy'), findsOneWidget);
  });
  testWidgets('insufficient ETH disables purchase', (tester) async {
    review = OpenSeaReview(
      purchaseQuote(),
      mint,
      'wallet',
      BigInt.from(1239),
      BigInt.from(240),
    );
    await pump(tester);
    final buy = tester.widget<MallowButton>(button('Insufficient ETH balance'));
    expect(buy.onPressed, isNull);
  });
  testWidgets('ERC1155 review says one copy of listed supply', (tester) async {
    final q = OpenSeaPurchaseQuote.fromJson(
      quoteJson(standard: 'erc1155')..['listedCopies'] = '8',
    );
    review = OpenSeaReview(
      q,
      mint,
      'wallet',
      BigInt.from(9999),
      BigInt.from(240),
    );
    await pump(tester);
    expect(find.text('1 of 8 listed'), findsOneWidget);
  });
  testWidgets('pending submission offers status recovery and prevents buy', (
    tester,
  ) async {
    final pending = PendingOpenSeaPurchase(
      purchaseQuote(),
      mint,
      '0x${'ab' * 32}',
      3,
    );
    when(() => service.pending()).thenAnswer((_) async => pending);
    when(
      () => service.resolve(any()),
    ).thenAnswer((_) async => OpenSeaResolution.pending);
    await pump(tester);
    expect(button('Buy'), findsNothing);
    expect(button('Check transaction status'), findsOneWidget);
    verifyNever(() => service.review(any()));
  });
  testWidgets('mined purchase without a verified transfer says so', (
    tester,
  ) async {
    when(() => service.pending()).thenAnswer(
      (_) async =>
          PendingOpenSeaPurchase(purchaseQuote(), mint, '0x${'ab' * 32}', 3),
    );
    when(
      () => service.resolve(any()),
    ).thenAnswer((_) async => OpenSeaResolution.unverified);
    await pump(tester);
    expect(find.text(openSeaUnverifiedMessage), findsOneWidget);
    expect(find.text('Artwork collected'), findsNothing);
    expect(button('Check transaction status'), findsNothing);
  });
  testWidgets('purchase waits for confirmed transfer before collected state', (
    tester,
  ) async {
    final done = Completer<String>();
    when(() => service.buy(any(), onSigned: any(named: 'onSigned'))).thenAnswer(
      (call) {
        (call.namedArguments[#onSigned] as VoidCallback?)?.call();
        return done.future;
      },
    );
    await pump(tester);
    await tester.tap(button('Buy'));
    await tester.pump();
    expect(find.text('Confirming on Ethereum…'), findsOneWidget);
    expect(find.text('Artwork collected'), findsNothing);
    done.complete('0x${'ab' * 32}');
    await tester.pumpAndSettle();
    expect(find.text('Artwork collected'), findsOneWidget);
    expect(button('Done'), findsOneWidget);
  });
  testWidgets('changed price clears the old review and offers refresh', (
    tester,
  ) async {
    when(() => service.buy(any(), onSigned: any(named: 'onSigned'))).thenThrow(
      const AppFailure.validation('The price changed. Refresh the quote.'),
    );
    await pump(tester);
    await tester.tap(button('Buy'));
    await tester.pumpAndSettle();
    expect(button('Buy'), findsNothing);
    expect(button('Refresh quote'), findsOneWidget);
    expect(find.text('The price changed. Refresh the quote.'), findsOneWidget);
  });
  testWidgets('store-hidden listing has no purchase button', (tester) async {
    debugShowNftCommerceOverride = false;
    await pump(
      tester,
      child: OpenSeaListingSheet(artwork: artwork, onBuy: () {}),
    );
    expect(find.text('Listed on OpenSea'), findsOneWidget);
    expect(button('Buy'), findsNothing);
  });
  testWidgets('store-hidden review cannot expose purchase or outlink', (
    tester,
  ) async {
    debugShowNftCommerceOverride = false;
    await pump(tester);
    expect(button('Buy'), findsNothing);
    expect(button('View on OpenSea'), findsNothing);
  });
  testWidgets('ended listing disables purchase', (tester) async {
    await pump(
      tester,
      child: OpenSeaListingSheet(
        artwork: artwork,
        onBuy: () {},
        block: ArtworkBuyBlock.ended,
      ),
    );
    expect(tester.widget<MallowButton>(button('Sale ended')).onPressed, isNull);
  });
}
