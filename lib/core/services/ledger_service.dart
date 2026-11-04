import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:ledger_ethereum/ledger_ethereum.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:ledger_tezos/ledger_tezos.dart';

import 'ledger_open_app.dart';

/// Thrown when a Ledger operation is attempted but no device is connected.
///
/// Callers should catch this to show a reconnection prompt.
class LedgerNotConnectedException implements Exception {
  const LedgerNotConnectedException();

  @override
  String toString() => 'Ledger device not connected. Please reconnect.';
}

/// Thrown when BLE connection fails because the device has stale pairing info.
///
/// On iOS the user must manually forget the device in Settings → Bluetooth.
class LedgerStalePairingException implements Exception {
  const LedgerStalePairingException();

  @override
  String toString() =>
      'Stale Bluetooth pairing. Please forget the device in '
      'Settings → Bluetooth and try again.';
}

/// Whether an Ethereum app reporting [version] hashes EIP-712 typed data on
/// the device (1.9.19 and later), so it can show the fields when its Raw
/// messages setting is on. An unparseable
/// version is treated as new: the first typed-data command then tells us.
@visibleForTesting
bool ledgerEthereumHashesTypedData(String version) {
  final parts = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version.trim());
  if (parts == null) return true;
  final numbers = [for (var i = 1; i <= 3; i++) int.parse(parts.group(i)!)];
  const minimum = [1, 9, 19];
  for (var i = 0; i < 3; i++) {
    if (numbers[i] != minimum[i]) return numbers[i] > minimum[i];
  }
  return true;
}

/// Signs typed data by streaming it to the device when [streamFirst], and
/// by host-computed hashes otherwise or when the app answers the stream with
/// 0x6D00 (instruction not supported). Any other failure, a rejection or a
/// refusal for settings included, is final: the hashes path would show the
/// user less, not more.
@visibleForTesting
Future<Uint8List> signLedgerTypedData({
  required bool streamFirst,
  required Future<Uint8List> Function() stream,
  required Future<Uint8List> Function() hashes,
}) async {
  if (streamFirst) {
    try {
      return await stream();
    } on LedgerDeviceException catch (e) {
      if (e.errorCode != 0x6D00) rethrow;
    }
  }
  return hashes();
}

class LedgerSigningCancelledException implements Exception {
  const LedgerSigningCancelledException();
}

@visibleForTesting
Future<T> raceLedgerOperationWithCancellation<T>({
  required Future<T> operation,
  required Future<void> cancelled,
  required Future<void> Function() cancelOperation,
}) {
  final result = Completer<T>();
  var cancellationStarted = false;
  operation.then(
    (value) {
      if (!cancellationStarted && !result.isCompleted) result.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!cancellationStarted && !result.isCompleted) {
        result.completeError(error, stackTrace);
      }
    },
  );
  cancelled.then((_) async {
    if (result.isCompleted) return;
    cancellationStarted = true;
    try {
      await cancelOperation();
    } catch (_) {
      // Cancellation still wins. The service keeps Ledger reconnect blocked
      // when physical teardown cannot be confirmed.
    } finally {
      if (!result.isCompleted) {
        result.completeError(const LedgerSigningCancelledException());
      }
    }
  });
  return result.future;
}

/// Connection state for the Ledger device.
enum LedgerConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  error,
}

/// Signing state emitted during Ledger transaction signing.
enum LedgerSigningState {
  idle,
  waitingForConfirmation,
  confirmed,
  rejected,
  timeout,
}

/// Manages BLE scanning, connection lifecycle, and Ledger operations.
///
/// Wraps [LedgerInterface] and [SolanaLedgerApp] into a single service.
@lazySingleton
class LedgerService {
  LedgerService();

  @visibleForTesting
  LedgerService.forConnection(LedgerConnection connection)
    : _connection = connection;

  LedgerInterface? _ledger;
  LedgerConnection? _connection;
  LedgerDevice? _connectedDevice;
  Timer? _inactivityTimer;
  StreamSubscription<LedgerDevice>? _bleScanSub;
  StreamSubscription<BleConnectionState>? _bleStateSub;
  LedgerSigningState _currentSigningState = LedgerSigningState.idle;
  Object? _activeCancellableSigning;
  Future<void>? _connectionReset;
  bool _reconnectBlocked = false;
  bool _isConnecting = false;

