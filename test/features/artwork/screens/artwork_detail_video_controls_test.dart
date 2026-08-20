import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/das_api_service.dart';
import 'package:mallow_wallet/core/realtime/market_realtime_service.dart';
import 'package:mallow_wallet/core/realtime/models/market_invalidation.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/token_price_service.dart';
import 'package:mallow_wallet/core/services/tx_landed_slots.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_events_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_listing_repository.dart';
import 'package:mallow_wallet/features/artwork/data/offer_repository.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/screens/artwork_detail_screen.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/features/profile/models/user_profile.dart';
import 'package:mallow_wallet/features/raffle/services/raffle_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_svg_icon.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../../support/no_verified_list_database.dart';

class MockMarketBloc extends MockBloc<MarketEvent, MarketState>
    implements MarketBloc {}

class MockArtworkBloc extends MockBloc<ArtworkEvent, ArtworkState>
    implements ArtworkBloc {
  @override
  Stream<String> get transientErrors => const Stream<String>.empty();
}

class MockRaffleBloc extends MockBloc<RaffleEvent, RaffleState>
    implements RaffleBloc {}

class MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class MockAuthService extends Mock implements AuthService {}

class MockSessionManager extends Mock implements SessionManager {}

class MockArtworkPermissionService extends Mock
    implements ArtworkPermissionService {}

class MockMarketListingRepository extends Mock
    implements MarketListingRepository {}

class MockArtworkEventsRepository extends Mock
    implements ArtworkEventsRepository {}

class MockMarketRealtimeService extends Mock implements MarketRealtimeService {}

class MockUserProfileRepository extends Mock implements UserProfileRepository {}

class MockOfferRepository extends Mock implements OfferRepository {}

class _FakeMallowApiClient extends Fake implements MallowApiClient {}

/// Stands in for the real decoder so the two states the detail media can be in
/// are reachable from a widget test: [canPlay] false makes every source fail to
/// open (what an unreachable gateway or a takedown looks like on device), true
/// initialises a player that reports a frame.
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  _FakeVideoPlayerPlatform({required this.canPlay});

  final bool canPlay;

  /// One id per source opened, so a restart's player is distinguishable from
  /// the one it replaced.
  int _nextId = 1;

  /// Every player opened, in order. Its *length* is what the fullscreen tests
  /// assert on: a second entry means a second source was fetched, which for a
  /// Mux artwork is the original download this screen exists to avoid.
  final List<int> created = <int>[];

  /// Seeks issued, per call. Continuing the inline player needs none — the
  /// frame fullscreen opens on is the frame already playing.
  final List<Duration> seeks = <Duration>[];

  /// Players the app asked to start. `initialize` never lands here — it only
  /// replays the controller's initial `isPlaying`, which is false.
  final List<int> played = <int>[];

  /// Final volume per player. `initialize` applies the controller's own 1.0
  /// default first, so only the last value states what the app intended.
  final Map<int, double> volume = <int, double>{};

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    if (!canPlay) throw Exception('source could not be opened');
    final id = _nextId++;
    created.add(id);
    return id;
  }

  // `Stream.value` delivers on listen, so the controller's `initialize()` sees
  // the event it is waiting on without the test having to drive the platform.
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream<VideoEvent>.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 5),
      size: const Size(640, 480),
    ),
  );

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double value) async =>
      volume[playerId] = value;

  @override
  Future<void> play(int playerId) async => played.add(playerId);

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      seeks.add(position);

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

