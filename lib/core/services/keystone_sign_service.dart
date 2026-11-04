import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:injectable/injectable.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:wallet/wallet.dart' show EthereumAddress;

import '../crypto/derivation.dart';
import '../crypto/ed25519_verify.dart';
import '../crypto/exceptions.dart';

/// The user closed the Keystone sheet, or the flow that asked for the
/// signature was cancelled underneath it.
///
/// A subtype of [TransactionAuthCancelledException] on purpose: every flow
/// already treats that as a clean abort (no signature, no chain state change),
/// and `AppFailure.from` files it as a cancel rather than as an error.
class KeystoneSigningCancelledException
    extends TransactionAuthCancelledException {
  KeystoneSigningCancelledException([
    super.message = 'Keystone signing was cancelled.',
  ]);

  @override
  String toString() => 'KeystoneSigningCancelledException: $message';
}

/// Nothing is listening to [KeystoneSignController] — the app shell that shows
/// the sheet is not mounted. Signing needs a screen; failing loud beats a
/// request that waits forever for a sheet nobody will show.
class KeystoneSigningUnavailableException extends SigningException {
  KeystoneSigningUnavailableException()
    : super('Keystone signing is not available right now.');
}

/// What a Keystone signature is being asked for. Drives the sheet's copy.
enum KeystoneSignPurpose { transaction, message }

/// Display context for the signing prompts belonging to one execution step.
class KeystoneSignContext {
  const KeystoneSignContext({this.notice, this.index, this.total});

  final String? notice;

  /// Zero-based position in the batch, omitted for a single transaction.
  final int? index;
  final int? total;
}

class _KeystoneSignScope {
  _KeystoneSignScope(this.context);

  KeystoneSignContext? context;
}

/// One QR round trip, from the request the device must scan to the reply it
/// shows back.
///
/// [validate] runs on every reply the sheet scans. It answers null when the
/// reply is the one this request is waiting for, and otherwise a sentence the
/// sheet shows while it keeps scanning — so a stale signature still on the
/// device's screen, or a code from a different Keystone, costs the user a
/// rescan instead of the whole flow.
class KeystoneSignPrompt {
  KeystoneSignPrompt({
    required this.request,
    required this.purpose,
    required this.address,
    required this.validate,
    this.replyType = RegistryType.solSignature,
    this.notice,
    this.index,
    this.total,
  });

  /// The request the device scans, shown as an animated QR.
  final UR request;

  /// The UR type of the device's reply: `sol-signature` or `eth-signature`.
  /// The sheet's scanner accepts only this type.
  final String replyType;

  final KeystoneSignPurpose purpose;

  /// The wallet the signature must come from. Shown on the sheet.
  final String address;

  final Future<String?> Function(UR reply) validate;

  /// Explanation shown above the QR exchange steps, when needed.
  String? notice;

  /// Zero-based batch position. Both fields are omitted for a single tx.
  int? index;
  int? total;

  /// Completes with the accepted reply, or with
  /// [KeystoneSigningCancelledException].
  final Completer<UR> completer = Completer<UR>();

  void cancel() {
    if (!completer.isCompleted) {
      completer.completeError(KeystoneSigningCancelledException());
    }
  }
}

/// Bridges a signing call (no `BuildContext`) to the sheet that runs the QR
/// exchange.
///
/// The same shape as `HardwareVerifyController`: a broadcast stream of
/// requests, listened to by the app shell in `app.dart`, which shows the sheet
/// and completes each request's [Completer].
@lazySingleton
class KeystoneSignController {
  final _requests = StreamController<KeystoneSignPrompt>.broadcast();
  final _contextKey = Object();

  Stream<KeystoneSignPrompt> get requests => _requests.stream;

  /// Attach [context] only to prompts presented while [body] runs.
  ///
  /// A zone keeps overlapping flows separate. Clearing in `finally` also
  /// strips the context from work that outlives the callback, even when no
  /// Keystone prompt was needed or signing failed.
  Future<T> withContext<T>(
    KeystoneSignContext context,
    Future<T> Function() body,
  ) {
    final scope = _KeystoneSignScope(context);
    return runZoned(() async {
      try {
        return await body();
      } finally {
        scope.context = null;
      }
    }, zoneValues: {_contextKey: scope});
  }

  /// Show [prompt] and wait for its accepted reply.
  ///
  /// When [cancelled] completes first, the prompt is cancelled and the sheet
  /// closes itself.
  Future<UR> present(KeystoneSignPrompt prompt, {Future<void>? cancelled}) {
    if (!_requests.hasListener) {
      throw KeystoneSigningUnavailableException();
    }
    final context = (Zone.current[_contextKey] as _KeystoneSignScope?)?.context;
    if (context != null) {
      prompt.notice = context.notice;
      prompt.index = context.index;
      prompt.total = context.total;
    }
    unawaited(cancelled?.then((_) => prompt.cancel()));
    _requests.add(prompt);
    return prompt.completer.future;
  }

