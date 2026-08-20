import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart'
    show ArtworkRoyaltySplit;
import 'package:mallow_wallet/features/market/models/market_price.dart';
import 'package:mallow_wallet/features/market/widgets/update_listing_sheet.dart';
import 'package:mallow_wallet/features/sale/services/proceeds_calculator.dart';
import 'package:mocktail/mocktail.dart';

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

const _seller = 'SeLLeR11111111111111111111111111111111111111';
const _creator = 'CrEaToR1111111111111111111111111111111111111';

/// Stands in for [resolveUpdateListingProceeds]: a 5% marketplace fee, a 10%
/// royalty to another creator, the rest to the seller — a secondary sale, so
/// the royalty is paid out of the price rather than folded into a primary
/// split.
List<ProceedsSplit> _splitsFor(int priceRaw) => computeProceedsSplits(
  seller: _seller,
  priceRaw: priceRaw,
  isSecondary: true,
  royaltyShares: const [
    ArtworkRoyaltySplit(address: _creator, sharePercent: 100),
  ],
  royaltyBps: 1000,
  primaryFeeBps: 500,
  secondaryFeeBps: 250,
);

/// Listing *creation* shows the owner exactly who gets what before they
/// commit to a price; changing that price showed nothing at all, so the one
/// screen where a seller re-prices their work was the one that wouldn't tell
/// them what the new price pays them. The webapp renders `ProceedsInfo` in
/// `UpdateListingModal` for precisely this reason.
void main() {
  late ValueNotifier<RemoteConfig> config;

  setUpAll(() {
    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }
  });

  setUp(() {
    config = ValueNotifier(RemoteConfig.permissive);
    final remoteConfig = MockRemoteConfigService();
    when(() => remoteConfig.config).thenReturn(config);
    when(remoteConfig.refreshIfStale).thenAnswer((_) async {});
    if (sl.isRegistered<RemoteConfigService>()) {
      sl.unregister<RemoteConfigService>();
    }
    sl.registerFactory<RemoteConfigService>(() => remoteConfig);
  });

  tearDown(() {
    if (sl.isRegistered<RemoteConfigService>()) {
      sl.unregister<RemoteConfigService>();
    }
    config.dispose();
  });

  Widget buildSheet({Future<ProceedsSplitsForPrice?> Function()? resolver}) =>
      MaterialApp(
        home: Scaffold(
          body: UpdateListingSheet(
            mintAccount: 'mint',
            currentPrice: const MarketPrice(
              rawAmount: 1000000000,
              currencyMint: solMint,
            ),
            proceedsResolver: resolver,
          ),
        ),
      );

  testWidgets('the breakdown follows the price being typed, not the price '
      'currently listed', (tester) async {
    await tester.pumpWidget(buildSheet(resolver: () async => _splitsFor));
    await tester.pumpAndSettle();

    // Before a price is entered the rows exist but carry no amount — same
    // treatment as the creation review step, so the layout doesn't jump.
    expect(find.text('Proceeds'), findsOneWidget);
    expect(find.text('—'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, '10');
    await tester.pumpAndSettle();

    // 10 SOL: 2.5% mallow fee, 10% royalty to the creator, 87.5% to the seller.
    expect(find.textContaining('8.75'), findsOneWidget);
    expect(find.textContaining('0.25'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('a failed resolve renders no breakdown and never blocks the '
      'price edit itself', (tester) async {
    await tester.pumpWidget(buildSheet(resolver: () async => null));
    await tester.pumpAndSettle();

    expect(find.text('Proceeds'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '2');
    await tester.pumpAndSettle();
    expect(find.text('Proceeds'), findsNothing);
    expect(find.widgetWithText(TextField, '2'), findsOneWidget);
  });
}