/// `_ArtworkImage` classifies an artwork as video up front, from its metadata,
/// and only *then* tries to open a source. The two facts are not the same: the
/// classification survives the whole init window and every gateway failing,
/// while what is actually on screen in both of those states is the still
/// poster. Keying the play/pause + mute row on the classification therefore
/// hung playback controls over a static image — dead buttons, plus a maximize
/// that pushed the video viewer to spin forever on sources that had already
/// refused to open. These tests pin the row to a live player instead.
void main() {
  const mint = 'mint-1';

  late MockMarketBloc marketBloc;
  late MockArtworkBloc artworkBloc;
  late MockRaffleBloc raffleBloc;
  late MockTokenBalanceBloc tokenBalanceBloc;
  late MockAuthService authService;
  late MockSessionManager sessionManager;
  late MockArtworkPermissionService permissionService;
  late MockMarketListingRepository listingRepository;
  late MockMarketRealtimeService realtimeService;
  late MockUserProfileRepository userProfileRepository;
  late MockArtworkEventsRepository eventsRepository;
  late MockOfferRepository offerRepository;

  /// Drives the detail screen's artwork state, so a test can deliver a refresh
  /// after the player is already running.
  late StreamController<ArtworkState> artworkStates;

  /// A Mux-backed video artwork whose original is on the blacklisted
  /// `shdw-drive` host, so the transcode is the *only* candidate: no
  /// `/original/` URL means no decision-26 HEAD probe, and the test never
  /// reaches the network. `imageUrl` is empty so the poster stays a local
  /// placeholder rather than a `CachedNetworkImage` (no path_provider here).
  const artwork = ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    animationUrl: 'https://shdw-drive.genesysgo.net/xyz/video.mp4',
    playbackId: 'pb123',
  );

  /// The same artwork after Mux finished a *different* transcode — the shape a
  /// refresh takes when the id lands mid-view. The changed id is what makes the
  /// inline player tear down and re-open a source.
  const retranscoded = ArtworkDetails(
    mintAccount: mint,
    title: 'Test Artwork',
    imageUrl: '',
    description: 'desc',
    artistName: 'Artist',
    artistAddress: 'artist-addr',
    animationUrl: 'https://shdw-drive.genesysgo.net/xyz/video.mp4',
    playbackId: 'pb456',
  );

  Finder icon(String asset) =>
      find.byWidgetPredicate((w) => w is MallowSvgIcon && w.assetPath == asset);

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    registerFallbackValue(EventMode.all);
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(
          Dio(),
          sl<PreferencesService>(),
          const FlutterSecureStorage(),
        ),
      );
    }
  });

  setUp(() {
    marketBloc = MockMarketBloc();
    artworkBloc = MockArtworkBloc();
    raffleBloc = MockRaffleBloc();
    tokenBalanceBloc = MockTokenBalanceBloc();
    authService = MockAuthService();
    sessionManager = MockSessionManager();
    permissionService = MockArtworkPermissionService();
    listingRepository = MockMarketListingRepository();
    realtimeService = MockMarketRealtimeService();
    userProfileRepository = MockUserProfileRepository();
    eventsRepository = MockArtworkEventsRepository();
    offerRepository = MockOfferRepository();

    whenListen(
      marketBloc,
      const Stream<MarketState>.empty(),
      initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
    );
    whenListen(
      raffleBloc,
      const Stream<RaffleState>.empty(),
      initialState: const RaffleState.initial(),
    );
    whenListen(
      tokenBalanceBloc,
      const Stream<TokenBalanceState>.empty(),
      initialState: const TokenBalanceState.initial(),
    );
    artworkStates = StreamController<ArtworkState>.broadcast();
    addTearDown(artworkStates.close);
    whenListen(
      artworkBloc,
      artworkStates.stream,
      initialState: const ArtworkState.loaded(artwork: artwork),
    );

    when(() => authService.currentAddress).thenReturn(null);
    when(() => sessionManager.sessionAddresses).thenReturn(const {});
    when(
      () => permissionService.checkPermissions(
        any(),
        sessionAddresses: any(named: 'sessionAddresses'),
        listingType: any(named: 'listingType'),
        inGroupedSale: any(named: 'inGroupedSale'),
      ),
    ).thenAnswer((_) => Completer<ArtworkPermissions>().future);
    when(
      () => listingRepository.getEditionState(any()),
    ).thenAnswer((_) async => null);
    when(
      () => realtimeService.watchMint(any()),
    ).thenAnswer((_) => const Stream<MarketInvalidation>.empty());
    when(
      () => userProfileRepository.getUserProfiles(any()),
    ).thenAnswer((_) async => <String, UserProfile?>{});
    when(
      () => eventsRepository.getEvents(
        mintAccount: any(named: 'mintAccount'),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        mode: any(named: 'mode'),
      ),
    ).thenAnswer((_) async => const MarketActivityEventsPage());
    when(
      () => offerRepository.getUserActiveOffer(
        mintAccount: any(named: 'mintAccount'),
        buyerAddresses: any(named: 'buyerAddresses'),
      ),
    ).thenAnswer((_) async => null);

    register<MarketBloc>(marketBloc);
    register<ArtworkBloc>(artworkBloc);
    register<RaffleBloc>(raffleBloc);
    register<TokenBalanceBloc>(tokenBalanceBloc);
    register<AuthService>(authService);
    register<SessionManager>(sessionManager);
    register<ArtworkPermissionService>(permissionService);
    register<MarketListingRepository>(listingRepository);
    register<MarketRealtimeService>(realtimeService);
    register<UserProfileRepository>(userProfileRepository);
    register<ArtworkEventsRepository>(eventsRepository);
    register<OfferRepository>(offerRepository);
    if (!sl.isRegistered<TxLandedSlots>()) {
      sl.registerLazySingleton<TxLandedSlots>(TxLandedSlots.new);
    }
    if (!sl.isRegistered<TokenPriceService>()) {
      sl.registerLazySingleton<TokenPriceService>(
        () => TokenPriceService(_FakeMallowApiClient()),
      );
    }
    if (!sl.isRegistered<TokenMetadataService>()) {
      sl.registerLazySingleton<TokenMetadataService>(
        () => TokenMetadataService(
          DasApiService(),
          sl<PreferencesService>(),
          NoVerifiedListDatabase(),
        ),
      );
    }
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<MarketBloc>();
    drop<ArtworkBloc>();
    drop<RaffleBloc>();
    drop<TokenBalanceBloc>();
    drop<AuthService>();
    drop<SessionManager>();
    drop<ArtworkPermissionService>();
    drop<MarketListingRepository>();
    drop<MarketRealtimeService>();
    drop<UserProfileRepository>();
    drop<ArtworkEventsRepository>();
    drop<OfferRepository>();
  });

  late _FakeVideoPlayerPlatform platform;

  Future<void> openDetail(WidgetTester tester, {required bool canPlay}) async {
    // `instance` is global, so hand it back rather than leaving this file's
    // fake in place for whatever is added here later.
    final realPlatform = VideoPlayerPlatform.instance;
    addTearDown(() => VideoPlayerPlatform.instance = realPlatform);
    platform = _FakeVideoPlayerPlatform(canPlay: canPlay);
    VideoPlayerPlatform.instance = platform;
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const ArtworkDetailScreen(mintAccount: mint),
      ),
    );
    // Source resolution and player init are async; several frames let the
    // candidate walk finish either way before the controls are read.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('a video that never opened shows no playback controls', (
    tester,
  ) async {
    await openDetail(tester, canPlay: false);

    // The media section built and settled on the still placeholder — so the
    // absences below are a real verdict, not an unrendered screen.
    expect(icon('assets/icons/stamp.svg'), findsOneWidget);
    expect(icon('assets/icons/video_play.svg'), findsNothing);
    expect(icon('assets/icons/video_pause.svg'), findsNothing);
    expect(icon('assets/icons/video_mute.svg'), findsNothing);
    expect(icon('assets/icons/video_volume.svg'), findsNothing);
    // This fixture has no poster either, so the corner is empty outright —
    // maximizing into the image viewer would open it on nothing.
    expect(icon('assets/icons/arrows_maximize.svg'), findsNothing);
  });

  testWidgets('a playing video shows play/pause and mute', (tester) async {
    await openDetail(tester, canPlay: true);

    // Autoplay leaves it running and muted, so the glyphs are the *actions*
    // available: pause it, and unmute it.
    expect(icon('assets/icons/video_pause.svg'), findsOneWidget);
    expect(icon('assets/icons/video_mute.svg'), findsOneWidget);
    expect(icon('assets/icons/arrows_maximize.svg'), findsOneWidget);
    // And the glyphs describe the player, not just widget state.
    expect(platform.played, [1]);
    expect(platform.volume[1], 0);
  });

  testWidgets('a restart keeps the viewer paused and unmuted', (tester) async {
    await openDetail(tester, canPlay: true);

    await tester.tap(icon('assets/icons/video_pause.svg'));
    await tester.pump();
    await tester.tap(icon('assets/icons/video_mute.svg'));
    await tester.pump();
    // Now paused and unmuted, so each glyph offers the opposite action.
    expect(icon('assets/icons/video_play.svg'), findsOneWidget);
    expect(icon('assets/icons/video_volume.svg'), findsOneWidget);

    // A refresh brings a finished transcode, which re-opens the source under
    // the viewer's feet.
    artworkStates.add(const ArtworkState.loaded(artwork: retranscoded));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Player 2 is the replacement source. It must never be told to start, and
    // must keep the audio the viewer turned on. The glyphs below read from
    // widget state, which the bug never touched — so these two assertions are
    // the ones that catch it: silently resuming a paused video, or re-muting
    // an unmuted one, under controls that still say the opposite.
    expect(platform.played, [1]);
    expect(platform.volume[2], 1);
    expect(icon('assets/icons/video_play.svg'), findsOneWidget);
    expect(icon('assets/icons/video_pause.svg'), findsNothing);
    expect(icon('assets/icons/video_volume.svg'), findsOneWidget);
    expect(icon('assets/icons/video_mute.svg'), findsNothing);
  });

  /// The fullscreen route is pushed over the still-mounted detail screen, so
  /// each control glyph is on screen twice. The pushed route is the later
  /// `Scaffold` in the tree, which is also the only one the user can reach.
  Finder fsIcon(String asset) =>
      find.descendant(of: find.byType(Scaffold).last, matching: icon(asset));

  /// Fullscreen used to open a player of its own, leading with `/original/` —
  /// which restarted the artwork from frame zero *and*, for the Mux artworks
  /// that are the common case, pulled a multi-megabyte original off a gateway
  /// the inline stream had already made unnecessary. It now borrows the running
  /// controller instead, so these tests assert on the platform's ledger rather
  /// than on glyphs: no second `create` is the whole point.
  testWidgets('maximizing continues the inline player, opening no second '
      'source', (tester) async {
    await openDetail(tester, canPlay: true);
    expect(platform.created, [1]);

    await tester.tap(icon('assets/icons/arrows_maximize.svg'));
    await tester.pumpAndSettle();

    // The route is up and showing video...
    expect(fsIcon('assets/icons/video_pause.svg'), findsOneWidget);
    // ...but nothing new was opened, nothing was restarted, and nothing was
    // seeked: it is the same player, mid-playback, on the same frame.
    expect(platform.created, [1]);
    expect(platform.played, [1]);
    expect(platform.seeks, isEmpty);
    // Both surfaces render that one controller rather than a copy each.
    final controllers = tester
        .widgetList<VideoPlayer>(find.byType(VideoPlayer))
        .map((w) => w.controller)
        .toSet();
    expect(controllers, hasLength(1));
  });

  testWidgets('unmuting in fullscreen carries back to the inline row', (
    tester,
  ) async {
    await openDetail(tester, canPlay: true);
    await tester.tap(icon('assets/icons/arrows_maximize.svg'));
    await tester.pumpAndSettle();

    await tester.tap(fsIcon('assets/icons/video_mute.svg'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    // One player was ever unmuted, so the row underneath cannot honestly show
    // a mute glyph — the two surfaces are the same playback session.
    expect(platform.volume[1], 1);
    expect(icon('assets/icons/video_volume.svg'), findsOneWidget);
    expect(icon('assets/icons/video_mute.svg'), findsNothing);
  });

  testWidgets('a transcode landing during fullscreen defers the restart to '
      'the pop', (tester) async {
    await openDetail(tester, canPlay: true);
    await tester.tap(icon('assets/icons/arrows_maximize.svg'));
    await tester.pumpAndSettle();

    // A refresh renames the source while the route is up. Acting on it now
    // would dispose the controller the fullscreen route is rendering.
    artworkStates.add(const ArtworkState.loaded(artwork: retranscoded));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(platform.created, [1]);
    expect(fsIcon('assets/icons/video_pause.svg'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Deferred, not dropped: the new transcode takes over once it is safe to
    // swap, and inherits the muted-and-playing state it replaced.
    expect(platform.created, [1, 2]);
    expect(platform.played, [1, 2]);
    expect(platform.volume[2], 0);
  });
}
