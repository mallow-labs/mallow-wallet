import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/data/mallow_tokens.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/market/models/market_price.dart';
import 'package:mallow_wallet/features/market/widgets/update_listing_sheet.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

/// The sheet only reads cached prices for its USD lines; nothing hits the
/// network, so an unimplemented client is enough.
class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

/// The listing row's two cells, read **by the sheet itself**.
///
/// The sheet takes no message parameters — it subscribes to
/// [RemoteConfigService.config]. Two properties that buys, both asserted below:
/// a caller cannot render it ungated by forgetting an optional argument (that is
/// a compile-time property now, so there is no test for it), and a kill landing
/// while the sheet is already open disables the button it applies to.
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

  /// Seeds the kill switch with `'<chain>:<flow>' -> message` cells.
  void kill(Map<String, String> cells) =>
      config.value = RemoteConfig(disabledMessages: cells);

  // No gating arguments — the sheet reads both cells itself. A caller
  // simply cannot construct it ungated any more.
  Widget buildSheet() => const MaterialApp(
    home: Scaffold(
      body: UpdateListingSheet(
        mintAccount: 'mint',
        currentPrice: MarketPrice(rawAmount: 1000000000, currencyMint: solMint),
      ),
    ),
  );

  VoidCallback? onPressedOf(WidgetTester tester, String label) => tester
      .widget<MallowButton>(find.widgetWithText(MallowButton, label))
      .onPressed;

  testWidgets('cancel stays live when only the price update is killed', (
    tester,
  ) async {
    // One sheet, two builders (`/tx/fixed-price/update` and 🔓
    // `/tx/fixed-price/cancel`). Cancelling is how an owner gets a listed
    // asset back — if a broken price-update kill also greyed out "Cancel
    // listing", every listed piece would be stuck until the incident ended.
    const message = 'Price updates are paused while we fix a rounding bug.';
    kill({'solana:fixed-price-update': message});
    await tester.pumpWidget(buildSheet());
    await tester.pumpAndSettle();

    expect(onPressedOf(tester, 'Cancel listing'), isNotNull);
    expect(onPressedOf(tester, 'Update price'), isNull);
    // Greyed out with the reason, not just greyed out.
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('the price update stays live when only cancel is killed', (
    tester,
  ) async {
    const message = 'Delisting is paused.';
    kill({'solana:fixed-price-cancel': message});
    await tester.pumpWidget(buildSheet());
    await tester.pumpAndSettle();

    expect(onPressedOf(tester, 'Cancel listing'), isNull);
    expect(find.text(message), findsOneWidget);

    // "Update price" is still only enabled by a valid new amount, so type one
    // to prove the kill switch isn't what's holding it back.
    await tester.enterText(find.byType(TextField).first, '2');
    await tester.pumpAndSettle();
    expect(onPressedOf(tester, 'Update price'), isNotNull);
  });

  testWidgets('neither action is touched when nothing is killed', (
    tester,
  ) async {
    await tester.pumpWidget(buildSheet());
    await tester.pumpAndSettle();

    expect(onPressedOf(tester, 'Cancel listing'), isNotNull);
    await tester.enterText(find.byType(TextField).first, '2');
    await tester.pumpAndSettle();
    expect(onPressedOf(tester, 'Update price'), isNotNull);
  });

  testWidgets('a dual kill renders BOTH cells\' copy, not just the update one', (
    tester,
  ) async {
    // `_onUpdateListing` used to early-return here and
    // show only the update-side message; the delist copy — the only thing that
    // tells an owner whether their asset is stuck for the incident — was
    // discarded. Both buttons dead, both reasons on screen.
    const updateMessage = 'Price updates are paused.';
    const cancelMessage = 'Delisting is paused — your artwork is safe.';
    kill({
      'solana:fixed-price-update': updateMessage,
      'solana:fixed-price-cancel': cancelMessage,
    });
    await tester.pumpWidget(buildSheet());
    await tester.pumpAndSettle();

    expect(onPressedOf(tester, 'Update price'), isNull);
    expect(onPressedOf(tester, 'Cancel listing'), isNull);
    expect(find.text(updateMessage), findsOneWidget);
    expect(find.text(cancelMessage), findsOneWidget);
  });

  testWidgets('a kill landing while the sheet is open disables it live', (
    tester,
  ) async {
    // The reason the read is reactive rather than a snapshot taken at the call
    // site: an operator pulling the switch mid-session must not leave an owner
    // holding a live "Cancel listing" button that will fail at the signing
    // backstop with no explanation.
    const message = 'Delisting is paused — your artwork is safe.';
    await tester.pumpWidget(buildSheet());
    await tester.pumpAndSettle();
    expect(onPressedOf(tester, 'Cancel listing'), isNotNull);

    kill({'solana:fixed-price-cancel': message});
    await tester.pumpAndSettle();

    expect(onPressedOf(tester, 'Cancel listing'), isNull);
    expect(find.text(message), findsOneWidget);
  });
}
