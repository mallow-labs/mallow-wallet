import 'dart:async';

import 'package:flutter/material.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/observability/app_logger.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/permission_settings_sheet.dart';

/// A camera view that reads a (possibly animated) UR code off a Keystone's
/// screen and hands back the decoded [UR] once every part is in.
///
/// Owns its [MobileScannerController] rather than taking the package default:
/// the default 250 ms detection timeout throttles a device cycling a frame
/// every 200 ms. QR only, 100 ms timeout, normal detection with duplicates
/// allowed — the decoder ignores parts it already holds.
///
/// Everything the camera reads is untrusted. The decoder rejects a UR of a
/// type the caller did not ask for and anything over its size limits; a
/// rejection resets it and shows guidance, and the scan carries on.
class UrScannerView extends StatefulWidget {
  const UrScannerView({
    required this.expectedTypes,
    required this.onScanned,
    this.hint,
    this.error,
    this.unexpectedTypeError,
    this.describeRejection,
    this.generation = 0,
    this.captionAlign = TextAlign.center,
    super.key,
  });

  /// The UR types this scan accepts, e.g. `{'sol-signature'}`.
  final Set<String> expectedTypes;

  /// Called once with each complete UR. Returning a message rearms the
  /// scanner and shows the rejection; returning null keeps it idle until
  /// the caller changes [generation], so the same code is not handed back twice.
  final Future<String?> Function(UR ur) onScanned;

  /// Change to begin a fresh scan while keeping the same camera controller.
  final int generation;

  /// One line of guidance under the viewfinder.
  final String? hint;

  /// How the hint or error line under the viewfinder is aligned.
  final TextAlign captionAlign;

  /// An error to show from the start (e.g. the caller's last rejection).
  final String? error;

  /// Guidance for [UrDecodeErrorKind.unexpectedType]. Other decoding failures
  /// use [describeRejection] or the default retry copy.
  final String? unexpectedTypeError;

  /// Guidance for a decoder rejection. Null uses the default retry copy;
  /// protocol diagnostics belong in the debug log, not on screen.
  final String? Function(UrDecodeException error)? describeRejection;

  @override
  State<UrScannerView> createState() => _UrScannerViewState();
}

