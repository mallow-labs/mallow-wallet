import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/mallow_theme.dart';
import 'confirm_sheet.dart';
import 'mallow_button.dart';
import 'mallow_svg_icon.dart';

/// A sensitive OS permission mallow explains in its own words before the
/// system dialog asks for it (prominent disclosure).
///
/// Each one is asked for only when the user starts the feature that needs it,
/// never at launch. The copy says what the permission is used for and what it
/// is not used for, so the OS dialog that follows is never the first the user
/// hears of it.
enum PermissionDisclosure {
  camera(
    title: 'Allow camera access',
    message:
        'mallow uses the camera only to read QR codes: wallet addresses, '
        'payment requests, WalletConnect links and the codes on a Keystone '
        'screen. Nothing is recorded, stored or uploaded.',
    icon: 'assets/icons/qr.svg',
  ),
  bluetooth(
    title: 'Allow nearby devices',
    message:
        'mallow uses Bluetooth only to find and connect to your Ledger, so it '
        'can sign with it. It does not use your location, and it does not '
        'look for any other device.',
    icon: 'assets/icons/bluetooth.svg',
  ),
  notifications(
    title: 'Turn on notifications?',
    message:
        'mallow sends notifications about activity on your wallets: offers, '
        'bids, sales, transfers and mints. You can turn them off at any time '
        'in Settings.',
    icon: 'assets/icons/bell.svg',
  );

  const PermissionDisclosure({
    required this.title,
    required this.message,
    required this.icon,
  });

  /// Heading of the explanation.
  final String title;

  /// What the permission is for, shown before the OS dialog.
  final String message;

  /// SVG asset shown above an in-place explanation.
  final String icon;
}

/// Explain [disclosure] in a sheet before the OS dialog for it.
///
/// Returns true when the user chose to continue, so the caller can go on to
/// the OS request. False (or a dismissed sheet) means the caller must not ask.
Future<bool> showPermissionDisclosure(
  BuildContext context,
  PermissionDisclosure disclosure,
) async {
  final confirmed = await showConfirmSheet(
    context,
    title: disclosure.title,
    message: disclosure.message,
    confirmLabel: 'Continue',
    cancelLabel: 'Not now',
  );
  return confirmed == true;
}

const _statusChannel = MethodChannel('mallow_wallet/permission_status');

/// Whether the camera permission is already granted, without requesting it.
///
/// Android only — iOS shows the purpose string from Info.plist in its own
/// dialog. A missing native handler answers true, so a host without the
/// channel keeps today's behaviour rather than gaining a step.
Future<bool> _isCameraGranted() async {
  try {
    return await _statusChannel.invokeMethod<bool>('isCameraGranted') ?? true;
  } on MissingPluginException {
    return true;
  }
}

/// Replaces the Android permission check in tests, which run on a host with
/// no camera and no Android. Null outside tests.
@visibleForTesting
Future<bool> Function()? debugCameraPermissionCheck;

/// Holds back a camera [child] until the user has read why mallow needs the
/// camera.
///
/// The camera plugin requests the permission as soon as its preview is
/// built, so the preview must not be built until then. When the permission is
/// already granted [child] is built straight away and the user sees nothing
/// new. Otherwise an in-place explanation with a Continue button stands in for
/// the preview, on the same black ground, and Continue builds [child], which
/// shows the OS dialog.
class CameraDisclosureGate extends StatefulWidget {
  const CameraDisclosureGate({required this.child, super.key});

  final Widget child;

  @override
  State<CameraDisclosureGate> createState() => _CameraDisclosureGateState();
}

class _CameraDisclosureGateState extends State<CameraDisclosureGate> {
  /// Null while the permission check is in flight.
  bool? _ready;

  @override
  void initState() {
    super.initState();
    final check =
        debugCameraPermissionCheck ??
        (Platform.isAndroid ? _isCameraGranted : null);
    if (check == null) {
      _ready = true;
      return;
    }
    check().then((granted) {
      if (mounted) setState(() => _ready = granted);
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_ready) {
      true => widget.child,
      null => const SizedBox.expand(),
      false => _CameraDisclosure(
        onContinue: () => setState(() => _ready = true),
      ),
    };
  }
}

class _CameraDisclosure extends StatelessWidget {
  const _CameraDisclosure({required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    const disclosure = PermissionDisclosure.camera;
    // Drawn over the camera's black ground regardless of app theme, like the
    // scanner's own error state — the white literals are deliberate.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MallowSvgIcon(
              disclosure.icon,
              width: 32,
              height: 32,
              color: Colors.white,
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              disclosure.title,
              textAlign: TextAlign.center,
              style: MallowTheme.uiTitle.copyWith(color: Colors.white),
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              disclosure.message,
              textAlign: TextAlign.center,
              style: MallowTheme.uiBody.copyWith(color: Colors.white),
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            MallowButton(label: 'Continue', onPressed: onContinue),
          ],
        ),
      ),
    );
  }
}
