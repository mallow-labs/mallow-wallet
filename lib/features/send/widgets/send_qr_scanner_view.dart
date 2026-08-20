import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/permission_settings_sheet.dart';

/// Fullscreen QR scanner used by the send screen. Renders a black chrome for
/// camera contrast regardless of app theme.
class SendQrScannerView extends StatelessWidget {
  const SendQrScannerView({
    required this.onDetect,
    required this.onClose,
    super.key,
  });

  final void Function(BarcodeCapture) onDetect;
  final VoidCallback onClose;

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
      body: MobileScanner(
        onDetect: onDetect,
        errorBuilder: (context, error) => _ScannerError(error: error),
      ),
    );
  }
}

/// Failure state for the camera preview: permission denials get an action that
/// leads to the OS settings, everything else just gets an explanation.
class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final message = denied
        ? "mallow can't use the camera, so QR codes can't be scanned. You can "
              'still paste an address instead.'
        : "The camera couldn't be started. Close the scanner and try again, or "
              'paste an address instead.';

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
