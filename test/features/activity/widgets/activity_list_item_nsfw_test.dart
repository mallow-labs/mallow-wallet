import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/activity/widgets/activity_list_item.dart';
import 'package:mallow_wallet/shared/widgets/nsfw_obscured.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAuthService extends Mock implements AuthService {}

// The activity feed renders the same artwork the portfolio grids render. A
// viewer who has left the show-NSFW setting off has said they don't want to see
// flagged work; the grids honour that and the feed did not, because the wire
// row carried no flag at all. These tests pin the row honouring the same
// setting, and — just as importantly — pin it NOT blurring unflagged art, since
// an over-eager blur would frost the whole feed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerSingleton<T>(instance);
  }

  Future<void> setUpServices({required bool showNsfw}) async {
    SharedPreferences.setMockInitialValues({
      'pref_show_nsfw': showNsfw,
      'pref_nsfw_warning_shown': true,
    });
    final prefs = await PreferencesService.create();
    final authService = _MockAuthService();
    when(() => authService.currentUser).thenReturn(null);
    register<PreferencesService>(prefs);
    register<AuthService>(authService);
  }

  tearDown(() {
    for (final drop in [
      () => sl.isRegistered<PreferencesService>()
          ? sl.unregister<PreferencesService>()
          : null,
      () =>
          sl.isRegistered<AuthService>() ? sl.unregister<AuthService>() : null,
    ]) {
      drop();
    }
  });

  api.Activity marketRow({required bool nsfw}) => api.Activity(
    id: 'a1',
    type: api.ActivityType.sale,
    timestamp: 1700000000,
    signature: 'sig1',
    status: api.ActivityStatus.confirmed,
    data: {
      'artwork': {
        'mintAccount': 'ArtMint11111111111111111111111111111111111',
        'name': 'Sunset',
        'imageUrl': 'https://example.com/art.png',
        'nsfw': nsfw,
      },
      'price': 0.5,
      'currencyMint': 'So11111111111111111111111111111111111111112',
      'currencySymbol': 'SOL',
    },
  );

  api.Activity nftTransferRow({required bool nsfw}) => api.Activity(
    id: 'a2',
    type: api.ActivityType.receive,
    timestamp: 1700000000,
    signature: 'sig2',
    status: api.ActivityStatus.confirmed,
    data: {
      'token': {
        'mint': 'NftMint111111111111111111111111111111111111',
        'symbol': '',
        'amount': 1.0,
        'decimals': 0,
        'logoUrl': 'https://example.com/art.png',
      },
      'counterparty': {
        'address': 'Sender1111111111111111111111111111111111111',
      },
      'isNft': true,
      'nftName': 'Sunset',
      'nftNsfw': nsfw,
    },
  );

  Future<void> pump(WidgetTester tester, api.Activity activity) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ActivityListItem(activity: activity)),
        ),
      );

  /// The overlay only exists when the widget is actually obscuring something —
  /// [NsfwObscured] returns its child untouched when `nsfw` is false.
  Finder obscured() =>
      find.byWidgetPredicate((w) => w is NsfwObscured && w.nsfw);

  testWidgets('marketplace row obscures a flagged artwork thumbnail', (
    tester,
  ) async {
    await setUpServices(showNsfw: false);
    await pump(tester, marketRow(nsfw: true));

    expect(obscured(), findsOneWidget);
  });

  testWidgets('marketplace row leaves an unflagged thumbnail alone', (
    tester,
  ) async {
    await setUpServices(showNsfw: false);
    await pump(tester, marketRow(nsfw: false));

    expect(obscured(), findsNothing);
  });

  testWidgets('NFT transfer row obscures a flagged artwork thumbnail', (
    tester,
  ) async {
    // Transfer rows render the artwork from `token.logoUrl`, not from a nested
    // artwork object, so they carry their own flag and need their own wiring.
    await setUpServices(showNsfw: false);
    await pump(tester, nftTransferRow(nsfw: true));

    expect(obscured(), findsOneWidget);
  });

  testWidgets('NFT transfer row leaves an unflagged thumbnail alone', (
    tester,
  ) async {
    await setUpServices(showNsfw: false);
    await pump(tester, nftTransferRow(nsfw: false));

    expect(obscured(), findsNothing);
  });
}
