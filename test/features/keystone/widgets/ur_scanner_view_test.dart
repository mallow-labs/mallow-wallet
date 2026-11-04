import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:mallow_wallet/features/keystone/widgets/ur_scanner_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../fake_scanner_platform.dart';

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

  Future<void> show(
    WidgetTester tester, {
    Future<String?> Function(UR)? onScanned,
    String? unexpectedTypeError,
    String? Function(UrDecodeException)? describeRejection,
    int generation = 0,
    String? error,
    Key? scannerKey,
    ValueNotifier<bool>? visibility,
  }) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final scanner = UrScannerView(
      key: scannerKey,
      generation: generation,
      error: error,
      expectedTypes: const {'bytes'},
      onScanned: onScanned ?? (_) async => null,
      unexpectedTypeError: unexpectedTypeError,
      describeRejection: describeRejection,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: visibility == null
              ? scanner
              : ValueListenableBuilder<bool>(
                  valueListenable: visibility,
                  builder: (_, visible, _) =>
                      visible ? scanner : const SizedBox(),
                ),
        ),
      ),
    );
    await tester.pump();
  }

  void deactivateScanner(WidgetTester tester, ValueNotifier<bool> visibility) {
    visibility.value = false;
    // Build without finalizing the frame, so Flutter deactivates the scanner
    // but keeps it mounted until startup settles or its GlobalKey is reused.
    tester.binding.buildOwner!.buildScope(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) async {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }

  void detect(WidgetTester tester, String raw) {
    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      BarcodeCapture(barcodes: [Barcode(rawValue: raw)]),
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await lifecycle(tester, AppLifecycleState.resumed);
  }

  testWidgets('reset clears partial progress and errors without a new camera', (
    tester,
  ) async {
    await show(tester);
    final state = tester.state(find.byType(UrScannerView));
    final encoder = UrEncoder(
      UR('bytes', Uint8List.fromList(List.generate(600, (i) => i % 251))),
      maxFragmentLength: 100,
    );
    detect(tester, encoder.nextPart());
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await show(tester, generation: 1, error: 'Choose another export');
    expect(tester.state(find.byType(UrScannerView)), same(state));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Choose another export'), findsOneWidget);
    await show(tester, generation: 2);
    expect(find.text('Choose another export'), findsNothing);
    expect(platform.starts, 1);
    expect(platform.isLive, isTrue);
    await close(tester);
  });

  testWidgets('reset rearms acceptance and restarts a camera left inactive', (
    tester,
  ) async {
    var scans = 0;
    Future<String?> onScanned(UR _) async {
      scans++;
      return null;
    }

    await show(tester, onScanned: onScanned);
    final state = tester.state(find.byType(UrScannerView));
    final raw = UrEncoder.encodeSinglePart(UR('bytes', Uint8List(3)));
    detect(tester, raw);
    await tester.pump();
    await lifecycle(tester, AppLifecycleState.inactive);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(platform.isLive, isFalse);

    await show(tester, generation: 1, onScanned: onScanned);
    expect(tester.state(find.byType(UrScannerView)), same(state));
    expect(platform.starts, 2);
    expect(platform.isLive, isTrue);
    detect(tester, raw);
    await tester.pump();
    expect(scans, 2);
    expect(platform.overlappingStarts, 0);
    await close(tester);
  });

  testWidgets('validation from before a reset cannot overwrite the new scan', (
    tester,
  ) async {
    final validation = Completer<String?>();
    await show(tester, onScanned: (_) => validation.future);
    final raw = UrEncoder.encodeSinglePart(UR('bytes', Uint8List(3)));
    detect(tester, raw);
    var scans = 0;
    await show(
      tester,
      generation: 1,
      onScanned: (_) async {
        scans++;
        return null;
      },
    );
    detect(tester, raw);
    await tester.pump();
    validation.complete('Old rejection');
    await tester.pump();
    expect(find.text('Old rejection'), findsNothing);
    detect(tester, raw);
    expect(scans, 1);
    await close(tester);
  });

  testWidgets('replacement stops the old camera before the new start', (
    tester,
  ) async {
    await show(tester, scannerKey: const ValueKey(0));
    await show(tester, scannerKey: const ValueKey(1));
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    expect(platform.starts, 2);
    expect(platform.stops, 1);
    expect(platform.overlappingStarts, 0);
    expect(platform.isLive, isTrue);
    expect(controller.value.error, isNull);
    expect(controller.value.isRunning, isTrue);
    await close(tester);
  });

  testWidgets('disposal during startup releases the camera for the next scan', (
    tester,
  ) async {
    final barrier = platform.startBarrier = Completer<void>();
    await show(tester);
    final oldController = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    expect(oldController.value.isStarting, isTrue);
    expect(platform.isLive, isFalse);
    // A rejected second start must not replace the startup cleanup awaits.
    await expectLater(
      oldController.start(),
      throwsA(
        isA<MobileScannerException>().having(
          (error) => error.errorCode,
          'errorCode',
          MobileScannerErrorCode.controllerInitializing,
        ),
      ),
    );

    await close(tester);
    barrier.complete();
    await tester.pump();
    expect(platform.isLive, isFalse);
    await show(tester);
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    expect(platform.starts, 2);
    expect(platform.overlappingStarts, 0);
    expect(platform.isLive, isTrue);
    expect(controller.value.error, isNull);
    expect(controller.value.isRunning, isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('replacement waits for a disposed scanner still starting', (
    tester,
  ) async {
    final barrier = platform.startBarrier = Completer<void>();
    await show(tester);
    await close(tester);
    await show(tester);
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;

    barrier.complete();
    await tester.pump();
    await tester.pump();
    expect(platform.starts, 2);
    expect(platform.overlappingStarts, 0);
    expect(platform.isLive, isTrue);
    expect(controller.value.error, isNull);
    expect(controller.value.isRunning, isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('disposal while waiting for release cancels the queued start', (
    tester,
  ) async {
    final barrier = platform.startBarrier = Completer<void>();
    await show(tester);
    await close(tester);
    await show(tester);
    await close(tester);

    barrier.complete();
    await tester.pump();
    expect(platform.starts, 1);
    expect(platform.overlappingStarts, 0);
    expect(platform.isLive, isFalse);
    expect(platform.hasPlatformListeners, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'replacement in the same frame waits for pending startup cleanup',
    (tester) async {
      final barrier = platform.startBarrier = Completer<void>();
      await show(tester, scannerKey: const ValueKey(0));
      await show(tester, scannerKey: const ValueKey(1));
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;

      barrier.complete();
      await tester.pump();
      await tester.pump();
      expect(platform.starts, 2);
      expect(platform.overlappingStarts, 0);
      expect(platform.isLive, isTrue);
      expect(controller.value.error, isNull);
      expect(controller.value.isRunning, isTrue);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('disposal after pending startup cancels platform listeners', (
    tester,
  ) async {
    final barrier = platform.startBarrier = Completer<void>();
    await show(tester);
    expect(platform.hasPlatformListeners, isTrue);
    await close(tester);

    barrier.complete();
    await tester.pump();
    expect(platform.isLive, isFalse);
    expect(platform.hasPlatformListeners, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed release does not block or stop the replacement camera',
    (tester) async {
      final barrier = platform.startBarrier = Completer<void>();
      await show(tester, scannerKey: const ValueKey(0));
      platform.disposeError = StateError('camera cleanup unavailable');
      await show(tester, scannerKey: const ValueKey(1));
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;

      barrier.complete();
      await tester.pump();
      await tester.pump();
      expect(platform.starts, 2);
      expect(platform.overlappingStarts, 0);
      expect(platform.isLive, isTrue);
      expect(controller.value.error, isNull);
      expect(controller.value.isRunning, isTrue);
      expect(tester.takeException(), isNull);
      platform.disposeError = null;
      await close(tester);
      expect(platform.hasPlatformListeners, isFalse);
    },
  );

  testWidgets('reactivation while waiting for release does not block startup', (
    tester,
  ) async {
    final barrier = platform.startBarrier = Completer<void>();
    await show(tester);
    await close(tester);
    final visibility = ValueNotifier(true);
    addTearDown(visibility.dispose);
    await show(tester, scannerKey: GlobalKey(), visibility: visibility);
    final state = tester.state(find.byType(UrScannerView));
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;

    deactivateScanner(tester, visibility);
    visibility.value = true;
    await tester.pump();
    barrier.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.state(find.byType(UrScannerView)), same(state));
    expect(platform.starts, 2);
    expect(platform.overlappingStarts, 0);
    expect(platform.isLive, isTrue);
    expect(controller.value.error, isNull);
    expect(controller.value.isRunning, isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('deactivation during startup stops once the camera is ready', (
    tester,
  ) async {
    final barrier = platform.startBarrier = Completer<void>();
    final visibility = ValueNotifier(true);
    addTearDown(visibility.dispose);
    await show(tester, scannerKey: GlobalKey(), visibility: visibility);
    final state = tester.state(find.byType(UrScannerView));
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    expect(controller.value.isStarting, isTrue);

    deactivateScanner(tester, visibility);
    barrier.complete();
    await tester.idle();
    expect(state.mounted, isTrue);
    expect(platform.isLive, isFalse);
    expect(platform.stops, 1);
    expect(controller.value.isRunning, isFalse);

    visibility.value = true;
    await tester.pump();
    await tester.pump();
    expect(tester.state(find.byType(UrScannerView)), same(state));
    expect(platform.starts, 2);
    expect(platform.overlappingStarts, 0);
    expect(platform.isLive, isTrue);
    expect(controller.value.error, isNull);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('reactivation during startup cancels the deferred stop', (
    tester,
  ) async {
    final barrier = platform.startBarrier = Completer<void>();
    final visibility = ValueNotifier(true);
    addTearDown(visibility.dispose);
    await show(tester, scannerKey: GlobalKey(), visibility: visibility);
    final state = tester.state(find.byType(UrScannerView));
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    expect(controller.value.isStarting, isTrue);

    deactivateScanner(tester, visibility);
    visibility.value = true;
    await tester.pump();
    expect(tester.state(find.byType(UrScannerView)), same(state));
    barrier.complete();
    await tester.pump();
    expect(platform.starts, 1);
    expect(platform.stops, 0);
    expect(platform.overlappingStarts, 0);
    expect(platform.isLive, isTrue);
    expect(controller.value.error, isNull);
    expect(controller.value.isRunning, isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  for (final dispose in [false, true]) {
    testWidgets(
      '${dispose ? 'disposal' : 'deactivation'} handles a failing pending start',
      (tester) async {
        final visibility = ValueNotifier(true);
        addTearDown(visibility.dispose);
        await show(tester, scannerKey: GlobalKey(), visibility: visibility);
        final barrier = platform.startBarrier = Completer<void>();
        platform.startError = StateError('camera unavailable');
        await lifecycle(tester, AppLifecycleState.inactive);
        await lifecycle(tester, AppLifecycleState.resumed);
        final controller = tester
            .widget<MobileScanner>(find.byType(MobileScanner))
            .controller!;
        expect(controller.value.isStarting, isTrue);

        if (dispose) {
          await close(tester);
        } else {
          deactivateScanner(tester, visibility);
        }
        barrier.complete();
        await tester.idle();
        expect(platform.isLive, isFalse);
        expect(tester.takeException(), isNull);

        platform.startBarrier = null;
        platform.startError = null;
        if (!dispose) await close(tester);
        await show(tester);
        final nextController = tester
            .widget<MobileScanner>(find.byType(MobileScanner))
            .controller!;
        expect(platform.starts, 3);
        expect(platform.overlappingStarts, 0);
        expect(platform.isLive, isTrue);
        expect(nextController.value.error, isNull);
        expect(nextController.value.isRunning, isTrue);
        expect(tester.takeException(), isNull);
        await close(tester);
      },
    );
  }

  testWidgets(
    'rapid resumes and rejection do not start an initializing camera',
    (tester) async {
      await show(tester, onScanned: (_) async => 'Try another code');
      platform.startBarrier = Completer<void>();
      await lifecycle(tester, AppLifecycleState.inactive);
      await lifecycle(tester, AppLifecycleState.resumed);
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .controller!;
      expect(controller.value.isStarting, isTrue);
      await lifecycle(tester, AppLifecycleState.inactive);
      await lifecycle(tester, AppLifecycleState.resumed);
      detect(tester, UrEncoder.encodeSinglePart(UR('bytes', Uint8List(3))));
      await tester.pump();
      expect(platform.starts, 2);
      expect(find.text('Try another code'), findsOneWidget);
      expect(tester.takeException(), isNull);

      platform.startBarrier!.complete();
      await tester.pump();
      expect(controller.value.isStarting, isFalse);
      expect(controller.value.isRunning, isTrue);
      await close(tester);
    },
  );

  testWidgets('a background restart failure is handled without a zone error', (
    tester,
  ) async {
    await show(tester);
    platform.startError = StateError('camera unavailable');
    await lifecycle(tester, AppLifecycleState.inactive);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(platform.starts, 2);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a reactivated scanner restarts after the tree update', (
    tester,
  ) async {
    final key = GlobalKey();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Widget app(bool left) {
      final scanner = UrScannerView(
        key: key,
        expectedTypes: const {'bytes'},
        onScanned: (_) async => null,
      );
      return MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: left ? scanner : const SizedBox()),
              Expanded(child: left ? const SizedBox() : scanner),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(app(true));
    await tester.pump();
    final state = tester.state(find.byType(UrScannerView));
    await tester.pumpWidget(app(false));
    await tester.pump();
    expect(tester.state(find.byType(UrScannerView)), same(state));
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    expect(platform.starts, 2);
    expect(platform.stops, 1);
    expect(platform.isLive, isTrue);
    expect(controller.value.error, isNull);
    expect(controller.value.isRunning, isTrue);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('camera stops when inactive and starts again when resumed', (
    tester,
  ) async {
    await show(tester);
    expect(platform.starts, 1);

    await lifecycle(tester, AppLifecycleState.inactive);
    expect(platform.stops, 1);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(platform.starts, 2);

    final observer = tester.state(find.byType(UrScannerView));
    await close(tester);
    expect(
      tester.binding.removeObserver(observer as WidgetsBindingObserver),
      isFalse,
    );
    expect(platform.starts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lifecycle ignores uninitialized and permission-denied cameras', (
    tester,
  ) async {
    await show(tester);
    final controller = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .controller!;
    final initialized = controller.value;
    for (final value in [
      const MobileScannerState.uninitialized(),
      initialized.copyWith(
        error: const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied,
        ),
      ),
    ]) {
      controller.value = value;
      await lifecycle(tester, AppLifecycleState.inactive);
      await lifecycle(tester, AppLifecycleState.resumed);
      expect(platform.stops, 0);
      expect(platform.starts, 1);
    }
    controller.value = initialized;
    await close(tester);
  });

  testWidgets('hidden, paused and detached leave the camera unchanged', (
    tester,
  ) async {
    await show(tester);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      await lifecycle(tester, state);
    }
    expect(platform.stops, 0);
    expect(platform.starts, 1);
    await close(tester);
  });

  testWidgets('resuming preserves the pause during validation and acceptance', (
    tester,
  ) async {
    final result = Completer<String?>();
    var scans = 0;
    await show(
      tester,
      onScanned: (_) {
        scans++;
        return result.future;
      },
    );
    final raw = UrEncoder.encodeSinglePart(UR('bytes', Uint8List(3)));
    detect(tester, raw);
    await lifecycle(tester, AppLifecycleState.inactive);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(platform.starts, 1);
    result.complete(null);
    await tester.pump();
    await lifecycle(tester, AppLifecycleState.inactive);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(platform.starts, 1);
    detect(tester, raw);
    expect(scans, 1);
    await close(tester);
  });

  testWidgets('resuming after validation rejects a code restarts the camera', (
    tester,
  ) async {
    final result = Completer<String?>();
    await show(tester, onScanned: (_) => result.future);
    detect(tester, UrEncoder.encodeSinglePart(UR('bytes', Uint8List(3))));
    await lifecycle(tester, AppLifecycleState.inactive);
    result.complete('Try another code');
    await tester.pump();
    expect(platform.starts, 1);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(platform.starts, 2);
    expect(find.text('Try another code'), findsOneWidget);
    await close(tester);
  });

  testWidgets('decoder rejections show friendly copy and allow another scan', (
    tester,
  ) async {
    var scans = 0;
    await show(
      tester,
      onScanned: (_) async {
        scans++;
        return null;
      },
    );
    for (final raw in [
      UrEncoder.encodeSinglePart(UR('crypto-hdkey', Uint8List(3))),
      'ur:bytes',
      'ur:bytes/not-bytewords',
    ]) {
      detect(tester, raw);
      await tester.pump();
      expect(
        find.text(
          "That code couldn't be read. Hold the camera steady and try again.",
        ),
        findsOneWidget,
      );
      expect(find.textContaining('unexpected UR type'), findsNothing);
      expect(find.textContaining('malformed UR'), findsNothing);
      expect(scans, 0);
    }
    detect(tester, UrEncoder.encodeSinglePart(UR('bytes', Uint8List(3))));
    await tester.pump();
    expect(scans, 1);
    await close(tester);
  });

  testWidgets('typed wrong-type guidance applies only to unexpected types', (
    tester,
  ) async {
    var scans = 0;
    await show(
      tester,
      unexpectedTypeError: 'Scan the account export from your Keystone.',
      onScanned: (_) async {
        scans++;
        return null;
      },
    );
    detect(
      tester,
      UrEncoder.encodeSinglePart(UR('crypto-hdkey', Uint8List(3))),
    );
    await tester.pump();
    expect(
      find.text('Scan the account export from your Keystone.'),
      findsOneWidget,
    );
    expect(scans, 0);

    detect(tester, 'ur:bytes');
    await tester.pump();
    expect(
      find.text(
        "That code couldn't be read. Hold the camera steady and try again.",
      ),
      findsOneWidget,
    );
    expect(
      find.text('Scan the account export from your Keystone.'),
      findsNothing,
    );
    detect(tester, UrEncoder.encodeSinglePart(UR('bytes', Uint8List(3))));
    await tester.pump();
    expect(scans, 1);
    await close(tester);
  });

  testWidgets('rejection callbacks can select guidance by typed reason', (
    tester,
  ) async {
    final kinds = <UrDecodeErrorKind>[];
    await show(
      tester,
      describeRejection: (e) {
        kinds.add(e.kind);
        return e.kind == UrDecodeErrorKind.unexpectedType
            ? 'Use the account export.'
            : null;
      },
    );
    detect(
      tester,
      UrEncoder.encodeSinglePart(UR('crypto-hdkey', Uint8List(3))),
    );
    await tester.pump();
    expect(find.text('Use the account export.'), findsOneWidget);
    detect(tester, 'ur:bytes');
    await tester.pump();
    expect(kinds, [
      UrDecodeErrorKind.unexpectedType,
      UrDecodeErrorKind.malformed,
    ]);
    expect(
      find.text(
        "That code couldn't be read. Hold the camera steady and try again.",
      ),
      findsOneWidget,
    );
    await close(tester);
  });

  testWidgets('validation rejecting after resume restarts the idle camera', (
    tester,
  ) async {
    final result = Completer<String?>();
    await show(tester, onScanned: (_) => result.future);
    detect(tester, UrEncoder.encodeSinglePart(UR('bytes', Uint8List(3))));
    await lifecycle(tester, AppLifecycleState.inactive);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(platform.starts, 1);

    result.complete('Try another code');
    await tester.pump();
    expect(platform.starts, 2);
    await tester.pump();
    expect(find.text('Try another code'), findsOneWidget);
    await close(tester);
  });
}
