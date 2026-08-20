import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../../../core/config/environment.dart';
import '../../../core/crypto/derivation.dart';
import '../../../core/database/database.dart' hide Wallet;
import '../../../core/database/database.dart' as db show Wallet;
import '../../../core/network/auth_service.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/services/ledger_open_app.dart';
import '../../../core/services/ledger_service.dart';

import '../../../shared/utils/chain.dart';
part 'ledger_auth_service.freezed.dart';

/// Unified state of the Ledger BLE session. Replaces the three private state
/// enums that `LedgerConnectSheet`, `LedgerVerifySheet`, and parts of
/// `LedgerConnectBloc` each maintained independently.
@freezed
sealed class LedgerSessionState with _$LedgerSessionState {
  const factory LedgerSessionState.disconnected() = LedgerSessionDisconnected;
  const factory LedgerSessionState.scanning({
    required List<LedgerDevice> devices,
    @Default(true) bool active,
  }) = LedgerSessionScanning;
  const factory LedgerSessionState.connecting(LedgerDevice device) =
      LedgerSessionConnecting;
  const factory LedgerSessionState.connected(LedgerDevice device) =
      LedgerSessionConnected;
  const factory LedgerSessionState.error(String message) = LedgerSessionError;
}

/// Single source of truth for Ledger session lifecycle (scan → connect →
/// connected) and wallet-ownership signature verification.
///
/// Sheets and BLoCs subscribe to [sessionState] instead of each owning their
/// own scan/connect state machine over [LedgerService]. The verify flow
/// (chain-specific sign + backend `/authToken/verify` + JWT cache) lives in
/// [verifyOwnership] so any Ledger-signed auth path can re-use it without
/// re-implementing wallet-type detection or the signing recipe.
@lazySingleton
class LedgerAuthService {
  LedgerAuthService(
    this._ledgerService,
    this._rpcService,
    this._authService,
    this._db,
    this._dio,
    this._storage,
  ) {
    _connectionSub = _ledgerService.connectionState.listen(_onConnectionState);
    final device = _ledgerService.connectedDevice;
    if (_ledgerService.isConnected && device != null) {
      _state = LedgerSessionState.connected(device);
    }
  }

  final LedgerService _ledgerService;
  final SolanaRpcService _rpcService;
  final AuthService _authService;
  final MallowDatabase _db;
  final Dio _dio;
  final SecureWalletStorage _storage;

  final _stateController = StreamController<LedgerSessionState>.broadcast();
  final _devices = <LedgerDevice>[];

  StreamSubscription<LedgerDevice>? _scanSub;
  StreamSubscription<void>? _scanFinishedSub;
  StreamSubscription<LedgerConnectionState>? _connectionSub;

  LedgerSessionState _state = const LedgerSessionState.disconnected();

  /// Current synchronous snapshot of the session state.
  LedgerSessionState get currentState => _state;

  /// Stream of session-state transitions. Subscribers receive only future
  /// emissions — read [currentState] to bootstrap UI on subscribe.
  Stream<LedgerSessionState> get sessionState => _stateController.stream;

  /// Re-exposed Ledger signing-state stream for views that want to surface
  /// per-stage copy ("Approve on Ledger…") without reaching into
  /// [LedgerService] directly.
  Stream<LedgerSigningState> get signingState => _ledgerService.signingState;

  /// Whether the BLE link is currently up.
  bool get isConnected => _ledgerService.isConnected;

  void _emit(LedgerSessionState next) {
    _state = next;
    _stateController.add(next);
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Begin a BLE scan. Preserves any bonded devices already in the list so
  /// `loadKnownDevices()` results stay visible across scan retries.
  Future<void> startScan() async {
    _emit(LedgerSessionState.scanning(devices: List.unmodifiable(_devices)));

    await _scanSub?.cancel();
    _scanSub = _ledgerService.scannedDevices.listen((device) {
      if (_devices.any((d) => d.id == device.id)) return;
      _devices.add(device);
      final current = _state;
      if (current is LedgerSessionScanning) {
        _emit(
          LedgerSessionState.scanning(
            devices: List.unmodifiable(_devices),
            active: current.active,
          ),
        );
      }
    });

    await _scanFinishedSub?.cancel();
    _scanFinishedSub = _ledgerService.scanFinished.listen((_) {
      if (_state is! LedgerSessionScanning) return;
      _emit(
        LedgerSessionState.scanning(
          devices: List.unmodifiable(_devices),
          active: false,
        ),
      );
    });

    try {
      await _ledgerService.startScan();
    } catch (e) {
      _emit(LedgerSessionState.error(e.toString()));
    }
  }

  /// Stop an in-flight scan but keep the discovered device list.
  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _scanFinishedSub?.cancel();
    _scanFinishedSub = null;
    await _ledgerService.stopScan();
  }

