import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show MallowApiClient;
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/sheets/artwork_auction_bid_sheet.dart';
import 'package:mallow_wallet/features/market/widgets/place_bid_sheet.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/no_verified_list_database.dart';

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

class _MockAuthService extends Mock implements AuthService {}

const _sol = 'So11111111111111111111111111111111111111112';

ArtworkDetails _artwork() => const ArtworkDetails(
  mintAccount: 'mint1',
  title: 'T',
  imageUrl: '',
  description: null,
  artistName: 'A',
  artistAddress: 'artist1',
  listingType: ListingType.auction,
  currency: _sol,
);

void main() {
  late _MockTokenBalanceBloc balances;

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
  tearDown(() => debugShowNftCommerceOverride = null);

  Future<void> pump(
    WidgetTester tester, {
    required bool warn,
    VoidCallback? onPlaceBid,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: BlocProvider<TokenBalanceBloc>.value(
            value: balances,
            child: ArtworkAuctionBidSheet(
              artwork: _artwork(),
              onPlaceBid: onPlaceBid ?? () {},
              showPermanentDelegateWarning: warn,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder warning() => find.text(kCoreAuctionPermanentDelegateWarning);

  testWidgets('warns, and the bid still goes through', (tester) async {
    var bids = 0;
    await pump(tester, warn: true, onPlaceBid: () => bids++);

    expect(warning(), findsOneWidget);
    final button = tester.widget<MallowButton>(
      find.widgetWithText(MallowButton, 'Place bid'),
    );
    expect(button.enabled, isTrue);
    await tester.tap(find.text('Place bid'));
    expect(bids, 1);
  });

  testWidgets('says nothing without a delegate and leaves bidding alone', (
    tester,
  ) async {
    await pump(tester, warn: false);

    expect(warning(), findsNothing);
    final button = tester.widget<MallowButton>(
      find.widgetWithText(MallowButton, 'Place bid'),
    );
    expect(button.enabled, isTrue);
  });

  testWidgets('a store build with no bidding has nothing to warn about', (
    tester,
  ) async {
    debugShowNftCommerceOverride = false;
    await pump(tester, warn: true);

    expect(warning(), findsNothing);
  });

  test('the copy covers settlement and promises no automatic refund', () {
    expect(
      kCoreAuctionPermanentDelegateWarning,
      contains('burn, move or freeze it before or after the sale settles'),
    );
    expect(
      kCoreAuctionPermanentDelegateWarning,
      contains('If that happens before it settles'),
    );
    expect(
      kCoreAuctionPermanentDelegateWarning,
      contains("the sale can't complete, even if you've won"),
    );
    expect(
      kCoreAuctionPermanentDelegateWarning,
      contains("refunds aren't automatic"),
    );
    expect(
      kCoreAuctionPermanentDelegateWarning,
      contains("after it settles, the bid can't be refunded"),
    );
    // An unused delegate opens no refund: the program answers AssetDeliverable.
    expect(
      kCoreAuctionPermanentDelegateWarning,
      isNot(contains('Before it settles, the bid can be')),
    );
  });
}
