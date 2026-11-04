import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/market/services/magic_eden_purchase.dart';
import 'package:mallow_wallet/features/market/widgets/magic_eden_purchase_sheet.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements MagicEdenPurchaseService {}

const _artwork = ArtworkDetails(
  mintAccount: 'mint',
  title: 'Test artwork',
  imageUrl: '',
  description: null,
  artistName: 'Artist',
  artistAddress: 'artist',
);
MagicEdenReview _review() => MagicEdenReview(
  MagicEdenBuyQuote(
    orderId: 'order',
    revision: 1,
    mintAccount: 'mint',
    seller: 'seller',
    currencyMint: solMint,
    currencySymbol: 'SOL',
    currencyDecimals: 9,
    sellerPrice: '1000000000',
    creatorRoyalty: '10000000',
    magicEdenFee: '20000000',
    mallowFeeLamports: '30000000',
    networkFeeLamports: '40000',
    rentLamports: '500000',
    totalPaymentAmount: '1030000000',
    totalSolDebitLamports: '1060540000',
    buyerPaymentBalance: '2000000000',
    buyerSolBalanceLamports: '2000000000',
    expiresAt: DateTime.now().add(const Duration(minutes: 1)),
  ),
  'buyer',
  'wallet',
);

void main() {
  late _Service service;
  late MagicEdenReview review;
  setUpAll(() {
    registerFallbackValue(_review());
    registerFallbackValue(
      const PendingMagicEdenPurchase(
        signature: 'sig',
        mintAccount: 'mint',
        buyer: 'buyer',
        lastValidBlockHeight: 100,
      ),
    );
  });
  setUp(() {
    service = _Service();
    review = _review();
    when(() => service.pending()).thenAnswer((_) async => null);
    when(() => service.review('mint')).thenAnswer((_) async => review);
  });
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MagicEdenPurchaseSheet(artwork: _artwork, service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder button(String label) => find.widgetWithText(MallowButton, label);

  testWidgets(
    'review shows total and every fee without adding SOL price twice',
    (tester) async {
      await pump(tester);
      expect(find.text('1.06054 SOL'), findsOneWidget);
      for (final label in [
        'Seller price',
        'Creator royalty',
        'Magic Eden fee',
        'mallow fee',
        'Estimated network fee',
        'Account rent',
        'Total cost',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      expect(tester.widget<MallowButton>(button('Buy')).onPressed, isNotNull);
    },
  );
  testWidgets('shortfall disables buy while leaving quote refresh available', (
    tester,
  ) async {
    review = MagicEdenReview(
      review.quote.copyWith(buyerSolBalanceLamports: '1000000000'),
      'buyer',
      'wallet',
    );
    await pump(tester);
    expect(
      tester.widget<MallowButton>(button('Insufficient SOL balance')).onPressed,
      isNull,
    );
    expect(
      tester.widget<MallowButton>(button('Refresh quote')).onPressed,
      isNotNull,
    );
  });
  testWidgets('unavailable quote shows reason and permits a fresh quote', (
    tester,
  ) async {
    when(
      () => service.review('mint'),
    ).thenThrow(const AppFailure.validation('Order sold'));
    await pump(tester);
    expect(find.text('Order sold'), findsOneWidget);
    expect(button('Buy'), findsNothing);
    expect(button('Refresh quote'), findsOneWidget);
  });
  testWidgets(
    'pending purchase checks exact signature and blocks another buy',
    (tester) async {
      const entry = PendingMagicEdenPurchase(
        signature: 'pending-sig',
        mintAccount: 'mint',
        buyer: 'buyer',
        lastValidBlockHeight: 100,
      );
      when(() => service.pending()).thenAnswer((_) async => entry);
      when(
        () => service.resolve(entry),
      ).thenAnswer((_) async => MagicEdenResolution.pending);
      await pump(tester);
      expect(find.text('Signature: pending-sig'), findsOneWidget);
      expect(button('Buy'), findsNothing);
      await tester.tap(button('Check transaction status'));
      await tester.pumpAndSettle();
      verify(() => service.resolve(entry)).called(2);
      verifyNever(() => service.review(any()));
    },
  );
  testWidgets('released purchase with an unread status says so', (
    tester,
  ) async {
    const entry = PendingMagicEdenPurchase(
      signature: 'pending-sig',
      mintAccount: 'mint',
      buyer: 'buyer',
      lastValidBlockHeight: 100,
    );
    when(() => service.pending()).thenAnswer((_) async => entry);
    when(
      () => service.resolve(entry),
    ).thenAnswer((_) async => MagicEdenResolution.unknown);
    await pump(tester);
    expect(find.text(magicEdenUnknownMessage), findsOneWidget);
    expect(find.text('Signature: pending-sig'), findsNothing);
  });
  testWidgets('approval disables taps then shows the collected result', (
    tester,
  ) async {
    final submitted = Completer<String>();
    when(
      () => service.buy(any(), onSigned: any(named: 'onSigned')),
    ).thenAnswer((_) => submitted.future);
    await pump(tester);
    await tester.tap(button('Buy'));
    await tester.pump();
    expect(tester.widget<MallowButton>(button('Buy')).isLoading, isTrue);
    expect(button('Close'), findsNothing);
    submitted.complete('signature');
    await tester.pumpAndSettle();
    expect(find.text('Artwork collected'), findsOneWidget);
    expect(button('Done'), findsOneWidget);
    verify(
      () => service.buy(review, onSigned: any(named: 'onSigned')),
    ).called(1);
  });
}
