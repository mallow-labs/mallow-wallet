import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/screens/your_art_screen.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/portfolio/widgets/art_group_skeleton.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mockito/mockito.dart';
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/portfolio_bloc_test.mocks.dart';

class _MockCastBloc extends MockBloc<CastEvent, CastState>
    implements CastBloc {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'shows group shimmers while an empty cached no-tab portfolio refreshes',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});

      final repository = MockPortfolioRepository();
      final walletManager = MockWalletManager();
      final curationRepository = MockCurationRepository();
      final authService = MockAuthService();
      final hardwareVerifyController = MockHardwareVerifyController();
      final freshArtworks = Completer<PortfolioArtworksResult>();
      final castBloc = _MockCastBloc();

      when(
        walletManager.onWalletChanged,
      ).thenAnswer((_) => const Stream<String>.empty());
      when(walletManager.getAddress()).thenAnswer((_) async => 'TestAddr');
      when(authService.currentAddress).thenReturn(null);
      when(authService.currentUser).thenReturn(null);
      when(
        authService.currentWalletNeedsHardwareVerification(),
      ).thenAnswer((_) async => false);
      when(curationRepository.getCurations()).thenAnswer((_) async => const []);
      when(repository.getCachedSnapshot()).thenAnswer(
        (_) async => const PortfolioSnapshot(
          artworks: PortfolioArtworksResult(artworks: [], total: 0),
          groups: PortfolioGroupsResult(groups: []),
        ),
      );
      when(
        repository.getOwnedArtworks(page: anyNamed('page')),
      ).thenAnswer((_) => freshArtworks.future);
      when(
        repository.getGroupedPortfolio(),
      ).thenAnswer((_) async => const PortfolioGroupsResult(groups: []));

      final bloc = PortfolioBloc(
        repository,
        curationRepository,
        authService,
        hardwareVerifyController,
        walletManager,
      );
      await sl.reset();
      mocktail.when(() => castBloc.state).thenReturn(const CastState.idle());
      sl.registerFactory<CastBloc>(() => castBloc);
      sl.registerFactory<PortfolioBloc>(() => bloc);
      addTearDown(sl.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: MallowTheme.lightTheme,
          home: const Scaffold(body: YourArtScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();

      // WHY: an empty cache is still being revalidated. With no tab selected,
      // rendering the empty state here makes a slow network look exactly like
      // the user owns no artwork.
      expect(find.byType(PortfolioSkeletonGrid), findsOneWidget);

      freshArtworks.complete(
        const PortfolioArtworksResult(artworks: [], total: 0),
      );
      await tester.pump();
    },
  );
}