  final _solanaApp = const SolanaLedgerApp();
  final _ethereumApp = const EthereumLedgerApp();
  final _tezosApp = const TezosLedgerApp();

  static const _inactivityTimeout = Duration(minutes: 5);
  static const _signingCancellationCleanupTimeout = Duration(seconds: 10);

  // ---------------------------------------------------------------------------
  // Streams
  // ---------------------------------------------------------------------------

  final _connectionStateController =
      StreamController<LedgerConnectionState>.broadcast();
  final _signingStateController =
      StreamController<LedgerSigningState>.broadcast();
  final _scannedDevicesController = StreamController<LedgerDevice>.broadcast();
  final _scanFinishedController = StreamController<void>.broadcast();

  /// Emits connection state changes.
  Stream<LedgerConnectionState> get connectionState =>
      _connectionStateController.stream;

  /// Emits signing state for UI overlay (confirm on device, etc.).
  Stream<LedgerSigningState> get signingState => _signingStateController.stream;

  /// Emits discovered Ledger devices during scanning.
  Stream<LedgerDevice> get scannedDevices => _scannedDevicesController.stream;

  /// Emits when the scan window expires (or fails). Listeners should surface
  /// a "Scan again" affordance — the scan does not auto-restart.
  Stream<void> get scanFinished => _scanFinishedController.stream;

  /// Whether a device is currently connected.
  bool get isConnected =>
      !_isConnecting && _connection != null && !_connection!.isDisconnected;

  /// The current signing state (for synchronous checks).
  LedgerSigningState get currentSigningState => _currentSigningState;

  /// The currently connected device, if any.
  LedgerDevice? get connectedDevice => _connectedDevice;

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Start BLE scanning for Ledger devices.
  ///
  /// Runs a single 60-second scan window. When it expires, [scanFinished]
  /// fires and listeners should surface a "Scan again" affordance — the
  /// scan does NOT auto-restart. Auto-restarting in a tight loop cancels
  /// the platform scanner before it can register devices.
  ///
  /// Each call disposes any cached [LedgerInterface] first. The underlying
  /// lib's scan stream sometimes ends instantly when the interface is reused
  /// across scan attempts; a fresh instance avoids that stale-state path.
  Future<void> startScan() async {
    debugPrint('[Ledger] startScan()');
    _connectionStateController.add(LedgerConnectionState.scanning);

    await _bleScanSub?.cancel();
    _bleScanSub = null;
    await _ledger?.stopScanning();
    await _ledger?.dispose();
    _ledger = null;

    await _beginScan();
  }

  Future<void> _beginScan() async {
    _ledger ??= LedgerInterface.ble(
      onPermissionRequest: _handlePermissionRequest,
      bleOptions: BluetoothOptions(
        maxScanDuration: const Duration(seconds: 60),
        connectionTimeout: const Duration(seconds: 10),
      ),
    );

    _bleScanSub = _ledger!.scan().listen(
      (device) {
        debugPrint('[Ledger] scan found device: ${device.name} (${device.id})');
        _scannedDevicesController.add(device);
      },
      onError: (Object error) {
        debugPrint('[Ledger] scan error: $error');
        _scanFinishedController.add(null);
      },
      onDone: () {
        debugPrint('[Ledger] scan window ended');
        _scanFinishedController.add(null);
      },
    );
  }

  /// Stop BLE scanning.
  Future<void> stopScan() async {
    debugPrint('[Ledger] stopScan()');
    await _bleScanSub?.cancel();
    _bleScanSub = null;
    await _ledger?.stopScanning();
    if (!isConnected) {
      _connectionStateController.add(LedgerConnectionState.disconnected);
    }
  }

