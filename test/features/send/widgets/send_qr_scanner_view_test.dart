import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mallow_wallet/features/send/widgets/send_qr_scanner_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../keystone/fake_scanner_platform.dart';

void main() {
  late FakeScannerPlatform platform;

  setUp(() {
    final originalPlatform = MobileScannerPlatform.instance;
    final originalFonts = GoogleFonts.config.allowRuntimeFetching;
    platform = FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
    GoogleFonts.config.allowRuntimeFetching = false;
    addTearDown(platform.closeStreams);
    addTearDown(() {
      MobileScannerPlatform.instance = originalPlatform;
      GoogleFonts.config.allowRuntimeFetching = originalFonts;
    });
  });

  group('scanWindowFor', () {
    test('is a square centred in the preview', () {
      final window = SendQrScannerView.scanWindowFor(const Size(400, 800));
      expect(window.width, window.height);
      expect(window.center, const Offset(200, 400));
      expect(window.width, closeTo(400 * 0.72, 0.001));
    });

    test('stays a focused area on a large preview', () {
      final window = SendQrScannerView.scanWindowFor(const Size(1000, 1400));
      expect(window.width, 300);
      expect(window.center, const Offset(500, 700));
    });
  });

  testWidgets('restricts detection to the centred window', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: SendQrScannerView(onDetect: (_) {}, onClose: () {}),
      ),
    );
    await tester.pump();

    final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
    final body = tester.getSize(find.byType(MobileScanner));
    expect(scanner.scanWindow, SendQrScannerView.scanWindowFor(body));
    expect(scanner.scanWindow!.width, lessThan(body.width));
    expect(find.text('Fit the QR code inside the frame'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
