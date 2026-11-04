import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mallow_wallet/core/services/deep_link_handler_registry.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/scan/widgets/scan_qr_code.dart';
import 'package:mallow_wallet/features/scan/widgets/send_to_address_sheet.dart';
import 'package:mallow_wallet/features/send/widgets/send_qr_scanner_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/sheet_menu_row.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../keystone/fake_scanner_platform.dart';

void main() {
  late FakeScannerPlatform platform;
  late DeepLinkHandlerRegistry handlers;

  setUp(() {
    final originalPlatform = MobileScannerPlatform.instance;
    final originalFonts = GoogleFonts.config.allowRuntimeFetching;
    platform = FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
    GoogleFonts.config.allowRuntimeFetching = false;
    handlers = DeepLinkHandlerRegistry();
    sl.registerSingleton<DeepLinkHandlerRegistry>(handlers);
    addTearDown(platform.closeStreams);
    addTearDown(sl.reset);
    addTearDown(() {
      MobileScannerPlatform.instance = originalPlatform;
      GoogleFonts.config.allowRuntimeFetching = originalFonts;
    });
  });

  Future<void> openScanner(WidgetTester tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => scanQrCode(context),
              child: const Text('scan'),
            ),
          ),
        ),
        GoRoute(
          path: '/artwork/:id',
          builder: (_, state) => Text('artwork ${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: MallowTheme.lightTheme, routerConfig: router),
    );
    await tester.tap(find.text('scan'));
    await tester.pumpAndSettle();
    expect(find.byType(SendQrScannerView), findsOneWidget);
  }

  Future<void> detect(WidgetTester tester, String value) async {
    platform.emit(BarcodeCapture(barcodes: [Barcode(rawValue: value)]));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a code it cannot open is refused once and keeps scanning', (
    tester,
  ) async {
    await openScanner(tester);

    await detect(tester, 'hello world');
    expect(
      find.text("This QR code isn't a link or wallet address mallow can open"),
      findsOne,
    );
    expect(find.byType(SendQrScannerView), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await detect(tester, 'hello world');
    expect(
      find.text("This QR code isn't a link or wallet address mallow can open"),
      findsNothing,
      reason: 'the same code in view is not refused on every frame',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a link closes the scanner and opens its screen', (tester) async {
    await openScanner(tester);

    await detect(tester, 'https://mallow.art/artwork/abc');
    await tester.pumpAndSettle();

    expect(find.byType(SendQrScannerView), findsNothing);
    expect(find.text('artwork abc'), findsOneWidget);
  });

  testWidgets('a link a feature claims goes to it, not to a screen', (
    tester,
  ) async {
    final claimed = <Uri>[];
    handlers.register((uri, {required replay}) {
      claimed.add(uri);
      return true;
    });
    await openScanner(tester);

    await detect(tester, 'https://mallow.art/artwork/abc');
    await tester.pumpAndSettle();

    expect(claimed, [Uri.parse('https://mallow.art/artwork/abc')]);
    expect(find.byType(SendQrScannerView), findsNothing);
    expect(find.text('artwork abc'), findsNothing);
  });

  SheetMenuRow row(WidgetTester tester, String label) =>
      tester.widget<SheetMenuRow>(find.widgetWithText(SheetMenuRow, label));

  testWidgets('a wallet address asks what to send to it', (tester) async {
    await openScanner(tester);

    await detect(tester, '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed');
    await tester.pumpAndSettle();

    expect(find.byType(SendQrScannerView), findsNothing);
    expect(find.byType(SendToAddressSheet), findsOneWidget);
    expect(find.text('To 0x5aA…BeAed on Ethereum'), findsOneWidget);
    expect(row(tester, 'Send tokens').enabled, isTrue);
    expect(row(tester, 'Transfer artwork').enabled, isTrue);
  });

  testWidgets('an artwork transfer to a chain without one says why', (
    tester,
  ) async {
    await openScanner(tester);

    await detect(tester, 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb');
    await tester.pumpAndSettle();

    expect(row(tester, 'Send tokens').enabled, isTrue);
    final transfer = row(tester, 'Transfer artwork');
    expect(transfer.enabled, isFalse);
    expect(transfer.subtitle, contains('Tezos artworks'));
  });
}
