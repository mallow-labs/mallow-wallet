import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/permission_settings_sheet.dart';

/// Fullscreen QR scanner used by the send screen. Renders a black chrome for
/// camera contrast regardless of app theme.
///
/// Only a square window in the middle of the preview reads codes, so a stray
/// QR elsewhere in view (a second code on the same page, a poster behind the
/// one being scanned) cannot be picked up by accident.
class SendQrScannerView extends StatelessWidget {
  const SendQrScannerView({
    required this.onDetect,
    required this.onClose,
    this.offersPaste = true,
    super.key,
  });

  final void Function(BarcodeCapture) onDetect;
  final VoidCallback onClose;

  /// Whether the camera-failure copy points to pasting an address instead,
  /// for a caller that has a field to paste into.
  final bool offersPaste;

  @override
  Widget build(BuildContext context) {
    // QR-scanner camera view always renders on a black chrome for camera
    // contrast — black/white literals intentional regardless of app theme.
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Close',
          icon: const MallowSvgIcon(
            'assets/icons/x.svg',
            color: Colors.white,
            semanticLabel: 'Close',
          ),
          onPressed: onClose,
        ),
        title: Text(
          'Scan QR Code',
          style: MallowTheme.uiTitle.copyWith(color: Colors.white),
        ),
        centerTitle: false,
      ),
      // Without an errorBuilder a denied camera permission renders as a black
      // rectangle, which reads as a broken scanner. Surface the reason and a
      // route back to the OS setting instead.
      body: LayoutBuilder(
        builder: (context, constraints) {
          final window = scanWindowFor(constraints.biggest);
          return MobileScanner(
            onDetect: onDetect,
            scanWindow: window,
            overlayBuilder: (context, _) => _ScanWindowOverlay(window: window),
            errorBuilder: (context, error) =>
                _ScannerError(error: error, offersPaste: offersPaste),
          );
        },
      ),
    );
  }

  /// The square, centred region of a preview of [size] that reads codes.
  @visibleForTesting
  static Rect scanWindowFor(Size size) {
    final side = (size.shortestSide * 0.72).clamp(0.0, 300.0);
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: side,
      height: side,
    );
  }
}

/// Dims the preview outside [window] and frames it, with a line of guidance
/// underneath, so the user can see where the code has to sit.
class _ScanWindowOverlay extends StatelessWidget {
  const _ScanWindowOverlay({required this.window});

  final Rect window;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _ScanWindowPainter(window)),
        ),
        Positioned(
          left: MallowTheme.spacing20,
          right: MallowTheme.spacing20,
          top: window.bottom + MallowTheme.spacingLg,
          child: Text(
            'Fit the QR code inside the frame',
            textAlign: TextAlign.center,
            style: MallowTheme.uiBody.copyWith(color: Colors.white),
          ),
        ),
      ],
    );
  }
}

class _ScanWindowPainter extends CustomPainter {
  const _ScanWindowPainter(this.window);

  final Rect window;

  static const _radius = Radius.circular(MallowTheme.radiusLg);

  @override
  void paint(Canvas canvas, Size size) {
    final frame = RRect.fromRectAndRadius(window, _radius);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(frame),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawRRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_ScanWindowPainter oldDelegate) =>
      oldDelegate.window != window;
}

/// Failure state for the camera preview: permission denials get an action that
/// leads to the OS settings, everything else just gets an explanation.
class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error, required this.offersPaste});

  final MobileScannerException error;
  final bool offersPaste;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final message = switch ((denied, offersPaste)) {
      (true, true) =>
        "mallow can't use the camera, so QR codes can't be scanned. You can "
            'still paste an address instead.',
      (true, false) =>
        "mallow can't use the camera, so QR codes can't be scanned.",
      (false, true) =>
        "The camera couldn't be started. Close the scanner and try again, or "
            'paste an address instead.',
      (false, false) =>
        "The camera couldn't be started. Close the scanner and try again.",
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MallowSvgIcon(
              'assets/icons/qr.svg',
              width: 32,
              height: 32,
              color: Colors.white,
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              message,
              textAlign: TextAlign.center,
              style: MallowTheme.uiBody.copyWith(color: Colors.white),
            ),
            if (denied) ...[
              const SizedBox(height: MallowTheme.spacingLg),
              MallowButton(
                label: 'Enable camera access',
                onPressed: () =>
                    showPermissionSettingsSheet(context, AppPermission.camera),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