class _UrScannerViewState extends State<UrScannerView>
    with WidgetsBindingObserver {
  final _controller = _ScannerController();
  late UrDecoder _decoder;
  double _progress = 0;
  String? _error;

  /// True while [UrScannerView.onScanned] runs and after acceptance, so frames
  /// cannot decode into an overlapping or duplicate result.
  bool _handling = false;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _error = widget.error;
    _resetDecoder();
  }

  void _resetDecoder() {
    _decoder = UrDecoder(expectedTypes: widget.expectedTypes);
    _progress = 0;
  }

  @override
  void didUpdateWidget(covariant UrScannerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generation == widget.generation) return;
    // A new controller can start before the old widget is disposed, but the
    // camera platform only owns one texture. Reset the scan in place instead.
    _resetDecoder();
    _error = widget.error;
    _handling = false;
    _startCamera();
  }

  void _startCamera() {
    if (!mounted ||
        !_active ||
        _handling ||
        !_controller.value.hasCameraPermission ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        _controller.value.isStarting) {
      return;
    }
    unawaited(
      _controller.start().catchError((Object _) {
        AppLogger.debug('UrScannerView', 'Camera restart did not complete.');
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // mobile_scanner observes lifecycle only for its own default controller.
    // Permission also requires initialization, so don't interrupt its prompt.
    if (!_controller.value.hasCameraPermission) return;

    switch (state) {
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        return;
      case AppLifecycleState.resumed:
        // Validation and acceptance deliberately leave this scan idle.
        _startCamera();
      case AppLifecycleState.inactive:
        unawaited(_controller.stop());
    }
  }

  @override
  void deactivate() {
    _active = false;
    // Release a running camera before a replacement initializes in this
    // frame; disposal runs only after the new widget has already been built.
    // A starting camera is released once its texture is ready.
    unawaited(_controller.stopForDeactivation(isActive: () => _active));
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _startCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling || !_active || !mounted) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      try {
        // Not a UR at all — some other QR in view. Ignore it quietly.
        if (!_decoder.receivePart(raw)) continue;
      } on UrDecodeException catch (e) {
        AppLogger.debug('UrScannerView', e.message);
        setState(() {
          _error =
              (e.kind == UrDecodeErrorKind.unexpectedType
                  ? widget.unexpectedTypeError
                  : null) ??
              widget.describeRejection?.call(e) ??
              "That code couldn't be read. Hold the camera steady and try again.";
          _resetDecoder();
        });
        return;
      }
      if (_decoder.progress != _progress) {
        setState(() => _progress = _decoder.progress);
      }
      final result = _decoder.result;
      if (!_decoder.isComplete || result == null) continue;

      _handling = true;
      final decoder = _decoder;
      final rejection = await widget.onScanned(result);
      // A reset can rearm this view while an earlier validation is in flight.
      if (!mounted || decoder != _decoder || rejection == null) return;
      setState(() {
        _handling = false;
        _error = rejection;
        _resetDecoder();
      });
      // Validation may finish after a resume that kept this scan idle.
      _startCamera();
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
          child: AspectRatio(
            aspectRatio: 1,
            // Camera preview on a black ground regardless of theme, like the
            // send scanner — the literal is deliberate.
            child: ColoredBox(
              color: Colors.black,
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) => _CameraError(error: error),
              ),
            ),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        if (_progress > 0 && _progress < 1) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 4,
              backgroundColor: colors.surfaceMuted,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
        ],
        if (_error case final error?)
          SizedBox(
            width: double.infinity,
            child: Text(
              error,
              textAlign: widget.captionAlign,
              style: MallowTheme.uiCaption.copyWith(color: colors.error),
            ),
          )
        else if (widget.hint case final hint?)
          SizedBox(
            width: double.infinity,
            child: Text(
              hint,
              textAlign: widget.captionAlign,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}

/// Releases the camera during tree updates without rebuilding a preview whose
/// ancestors may already have been deactivated.
class _ScannerController extends MobileScannerController {
  _ScannerController()
    : super(formats: const [BarcodeFormat.qrCode], detectionTimeoutMs: 100);

  // All controllers share one platform camera, including startups whose
  // texture has not returned yet. Replacements must wait for its release.
  static Future<void>? _release;

  bool _deactivating = false;
  bool _disposed = false;
  Future<void>? _pendingStart;
  Future<void>? _pendingDispose;
  Future<void>? _cameraDisposal;

  static Future<void> _queueRelease(Future<void> Function() cleanup) {
    late final Future<void> releasing;
    releasing = (_release ?? Future<void>.value())
        .then((_) => cleanup())
        .catchError((Object _) {
          AppLogger.debug('UrScannerView', 'Camera cleanup did not complete.');
        })
        .whenComplete(() {
          if (identical(_release, releasing)) _release = null;
        });
    return _release = releasing;
  }

  @override
  Future<void> start({
    CameraFacing? cameraDirection,
    CameraLensType? cameraLensType,
  }) {
    if (_disposed) return Future<void>.value();
    if (_pendingStart != null) {
      return Future<void>.error(
        const MobileScannerException(
          errorCode: MobileScannerErrorCode.controllerInitializing,
        ),
      );
    }
    if (value.isRunning) return Future<void>.value();

    // Include the wait in startup bookkeeping so lifecycle restarts cannot
    // race it. Capture this chain before a deferred stop can queue behind us;
    // waiting on that later stop would make startup wait on itself.
    value = value.copyWith(isStarting: true);
    final starting = _startAfterRelease(
      _release,
      cameraDirection: cameraDirection,
      cameraLensType: cameraLensType,
    );
    _pendingStart = starting
        .catchError((Object _) {
          AppLogger.debug('UrScannerView', 'Camera startup did not complete.');
        })
        .whenComplete(() => _pendingStart = null);
    return starting;
  }

  Future<void> _startAfterRelease(
    Future<void>? release, {
    CameraFacing? cameraDirection,
    CameraLensType? cameraLensType,
  }) async {
    if (release != null) await release;
    // Disposal can happen while another controller is still releasing.
    if (_disposed) return;
    value = value.copyWith(isStarting: false);
    await super.start(
      cameraDirection: cameraDirection,
      cameraLensType: cameraLensType,
    );
  }

  Future<void> stopForDeactivation({required bool Function() isActive}) {
    if (_disposed) return Future<void>.value();
    final pending = _pendingStart;
    if (pending == null) {
      // A running camera releases its texture during this tree update. Keep
      // replacements waiting until the asynchronous native stop also settles.
      final stopping = _stopForTreeUpdate().catchError((Object _) {
        AppLogger.debug('UrScannerView', 'Camera stop did not complete.');
      });
      return _queueRelease(() async {
        await stopping;
        if (_disposed) await _disposeCamera(() => super.dispose());
      });
    }
    return _queueRelease(() async {
      // stop() does nothing until startup has produced a camera texture.
      await pending;
      if (_disposed) {
        // A replacement can await this stop before disposal is queued later
        // in the frame. Finish disposal here so it cannot stop that camera.
        await _disposeCamera(() => super.dispose());
      } else if (!isActive()) {
        await _stopForTreeUpdate();
      }
    });
  }

  Future<void> _stopForTreeUpdate() {
    _deactivating = true;
    try {
      return stop();
    } finally {
      _deactivating = false;
    }
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    if (_deactivating) {
      // stop() must release the platform texture now, but its preview listener
      // can only rebuild after this tree update. Disposal makes it unnecessary.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) super.notifyListeners();
      });
      return;
    }
    super.notifyListeners();
  }

  @override
  Future<void> dispose() {
    if (_disposed) return _pendingDispose ?? Future<void>.value();
    _disposed = true;
    final pending = _pendingStart;
    return _pendingDispose = _queueRelease(() async {
      // Platform disposal cannot release a texture that startup has not yet
      // returned. Wait so it cannot appear after the final stop and leak.
      if (pending != null) await pending;
      await _disposeCamera(() => super.dispose());
    });
  }

  Future<void> _disposeCamera(Future<void> Function() disposeController) =>
      _cameraDisposal ??= _stopAndDispose(disposeController);

  Future<void> _stopAndDispose(
    Future<void> Function() disposeController,
  ) async {
    try {
      // Platform disposal alone does not cancel the controller's listeners.
      await stop();
    } finally {
      await disposeController();
    }
  }
}

/// The camera could not start: a denied permission gets a way to the OS
/// setting, anything else an explanation.
class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
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
              denied
                  ? "mallow can't use the camera, so it can't read your "
                        "Keystone's codes."
                  : "The camera couldn't be started. Close this and try again.",
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
