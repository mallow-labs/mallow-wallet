import 'dart:async';

import 'package:flutter/material.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../../../shared/theme/mallow_theme.dart';

/// Shows a UR as a QR code the Keystone can scan — one frame for a short
/// payload, an animated cycle of fountain-coded frames for a long one.
///
/// The device's decoder accepts frames in any order and tolerates missed
/// ones, so the cycle never needs to restart: it keeps emitting fresh fountain
/// parts until the widget goes away.
class AnimatedUrQr extends StatefulWidget {
  const AnimatedUrQr({
    required this.ur,
    this.size = 280,
    this.frameInterval = kKeystoneFrameInterval,
    super.key,
  });

  final UR ur;
  final double size;
  final Duration frameInterval;

  @override
  State<AnimatedUrQr> createState() => _AnimatedUrQrState();
}

class _AnimatedUrQrState extends State<AnimatedUrQr> {
  late UrEncoder _encoder;
  late String _part;
  late QrImage _qrImage;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(AnimatedUrQr oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ur, widget.ur) ||
        oldWidget.frameInterval != widget.frameInterval) {
      _timer?.cancel();
      _start();
    }
  }

  void _start() {
    _encoder = UrEncoder(widget.ur);
    _nextPart();
    if (_encoder.isSinglePart) return;
    _timer = Timer.periodic(widget.frameInterval, (_) {
      if (!mounted) return;
      setState(_nextPart);
    });
  }

  void _nextPart() {
    _part = _encoder.nextPart();
    // Encoding and mask selection are only needed when the frame changes,
    // not when the surrounding sheet rebuilds.
    _qrImage = buildUrQrImage(_part);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Signing request QR code for your Keystone',
      image: true,
      child: Container(
        width: widget.size,
        height: widget.size,
        padding: const EdgeInsets.all(MallowTheme.spacingMd),
        decoration: BoxDecoration(
          // Literal white in both themes: the device's camera needs the
          // contrast and the quiet zone, whatever the app theme is.
          color: Colors.white,
          borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
        ),
        // Low error correction keeps the modules large for a camera reading
        // a phone screen (nothing overlays this code). Plain black squares
        // preserve contrast at their edges: rounded modules cost a scanner
        // contrast and a fast frame cycle has no margin.
        //
        // Keyed by the part it draws, so each frame is its own code rather
        // than an update the view might coalesce — and so a test can read
        // which part is on screen.
        child: KeyedSubtree(
          key: ValueKey<String>(_part),
          child: PrettyQrView(
            qrImage: _qrImage,
            decoration: const PrettyQrDecoration(
              quietZone: PrettyQrQuietZone.zero,
              shape: PrettyQrSquaresSymbol(),
            ),
          ),
        ),
      ),
    );
  }
}

final RegExp _nonAlphanumeric = RegExp(r'[^A-Z0-9 $%*+\-./:]');

/// Builds the smallest low-error-correction QR for a request frame.
@visibleForTesting
QrImage buildUrQrImage(String part) {
  // UR parts are uppercase so alphanumeric encoding keeps the modules
  // larger than byte encoding. Fall back to bytes for unexpected characters
  // rather than rejecting a frame or changing its contents.
  if (part.isEmpty || _nonAlphanumeric.hasMatch(part)) {
    return QrImage(
      QrCode.fromData(data: part, errorCorrectLevel: QrErrorCorrectLevel.L),
    );
  }

  var typeNumber = 1;
  while (true) {
    final code = QrCode(typeNumber, QrErrorCorrectLevel.L)
      ..addAlphaNumeric(part);
    try {
      // Capacity is checked when the image materializes the encoded data.
      return QrImage(code);
    } on InputTooLongException {
      if (typeNumber == 40) rethrow;
      typeNumber++;
    }
  }
}
