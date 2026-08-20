import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/offers/widgets/offers_artwork_group.dart';
import 'package:mallow_wallet/features/offers/widgets/offers_auction_bid_card.dart';
import 'package:mallow_wallet/shared/widgets/nsfw_obscured.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAuthService extends Mock implements AuthService {}

class _MockDio extends Mock implements Dio {}

// The offers inbox renders the same artwork the portfolio grids render, so a
// viewer who left the show-NSFW setting off must not have flagged work pushed
// at them here just because someone bid on it. These tests pin the blur, and
// pin unflagged art staying untouched — an over-eager blur would frost the
// whole inbox.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const solMint = 'So11111111111111111111111111111111111111112';

  setUpAll(() {
    // Bid cards render identicon avatars via AvatarService; an unstubbed Dio
    // makes every fetch fail so rows fall back to the anon avatar.
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
    }
  });
  tearDownAll(() {
    if (sl.isRegistered<AvatarService>()) sl.unregister<AvatarService>();
  });

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerSingleton<T>(instance);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'pref_show_nsfw': false,
      'pref_nsfw_warning_shown': true,
    });
    final prefs = await PreferencesService.create();
    final authService = _MockAuthService();
    when(() => authService.currentUser).thenReturn(null);
    register<PreferencesService>(prefs);
    register<AuthService>(authService);
  });

  tearDown(() {
    if (sl.isRegistered<PreferencesService>()) {
      sl.unregister<PreferencesService>();
    }
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
  });

  api.OffersInboxItem offer({required bool nsfw}) => api.OffersInboxItem(
    kind: api.OffersInboxKind.offer,
    direction: api.OffersInboxDirection.received,
    asset: 'ASSET',
    artworkTitle: 'Art',
    artworkImageUrl: 'https://example.com/art.png',
    nsfw: nsfw,
    actorAddress: 'W1',
    viewerAddress: 'SELLER',
    rawAmount: 2000000000,
    currencyMint: solMint,
  );

  api.OffersInboxItem bid({required bool nsfw}) => api.OffersInboxItem(
    kind: api.OffersInboxKind.bid,
    direction: api.OffersInboxDirection.placed,
    asset: 'ASSET',
    artworkTitle: 'Art',
    artworkImageUrl: 'https://example.com/art.png',
    nsfw: nsfw,
    actorAddress: 'W1',
    viewerAddress: 'W1',
    rawAmount: 2000000000,
    currencyMint: solMint,
    auction: const api.AuctionInfo(
      status: api.AuctionStatus.live,
      sellerAddress: 'SELLER',
    ),
  );

  /// The overlay only exists when it is actually obscuring something —
  /// [NsfwObscured] is not inserted at all for an unflagged artwork.
  Finder obscured() =>
      find.byWidgetPredicate((w) => w is NsfwObscured && w.nsfw);

  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('offer card obscures a flagged artwork thumbnail', (
    tester,
  ) async {
    await pump(
      tester,
      OffersArtworkGroup(item: offer(nsfw: true), rows: const []),
    );

    expect(obscured(), findsOneWidget);
  });

  testWidgets('offer card leaves an unflagged thumbnail alone', (tester) async {
    await pump(
      tester,
      OffersArtworkGroup(item: offer(nsfw: false), rows: const []),
    );

    expect(obscured(), findsNothing);
  });

  testWidgets('auction bid card obscures a flagged artwork thumbnail', (
    tester,
  ) async {
    await pump(
      tester,
      OffersAuctionBidCard(item: bid(nsfw: true), onView: () {}),
    );

    expect(obscured(), findsOneWidget);
  });

  testWidgets('auction bid card leaves an unflagged thumbnail alone', (
    tester,
  ) async {
    await pump(
      tester,
      OffersAuctionBidCard(item: bid(nsfw: false), onView: () {}),
    );

    expect(obscured(), findsNothing);
  });
}
