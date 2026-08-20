import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/pickers/image_source_picker.dart';

/// Every image upload box in the app routes through [pickImageFromSource], so
/// these tests stand in for the profile avatar/banner boxes and the auction
/// physical-photo box alike: they pin that *both* system pickers are reachable
/// and that the app's own allowlist is enforced on whatever either one returns.
///
/// The Photos branch is the one that needs the guarding. The document browser
/// is at least handed a type filter, but the system photo picker knows nothing
/// about our rules and will happily return a `.gif`, a 40 MB still, or an
/// iPhone `.heic` regardless of what the caller accepts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const photoChannel = MethodChannel('plugins.flutter.io/image_picker');
  const fileChannel = MethodChannel('plugins.flutter.io/file_selector');

  // 1x1 transparent PNG — real bytes, so nothing downstream chokes decoding.
  final pngBytes = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, //
    0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, //
    0x00, 0x05, 0x00, 0x01, 0xE9, 0xFA, 0xDC, 0xD8, //
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
    0xAE, 0x42, 0x60, 0x82,
  ]);

  late Directory tempDir;
  late List<MethodCall> photoCalls;
  late List<MethodCall> fileCalls;
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('image_source_picker_test');
    photoCalls = [];
    fileCalls = [];
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(photoChannel, null);
    messenger.setMockMethodCallHandler(fileChannel, null);
    tempDir.deleteSync(recursive: true);
  });

  /// Stands in for the OS photo picker, handing back a real on-disk file —
  /// the production path stats it and reads it, so a path to nowhere would
  /// exercise the wrong branch.
  void mockPhotoPick({required String name, required List<int> bytes}) {
    final file = File('${tempDir.path}/$name')..writeAsBytesSync(bytes);
    messenger.setMockMethodCallHandler(photoChannel, (call) async {
      photoCalls.add(call);
      return file.path;
    });
  }

  /// Stands in for the OS document browser, handing back a path to a real
  /// on-disk file. `file_selector` returns paths rather than inline bytes, so
  /// the production path reads the file itself and a path to nowhere would
  /// exercise the wrong branch.
  void mockFilePick({required String name, required List<int> bytes}) {
    final file = File('${tempDir.path}/$name')..writeAsBytesSync(bytes);
    messenger.setMockMethodCallHandler(fileChannel, (call) async {
      fileCalls.add(call);
      return <String>[file.path];
    });
  }

  /// Stands in for a pick the app cannot read back: the browser returns a path
  /// that was never written. On a device the same shape is an Android content
  /// Uri whose provider throws, or an iOS security-scoped copy the OS reaped
  /// between the pick and the read.
  void mockUnreadableFilePick({required String name}) {
    messenger.setMockMethodCallHandler(fileChannel, (call) async {
      fileCalls.add(call);
      return <String>['${tempDir.path}/$name'];
    });
  }

  void mockNoPicks() {
    messenger.setMockMethodCallHandler(photoChannel, (call) async {
      photoCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(fileChannel, (call) async {
      fileCalls.add(call);
      return null;
    });
  }

  /// Resolves [future] while keeping the tree pumping.
  ///
  /// The Photos branch stats and reads a real file off disk. Real I/O only
  /// progresses inside [WidgetTester.runAsync], while the continuations that
  /// follow each `await` are queued in the test's fake-async zone and only run
  /// on a pump — neither alone finishes the chain, so alternate the two.
  Future<PickedImage?> drain(
    WidgetTester tester,
    Future<PickedImage?> future,
  ) async {
    PickedImage? value;
    var done = false;
    unawaited(
      future.then((v) {
        value = v;
        done = true;
      }),
    );
    for (var i = 0; i < 100 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(done, isTrue, reason: 'the pick never completed');
    return value;
  }

  /// Pumps a single button wired to [pickImageFromSource] and drives it through
  /// the sheet to a result. Defaults mirror the profile boxes.
  Future<({PickedImage? picked, List<String> errors})> pickVia(
    WidgetTester tester,
    String sourceLabel, {
    List<String> allowedExtensions = const ['png', 'jpg', 'jpeg', 'webp'],
    int maxSizeBytes = 20 * 1024 * 1024,
    bool dismissSheet = false,
  }) async {
    Future<PickedImage?>? pending;
    final errors = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  pending = pickImageFromSource(
                    context,
                    allowedExtensions: allowedExtensions,
                    maxSizeBytes: maxSizeBytes,
                    typeSummary: 'an image',
                    onError: errors.add,
                  );
                },
                child: const Text('Upload'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    // Tapping the barrier above the sheet dismisses it.
    await (dismissSheet
        ? tester.tapAt(const Offset(10, 10))
        : tester.tap(find.text(sourceLabel)));
    await tester.pumpAndSettle();

    final picked = await drain(tester, pending!);
    return (picked: picked, errors: errors);
  }

  group('source choice', () {
    testWidgets('Photo Library returns the still the photo picker gave back', (
      tester,
    ) async {
      mockPhotoPick(name: 'IMG_0042.png', bytes: pngBytes);
      mockFilePick(name: 'unused.png', bytes: pngBytes);

      final result = await pickVia(tester, 'Photo Library');

      expect(result.picked?.fileName, 'IMG_0042.png');
      expect(result.picked?.bytes, pngBytes);
      expect(result.errors, isEmpty);
      expect(
        fileCalls,
        isEmpty,
        reason: 'the Photos branch must not fall through to the file browser',
      );
    });

    testWidgets('Browse Files returns the file the document picker gave back', (
      tester,
    ) async {
      mockPhotoPick(name: 'unused.png', bytes: pngBytes);
      mockFilePick(name: 'artwork.png', bytes: pngBytes);

      final result = await pickVia(tester, 'Browse Files…');

      expect(result.picked?.fileName, 'artwork.png');
      expect(result.picked?.bytes, pngBytes);
      expect(result.errors, isEmpty);
      expect(photoCalls, isEmpty);
    });

    testWidgets('dismissing the sheet opens no picker at all', (tester) async {
      mockNoPicks();

      final result = await pickVia(tester, '', dismissSheet: true);

      expect(result.picked, isNull);
      expect(result.errors, isEmpty);
      expect(photoCalls, isEmpty);
      expect(fileCalls, isEmpty);
    });
  });

  group('validation of what the pickers return', () {
    testWidgets('rejects a photo whose type the caller does not accept', (
      tester,
    ) async {
      mockPhotoPick(name: 'loop.gif', bytes: pngBytes);

      final result = await pickVia(
        tester,
        'Photo Library',
        allowedExtensions: const ['png', 'jpg'],
      );

      expect(result.picked, isNull);
      expect(result.errors, ['File must be an image']);
    });

    testWidgets('rejects a photo over the size cap', (tester) async {
      mockPhotoPick(name: 'huge.png', bytes: List.filled(2 * 1024 * 1024, 0));

      final result = await pickVia(
        tester,
        'Photo Library',
        maxSizeBytes: 1024 * 1024,
      );

      expect(result.picked, isNull);
      expect(result.errors, ['File must be 1MB or smaller']);
    });

    testWidgets('rejects an unreadable file rather than uploading nothing', (
      tester,
    ) async {
      mockFilePick(name: 'empty.png', bytes: const []);

      final result = await pickVia(tester, 'Browse Files…');

      expect(result.picked, isNull);
      expect(result.errors, ['File is empty or unreadable']);
    });

    // A read that throws must land on the same message as one that comes back
    // empty. Unguarded it leaves the picker as an unhandled async exception —
    // the tap produces no asset and no snackbar, which reads as a dead box.
    // (An escaping error also fails this test outright: `drain` awaits the
    // pick without an error handler.)
    testWidgets('rejects a file whose read throws rather than throwing on', (
      tester,
    ) async {
      mockUnreadableFilePick(name: 'reaped.png');

      final result = await pickVia(tester, 'Browse Files…');

      expect(result.picked, isNull);
      expect(result.errors, ['File is empty or unreadable']);
    });

    // `heic` is appended to every stills allowlist, so a dotless file named
    // exactly that used to satisfy the allowlist by matching itself, while the
    // transcode — stricter on purpose — left it alone. Raw HEIF then uploaded
    // under a name no mime type can be derived from, and the presign route,
    // which gates on the declared mime, refused it with an opaque 400 instead
    // of the message below.
    testWidgets('rejects a file whose whole name spells an accepted type', (
      tester,
    ) async {
      mockFilePick(name: 'heic', bytes: pngBytes);

      final result = await pickVia(
        tester,
        'Browse Files…',
        allowedExtensions: const ['png', 'jpg'],
      );

      expect(result.picked, isNull);
      expect(result.errors, ['File must be an image']);
    });
  });

  group('document-browser filter', () {
    // One unspelled extension used to collapse the whole type group, and an
    // empty group opens the browser on every file on the device — for every
    // caller, not just the one that added it. `avif` is the live example: it
    // is already in the mint image whitelist and one word away from the
    // profile boxes, and nothing about adding it says you are also turning
    // filtering off.
    testWidgets('keeps filtering for the types it can name', (tester) async {
      mockFilePick(name: 'art.png', bytes: pngBytes);

      await pickVia(
        tester,
        'Browse Files…',
        allowedExtensions: const ['png', 'avif'],
      );

      final groups = fileCalls.single.arguments['acceptedTypeGroups'] as List;
      expect(
        groups,
        hasLength(1),
        reason: 'no group at all means an unfiltered browser',
      );
      expect(groups.single['uniformTypeIdentifiers'], contains('public.png'));
      expect(groups.single['mimeTypes'], contains('image/png'));
      // The unspellable one is dropped, not guessed at: it is greyed out in
      // the browser and reachable from Photos until a spelling is added.
      expect(groups.single['extensions'], isNot(contains('avif')));
    });
  });

  group('HEIC', () {
    // An iPhone camera roll is full of HEIC, which the backend cannot render.
    // It is offered to the document picker and transcoded on the way in rather
    // than being greyed out or rejected.
    testWidgets('offers HEIC to the document picker', (tester) async {
      mockFilePick(name: 'IMG_0042.png', bytes: pngBytes);

      await pickVia(
        tester,
        'Browse Files…',
        allowedExtensions: const ['png', 'jpg'],
      );

      final group =
          (fileCalls.single.arguments['acceptedTypeGroups'] as List).single;
      expect(
        group['extensions'],
        containsAll(<String>['png', 'jpg', 'heic', 'heif']),
      );
      // iOS filters the browser by UTI, not extension: a type the group fails
      // to spell as a UTI is greyed out there however the extension list reads,
      // which would put camera-roll HEIC out of reach on the platform that
      // produces it.
      expect(
        group['uniformTypeIdentifiers'],
        containsAll(<String>['public.heic', 'public.heif']),
      );
    });

    // The successful transcode has no coverage here: `flutter_image_compress`
    // has no implementation on the desktop test host, so `compressWithList`
    // throws `UnimplementedError` before reaching any mockable channel. What
    // that does give us is the failure case for free — and it is the one that
    // matters, because a HEIC that slips through unconverted is a file the
    // backend cannot render.
    testWidgets('rejects a HEIC the platform cannot decode', (tester) async {
      mockFilePick(name: 'IMG_0042.heic', bytes: pngBytes);

      final result = await pickVia(
        tester,
        'Browse Files…',
        allowedExtensions: const ['png', 'jpg'],
      );

      expect(result.picked, isNull);
      expect(result.errors, ['File must be an image']);
    });
  });
}
