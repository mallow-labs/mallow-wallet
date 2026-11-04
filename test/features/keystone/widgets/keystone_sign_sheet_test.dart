import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:mallow_wallet/features/keystone/widgets/animated_ur_qr.dart';
import 'package:mallow_wallet/features/keystone/widgets/keystone_sign_sheet.dart';
import 'package:mallow_wallet/features/keystone/widgets/ur_scanner_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mallow_wallet/shared/widgets/mallow_sheet.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../fake_scanner_platform.dart';

void main() {
  const address = '9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin';

  UR request({int size = 120}) => SolSignRequest(
    requestId: SolSignRequest.newRequestId(),
    signData: Uint8List.fromList(List<int>.generate(size, (i) => i % 251)),
    path: KeystoneKeypath.parse(
      "m/44'/501'/0'/0'",
      sourceFingerprint: 0x12121212,
    ),
  ).toUr();

  KeystoneSignPrompt prompt({UR? ur, String? notice, int? index, int? total}) =>
      KeystoneSignPrompt(
        request: ur ?? request(),
        purpose: KeystoneSignPurpose.transaction,
        address: address,
        validate: (_) async => null,
        notice: notice,
        index: index,
        total: total,
      );

  /// Lets the sheet's route transition finish. Not `pumpAndSettle`: an
  /// animated QR keeps scheduling frames forever.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Opens the sheet over a host page, the way the app shell does.
  Future<void> open(
    WidgetTester tester,
    KeystoneSignPrompt p, {
    bool pushHost = false,
    VoidCallback? onClosed,
  }) async {
    // A phone-shaped viewport: the sheet is taller than the default 800×600
    // test surface, and a tap below its fold silently misses.
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    final host = Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () {
              unawaited(
                showKeystoneSignSheet(
                  context,
                  p,
                ).whenComplete(() => onClosed?.call()),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: MallowTheme.lightTheme,
        home: pushHost ? const Scaffold(body: Text('root')) : host,
      ),
    );
    if (pushHost) {
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(builder: (_) => host),
        ),
      );
      await settle(tester);
    }
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  testWidgets('shows the request as a QR and names the transaction', (
    tester,
  ) async {
    await open(tester, prompt());

    expect(find.text('Sign with Keystone'), findsOneWidget);
    expect(find.text('9xQeW…sVFin'), findsOneWidget);
    expect(find.byType(AnimatedUrQr), findsOneWidget);
    expect(find.textContaining('transaction'), findsWidgets);
    expect(find.text('Scan the signature'), findsOneWidget);
    expect(find.textContaining('Transaction '), findsNothing);
  });

  testWidgets('an export scanned as a signature explains which code to scan', (
    tester,
  ) async {
    final originalPlatform = MobileScannerPlatform.instance;
    final platform = FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
    addTearDown(platform.closeStreams);
    addTearDown(() => MobileScannerPlatform.instance = originalPlatform);
    var validations = 0;
    final p = KeystoneSignPrompt(
      request: request(),
      purpose: KeystoneSignPurpose.transaction,
      address: address,
      validate: (_) async {
        validations++;
        return null;
      },
    );
    await open(tester, p);
    await tester.ensureVisible(find.text('Scan the signature'));
    await tester.tap(find.text('Scan the signature'));
    await tester.pump();
    final scannerWidget = tester.widget<UrScannerView>(
      find.byType(UrScannerView),
    );
    expect(
      scannerWidget.unexpectedTypeError,
      "That isn't a signature. Scan the code your Keystone shows after "
      'you approve.',
    );
    expect(scannerWidget.describeRejection, isNull);
    final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
    scanner.onDetect!(
      BarcodeCapture(
        barcodes: [
          Barcode(
            rawValue: UrEncoder.encodeSinglePart(
              UR('crypto-multi-accounts', Uint8List(3)),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(
      find.text(
        "That isn't a signature. Scan the code your Keystone shows after "
        'you approve.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('unexpected UR type'), findsNothing);
    expect(validations, 0);
    expect(p.completer.isCompleted, isFalse);

    scanner.onDetect!(
      const BarcodeCapture(barcodes: [Barcode(rawValue: 'ur:sol-signature')]),
    );
    await tester.pump();
    expect(
      find.text(
        "That code couldn't be read. Hold the camera steady and try again.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('malformed UR'), findsNothing);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await settle(tester);
  });

  testWidgets('switching request and scan steps releases the shared camera', (
    tester,
  ) async {
    final originalPlatform = MobileScannerPlatform.instance;
    final platform = FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
    addTearDown(platform.closeStreams);
    addTearDown(() => MobileScannerPlatform.instance = originalPlatform);
    await open(tester, prompt());

    for (var attempt = 0; attempt < 3; attempt++) {
      await tester.ensureVisible(find.text('Scan the signature'));
      await tester.tap(find.text('Scan the signature'));
      await tester.pump();
      await tester.pump();
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;
      expect(controller.value.error, isNull);
      expect(controller.value.isRunning, isTrue);
      expect(platform.isLive, isTrue);
      expect(platform.overlappingStarts, 0);

      await tester.ensureVisible(find.text('Show the request again'));
      await tester.tap(find.text('Show the request again'));
      await tester.pump();
      expect(find.byType(UrScannerView), findsNothing);
      expect(platform.isLive, isFalse);
      expect(platform.stops, attempt + 1);
    }
    expect(platform.starts, 3);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scan back scan during startup waits for the shared camera', (
    tester,
  ) async {
    final originalPlatform = MobileScannerPlatform.instance;
    final platform = FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
    addTearDown(platform.closeStreams);
    addTearDown(() => MobileScannerPlatform.instance = originalPlatform);
    final barrier = platform.startBarrier = Completer<void>();
    await open(tester, prompt());
    await tester.ensureVisible(find.text('Scan the signature'));
    await tester.tap(find.text('Scan the signature'));
    await tester.pump();
    await tester.pump();
    final oldController = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    expect(oldController.value.isStarting, isTrue);

    await tester.ensureVisible(find.text('Show the request again'));
    await tester.tap(find.text('Show the request again'));
    await tester.pump();
    await tester.ensureVisible(find.text('Scan the signature'));
    await tester.tap(find.text('Scan the signature'));
    await tester.pump();
    await tester.pump();
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    expect(controller, isNot(same(oldController)));

    barrier.complete();
    await tester.pump();
    await tester.pump();
    expect(platform.starts, 2);
    expect(platform.overlappingStarts, 0);
    expect(platform.isLive, isTrue);
    expect(controller.value.error, isNull);
    expect(controller.value.isRunning, isTrue);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(platform.isLive, isFalse);
    expect(platform.hasPlatformListeners, isFalse);
  });

  testWidgets('shows the expiry notice above the steps and batch position', (
    tester,
  ) async {
    const notice =
        'That took too long, so the transaction expired before it was sent. '
        'Approve it again on your Keystone.';
    await open(tester, prompt(notice: notice, index: 1, total: 3));

    expect(find.text(notice), findsOneWidget);
    expect(find.text('9xQeW…sVFin • Transaction 2 of 3'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(notice)).dy,
      lessThan(tester.getTopLeft(find.textContaining('On your Keystone')).dy),
    );
  });

  for (final action in ['Show the request again', 'Cancel']) {
    testWidgets('$action during camera startup releases it for the next scan', (
      tester,
    ) async {
      final originalPlatform = MobileScannerPlatform.instance;
      final platform = FakeScannerPlatform();
      MobileScannerPlatform.instance = platform;
      addTearDown(platform.closeStreams);
      addTearDown(() => MobileScannerPlatform.instance = originalPlatform);
      final barrier = platform.startBarrier = Completer<void>();
      await open(tester, prompt());
      await tester.ensureVisible(find.text('Scan the signature'));
      await tester.tap(find.text('Scan the signature'));
      await tester.pump();
      await tester.pump();
      final oldController = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;
      expect(oldController.value.isStarting, isTrue);
      expect(platform.isLive, isFalse);

      await tester.ensureVisible(find.text(action));
      await tester.tap(find.text(action));
      await settle(tester);
      expect(find.byType(UrScannerView), findsNothing);
      barrier.complete();
      await tester.pump();
      expect(platform.isLive, isFalse);
      if (action == 'Cancel') {
        await open(tester, prompt());
      }
      await tester.ensureVisible(find.text('Scan the signature'));
      await tester.tap(find.text('Scan the signature'));
      await tester.pump();
      await tester.pump();
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;
      expect(platform.starts, 2);
      expect(platform.overlappingStarts, 0);
      expect(platform.isLive, isTrue);
      expect(controller.value.error, isNull);
      expect(controller.value.isRunning, isTrue);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await settle(tester);
    });
  }

  testWidgets('Cancel cancels the prompt and closes the sheet', (tester) async {
    final p = prompt();
    Object? error;
    unawaited(
      p.completer.future.then<void>((_) {}, onError: (Object e) => error = e),
    );
    await open(tester, p);

    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(error, isA<KeystoneSigningCancelledException>());
    expect(find.text('Sign with Keystone'), findsNothing);
  });

  testWidgets('a flow cancelled underneath closes the sheet', (tester) async {
    final p = prompt();
    unawaited(p.completer.future.catchError((_) => request()));
    await open(tester, p);

    p.cancel();
    await settle(tester);

    expect(find.text('Sign with Keystone'), findsNothing);
  });

  testWidgets('cancellation removes a covered sheet and completes its future', (
    tester,
  ) async {
    final p = prompt();
    var closed = false;
    await open(tester, p, pushHost: true, onClosed: () => closed = true);
    final sheetContext = tester.element(find.byType(KeystoneSignSheet));
    final navigator = Navigator.of(sheetContext);
    unawaited(
      showMallowSheet<void>(
        context: sheetContext,
        builder: (_) => const SizedBox(
          height: 200,
          child: Center(child: Text('permission sheet')),
        ),
      ),
    );
    await settle(tester);

    p.cancel();
    await settle(tester);

    expect(find.text('permission sheet'), findsOneWidget);
    expect(find.byType(KeystoneSignSheet, skipOffstage: false), findsNothing);
    expect(closed, isTrue);

    navigator.pop();
    await settle(tester);

    expect(find.text('permission sheet'), findsNothing);
    expect(find.byType(KeystoneSignSheet), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(find.text('root'), findsNothing);
    expect(navigator.canPop(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cancel closes a sheet whose prompt is already completed', (
    tester,
  ) async {
    final p = prompt();
    var closed = false;
    await open(tester, p, pushHost: true, onClosed: () => closed = true);
    p.completer.complete(request());
    await tester.pump();
    expect(find.byType(KeystoneSignSheet), findsOneWidget);

    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(find.byType(KeystoneSignSheet), findsNothing);
    expect(closed, isTrue);
    expect(find.text('open'), findsOneWidget);
    expect(find.text('root'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cancel racing external cancellation keeps the host route', (
    tester,
  ) async {
    final p = prompt();
    await open(tester, p, pushHost: true);
    final cancel = tester.widget<MallowButton>(
      find.widgetWithText(MallowButton, 'Cancel'),
    );

    // Cancel again before the completer's error listener runs. Both closers
    // see the sheet mounted during its exit animation.
    p.cancel();
    cancel.onPressed!();
    await settle(tester);

    expect(find.byType(KeystoneSignSheet), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(find.text('root'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('validation finishing after cancel keeps the host route', (
    tester,
  ) async {
    final originalPlatform = MobileScannerPlatform.instance;
    final platform = FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
    addTearDown(platform.closeStreams);
    addTearDown(() => MobileScannerPlatform.instance = originalPlatform);
    final validation = Completer<String?>();
    final p = KeystoneSignPrompt(
      request: request(),
      purpose: KeystoneSignPurpose.transaction,
      address: address,
      validate: (_) => validation.future,
    );
    await open(tester, p, pushHost: true);
    await tester.ensureVisible(find.text('Scan the signature'));
    await tester.tap(find.text('Scan the signature'));
    await tester.pump();
    final scanner = tester.widget<UrScannerView>(find.byType(UrScannerView));
    final scanned = scanner.onScanned(UR('sol-signature', Uint8List(64)));

    p.cancel();
    await tester.pump();
    // Complete during the exit animation, while the sheet is still mounted.
    expect(find.byType(KeystoneSignSheet), findsOneWidget);
    validation.complete(null);
    await scanned;
    await settle(tester);

    expect(find.byType(KeystoneSignSheet), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(find.text('root'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long request animates through its fragments', (tester) async {
    // Far more than one fragment, so the code has to cycle for the device to
    // collect every part.
    final p = prompt(ur: request(size: 1200));
    unawaited(p.completer.future.catchError((_) => request()));
    await open(tester, p);

    // The part on screen, read off the key the widget gives each frame.
    String currentData() {
      final frame = tester.widget<KeyedSubtree>(
        find.descendant(
          of: find.byType(AnimatedUrQr),
          matching: find.byType(KeyedSubtree),
        ),
      );
      return (frame.key! as ValueKey<String>).value;
    }

    final seen = <String>{currentData()};
    for (var i = 0; i < 4; i++) {
      await tester.pump(kKeystoneFrameInterval);
      seen.add(currentData());
    }
    expect(seen.length, greaterThan(1));

    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await settle(tester);
  });
}
