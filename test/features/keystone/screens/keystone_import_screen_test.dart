import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/router/auth_state_notifier.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/home/widgets/drawer_signal.dart';
import 'package:mallow_wallet/features/keystone/screens/keystone_account_picker_screen.dart';
import 'package:mallow_wallet/features/keystone/screens/keystone_import_screen.dart';
import 'package:mallow_wallet/features/keystone/services/keystone_connect_bloc.dart';
import 'package:mallow_wallet/features/keystone/widgets/ur_scanner_view.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/app_snack_bar.dart';
import 'package:mallow_wallet/shared/widgets/loading_indicator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mocktail/mocktail.dart';

import '../fake_scanner_platform.dart';

class _MockRepo extends Mock implements WalletRepository {}

class _MockTokens extends Mock implements TokenRepository {}

class _MockPortfolio extends Mock implements PortfolioRepository {}

class _MockAuthNotifier extends Mock implements AuthStateNotifier {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockGoRouter extends Mock implements GoRouter {}

void main() {
  late FakeScannerPlatform platform;

  setUp(() {
    final originalPlatform = MobileScannerPlatform.instance;
    final originalFonts = GoogleFonts.config.allowRuntimeFetching;
    platform = FakeScannerPlatform();
    addTearDown(platform.closeStreams);
    MobileScannerPlatform.instance = platform;
    GoogleFonts.config.allowRuntimeFetching = false;
    addTearDown(() {
      MobileScannerPlatform.instance = originalPlatform;
      GoogleFonts.config.allowRuntimeFetching = originalFonts;
    });
  });

  Future<void> show(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(body: child),
      ),
    );
    await tester.pump();
  }

  void detect(WidgetTester tester, UR ur) {
    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      BarcodeCapture(
        barcodes: [Barcode(rawValue: UrEncoder.encodeSinglePart(ur))],
      ),
    );
  }

  final ur = UR('bytes', Uint8List.fromList([1, 2, 3]));

  for (final onboarded in [false, true]) {
    testWidgets('successful import keeps the camera off while leaving for '
        '${onboarded ? 'home' : 'onboarding'}', (tester) async {
      final authNotifier = _MockAuthNotifier();
      final walletManager = _MockWalletManager();
      final router = _MockGoRouter();
      when(walletManager.notifyWalletDataChanged).thenAnswer((_) async {});
      when(() => authNotifier.hasCompletedOnboarding).thenReturn(onboarded);
      sl.registerSingleton<WalletRepository>(_MockRepo());
      sl.registerSingleton<TokenRepository>(_MockTokens());
      sl.registerSingleton<PortfolioRepository>(_MockPortfolio());
      sl.registerSingleton<AuthStateNotifier>(authNotifier);
      sl.registerSingleton<WalletManager>(walletManager);
      final originalDrawerSignal = DrawerSignal.showAccountsOnNextOpen;
      addTearDown(() async {
        DrawerSignal.showAccountsOnNextOpen = originalDrawerSignal;
        await sl.unregister<WalletRepository>();
        await sl.unregister<TokenRepository>();
        await sl.unregister<PortfolioRepository>();
        await sl.unregister<AuthStateNotifier>();
        await sl.unregister<WalletManager>();
      });
      // Keep the outgoing page mounted after go, as during a pop transition.
      await show(
        tester,
        InheritedGoRouter(
          goRouter: router,
          child: const KeystoneImportScreen(),
        ),
      );
      final bloc = tester
          .element(find.byType(UrScannerView))
          .read<KeystoneConnectBloc>();
      expect(platform.starts, 1);
      bloc.emit(const KeystoneImporting());
      await tester.pump();
      await tester.pump();
      expect(find.byType(KeystoneAccountPickerView), findsOneWidget);
      expect(find.byType(MallowLoader), findsOneWidget);
      expect(find.byType(UrScannerView), findsNothing);
      expect(platform.isLive, isFalse);
      final startsBeforeImport = platform.starts;

      bloc.emit(const KeystoneImported([]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      verify(
        () => router.go(onboarded ? AppRoutes.home : AppRoutes.biometricSetup),
      ).called(1);
      expect(find.byType(KeystoneImportScreen), findsOneWidget);
      expect(platform.starts, startsBeforeImport);
      expect(find.byType(UrScannerView), findsNothing);
      expect(find.byType(MobileScanner), findsNothing);
      expect(find.byType(KeystoneAccountPickerView), findsOneWidget);
      expect(find.byType(MallowLoader), findsNothing);
      expect(platform.isLive, isFalse);
      if (onboarded) {
        verify(walletManager.notifyWalletDataChanged).called(1);
        expect(find.text('Wallet imported'), findsOneWidget);
        expect(DrawerSignal.showAccountsOnNextOpen, isTrue);
        AppSnackBar.dismiss();
        await tester.pumpAndSettle();
      } else {
        verify(authNotifier.onWalletCreated).called(1);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testWidgets('wrong code type explains which entries to choose', (
    tester,
  ) async {
    sl.registerSingleton<WalletRepository>(_MockRepo());
    sl.registerSingleton<TokenRepository>(_MockTokens());
    sl.registerSingleton<PortfolioRepository>(_MockPortfolio());
    addTearDown(() async {
      await sl.unregister<WalletRepository>();
      await sl.unregister<TokenRepository>();
      await sl.unregister<PortfolioRepository>();
    });
    await show(tester, const KeystoneImportScreen());
    final scannerWidget = tester.widget<UrScannerView>(
      find.byType(UrScannerView),
    );
    expect(
      scannerWidget.unexpectedTypeError,
      "That's not a Keystone account code. On your Keystone, open Connect "
      'Software Wallet and choose Solflare or MetaMask.',
    );
    expect(scannerWidget.describeRejection, isNull);
    final scanner = tester.state(find.byType(UrScannerView));
    detect(tester, UR('crypto-psbt', Uint8List(3)));
    await tester.pump();

    expect(
      find.text(
        "That's not a Keystone account code. On your Keystone, open Connect "
        'Software Wallet and choose Solflare or MetaMask.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('unexpected UR type'), findsNothing);
    expect(tester.state(find.byType(UrScannerView)), same(scanner));
    final bloc = tester
        .element(find.byType(UrScannerView))
        .read<KeystoneConnectBloc>();
    expect(bloc.state, isA<KeystoneScanning>());

    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      const BarcodeCapture(
        barcodes: [Barcode(rawValue: 'ur:crypto-multi-accounts')],
      ),
    );
    await tester.pump();
    expect(
      find.text(
        "That code couldn't be read. Hold the camera steady and try again.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('malformed UR'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('accepted UR stays idle through duplicate frames and rebuilds', (
    tester,
  ) async {
    var calls = 0;
    final result = Completer<String?>();
    Widget scanner() => UrScannerView(
      expectedTypes: const {'bytes'},
      onScanned: (_) {
        calls++;
        return result.future;
      },
    );
    await show(tester, scanner());
    detect(tester, ur);
    detect(tester, ur);
    expect(calls, 1);

    result.complete(null);
    await tester.pump();
    detect(tester, ur);
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(body: scanner()),
      ),
    );
    detect(tester, ur);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('rejected UR rearms the scanner and shows the reason', (
    tester,
  ) async {
    var calls = 0;
    await show(
      tester,
      UrScannerView(
        expectedTypes: const {'bytes'},
        onScanned: (_) async {
          calls++;
          return 'Try a different code';
        },
      ),
    );
    detect(tester, ur);
    await tester.pump();
    expect(find.text('Try a different code'), findsOneWidget);
    detect(tester, ur);
    await tester.pump();
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('repeated refused exports and Scan again reuse a live camera', (
    tester,
  ) async {
    sl.registerSingleton<WalletRepository>(_MockRepo());
    sl.registerSingleton<TokenRepository>(_MockTokens());
    sl.registerSingleton<PortfolioRepository>(_MockPortfolio());
    addTearDown(() async {
      await sl.unregister<WalletRepository>();
      await sl.unregister<TokenRepository>();
      await sl.unregister<PortfolioRepository>();
    });
    await show(tester, const KeystoneImportScreen());
    final invalid = KeystoneMultiAccounts(
      masterFingerprint: 0x23D048F0,
      keys: [
        KeystoneHdKey(
          keyData: Uint8List.fromList(List.filled(32, 1)),
          origin: KeystoneKeypath.parse("m/44'/60'/0'"),
        ),
      ],
    ).toUr();

    for (var attempt = 0; attempt < 2; attempt++) {
      final previousScanner = tester.state(find.byType(UrScannerView));
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;
      for (var refusal = 0; refusal < 2; refusal++) {
        detect(tester, invalid);
        await tester.pump();
        await tester.pump();
        expect(controller.value.error, isNull);
        expect(tester.state(find.byType(UrScannerView)), same(previousScanner));
        expect(controller.value.isRunning, isTrue);
        expect(platform.isLive, isTrue);
        expect(platform.overlappingStarts, 0);
        expect(
          find.textContaining('no Solana or Ethereum accounts'),
          findsOneWidget,
        );
      }
      await tester.ensureVisible(find.text('Scan again'));
      await tester.tap(find.text('Scan again'));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('no Solana or Ethereum accounts'),
        findsNothing,
      );
      expect(tester.state(find.byType(UrScannerView)), same(previousScanner));
      expect(controller.value.error, isNull);
      expect(controller.value.isRunning, isTrue);
      expect(platform.starts, 1);
      expect(platform.overlappingStarts, 0);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'a loading failure returns to a scanner that accepts another export',
    (tester) async {
      final repo = _MockRepo();
      when(
        repo.peekNextAccountNumber,
      ).thenAnswer((_) async => throw StateError('lookup failed'));
      sl.registerSingleton<WalletRepository>(repo);
      sl.registerSingleton<TokenRepository>(_MockTokens());
      sl.registerSingleton<PortfolioRepository>(_MockPortfolio());
      addTearDown(() async {
        await sl.unregister<WalletRepository>();
        await sl.unregister<TokenRepository>();
        await sl.unregister<PortfolioRepository>();
      });
      await show(tester, const KeystoneImportScreen());
      final export = KeystoneMultiAccounts(
        masterFingerprint: 0x23D048F0,
        keys: [
          KeystoneHdKey(
            keyData: Uint8List.fromList(List.filled(32, 1)),
            origin: KeystoneKeypath.parse("m/44'/501'/0'/0'"),
          ),
        ],
      ).toUr();

      for (var attempt = 0; attempt < 2; attempt++) {
        final previousScanner = tester.state(find.byType(UrScannerView));
        final bloc = tester
            .element(find.byType(UrScannerView))
            .read<KeystoneConnectBloc>();
        final rescanned = bloc.stream.firstWhere((s) => s is KeystoneScanning);
        detect(tester, export);
        await rescanned;
        await tester.pump();
        await tester.pump();
        expect(find.byType(UrScannerView), findsOneWidget);
        expect(tester.state(find.byType(UrScannerView)), same(previousScanner));
      }
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;
      expect(controller.value.error, isNull);
      expect(controller.value.isRunning, isTrue);
      expect(platform.starts, 1);
      expect(platform.overlappingStarts, 0);
      verify(repo.peekNextAccountNumber).called(2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
