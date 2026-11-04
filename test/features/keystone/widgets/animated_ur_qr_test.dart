import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:mallow_wallet/features/keystone/widgets/animated_ur_qr.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

UR _request({int size = 120}) => SolSignRequest(
  requestId: Uint8List.fromList(List<int>.generate(16, (i) => i)),
  signData: Uint8List.fromList(List<int>.generate(size, (i) => i % 251)),
  path: KeystoneKeypath.parse(
    "m/44'/501'/0'/0'",
    sourceFingerprint: 0x12121212,
  ),
).toUr();

QrImage _image(WidgetTester tester) {
  final properties = DiagnosticPropertiesBuilder();
  tester
      .widget<PrettyQrView>(find.byType(PrettyQrView))
      .debugFillProperties(properties);
  return properties.properties
      .whereType<DiagnosticsProperty<QrImage>>()
      .single
      .value!;
}

// The first four data modules sit at the bottom right, clear of every
// function pattern. Undo the selected mask to read the QR mode indicator.
int _mode(QrImage image) {
  var mode = 0;
  for (var i = 0; i < 4; i++) {
    final row = image.moduleCount - 1 - i ~/ 2;
    final col = image.moduleCount - 1 - i % 2;
    final masked = switch (image.maskPattern) {
      0 => (row + col).isEven,
      1 => row.isEven,
      2 => col % 3 == 0,
      3 => (row + col) % 3 == 0,
      4 => (row ~/ 2 + col ~/ 3).isEven,
      5 => (row * col) % 2 + (row * col) % 3 == 0,
      6 => ((row * col) % 2 + (row * col) % 3).isEven,
      7 => ((row * col) % 3 + (row + col) % 2).isEven,
      _ => throw StateError('Unexpected QR mask'),
    };
    mode = (mode << 1) | (image.isDark(row, col) != masked ? 1 : 0);
  }
  return mode;
}

void main() {
  testWidgets('a full 200-byte request fragment fits QR version 12', (
    tester,
  ) async {
    // Keep the CBOR body at exactly two full fragments, including the
    // request metadata, so balanced fountain splitting cannot shorten them.
    final overhead = _request(size: 300).cbor.length - 300;
    final ur = _request(size: 400 - overhead);
    expect(ur.cbor, hasLength(400));
    final part = UrEncoder(ur).nextPart();

    await tester.pumpWidget(MaterialApp(home: AnimatedUrQr(ur: ur)));

    expect(find.byKey(ValueKey<String>(part)), findsOneWidget);
    final image = _image(tester);
    expect(image.typeNumber, lessThanOrEqualTo(12));
    expect(image.errorCorrectLevel, QrErrorCorrectLevel.L);
    expect(_mode(image), 0x2);
    expect(
      () => QrImage(
        QrCode(image.typeNumber - 1, QrErrorCorrectLevel.L)
          ..addAlphaNumeric(part),
      ),
      throwsA(isA<InputTooLongException>()),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a short request renders one stable alphanumeric frame', (
    tester,
  ) async {
    final ur = _request(size: 20);
    final encoder = UrEncoder(ur);
    expect(encoder.isSinglePart, isTrue);
    final part = encoder.nextPart();

    await tester.pumpWidget(MaterialApp(home: AnimatedUrQr(ur: ur)));

    final image = _image(tester);
    expect(find.byKey(ValueKey<String>(part)), findsOneWidget);
    expect(_mode(image), 0x2);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(ValueKey<String>(part)), findsOneWidget);
    expect(_image(tester), same(image));
    expect(tester.takeException(), isNull);
  });

  testWidgets('caches the image across rebuilds and refreshes on each frame', (
    tester,
  ) async {
    final ur = _request(size: 1000);
    final encoder = UrEncoder(ur);
    final firstPart = encoder.nextPart();
    await tester.pumpWidget(MaterialApp(home: AnimatedUrQr(ur: ur)));
    final firstImage = _image(tester);

    await tester.pumpWidget(MaterialApp(home: AnimatedUrQr(ur: ur, size: 300)));
    expect(_image(tester), same(firstImage));
    expect(find.byKey(ValueKey<String>(firstPart)), findsOneWidget);

    await tester.pump(kKeystoneFrameInterval);
    final nextPart = encoder.nextPart();
    expect(find.byKey(ValueKey<String>(firstPart)), findsNothing);
    expect(find.byKey(ValueKey<String>(nextPart)), findsOneWidget);
    final nextImage = _image(tester);
    expect(nextImage, isNot(same(firstImage)));
    expect(_mode(nextImage), 0x2);
    expect(nextImage.qrModules, isNot(equals(firstImage.qrModules)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replacing an animated request refreshes the image and timer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: AnimatedUrQr(ur: _request(size: 1000))),
    );
    final oldImage = _image(tester);
    final ur = _request(size: 20);
    final part = UrEncoder(ur).nextPart();

    await tester.pumpWidget(MaterialApp(home: AnimatedUrQr(ur: ur)));

    final image = _image(tester);
    expect(image, isNot(same(oldImage)));
    expect(find.byKey(ValueKey<String>(part)), findsOneWidget);
    expect(_mode(image), 0x2);
    await tester.pump(const Duration(seconds: 1));
    expect(_image(tester), same(image));
    expect(find.byKey(ValueKey<String>(part)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final part in [
    'ur:sol-sign-request/ABC',
    'UR:SOL-SIGN-REQUEST/ABC_',
    'UR:SOL-SIGN-REQUEST/☃',
    'UR:SOL-SIGN-REQUEST/ABC\n',
  ]) {
    testWidgets('renders unexpected characters in byte mode: ${part.trim()}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: PrettyQrView(qrImage: buildUrQrImage(part))),
      );

      final image = _image(tester);
      expect(_mode(image), 0x4);
      expect(
        image.qrModules,
        QrImage(
          QrCode.fromData(data: part, errorCorrectLevel: QrErrorCorrectLevel.L),
        ).qrModules,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
