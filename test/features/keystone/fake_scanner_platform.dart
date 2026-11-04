import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Models the platform's single camera without the MethodChannel implementation
/// type, so MobileScanner's debug-only pre-stop cannot hide release overlaps.
class FakeScannerPlatform extends MobileScannerPlatform {
  int starts = 0;
  int stops = 0;
  int overlappingStarts = 0;
  bool isLive = false;
  bool _isStarting = false;
  Completer<void>? startBarrier;
  Object? startError;
  Object? disposeError;
  final _barcodes = StreamController<BarcodeCapture?>.broadcast();
  final _torchStates = StreamController<TorchState>.broadcast();
  final _zoomScales = StreamController<double>.broadcast();

  bool get hasPlatformListeners =>
      _barcodes.hasListener ||
      _torchStates.hasListener ||
      _zoomScales.hasListener;

  Future<void> closeStreams() async {
    await Future.wait([
      _barcodes.close(),
      _torchStates.close(),
      _zoomScales.close(),
    ]);
  }

  /// Delivers [capture] as if the camera had read it.
  void emit(BarcodeCapture capture) => _barcodes.add(capture);

  @override
  Stream<BarcodeCapture?> get barcodesStream => _barcodes.stream;

  @override
  Stream<TorchState> get torchStateStream => _torchStates.stream;

  @override
  Stream<double> get zoomScaleStateStream => _zoomScales.stream;

  @override
  Widget buildCameraView() => const SizedBox();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    starts++;
    // Native startup reserves the single camera before returning a texture.
    if (isLive || _isStarting) {
      overlappingStarts++;
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.controllerAlreadyInitialized,
      );
    }
    _isStarting = true;
    try {
      if (startBarrier case final barrier?) await barrier.future;
      if (startError case final error?) throw error;
      await Future<void>.value();
      isLive = true;
      return const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        size: Size(640, 480),
      );
    } finally {
      _isStarting = false;
    }
  }

  @override
  Future<void> updateScanWindow(Rect? window) async {}

  @override
  Future<void> stop() async {
    // The platform releases its texture before awaiting the native stop.
    isLive = false;
    stops++;
  }

  @override
  Future<void> dispose() async {
    isLive = false;
    if (disposeError case final error?) throw error;
  }
}
