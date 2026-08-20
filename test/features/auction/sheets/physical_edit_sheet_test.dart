import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/auction/sheets/physical_edit_sheet.dart';

void main() {
  // 1x1 transparent PNG — small but decodable, so Image.memory doesn't
  // throw during the test.
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
  final dataUrl = Uri.dataFromBytes(pngBytes, mimeType: 'image/png').toString();

  Future<PhysicalEditResult?> openSheet(
    WidgetTester tester, {
    PhysicalDetailsPayload? initial,
  }) async {
    PhysicalEditResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showPhysicalEditSheet(
                    context,
                    showUnlockPrice: false,
                    initial: initial,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return result;
  }

  // Every image upload box in the app lets the user choose between the photo
  // library and the Files browser. Opening one picker directly — as this box
  // used to — makes a camera-roll photo unreachable.
  testWidgets('the photo box offers Photos and Files', (tester) async {
    await openSheet(tester);

    await tester.tap(find.text('Tap to upload your photo'));
    await tester.pumpAndSettle();

    expect(find.text('Photo Library'), findsOneWidget);
    expect(find.text('Browse Files…'), findsOneWidget);

    // Dismiss both sheets so the routes dispose normally before teardown.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  // The physical photo has no upload endpoint — it lives inside the payload
  // as a base64 data URL (webapp `PhysicalSection` contract). If the sheet
  // drops it on save or fails to decode it on open, the photo silently
  // vanishes from the listing and from re-edit previews.
  group('physical photo persistence', () {
    testWidgets('previews the saved data-URL photo when re-opened', (
      tester,
    ) async {
      await openSheet(
        tester,
        initial: PhysicalDetailsPayload(
          description: 'Signed print',
          imageUrl: dataUrl,
        ),
      );

      final image = tester.widget<Image>(find.byType(Image));
      // The drop zone caps the decode at the rendered width (a full-resolution
      // camera still is tens of MB of RGBA), so the provider is a ResizeImage
      // wrapping the MemoryImage rather than the bare MemoryImage. The cap
      // must never upscale — this 1x1 source has to stay 1x1.
      final provider = image.image;
      expect(provider, isA<ResizeImage>());
      final resized = provider as ResizeImage;
      expect(resized.width, isNotNull);
      expect(resized.allowUpscaling, isFalse);
      expect(resized.imageProvider, isA<MemoryImage>());
      expect((resized.imageProvider as MemoryImage).bytes, pngBytes);

      // Close the sheet so the route disposes normally before teardown.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    });

    testWidgets('Done preserves the photo in the returned payload', (
      tester,
    ) async {
      PhysicalEditResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showPhysicalEditSheet(
                      context,
                      showUnlockPrice: false,
                      initial: PhysicalDetailsPayload(
                        description: 'Signed print',
                        imageUrl: dataUrl,
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(result, isA<PhysicalEditSaved>());
      final payload = (result! as PhysicalEditSaved).payload;
      expect(
        payload.imageUrl,
        dataUrl,
        reason:
            'photo must round-trip through save so re-editing and the '
            'rewardsDescription POST both see it',
      );
      expect(payload.description, 'Signed print');
    });

    testWidgets('ignores a malformed data URL instead of crashing', (
      tester,
    ) async {
      await openSheet(
        tester,
        initial: const PhysicalDetailsPayload(
          description: 'Signed print',
          imageUrl: 'data:image/png;base64,!!!not-base64!!!',
        ),
      );

      expect(find.byType(Image), findsNothing);
      expect(find.text('Tap to upload your photo'), findsOneWidget);

      // Close the sheet so the route disposes normally before teardown.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    });
  });
}