  /// Return Ledger devices the OS already has bonded/known for our app's BLE
  /// services. Bonded peripherals frequently stop emitting fresh advertisements
  /// (so [scan] sees nothing), but they remain in the system list and can be
  /// connected to directly.
  Future<List<LedgerDevice>> getKnownDevices() async {
    final services = LedgerDeviceType.ble.map((e) => e.serviceId).toList();
    try {
      final systemDevices = await UniversalBle.getSystemDevices(
        withServices: services,
      );
      debugPrint(
        '[Ledger] getKnownDevices() returned ${systemDevices.length} bonded device(s)',
      );
      return systemDevices.map((d) {
        final advertisedServices = d.services
            .map((s) => s.toLowerCase())
            .toSet();
        final deviceInfo = LedgerDeviceType.ble.firstWhere(
          (t) => advertisedServices.contains(t.serviceId.toLowerCase()),
          orElse: () => LedgerDeviceType.nanoX,
        );
        return LedgerDevice.ble(
          id: d.deviceId,
          name: d.name ?? 'Ledger',
          deviceInfo: deviceInfo,
        );
      }).toList();
    } catch (e) {
      debugPrint('[Ledger] getKnownDevices() failed: $e');
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  /// Connect to a discovered Ledger device.
  ///
  /// If the connection fails due to stale pairing info ("Peer removed pairing
  /// information"), the device is unpaired and the connection is retried once.
  Future<void> connect(LedgerDevice device) async {
    if (_activeCancellableSigning != null || _isConnecting) {
      throw StateError(
        'Cannot start a Ledger connection while another operation is in progress',
      );
    }
    _isConnecting = true;
    try {
      await _waitForConnectionReset();
      debugPrint(
        '[Ledger] connect() start — device=${device.name} id=${device.id}',
      );
      _connectionStateController.add(LedgerConnectionState.connecting);

      _ledger ??= LedgerInterface.ble(
        onPermissionRequest: _handlePermissionRequest,
        bleOptions: BluetoothOptions(
          connectionTimeout: const Duration(seconds: 10),
        ),
      );

      debugPrint('[Ledger] BLE interface ready, calling _ledger.connect()...');
      try {
        _connection = await _ledger!.connect(device);
        debugPrint('[Ledger] BLE connect succeeded');
      } on EstablishConnectionException catch (e) {
        debugPrint('[Ledger] EstablishConnectionException: $e');
        if (_isStalePairingError(e)) {
          if (defaultTargetPlatform == TargetPlatform.android) {
            debugPrint('[Ledger] Stale pairing — unpairing and retrying...');
            await UniversalBle.unpair(device.id);
            _connection = await _ledger!.connect(device);
            debugPrint('[Ledger] Retry connect succeeded');
          } else {
            // iOS can't unpair programmatically — user must do it in Settings.
            debugPrint(
              '[Ledger] Stale pairing on iOS — user must forget device',
            );
            throw const LedgerStalePairingException();
          }
        } else {
          rethrow;
        }
      }

      debugPrint(
        '[Ledger] Connection established, isDisconnected=${_connection!.isDisconnected}',
      );
      _connectedDevice = device;

      // Listen for unexpected BLE disconnections (device powered off, out of range).
      await _bleStateSub?.cancel();
      _bleStateSub = _ledger!.deviceStateChanges(device.id).listen((state) {
        debugPrint('[Ledger] BLE state change: $state');
        if (state == BleConnectionState.disconnected) {
          disconnect();
        }
      });
      _isConnecting = false;
      _connectionStateController.add(LedgerConnectionState.connected);
      _resetInactivityTimer();
      debugPrint('[Ledger] connect() complete');
    } catch (e, st) {
      debugPrint('[Ledger] connect() FAILED: $e');
      debugPrint('[Ledger] stackTrace: $st');
      // Dispose the BLE interface so the next attempt gets a fresh instance.
      // LedgerInterface.ble() caches a singleton internally; dispose() clears
      // that cache along with any stale connection-manager state.
      await _ledger?.dispose();
      _ledger = null;
      _connection = null;
      _connectedDevice = null;

      // "Stream has already been listened to" means the BLE interface has
      // stale internal state. Retry once with a fresh interface.
      if (e is StateError && e.message.contains('already been listened')) {
        debugPrint(
          '[Ledger] Stale stream — retrying connect with fresh BLE interface...',
        );
        _connectionStateController.add(LedgerConnectionState.connecting);
        try {
          _isConnecting = false;
          return await connect(device);
        } catch (_) {
          // Fall through to error state if retry also fails.
        }
      }

      _connectionStateController.add(LedgerConnectionState.error);
      rethrow;
    } finally {
      _isConnecting = false;
    }
  }

  /// Disconnect from the current device.
  Future<void> disconnect() async {
    _inactivityTimer?.cancel();
    final connection = _connection;
    final stateSubscription = _bleStateSub;
    _bleStateSub = null;
    _connection = null;
    _connectedDevice = null;
    _connectionStateController.add(LedgerConnectionState.disconnected);
    if (connection == null) {
      final reset = _connectionReset;
      if (reset != null) await reset;
      return;
    }
    await _startConnectionReset(connection, stateSubscription);
  }

  // ---------------------------------------------------------------------------
  // App detection
  // ---------------------------------------------------------------------------

  /// Read which app the user currently has open on the device, so the import
  /// flow can route to the matching chain instead of asking the user to pick.
  ///
  /// Uses the BOLOS dashboard "Get App and Version" command, which every Ledger
  /// app proxies to the OS — so it works from inside the Solana or Ethereum app.
  Future<LedgerAppInfo> getOpenApp() async {
    _ensureConnected();
    _resetInactivityTimer();
    final info = await _connection!.sendOperation(
      LedgerGetAppAndVersionOperation(),
    );
    debugPrint('[Ledger] getOpenApp() — ${info.name} v${info.version}');
    return info;
  }

  // ---------------------------------------------------------------------------
  // Solana Operations
  // ---------------------------------------------------------------------------

  /// Get the Solana app configuration from the connected device.
  Future<SolanaAppConfig> getAppConfig() async {
    debugPrint('[Ledger] getAppConfig() — isConnected=$isConnected');
    _ensureConnected();
    _resetInactivityTimer();
    final config = await _solanaApp.getAppConfig(_connection!);
    debugPrint('[Ledger] getAppConfig() OK — Solana app v${config.version}');
    return config;
  }

  /// Get the Ed25519 public key at the given derivation index.
  ///
  /// Returns raw 32-byte public key.
  Future<Uint8List> getPublicKey({
    int account = 0,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
  }) async {
    _ensureConnected();
    _resetInactivityTimer();
    return _solanaApp.getPublicKey(
      _connection!,
      account: account,
      scheme: scheme,
    );
  }

  /// Discover multiple accounts by deriving public keys.
  ///
  /// Returns a list of 32-byte public keys.
  Future<List<Uint8List>> discoverAccounts({
    int count = 5,
    int startIndex = 0,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
  }) async {
    _ensureConnected();
    _resetInactivityTimer();
    return _solanaApp.getAccounts(
      _connection!,
      count: count,
      startIndex: startIndex,
      scheme: scheme,
    );
  }

  // ---------------------------------------------------------------------------
  // Ethereum Operations
  // ---------------------------------------------------------------------------

  /// Discover multiple Ethereum accounts by deriving addresses at sequential
  /// indices (`m/44'/60'/0'/0/{index}`).
  ///
  /// Requires the Ethereum app to be open on the device. Addresses come back
  /// `0x`-prefixed and lowercase; the caller checksums them for display.
  Future<List<EthereumLedgerAddress>> discoverEthereumAccounts({
    int count = 5,
    int startIndex = 0,
  }) async {
    _ensureConnected();
    _resetInactivityTimer();
    return _ethereumApp.getAccounts(
      _connection!,
      count: count,
      startIndex: startIndex,
    );
  }

  /// EIP-191 `personal_sign` of [message] with the Ethereum app at the given
  /// derivation [account]. The device applies the EIP-191 prefix, keccak256
  /// hashes, and secp256k1-signs after on-screen confirmation.
  ///
  /// Emits [LedgerSigningState.waitingForConfirmation] while the user confirms,
  /// then [confirmed] or [rejected]. Returns the 65-byte `r‖s‖v` signature.
  Future<Uint8List> signEthereumPersonalMessage(
    Uint8List message, {
    int account = 0,
  }) async {
    _ensureConnected();
    _cancelInactivityTimer();
    _emitSigningState(LedgerSigningState.waitingForConfirmation);

    try {
      final sig = await _ethereumApp.signPersonalMessage(
        _connection!,
        message: message,
        account: account,
      );
      _emitSigningState(LedgerSigningState.confirmed);
      return sig;
    } on LedgerException catch (e) {
      if (e is LedgerDeviceException &&
          (e.errorCode == 0x6985 || e.errorCode == 0x6982)) {
        _emitSigningState(LedgerSigningState.rejected);
      } else {
        _emitSigningState(LedgerSigningState.timeout);
      }
      rethrow;
    } catch (_) {
      _emitSigningState(LedgerSigningState.timeout);
      rethrow;
    } finally {
      _resetInactivityTimer();
    }
  }

  /// EIP-712 typed-data signature with the Ethereum app at the given
  /// derivation [account]. Returns the 65-byte `r‖s‖v`.
  ///
  /// On Ethereum app 1.9.19 or later the device is sent [message] and hashes
  /// it itself. With the app's Raw messages setting on, it shows each domain
  /// and message field for the user to step through; with only Blind signing
  /// on, it shows the domain and the message hash. With neither, it refuses
  /// with 0x6A80 before showing anything. An older app (or one that answers
  /// the first typed-data command with "instruction not supported") signs
  /// [domainSeparator] and [messageHash] instead, shows those two hashes, and
  /// needs Blind signing on. The caller recovers the signer either way, so a
  /// device that hashed something else cannot pass.
  ///
  /// Fails loud if the Ethereum app isn't open. [cancelled] tears the
  /// connection down mid-review, as for Solana signing.
  Future<Uint8List> signEthereumTypedData({
    required Eip712LedgerMessage message,
    required Uint8List domainSeparator,
    required Uint8List messageHash,
    int account = 0,
    Future<void>? cancelled,
  }) async {
    _ensureConnected();
    _cancelInactivityTimer();

    final app = await getOpenApp();
    if (app.openApp != LedgerOpenApp.ethereum) {
      _resetInactivityTimer();
      throw Exception('Open the Ethereum app on your Ledger, then try again.');
    }
    final onDevice = ledgerEthereumHashesTypedData(app.version);

    _emitSigningState(LedgerSigningState.waitingForConfirmation);
    try {
      final connection = _connection!;
      final sig = await _runCancellableSigning(
        connection: connection,
        cancelled: cancelled,
        operation: () => signLedgerTypedData(
          streamFirst: onDevice,
          stream: () => _ethereumApp.signTypedData(
            connection,
            message: message,
            account: account,
          ),
          hashes: () => _ethereumApp.signTypedDataHashes(
            connection,
            domainSeparator: domainSeparator,
            messageHash: messageHash,
            account: account,
          ),
        ),
      );
      _emitSigningState(LedgerSigningState.confirmed);
      return sig;
    } on LedgerException catch (e) {
      if (e is LedgerDeviceException &&
          (e.errorCode == 0x6985 || e.errorCode == 0x6982)) {
        _emitSigningState(LedgerSigningState.rejected);
      } else {
        _emitSigningState(LedgerSigningState.timeout);
      }
      rethrow;
    } catch (_) {
      _emitSigningState(LedgerSigningState.timeout);
      rethrow;
    } finally {
      _resetInactivityTimer();
    }
  }

  /// Sign the RLP-serialized unsigned [rawTx] with the Ethereum app at the given
  /// derivation [account]. [rawTx] is the exact payload the device hashes and
  /// signs — the `0x02`-prefixed unsigned EIP-1559 serialization
  /// (`Transaction.getUnsignedSerialized`). The device keccak256-hashes and
  /// secp256k1-signs after the user confirms the transaction on-device.
  ///
  /// Fails loud if the Ethereum app isn't open — the ETH APDUs (CLA=0xE0) return
  /// "class not supported" against the Solana/Tezos app.
  ///
  /// Emits [LedgerSigningState.waitingForConfirmation] while the user confirms,
  /// then [confirmed] or [rejected]. Returns the raw `(v, r, s)`.
  Future<EthereumLedgerSignature> signEthereumTransaction(
    Uint8List rawTx, {
    int account = 0,
  }) async {
    _ensureConnected();
    _cancelInactivityTimer();

    final openApp = (await getOpenApp()).openApp;
    if (openApp != LedgerOpenApp.ethereum) {
      _resetInactivityTimer();
      throw Exception('Open the Ethereum app on your Ledger, then try again.');
    }

    _emitSigningState(LedgerSigningState.waitingForConfirmation);
    try {
      final sig = await _ethereumApp.signTransaction(
        _connection!,
        rawTx: rawTx,
        account: account,
      );
      _emitSigningState(LedgerSigningState.confirmed);
      return sig;
    } on LedgerException catch (e) {
      if (e is LedgerDeviceException &&
          (e.errorCode == 0x6985 || e.errorCode == 0x6982)) {
        _emitSigningState(LedgerSigningState.rejected);
      } else {
        _emitSigningState(LedgerSigningState.timeout);
      }
      rethrow;
    } catch (_) {
      _emitSigningState(LedgerSigningState.timeout);
      rethrow;
    } finally {
      _resetInactivityTimer();
    }
  }

  // ---------------------------------------------------------------------------
  // Tezos Operations
  // ---------------------------------------------------------------------------

  /// Discover multiple Tezos accounts by deriving Ed25519 public keys at
  /// sequential indices (`m/44'/1729'/{index}'/0'`).
  ///
  /// Requires the Tezos app to be open on the device. Returns raw 32-byte
  /// public keys; the caller encodes them to `tz1` addresses.
  Future<List<Uint8List>> discoverTezosAccounts({
    int count = 5,
    int startIndex = 0,
  }) async {
    _ensureConnected();
    _resetInactivityTimer();
    return _tezosApp.getAccounts(
      _connection!,
      count: count,
      startIndex: startIndex,
    );
  }

  /// Get the raw 32-byte Ed25519 public key at `m/44'/1729'/{account}'/0'`.
  ///
  /// Requires the Tezos app to be open. Used to build the `edpk…` the backend
  /// needs to verify a Tezos ownership signature and re-derive the `tz1`.
  Future<Uint8List> getTezosPublicKey({
    int account = 0,
    Future<void>? cancelled,
    void Function()? ensureActive,
  }) async {
    _ensureConnected();
    final connection = _connection!;
    _cancelInactivityTimer();
    try {
      return await _runCancellableSigning(
        connection: connection,
        cancelled: cancelled,
        operation: () async {
          ensureActive?.call();
          await _requireTezosWalletApp();
          _cancelInactivityTimer();
          ensureActive?.call();
          final key = await _tezosApp.getPublicKey(
            connection,
            account: account,
          );
          ensureActive?.call();
          return key;
        },
      );
    } finally {
      _resetInactivityTimer();
    }
  }

  Future<void> _requireTezosWalletApp() async {
    final name = (await getOpenApp()).name.trim().toLowerCase();
    // The Baking app can sign some operations without an on-device prompt.
    // Browser requests must use the Wallet app and its user confirmation.
    if (name != 'tezos' && !name.startsWith('tezos wallet')) {
      throw LedgerDeviceException(
        message: 'Open the Tezos Wallet app on your Ledger.',
        errorCode: 0x6e00,
        connectionType: ConnectionType.ble,
      );
    }
  }

  /// Signs the packed message bytes on-device, without repacking or hashing.
  Future<Uint8List> signTezosMessage(
    Uint8List message, {
    int account = 0,
    Future<void>? cancelled,
    void Function()? ensureActive,
  }) => _signTezos(
    message,
    account: account,
    cancelled: cancelled,
    ensureActive: ensureActive,
    operation: false,
  );

  /// Adds the operation watermark on-device transport, then signs the forged
  /// group after the device's review. Returned signatures are raw Ed25519.
  Future<Uint8List> signTezosOperation(
    Uint8List operation, {
    int account = 0,
    Future<void>? cancelled,
    void Function()? ensureActive,
  }) => _signTezos(
    operation,
    account: account,
    cancelled: cancelled,
    ensureActive: ensureActive,
    operation: true,
  );

  Future<Uint8List> _signTezos(
    Uint8List payload, {
    required int account,
    required bool operation,
    Future<void>? cancelled,
    void Function()? ensureActive,
  }) async {
    _ensureConnected();
    _cancelInactivityTimer();
    _emitSigningState(LedgerSigningState.waitingForConfirmation);
    final bytes = Uint8List.fromList(payload).asUnmodifiableView();
    try {
      final connection = _connection!;
      final signature = await _runCancellableSigning(
        connection: connection,
        cancelled: cancelled,
        operation: () async {
          ensureActive?.call();
          await _requireTezosWalletApp();
          _cancelInactivityTimer();
          ensureActive?.call();
          return operation
              ? _tezosApp.signOperation(
                  connection,
                  operation: bytes,
                  account: account,
                  ensureActive: ensureActive,
                )
              : _tezosApp.signMessage(
                  connection,
                  message: bytes,
                  account: account,
                  ensureActive: ensureActive,
                );
        },
      );
      ensureActive?.call();
      _emitSigningState(LedgerSigningState.confirmed);
      return signature;
    } on LedgerException catch (error) {
      _emitSigningState(
        error is LedgerDeviceException &&
                (error.errorCode == 0x6985 || error.errorCode == 0x6982)
            ? LedgerSigningState.rejected
            : LedgerSigningState.timeout,
      );
      rethrow;
    } catch (_) {
      _emitSigningState(LedgerSigningState.timeout);
      rethrow;
    } finally {
      _resetInactivityTimer();
    }
  }

  /// Sign a compiled Solana transaction.
  ///
  /// Emits [LedgerSigningState.waitingForConfirmation] while the user
  /// confirms on device, then [confirmed] or [rejected].
  ///
  /// Returns a 64-byte Ed25519 signature.
  Future<Uint8List> signTransaction(
    Uint8List transaction, {
    int account = 0,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
    Future<void>? cancelled,
  }) async {
    _ensureConnected();
    _cancelInactivityTimer();
    _emitSigningState(LedgerSigningState.waitingForConfirmation);

    try {
      final connection = _connection!;
      final sig = await _runCancellableSigning(
        connection: connection,
        cancelled: cancelled,
        operation: () => _solanaApp.signTransaction(
          connection,
          transaction: transaction,
          account: account,
          scheme: scheme,
        ),
      );
      _emitSigningState(LedgerSigningState.confirmed);
      return sig;
    } on LedgerException catch (e) {
      if (e is LedgerDeviceException &&
          (e.errorCode == 0x6985 || e.errorCode == 0x6982)) {
        _emitSigningState(LedgerSigningState.rejected);
      } else {
        _emitSigningState(LedgerSigningState.timeout);
      }
      rethrow;
    } catch (_) {
      _emitSigningState(LedgerSigningState.timeout);
      rethrow;
    } finally {
      _resetInactivityTimer();
    }
  }

  /// Sign an off-chain message (Anza spec).
  ///
  /// Returns a 64-byte Ed25519 signature.
  Future<Uint8List> signMessage(
    Uint8List message, {
    int account = 0,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
  }) async {
    _ensureConnected();
    _cancelInactivityTimer();
    _emitSigningState(LedgerSigningState.waitingForConfirmation);

    try {
      final sig = await _solanaApp.signOffChainMessage(
        _connection!,
        message: message,
        account: account,
        scheme: scheme,
      );
      _emitSigningState(LedgerSigningState.confirmed);
      return sig;
    } on LedgerException catch (e) {
      if (e is LedgerDeviceException &&
          (e.errorCode == 0x6985 || e.errorCode == 0x6982)) {
        _emitSigningState(LedgerSigningState.rejected);
      } else {
        _emitSigningState(LedgerSigningState.timeout);
      }
      rethrow;
    } catch (_) {
      _emitSigningState(LedgerSigningState.timeout);
      rethrow;
    } finally {
      _resetInactivityTimer();
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Dispose all resources.
  Future<void> dispose() async {
    _inactivityTimer?.cancel();
    await _bleScanSub?.cancel();
    await _bleStateSub?.cancel();
    await _connection?.disconnect();
    await _ledger?.dispose();
    await _connectionStateController.close();
    await _signingStateController.close();
    await _scannedDevicesController.close();
    await _scanFinishedController.close();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  Future<T> _runCancellableSigning<T>({
    required LedgerConnection connection,
    required Future<T> Function() operation,
    Future<void>? cancelled,
  }) async {
    if (_activeCancellableSigning != null) {
      throw StateError('A Ledger signing operation is already in progress');
    }
    final token = Object();
    _activeCancellableSigning = token;
    try {
      final pending = operation();
      if (cancelled == null) return await pending;
      return await raceLedgerOperationWithCancellation(
        operation: pending,
        cancelled: cancelled,
        cancelOperation: () => _cancelSigningConnection(token, connection),
      );
    } finally {
      if (identical(_activeCancellableSigning, token)) {
        _activeCancellableSigning = null;
      }
    }
  }

  Future<void> _cancelSigningConnection(
    Object token,
    LedgerConnection connection,
  ) async {
    if (!identical(_activeCancellableSigning, token)) {
      return;
    }
    _inactivityTimer?.cancel();
    Future<void> reset;
    if (identical(_connection, connection)) {
      final stateSubscription = _bleStateSub;
      _bleStateSub = null;
      _connection = null;
      _connectedDevice = null;
      _connectionStateController.add(LedgerConnectionState.disconnected);
      reset = _startConnectionReset(connection, stateSubscription);
    } else {
      reset = _connectionReset ?? _startConnectionReset(connection, null);
    }
    await _awaitConnectionResetBounded(reset);
  }

  Future<void> _startConnectionReset(
    LedgerConnection connection,
    StreamSubscription<BleConnectionState>? stateSubscription,
  ) {
    _reconnectBlocked = true;
    final reset = Future.wait<void>([
      if (stateSubscription != null) Future.sync(stateSubscription.cancel),
      Future.sync(connection.disconnect),
    ]);
    late final Future<void> trackedReset;
    trackedReset = reset.then(
      (_) {
        _reconnectBlocked = false;
        if (identical(_connectionReset, trackedReset)) {
          _connectionReset = null;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _reconnectBlocked = true;
        if (identical(_connectionReset, trackedReset)) {
          _connectionReset = null;
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _connectionReset = trackedReset;
    return trackedReset;
  }

  Future<void> _awaitConnectionResetBounded(Future<void> reset) async {
    try {
      await reset.timeout(_signingCancellationCleanupTimeout);
    } on TimeoutException {
      // The browser request can finish, but reconnect stays fail-closed until
      // the native disconnect settles. This prevents two physical APDUs from
      // running concurrently on a connection whose response was abandoned.
    }
  }

  Future<void> _waitForConnectionReset() async {
    final reset = _connectionReset;
    if (reset != null) {
      try {
        await _awaitConnectionResetBounded(reset);
      } on TimeoutException {
        throw const LedgerNotConnectedException();
      }
    }
    if (_reconnectBlocked) throw const LedgerNotConnectedException();
  }

  /// Requests Bluetooth permissions when the OS state requires it.
  ///
  /// Called by [LedgerInterface] before scanning or connecting.
  /// On Android this triggers the "Nearby Devices" runtime permission dialog;
  /// on iOS the system Bluetooth permission dialog.
  Future<bool> _handlePermissionRequest(AvailabilityState state) async {
    debugPrint('[Ledger] permission request — BLE state: $state');
    if (state == AvailabilityState.poweredOn) return true;

    if (state == AvailabilityState.unauthorized) {
      await UniversalBle.requestPermissions();
      final updated = await UniversalBle.getBluetoothAvailabilityState();
      return updated == AvailabilityState.poweredOn;
    }

    if (state == AvailabilityState.poweredOff &&
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        return await UniversalBle.enableBluetooth();
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  /// Whether the error is a stale BLE pairing ("Peer removed pairing
  /// information"). This happens when the Ledger forgets the phone but the
  /// phone still has the old bond cached.
  bool _isStalePairingError(EstablishConnectionException e) {
    final nested = e.nestedError;
    if (nested is UniversalBleException) {
      final msg = nested.message.toLowerCase();
      return msg.contains('pairing') || msg.contains('bond');
    }
    return false;
  }

  void _ensureConnected() {
    if (!isConnected) {
      throw const LedgerNotConnectedException();
    }
  }

  void _cancelInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (!isConnected) {
      _inactivityTimer = null;
      return;
    }
    _inactivityTimer = Timer(_inactivityTimeout, () {
      disconnect();
    });
  }

  void _emitSigningState(LedgerSigningState state) {
    _currentSigningState = state;
    _signingStateController.add(state);
  }
}
