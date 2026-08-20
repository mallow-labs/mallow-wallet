import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/screens/portfolio_group_screen.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_network_image.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

class _MockAuthService extends Mock implements AuthService {}

class _MockPreferencesService extends Mock implements PreferencesService {}

class _MockPortfolioRepository extends Mock implements PortfolioRepository {}

class _MockUserProfileRepository extends Mock
    implements UserProfileRepository {}

class _MockSessionManager extends Mock implements SessionManager {}

class _MockCastBloc extends MockBloc<CastEvent, CastState>
    implements CastBloc {}

/// The drilldown header names the group, so its image must be the group's own
/// identity — the artist's profile picture, the collection's cover. The
/// grouped portfolio feed fills `ArtGroup.thumbnailUrl` with one of the owned
/// artworks whenever it has nothing better, so a header that reads that field
/// first claims "this artist IS this piece I happen to hold".
void main() {
  const artistAddress = 'SOL_ARTIST_A';
  const viewerAddress = 'SOL_VIEWER_V';
  const mint = 'COLLECTION_MINT';
  const ownedArtworkUrl = 'https://cdn.example/owned-artwork.png';
  const artistAvatarUrl = 'https://cdn.example/artist-pfp.png';
  const collectionImageUrl = 'https://cdn.example/collection-cover.png';

  late _MockAuthService authService;
  late _MockPreferencesService prefs;
  late _MockPortfolioRepository portfolioRepo;
  late _MockUserProfileRepository profileRepo;
  late _MockCastBloc castBloc;

  setUpAll(() {
    if (!sl.isRegistered<AvatarService>()) {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
    }
  });

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUp(() {
    authService = _MockAuthService();
    prefs = _MockPreferencesService();
    portfolioRepo = _MockPortfolioRepository();
    profileRepo = _MockUserProfileRepository();
    castBloc = _MockCastBloc();

    whenListen(
      castBloc,
      const Stream<CastState>.empty(),
      initialState: const CastState.idle(),
    );

    when(() => authService.currentAddress).thenReturn(viewerAddress);
    when(() => authService.isFollowing(any())).thenReturn(false);
    // An empty owned slice keeps the header's image the only one on screen.
    when(
      () => portfolioRepo.getGroupArtworks(any(), page: any(named: 'page')),
    ).thenAnswer(
      (_) async => const PortfolioArtworksResult(artworks: [], total: 0),
    );
    when(() => profileRepo.getCollectionByMint(any())).thenAnswer(
      (_) async => const api.CollectionFullRender(
        slug: mint,
        name: 'A Collection',
        imageUrl: collectionImageUrl,
      ),
    );

    final session = _MockSessionManager();
    when(() => session.sessionAddresses).thenReturn({viewerAddress});
    when(() => session.ownsAddress(any())).thenReturn(false);

    register<AuthService>(authService);
    register<PreferencesService>(prefs);
    register<PortfolioRepository>(portfolioRepo);
    register<UserProfileRepository>(profileRepo);
    register<SessionManager>(session);
    register<CastBloc>(castBloc);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<AuthService>();
    drop<PreferencesService>();
    drop<PortfolioRepository>();
    drop<UserProfileRepository>();
    drop<SessionManager>();
    drop<CastBloc>();
  });

  /// Mounts the drilldown and settles the header's own async lookups.
  Future<void> mount(WidgetTester tester, ArtGroup group) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: PortfolioGroupScreen(group: group),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// The raw URL the header handed to [MallowNetworkImage]. Null when the
  /// header fell through to the generated identicon.
  String? headerImageUrl(WidgetTester tester) {
    final images = tester.widgetList<MallowNetworkImage>(
      find.byType(MallowNetworkImage),
    );
    return images.isEmpty ? null : images.first.imageUrl;
  }

  testWidgets('artist header shows the artist pfp, not an owned artwork', (
    tester,
  ) async {
    await mount(
      tester,
      const ArtGroup(
        id: 'artist:$artistAddress',
        type: ArtGroupType.artist,
        // What the grouped feed sends: a piece the viewer holds.
        thumbnailUrl: ownedArtworkUrl,
        avatarUrl: artistAvatarUrl,
        name: 'An Artist',
        artworkCount: 3,
        artistAddress: artistAddress,
      ),
    );

    expect(headerImageUrl(tester), artistAvatarUrl);
  });

  testWidgets('artist header keeps the feed thumbnail when there is no pfp', (
    tester,
  ) async {
    // Why: an artist who never set a profile picture would otherwise drop to
    // the identicon, losing the only image the feed could offer.
    await mount(
      tester,
      const ArtGroup(
        id: 'artist:$artistAddress',
        type: ArtGroupType.artist,
        thumbnailUrl: ownedArtworkUrl,
        name: 'An Artist',
        artworkCount: 3,
        artistAddress: artistAddress,
      ),
    );

    expect(headerImageUrl(tester), ownedArtworkUrl);
  });

  testWidgets('collection header shows the collection image, not owned art', (
    tester,
  ) async {
    await mount(
      tester,
      const ArtGroup(
        id: 'collection:$mint',
        type: ArtGroupType.collection,
        // The feed's owned-artwork fallback, sent when the collection record
        // it read carried no image of its own.
        thumbnailUrl: ownedArtworkUrl,
        name: 'A Collection',
        artworkCount: 2,
        collectionMint: mint,
      ),
    );

    expect(headerImageUrl(tester), collectionImageUrl);
  });

  testWidgets('collection header falls back to the collection token image', (
    tester,
  ) async {
    // Why: the curated image defaults to empty on the collection record, so
    // treating "" as an image would blank the header for every collection
    // that only has on-chain metadata.
    when(() => profileRepo.getCollectionByMint(any())).thenAnswer(
      (_) async => const api.CollectionFullRender(
        slug: mint,
        name: 'A Collection',
        imageUrl: '',
        nft: api.CollectionDetailNft(
          mintAccount: mint,
          imageUrl: collectionImageUrl,
        ),
      ),
    );

    await mount(
      tester,
      const ArtGroup(
        id: 'collection:$mint',
        type: ArtGroupType.collection,
        thumbnailUrl: ownedArtworkUrl,
        name: 'A Collection',
        artworkCount: 2,
        collectionMint: mint,
      ),
    );

    expect(headerImageUrl(tester), collectionImageUrl);
  });
}
