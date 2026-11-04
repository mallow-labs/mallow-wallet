import 'dart:io';
import 'dart:typed_data';

import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';

import '../walletconnect_module.dart';

/// The first WalletConnect link among the decoded [values], if any.
String? walletConnectCodeIn(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && isWalletConnectText(value)) return value.trim();
  }
  return null;
}

/// Decodes the QR codes in [png], a capture of the page in a browser tab, so
/// a website showing a WalletConnect code connects without its link being
/// copied out of the tab.
///
/// The capture can show anything the page does, so it is decoded on the
/// device, never kept in memory past the call, and its temporary file is
/// deleted before this returns. The platform decoder reads only from a file.
Future<List<String?>> decodePageCodes(Uint8List png) async {
  final directory = await getTemporaryDirectory();
  final file = File(
    '${directory.path}/page-code-${DateTime.now().microsecondsSinceEpoch}.png',
  );
  final scanner = MobileScannerController(autoStart: false);
  try {
    await file.writeAsBytes(png, flush: true);
    final capture = await scanner.analyzeImage(
      file.path,
      formats: const [BarcodeFormat.qrCode],
    );
    return [
      for (final barcode in capture?.barcodes ?? const <Barcode>[])
        barcode.rawValue,
    ];
  } finally {
    await scanner.dispose();
    try {
      await file.delete();
    } catch (_) {
      // The OS clears the temporary directory; nothing else reads it.
    }
  }
}
