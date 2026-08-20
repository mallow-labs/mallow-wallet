import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/activity/widgets/activity_preview.dart';
import 'package:mallow_wallet/shared/widgets/nsfw_obscured.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAuthService extends Mock implements AuthService {}

// The activity *row* blurs flagged artwork; the detail sheet it opens rendered
// the same artwork at ~300dp unblurred. That made the row's blur theatre: one
// tap defeated a setting the viewer explicitly left off, on a surface reached
// without any warning. These tests pin the sheet honouring the same setting as
// the row it came from — and, equally, pin it NOT blurring unflagged art, since
// an over-eager frost would cover every activity detail on the app.
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
    if (sl.isRegistered<PreferencesService>()) {
      sl.unregister<PreferencesService>();
    }
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
  });

  Map<String, dynamic> artwork(bool nsfw) => {
    'mintAccount': 'ArtMint11111111111111111111111111111111111',
    'name': 'Sunset',
    'imageUrl': 'https://example.com/art.png',
    'nsfw': nsfw,
  };

  // `sale` renders through the single-image branch.
  api.Activity saleRow({required bool nsfw}) => api.Activity(
    id: 'a1',
    type: api.ActivityType.sale,
    timestamp: 1700000000,
    signature: 'sig1',
    status: api.ActivityStatus.confirmed,
    data: {
      'artwork': artwork(nsfw),
      'price': 0.5,
      'currencyMint': 'So11111111111111111111111111111111111111112',
      'currencySymbol': 'SOL',
    },
  );

  // `buy` renders through the split-view branch, whose NFT side is a separate
  // code path from the single image above.
  api.Activity buyRow({required bool nsfw}) => api.Activity(
    id: 'a2',
    type: api.ActivityType.buy,
    timestamp: 1700000000,
    signature: 'sig2',
    status: api.ActivityStatus.confirmed,
    data: {
      'artwork': artwork(nsfw),
      'price': 0.5,
      'currencyMint': 'So11111111111111111111111111111111111111112',
      'currencySymbol': 'SOL',
    },
  );

  api.Activity nftTransferRow({required bool nsfw}) => api.Activity(
    id: 'a3',
    type: api.ActivityType.receive,
    timestamp: 1700000000,
    signature: 'sig3',
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

  // The single-image preview is a full-width 1:1 square, which overflows the
  // default 800×600 test window; bound it to a phone-ish width so layout is
  // representative rather than clipped.
  Future<void> pump(WidgetTester tester, api.Activity activity) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: ActivityPreview(activity: activity),
              ),
            ),
          ),
        ),
      );

  /// [NsfwObscured] returns its child untouched when `nsfw` is false, so an
  /// obscuring instance existing at all is the signal.
  Finder obscured() =>
      find.byWidgetPredicate((w) => w is NsfwObscured && w.nsfw);

  testWidgets('sale preview obscures a flagged artwork', (tester) async {
    await setUpServices(showNsfw: false);
    await pump(tester, saleRow(nsfw: true));

    expect(obscured(), findsOneWidget);
  });

  testWidgets('sale preview leaves an unflagged artwork alone', (tester) async {
    await setUpServices(showNsfw: false);
    await pump(tester, saleRow(nsfw: false));

    expect(obscured(), findsNothing);
  });

  testWidgets('buy preview obscures the flagged artwork side', (tester) async {
    await setUpServices(showNsfw: false);
    await pump(tester, buyRow(nsfw: true));

    // Exactly one: the currency side is a token logo and must stay legible.
    expect(obscured(), findsOneWidget);
  });

  testWidgets('NFT transfer preview obscures a flagged artwork', (
    tester,
  ) async {
    // Transfer previews render the artwork from `token.logoUrl` and carry
    // their own flag, so they need their own wiring.
    await setUpServices(showNsfw: false);
    await pump(tester, nftTransferRow(nsfw: true));

    expect(obscured(), findsOneWidget);
  });

  testWidgets('the viewer\'s show-NSFW setting still wins', (tester) async {
    // The frost is the *setting*, not a hard block: a viewer who opted in sees
    // the artwork here exactly as they do in the grids.
    await setUpServices(showNsfw: true);
    await pump(tester, saleRow(nsfw: true));

    expect(find.text('Reveal artwork'), findsNothing);
  });
}