  /// Surface OS-bonded peripherals so the user can reconnect without
  /// waiting for fresh BLE advertisements. Safe to call alongside [startScan].
  Future<void> loadKnownDevices() async {
    final known = await _ledgerService.getKnownDevices();
    if (known.isEmpty) return;

    var changed = false;
    for (final device in known) {
      if (!_devices.any((d) => d.id == device.id)) {
        _devices.add(device);
        changed = true;
      }
    }
    if (!changed) return;

    final current = _state;
    if (current is LedgerSessionScanning) {
      _emit(
        LedgerSessionState.scanning(
          devices: List.unmodifiable(_devices),
          active: current.active,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  static const _maxConnectRetries = 2;

  /// Connect to [device]. Mirrors `LedgerConnectBloc._onConnectDevice` —
  /// retries `StateError`s once, surfaces stale-pairing guidance, and confirms
  /// the device is unlocked with an app open via [LedgerService.getOpenApp].
  ///
  /// Uses the app-agnostic BOLOS "Get App and Version" probe rather than the
  /// Solana-only `getAppConfig` — the latter throws "Not enough bytes to read"
  /// against an Ethereum or Tezos app, which is the wallet the user is here to
  /// verify. The per-wallet chain check happens later in [verifyOwnership].
  ///
  /// [expectedApp] names the single Ledger app the caller knows is required
  /// (e.g. "Solana" / "Ethereum" when verifying a specific wallet). When null
  /// — the import flow, where the chain isn't yet known — the connect-error
  /// hint lists every supported app instead.
  Future<void> connectDevice(LedgerDevice device, {String? expectedApp}) async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _ledgerService.stopScan();
    _emit(LedgerSessionState.connecting(device));

    for (var attempt = 0; attempt <= _maxConnectRetries; attempt++) {
      try {
        await _ledgerService.connect(device);
        await _ledgerService.getOpenApp();
        _emit(LedgerSessionState.connected(device));
        return;
      } on LedgerStalePairingException {
        _emit(
          const LedgerSessionState.error(
            'Bluetooth pairing is out of sync. Go to Settings → Bluetooth, '
            'tap the info button next to your Ledger, and choose "Forget '
            'This Device". Then try connecting again.',
          ),
        );
        return;
      } on StateError catch (e, st) {
        debugPrint(
          '[LedgerAuth] connect attempt ${attempt + 1} StateError: $e',
        );
        debugPrint('[LedgerAuth] stackTrace: $st');
        if (attempt < _maxConnectRetries) {
          try {
            await _ledgerService.disconnect();
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        _emit(
          const LedgerSessionState.error(
            'Could not read from Ledger. Unlock your device and try again.',
          ),
        );
      } catch (e, st) {
        debugPrint('[LedgerAuth] connect error: $e');
        debugPrint('[LedgerAuth] stackTrace: $st');
        final appHint = expectedApp != null
            ? 'the $expectedApp app'
            : 'the Solana, Ethereum, or Tezos app';
        _emit(
          LedgerSessionState.error(
            'Could not connect. Make sure $appHint is open on your Ledger.',
          ),
        );
        return;
      }
    }
  }

  /// Disconnect and reset to [LedgerSessionState.disconnected].
  Future<void> disconnect() async {
    await _ledgerService.disconnect();
    _emit(const LedgerSessionState.disconnected());
  }

  /// Forget the in-memory discovered-device list. Useful when a view tears
  /// down and the next session should not surface a stale device list.
  ///
  /// If the current state still references the cleared devices (i.e. we're
  /// in a scanning state), reset to [LedgerSessionState.disconnected] so a
  /// re-opened sheet doesn't render the stale snapshot held by the state
  /// object before its own [startScan] re-emits.
  void clearDevices() {
    _devices.clear();
    if (_state is LedgerSessionScanning) {
      _emit(const LedgerSessionState.disconnected());
    }
  }

  void _onConnectionState(LedgerConnectionState state) {
    switch (state) {
      case LedgerConnectionState.connected:
        final device = _ledgerService.connectedDevice;
        if (device != null && _state is! LedgerSessionConnected) {
          _emit(LedgerSessionState.connected(device));
        }
      case LedgerConnectionState.disconnected:
        if (_state is LedgerSessionConnected) {
          _emit(const LedgerSessionState.disconnected());
        }
      case LedgerConnectionState.error:
        if (_state is! LedgerSessionError) {
          _emit(
            const LedgerSessionState.error(
              'Connection error. Please try again.',
            ),
          );
        }
      case LedgerConnectionState.scanning:
      case LedgerConnectionState.connecting:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Ownership verification
  // ---------------------------------------------------------------------------

  /// The login challenge message prefix the backend reconstructs and verifies
  /// (the signed content is `<prefix>\n\ntoken:<token>`). Matches
  /// `AuthService._loginMessagePrefix` so the Ledger and HD paths agree.
  static const _messagePrefix = 'mallow Login';

  /// Verify wallet ownership by signing the login challenge with the connected
  /// Ledger and submitting it to the backend's `/authToken/verify` endpoint.
  /// The signing recipe is chain-specific (Solana memo transaction; Ethereum
  /// EIP-191 `personal_sign`; Tezos `edsig` over the Micheline payload). Caches
  /// the resulting wallet-sig JWT and session-expiry timestamp.
  ///
  /// Throws if the device is not connected, the wrong app is open, the user
  /// rejects the prompt, or any pipeline step fails. Callers branch on
  /// [LedgerDeviceException] for device-specific error codes (rejected /
  /// blind-signing disabled / app not open).
  Future<void> verifyOwnership(String address) async {
    if (!isConnected) {
      throw const LedgerNotConnectedException();
    }

    final row = await _db.getWalletByAddress(address);
    if (row == null) throw Exception('Wallet not found');
    final chain = Chain.fromDbString(row.chain);

    // The backend keys the wallet-sig cookie by the normalized address —
    // Ethereum (`0x…`) lowercased, Solana/Tezos unchanged — so the auth-token
    // request, verify body, and cookie extraction all use this form. The
    // signature itself is bound to the derivation path, not the address string,
    // so casing here never affects what the device signs.
    final cookieAddress = address.startsWith('0x')
        ? address.toLowerCase()
        : address;

    // Step 1: Get auth token
    final tokenResponse = await _dio.post<Map<String, dynamic>>(
      '${Config.apiBaseUrl}/v0/authToken',
      data: {'address': cookieAddress},
    );
    final token = tokenResponse.data?['result'] as String?;
    if (token == null) throw Exception('Failed to get auth token');

    // Step 2: Build the chain-specific `/authToken/verify` body. Solana submits
    // a signed memo transaction; Ethereum an EIP-191 signature; Tezos an `edsig`
    // over the Micheline payload plus the `edpk` the backend re-derives from.
    final verifyBody = switch (chain) {
      Chain.solana => await _solanaVerifyBody(cookieAddress, row, token),
      Chain.ethereum => await _ethereumVerifyBody(cookieAddress, row, token),
      Chain.tezos => await _tezosVerifyBody(cookieAddress, row, token),
    };

    // Step 3: Verify with backend
    final verifyResponse = await _dio.post<Map<String, dynamic>>(
      '${Config.apiBaseUrl}/v0/authToken/verify',
      data: verifyBody,
    );

    // Step 4: Cache the wallet-sig JWT + session expiry
    await _authService.handleVerifyResponse(
      verifyResponse.headers,
      cookieAddress,
    );
    final resultData = verifyResponse.data?['result'] as Map<String, dynamic>?;
    final expiresAt = resultData?['expiresAt'] as String?;
    if (expiresAt != null) {
      await _storage.storeSessionExpiry(expiresAt);
    }
  }

  /// Sign the login challenge as a Solana memo transaction and return the
  /// `/authToken/verify` body the backend expects (`tx` = base64 signed tx).
  Future<Map<String, dynamic>> _solanaVerifyBody(
    String address,
    db.Wallet row,
    String token,
  ) async {
    final fullMessage = '$_messagePrefix\n\ntoken:$token';
    final feePayer = Ed25519HDPublicKey.fromBase58(address);

    final memoInstruction = MemoInstruction(
      signers: [feePayer],
      memo: fullMessage,
    );
    final message = Message.only(memoInstruction);
    final recentBlockhash = await _rpcService.getLatestBlockhash();

    final scheme = _schemeFromRow(row);
    final compiledMessage = message.compile(
      recentBlockhash: recentBlockhash,
      feePayer: feePayer,
    );
    final messageBytes = compiledMessage.toByteArray().toList();

    final sigBytes = await _ledgerService.signTransaction(
      Uint8List.fromList(messageBytes),
      account: row.derivationIndex ?? 0,
      scheme: scheme,
    );

    final signature = Signature(sigBytes.toList(), publicKey: feePayer);
    final signedTx = SignedTx(
      signatures: [signature],
      compiledMessage: compiledMessage,
    );

    return {
      'address': address,
      'message': _messagePrefix,
      'tx': signedTx.encode(),
    };
  }

  /// Sign the login challenge with the Tezos app and return the
  /// `/authToken/verify` body. Mirrors the HD path
  /// (`WalletManager.signLoginChallenge` + `AuthService._verifyBody`) so the
  /// backend verifies a Ledger Tezos signature exactly as a seed-derived one:
  /// the device Blake2b-256-hashes and Ed25519-signs the same Micheline payload.
  Future<Map<String, dynamic>> _tezosVerifyBody(
    String address,
    db.Wallet row,
    String token,
  ) async {
    // Fail loud if the Tezos app isn't the one open — the Tezos APDUs below
    // (CLA=0x80) return "class not supported" against the Solana/Ethereum app.
    final openApp = (await _ledgerService.getOpenApp()).openApp;
    if (openApp != LedgerOpenApp.tezos) {
      throw Exception('Open the Tezos app on your Ledger, then try again.');
    }

    final account = row.derivationIndex ?? 0;
    final messageToSign = '$_messagePrefix\n\ntoken:$token';
    // The wallet stamps the time it signs; the backend rebuilds the same
    // payload from this exact string, so any stable ISO-8601 form works.
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final formatted = MultiChainDerivation.formatTezosSignedMessage(
      messageToSign,
      timestamp,
    );
    final packed = MultiChainDerivation.packTezosMicheline(formatted);

    final pubKey = await _ledgerService.getTezosPublicKey(account: account);
    final sigBytes = await _ledgerService.signTezosMessage(
      packed,
      account: account,
    );

    return {
      'address': address,
      'message': _messagePrefix,
      'signature': MultiChainDerivation.encodeTezosEdsig(sigBytes),
      'chain': Chain.tezos.toDbString(),
      'publicKey': MultiChainDerivation.encodeTezosEdpk(pubKey),
      'timestamp': timestamp,
    };
  }

  /// Sign the login challenge with the Ethereum app and return the
  /// `/authToken/verify` body. Mirrors the HD path
  /// (`WalletManager.signLoginChallenge` Ethereum case +
  /// `AuthService._verifyBody`): the device EIP-191 `personal_sign`s the same
  /// `<prefix>\n\ntoken:<token>` bytes, so the backend recovers the signer the
  /// same way it does for a seed-derived signature.
  Future<Map<String, dynamic>> _ethereumVerifyBody(
    String address,
    db.Wallet row,
    String token,
  ) async {
    // Fail loud if the Ethereum app isn't the one open — the ETH APDUs below
    // (CLA=0xE0) return "class not supported" against the Solana/Tezos app.
    final openApp = (await _ledgerService.getOpenApp()).openApp;
    if (openApp != LedgerOpenApp.ethereum) {
      throw Exception('Open the Ethereum app on your Ledger, then try again.');
    }

    final messageToSign = '$_messagePrefix\n\ntoken:$token';
    final sigBytes = await _ledgerService.signEthereumPersonalMessage(
      Uint8List.fromList(utf8.encode(messageToSign)),
      account: row.derivationIndex ?? 0,
    );

    return {
      'address': address,
      'message': _messagePrefix,
      // 65-byte r‖s‖v as `0x`-hex, the form viem `verifyMessage` recovers from.
      'signature': '0x${_hex(sigBytes)}',
      'chain': Chain.ethereum.toDbString(),
    };
  }

  /// Lowercase hex with no `0x` prefix.
  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Map a Ledger device error code to a user-friendly message for the wallet
  /// at [address], whose chain decides which app the copy names.
  ///
  /// Exposed as a static helper so views can render the same copy without
  /// reaching back into the service for trivial string conversion.
  static String describeLedgerError(int errorCode, String address) {
    final chain = Chain.fromAddress(address);
    final appName = chain.label;
    switch (errorCode) {
      case 0x6985:
        return 'Signing request rejected on Ledger device.';
      case 0x6A80:
      case 0x6A82:
      case 0xB008:
        // Blind signing is a Solana-app setting; the Ethereum and Tezos
        // message-signing paths don't use it.
        if (chain == Chain.solana) {
          return 'Blind signing is not enabled.\n\n'
              'Open the Solana app on your Ledger, go to Settings, '
              'and enable "Allow blind sign".';
        }
        return 'The $appName app rejected the request. '
            'Make sure it is up to date, then try again.';
      case 0x6E00:
        return 'The $appName app is not open on your Ledger device.';
      case 0x6D00:
        return 'Unsupported operation. Please update your Ledger $appName app.';
      default:
        return 'Ledger error (0x${errorCode.toRadixString(16)}). '
            'Please try again.';
    }
  }

  SolanaDerivationScheme _schemeFromRow(db.Wallet row) {
    final raw = row.derivationScheme;
    if (raw == null) return SolanaDerivationScheme.standard;
    return SolanaDerivationScheme.values.asNameMap()[raw] ??
        SolanaDerivationScheme.standard;
  }

  @disposeMethod
  Future<void> dispose() async {
    await _scanSub?.cancel();
    await _scanFinishedSub?.cancel();
    await _connectionSub?.cancel();
    await _stateController.close();
  }
}