  void dispose() => _requests.close();
}

/// Signs with a Keystone by QR.
///
/// Builds the device's own request type, has the sheet run the exchange, and
/// accepts a reply only after checking it is the answer to *this* request
/// (matching request id) from *this* wallet (an Ed25519 verification over the
/// exact bytes sent). The second check is the one that matters: the device's
/// reply carries no public key, and a request that named the wrong path or
/// device would come back with a valid signature from a different address.
@lazySingleton
class KeystoneSignService {
  KeystoneSignService(this._controller);

  final KeystoneSignController _controller;

  /// Largest payload sent to the device: a Solana off-chain message's limit.
  /// Transactions are far smaller (1232 bytes, 4096 for the v1 format).
  static const maxPayloadLength = 65535;

  /// Ask the Keystone holding [address] to sign [payload] — a compiled
  /// transaction message or raw message bytes — and return the 64-byte
  /// Ed25519 signature.
  ///
  /// Throws [KeystoneSigningCancelledException] when the user closes the
  /// sheet or [cancelled] completes.
  Future<Uint8List> signSolana({
    required Uint8List payload,
    required String address,
    required int masterFingerprint,
    required int derivationIndex,
    required SolanaDerivationScheme scheme,
    required KeystoneSignPurpose purpose,
    Future<void>? cancelled,
  }) async {
    if (payload.isEmpty || payload.length > maxPayloadLength) {
      throw SigningException('This payload is too large for a Keystone.');
    }
    if (masterFingerprint == 0) {
      throw SigningException(
        'This Keystone wallet is missing its device fingerprint. Remove it '
        'and import it again.',
      );
    }

    final requestId = SolSignRequest.newRequestId();
    final request = SolSignRequest(
      requestId: requestId,
      signData: payload,
      path: solanaKeypath(
        keystoneSolanaPath(scheme),
        derivationIndex,
        masterFingerprint,
      ),
      type: switch (purpose) {
        KeystoneSignPurpose.transaction => SolSignType.transaction,
        KeystoneSignPurpose.message => SolSignType.message,
      },
    );

    Uint8List? accepted;
    Future<String?> validate(UR reply) async {
      final SolSignature signature;
      try {
        signature = SolSignature.fromUr(reply);
      } on UrDecodeException {
        return 'That is not a Keystone signature. Scan the code on your '
            "Keystone's screen.";
      }
      final replyId = signature.requestId;
      if (replyId == null ||
          !const ListEquality<int>().equals(replyId, requestId)) {
        return 'That signature is for a different request. Scan the code '
            'your Keystone is showing now.';
      }
      if (!await isValidEd25519Signature(
        payload,
        signature.signature,
        address,
      )) {
        return 'This Keystone signed with a different account. Check that '
            'it is the device this wallet was imported from.';
      }
      accepted = signature.signature;
      return null;
    }

    await _controller.present(
      KeystoneSignPrompt(
        request: request.toUr(),
        purpose: purpose,
        address: address,
        validate: validate,
      ),
      cancelled: cancelled,
    );
    final signature = accepted;
    // Unreachable unless the sheet completed a prompt it never validated —
    // refuse rather than hand back an unchecked signature.
    if (signature == null) {
      throw SigningException('The Keystone signature was not verified.');
    }
    return signature;
  }

