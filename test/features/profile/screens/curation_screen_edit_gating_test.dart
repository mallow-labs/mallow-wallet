import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/profile/screens/curation_screen.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockAuthService extends Mock implements AuthService {}

class MockSessionManager extends Mock implements SessionManager {}

class MockCastBloc extends MockBloc<CastEvent, CastState> implements CastBloc {}

/// Write-gating regression for the curation options sheet: Edit / Delete are
/// backend writes matched on `owner == loginAddress`, so they must gate on the
/// ACTIVE login wallet — not the widened session set that surfaces read-only
/// concerns and the local Cast action. A linked-but-inactive owner wallet must
/// NOT see Edit / Delete (they would 404), but must still see Cast curation.
void main() {
  const active = 'wallet-active-A';
  const linkedOwner = 'wallet-linked-B';

  late MockAuthService authService;
  late MockSessionManager sessionManager;
  late MockCastBloc castBloc;

  const group = ArtGroup(
    id: 'curation-1',
    type: ArtGroupType.curation,
    name: 'My Curation',
    thumbnailUrl: null,
    artworkCount: 0,
  );

  void register<T extends Object>(T instance) {
    if (sl.isRegistered<T>()) sl.unregister<T>();
    sl.registerFactory<T>(() => instance);
  }

  setUpAll(() async {
    if (!sl.isRegistered<PreferencesService>()) {
      SharedPreferences.setMockInitialValues({});
      sl.registerSingleton<PreferencesService>(
        await PreferencesService.create(),
      );
    }
    // The screen tracks a screen-view on mount; an uninitialized
    // AnalyticsService no-ops without network/config.
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
    authService = MockAuthService();
    sessionManager = MockSessionManager();
    castBloc = MockCastBloc();

    when(() => authService.isFollowing(any())).thenReturn(false);
    // "Add to cast" is gated behind an active cast session; keep it inactive so
    // the only owner-write rows in the sheet are Edit / Delete.
    whenListen(
      castBloc,
      const Stream<CastState>.empty(),
      initialState: const CastState.idle(),
    );

    register<AuthService>(authService);
    register<SessionManager>(sessionManager);
    register<CastBloc>(castBloc);
  });

  tearDown(() {
    void drop<T extends Object>() {
      if (sl.isRegistered<T>()) sl.unregister<T>();
    }

    drop<AuthService>();
    drop<SessionManager>();
    drop<CastBloc>();
  });

  /// Mounts the curation screen (empty, preloaded so no repository fetch) and
  /// opens the options sheet by tapping the header kebab.
  Future<void> openOptionsSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const CurationScreen(
          group: group,
          ownerAddress: linkedOwner,
          preloadedArtworks: [],
        ),
      ),
    );
    await tester.pump();

    final kebab = find.byWidgetPredicate(
      (w) =>
          w is SvgPicture &&
          w.bytesLoader is SvgAssetLoader &&
          (w.bytesLoader as SvgAssetLoader).assetName.contains('dots_vertical'),
    );
    await tester.tap(
      find.ancestor(of: kebab, matching: find.byType(GestureDetector)).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Pops the open modal sheet while the tree is still mounted so the
  /// module-global `runGuardedSheet` key is released — otherwise its future
  /// never completes and the next test's sheet is guarded off from opening.
  Future<void> closeOptionsSheet(WidgetTester tester) async {
    final nav = tester.firstState<NavigatorState>(find.byType(Navigator));
    if (nav.canPop()) nav.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('active wallet is the owner → Edit / Delete are offered', (
    tester,
  ) async {
    when(() => authService.currentAddress).thenReturn(linkedOwner);
    when(() => sessionManager.sessionAddresses).thenReturn(const {linkedOwner});

    await openOptionsSheet(tester);

    expect(find.text('Edit curation'), findsOneWidget);
    expect(find.text('Delete curation'), findsOneWidget);
    expect(find.text('Cast curation'), findsOneWidget);

    await closeOptionsSheet(tester);
  });

  testWidgets(
    'linked owner wallet is not active → Edit / Delete hidden, Cast still '
    'offered',
    (tester) async {
      // Active wallet A, but the curation is owned by linked wallet B (in the
      // session). Reads/casting stay unlocked; the backend writes do not.
      when(() => authService.currentAddress).thenReturn(active);
      when(
        () => sessionManager.sessionAddresses,
      ).thenReturn(const {active, linkedOwner});

      await openOptionsSheet(tester);

      // Owner-only management block is present (Cast), proving the widened
      // read notion still holds…
      expect(find.text('Cast curation'), findsOneWidget);
      // …but the backend writes are gated off the inactive owner wallet.
      expect(find.text('Edit curation'), findsNothing);
      expect(find.text('Delete curation'), findsNothing);

      await closeOptionsSheet(tester);
    },
  );
}
