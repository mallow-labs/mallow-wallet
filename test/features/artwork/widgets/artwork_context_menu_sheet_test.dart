import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/artwork/widgets/artwork_context_menu_sheet.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/shared/widgets/sheet_menu_row.dart';
import 'package:mocktail/mocktail.dart';

class _WalletRepository extends Mock implements WalletRepository {}

class _Wallet extends Mock implements WalletInfo {}

class _PermissionService extends Mock implements ArtworkPermissionService {}

class _CastBloc extends Mock implements CastBloc {}

void main() {
  final artwork = PortfolioArtwork(
    mintAccount: 'artwork-mint',
    title: 'Artwork',
    imageUrl: '',
    artistName: 'Artist',
    updateAuth: 'owner',
  );
  const allowed = ArtworkPermissions(
    canTransfer: true,
    canEdit: true,
    canBurn: true,
    canList: true,
    canDownload: true,
    canHide: true,
  );
  late _PermissionService permissions;
  late Completer<ArtworkPermissions> resolution;

  setUp(() {
    final wallets = _WalletRepository();
    final wallet = _Wallet();
    when(() => wallet.address).thenReturn('owner');
    when(() => wallet.canSign).thenReturn(true);
    when(() => wallets.getActiveWallet()).thenAnswer((_) async => wallet);
    permissions = _PermissionService();
    when(
      () => permissions.checkPermissions(
        any(),
        sessionAddresses: any(named: 'sessionAddresses'),
        listingType: any(named: 'listingType'),
        inGroupedSale: any(named: 'inGroupedSale'),
      ),
    ).thenAnswer((_) => resolution.future);
    final cast = _CastBloc();
    when(() => cast.state).thenReturn(const CastState.idle());
    sl.registerSingleton<WalletRepository>(wallets);
    sl.registerSingleton<ArtworkPermissionService>(permissions);
    sl.registerSingleton<CastBloc>(cast);
  });

  tearDown(() async => sl.reset());

  ArtworkContextMenuState ready({
    ArtworkPermissions permissions = allowed,
    bool inGroupedSale = false,
    bool canSign = true,
  }) => ArtworkContextMenuState(
    artwork: artwork,
    permissions: permissions,
    canCast: false,
    canSign: canSign,
    inGroupedSale: inGroupedSale,
  );

  Future<void> Function()? closeSheet;

  void testOptions(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      closeSheet = null;
      try {
        await body(tester);
      } finally {
        await closeSheet?.call();
      }
    });
  }

  Future<void> open(
    WidgetTester tester, {
    Future<ArtworkPermissions>? permissionsFuture,
    ValueNotifier<ArtworkContextMenuState?>? liveState,
    bool inGroupedSale = false,
  }) async {
    resolution = Completer<ArtworkPermissions>();
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigator = GlobalKey<NavigatorState>();
    late Future<ArtworkContextMenuAction?> sheet;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                sheet = showArtworkContextMenu(
                  context,
                  artwork: artwork,
                  initialIsLiked: false,
                  permissionsFuture: permissionsFuture,
                  liveState: liveState,
                  inGroupedSale: inGroupedSale,
                );
              },
              child: const Text('Open options'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open options'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    closeSheet = () async {
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await sheet;
      await tester.pumpWidget(const SizedBox.shrink());
      liveState?.dispose();
    };
  }

  testOptions(
    'pending lookup shimmers every option, including public actions',
    (tester) async {
      await open(tester);

      expect(
        find.byKey(const ValueKey('artwork-options-loading')),
        findsOneWidget,
      );
      expect(find.byType(SheetMenuRow), findsNothing);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Report artwork'), findsNothing);
      verify(() => permissions.checkPermissions(artwork.mintAccount)).called(1);

      resolution.complete(ArtworkPermissions.none);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey('artwork-options-loading')),
        findsNothing,
      );
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Report artwork'), findsOneWidget);
      for (final label in [
        'Transfer artwork',
        'Edit artwork',
        'Burn artwork',
        'Download to device',
      ]) {
        expect(find.text(label), findsNothing);
      }
    },
  );

  testOptions('prestarted lookup is reused without starting a second request', (
    tester,
  ) async {
    final prestarted = Completer<ArtworkPermissions>();
    await open(tester, permissionsFuture: prestarted.future);

    expect(
      find.byKey(const ValueKey('artwork-options-loading')),
      findsOneWidget,
    );
    verifyZeroInteractions(permissions);

    prestarted.complete(allowed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('artwork-options-loading')), findsNothing);
    expect(find.text('Transfer artwork'), findsOneWidget);
    verifyZeroInteractions(permissions);
  });

  testOptions(
    'detail snapshot is reused and an open sheet revokes stale actions',
    (tester) async {
      final live = ValueNotifier<ArtworkContextMenuState?>(ready());
      await open(
        tester,
        permissionsFuture: Future.value(ArtworkPermissions.none),
        liveState: live,
      );
      expect(find.text('Transfer artwork'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artwork-options-loading')),
        findsNothing,
      );

      live.value = null;
      await tester.pump();
      expect(find.byType(SheetMenuRow), findsNothing);
      expect(
        find.byKey(const ValueKey('artwork-options-loading')),
        findsOneWidget,
      );

      live.value = ready(permissions: ArtworkPermissions.none);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Transfer artwork'), findsNothing);
      expect(find.text('Burn artwork'), findsNothing);
      expect(find.text('Share'), findsOneWidget);
      verifyZeroInteractions(permissions);
    },
  );

  testOptions(
    'leaving a grouped sale reveals newly available actions while open',
    (tester) async {
      final live = ValueNotifier<ArtworkContextMenuState?>(
        ready(inGroupedSale: true),
      );
      await open(tester, liveState: live, inGroupedSale: true);
      expect(find.text('Transfer artwork'), findsNothing);
      expect(find.text('Edit artwork'), findsNothing);

      live.value = ready();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Transfer artwork'), findsOneWidget);
      expect(find.text('Edit artwork'), findsOneWidget);

      live.value = ready(canSign: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Transfer artwork'), findsNothing);
      expect(find.text('Edit artwork'), findsNothing);
      expect(find.text('Share'), findsOneWidget);
    },
  );

  testOptions('failed lookup ends loading without offering gated actions', (
    tester,
  ) async {
    await open(tester);
    resolution.completeError(StateError('Permission lookup unavailable'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('artwork-options-loading')), findsNothing);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Transfer artwork'), findsNothing);
    expect(find.text('Download to device'), findsNothing);
  });
}