  /// Ask the Keystone holding the Ethereum [address] to sign [signData] and
  /// return the 65-byte `r‖s‖v`, with `v` as 27 or 28.
  ///
  /// [signData] is what the device is sent for [dataType]: the `0x02`-prefixed
  /// unsigned EIP-1559 serialization, the raw `personal_sign` message, or the
  /// EIP-712 JSON. [digest] is the 32-byte hash the device signs over it,
  /// computed here so the reply can be checked.
  ///
  /// The device signs by path once the fingerprint matches and ignores the
  /// address, so the reply is accepted only when the signer recovered from
  /// [digest] is [address]. A request that named the wrong path would
  /// otherwise come back with a valid signature from a different account.
  ///
  /// Throws [KeystoneSigningCancelledException] when the user closes the
  /// sheet or [cancelled] completes.
  Future<Uint8List> signEthereum({
    required Uint8List signData,
    required EthDataType dataType,
    required Uint8List digest,
    required int chainId,
    required String address,
    required int masterFingerprint,
    required int derivationIndex,
    Future<void>? cancelled,
  }) async {
    if (signData.length > maxPayloadLength) {
      throw SigningException('This payload is too large for a Keystone.');
    }
    // EIP-191 signs an empty message as readily as any other, and a website
    // may ask for one; every other data type needs a payload.
    if (signData.isEmpty && dataType != EthDataType.personalMessage) {
      throw SigningException('There is nothing to sign.');
    }
    if (digest.length != 32) {
      throw ArgumentError.value(digest.length, 'digest', 'must be 32 bytes');
    }
    if (masterFingerprint == 0) {
      throw SigningException(
        'This Keystone wallet is missing its device fingerprint. Remove it '
        'and import it again.',
      );
    }

    final requestId = EthSignRequest.newRequestId();
    final request = EthSignRequest(
      requestId: requestId,
      signData: signData,
      dataType: dataType,
      chainId: chainId,
      path: ethereumStandardKeypath(derivationIndex, masterFingerprint),
      address: EthereumAddress.fromHex(address).value,
    );

    Uint8List? accepted;
    Future<String?> validate(UR reply) async {
      final EthSignature signature;
      try {
        signature = EthSignature.fromUr(reply);
      } on UrDecodeException {
        return 'That is not a Keystone signature. Scan the code on your '
            "Keystone's screen.";
      }
      final replyId = signature.requestId;
      if (replyId == null ||
          !const ListEquality<int>().equals(replyId, requestId)) {
        return 'That signature is for a different request. Scan the code '
            'your Keystone is showing now.';
      }
      final normalized = normalizeEthereumSignature(signature.signature);
      final signer = normalized == null
          ? null
          : MultiChainDerivation.recoverEthereumAddress(digest, normalized);
      if (signer == null || signer != address.toLowerCase()) {
        return 'This Keystone signed with a different account. Check that '
            'it is the device this wallet was imported from.';
      }
      accepted = normalized;
      return null;
    }

    await _controller.present(
      KeystoneSignPrompt(
        request: request.toUr(),
        purpose: switch (dataType) {
          EthDataType.transaction ||
          EthDataType.typedTransaction => KeystoneSignPurpose.transaction,
          EthDataType.personalMessage ||
          EthDataType.typedData => KeystoneSignPurpose.message,
        },
        address: address,
        validate: validate,
        replyType: RegistryType.ethSignature,
      ),
      cancelled: cancelled,
    );
    final signature = accepted;
    if (signature == null) {
      throw SigningException('The Keystone signature was not verified.');
    }
    return signature;
  }
}

/// A Keystone `eth-signature` body as the 65-byte `r‖s‖v` the rest of the app
/// uses, with `v` as 27 or 28; null when `v` is not a recovery id.
///
/// The device writes `v` big-endian in one or more bytes, and as 0/1, 27/28,
/// or the EIP-155 form `chainId * 2 + 35/36` depending on the data type.
Uint8List? normalizeEthereumSignature(Uint8List signature) {
  if (signature.length < 65) return null;
  var v = BigInt.zero;
  for (final b in signature.sublist(64)) {
    v = (v << 8) | BigInt.from(b);
  }
  final int parity;
  if (v <= BigInt.one) {
    parity = v.toInt();
  } else if (v == BigInt.from(27) || v == BigInt.from(28)) {
    parity = v.toInt() - 27;
  } else if (v >= BigInt.from(35)) {
    parity = ((v - BigInt.from(35)) % BigInt.two).toInt();
  } else {
    return null;
  }
  return Uint8List.fromList([...signature.sublist(0, 64), 27 + parity]);
}

/// Our derivation scheme as the Keystone package names it. The two enums are
/// the same three paths; this is the one place they meet.
KeystoneSolanaPath keystoneSolanaPath(SolanaDerivationScheme scheme) =>
    switch (scheme) {
      SolanaDerivationScheme.standard => KeystoneSolanaPath.standard,
      SolanaDerivationScheme.legacy => KeystoneSolanaPath.legacy,
      SolanaDerivationScheme.root => KeystoneSolanaPath.root,
    };

/// The inverse of [keystoneSolanaPath].
SolanaDerivationScheme solanaSchemeFromKeystone(KeystoneSolanaPath path) =>
    switch (path) {
      KeystoneSolanaPath.standard => SolanaDerivationScheme.standard,
      KeystoneSolanaPath.legacy => SolanaDerivationScheme.legacy,
      KeystoneSolanaPath.root => SolanaDerivationScheme.root,
    };

/// A master fingerprint as the device shows it: eight upper-case hex digits.
String formatMasterFingerprint(int fingerprint) =>
    fingerprint.toRadixString(16).padLeft(8, '0').toUpperCase();
