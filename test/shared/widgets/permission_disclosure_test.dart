import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/permission_disclosure.dart';

const _camera = Text('camera preview');

Future<void> _pumpGate(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: const Scaffold(
        backgroundColor: Colors.black,
        body: CameraDisclosureGate(child: _camera),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    final originalFonts = GoogleFonts.config.allowRuntimeFetching;
    GoogleFonts.config.allowRuntimeFetching = false;
    addTearDown(() {
      GoogleFonts.config.allowRuntimeFetching = originalFonts;
      debugCameraPermissionCheck = null;
    });
  });

  testWidgets('builds the camera straight away off Android', (tester) async {
    await _pumpGate(tester);

    expect(find.text('camera preview'), findsOneWidget);
    expect(find.text(PermissionDisclosure.camera.title), findsNothing);
  });

  testWidgets('builds the camera when the permission is already granted', (
    tester,
  ) async {
    debugCameraPermissionCheck = () async => true;
    await _pumpGate(tester);

    expect(find.text('camera preview'), findsOneWidget);
    expect(find.text(PermissionDisclosure.camera.title), findsNothing);
  });

  testWidgets('explains the camera before building it when not granted', (
    tester,
  ) async {
    debugCameraPermissionCheck = () async => false;
    await _pumpGate(tester);

    // The preview is what requests the permission, so it must not exist yet.
    expect(find.text('camera preview'), findsNothing);
    expect(find.text(PermissionDisclosure.camera.title), findsOneWidget);
    expect(find.text(PermissionDisclosure.camera.message), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.text('camera preview'), findsOneWidget);
    expect(find.text(PermissionDisclosure.camera.title), findsNothing);
  });
}
