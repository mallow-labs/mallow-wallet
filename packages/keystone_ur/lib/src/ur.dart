// UrEncoder and UrDecoder are a Dart rewrite of src/ur-encoder.cpp and
// src/ur-decoder.cpp from the Blockchain Commons bc-ur reference
// implementation (https://github.com/BlockchainCommons/bc-ur, commit 4479fb8),
// built around this package's API and with stricter input checks.
//
// Copyright © 2020 by Blockchain Commons, LLC
// Licensed under the BSD-2-Clause Plus Patent License
// (SPDX-License-Identifier: BSD-2-Clause-Patent). See this package's LICENSE
// and NOTICE files.
//
// Dart port: Copyright © 2026 mallow labs LLC, under the same licence.

import 'dart:typed_data';

import 'bc_ur/bytewords.dart';
import 'bc_ur/fountain_decoder.dart';
import 'bc_ur/fountain_encoder.dart';

/// Fragment length, in bytes of CBOR, of the animated QR codes we show the
/// device. Keystone's own firmware animates 200-byte fragments.
const int kKeystoneFragmentLength = 200;

/// How long each animated frame we show the device stays on screen.
const Duration kKeystoneFrameInterval = Duration(milliseconds: 150);

/// A Uniform Resource (BCR-2020-005): a registry type name and its CBOR body.
class UR {
  const UR(this.type, this.cbor);

  /// The registry type, lowercase, e.g. `sol-sign-request`.
  final String type;

  /// The CBOR-encoded body.
  final Uint8List cbor;

  /// True if [type] is a valid UR type: one or more of `a-z`, `0-9`, `-`.
  static bool isValidType(String type) => _typePattern.hasMatch(type);

  @override
  String toString() => 'UR($type, ${cbor.length} bytes)';
}

final RegExp _typePattern = RegExp(r'^[a-z0-9-]+$');

/// The reason decoding failed, independent of diagnostic wording.
enum UrDecodeErrorKind {
  /// A caller supplied no more specific reason.
  generic,

  /// The UR type is not one the caller accepts.
  unexpectedType,

  /// The UR, fountain header or registry data is invalid.
  malformed,

  /// A part disagrees with its sequence or the message already being scanned.
  inconsistentPart,

  /// The input exceeds a supported size, count or account-index limit.
  limitExceeded,

  /// The Bytewords or reconstructed message CRC does not match.
  checksumMismatch,
}

/// Thrown for every failure to decode a scanned UR or a registry type: a wrong
/// type, a malformed or inconsistent part, a checksum failure, a limit
/// exceeded, or CBOR that does not match the expected schema.
///
/// A scanned QR code is attacker-controlled input, so no decoding path in this
/// package lets a `TypeError`, `RangeError` or `FormatException` escape;
/// everything surfaces as this one type.
class UrDecodeException implements Exception {
  UrDecodeException(this.message, {this.kind = UrDecodeErrorKind.generic});

  final String message;

  /// Use this to choose recovery or guidance; [message] is diagnostic text.
  final UrDecodeErrorKind kind;

  @override
  String toString() => 'UrDecodeException: $message';
}

/// Encodes a [UR] as a sequence of QR-ready strings.
///
/// A body that fits in one fragment yields the same single-part string every
/// time (`UR:<TYPE>/<BYTEWORDS>`). A larger body yields multi-part strings
/// (`UR:<TYPE>/<SEQ>-<LEN>/<BYTEWORDS>`): the [fragmentCount] pure fragments
/// first, then fountain-mixed parts forever, so a receiver that misses frames
/// still completes. Strings are uppercase, which lets the QR encoder use its
/// denser alphanumeric mode; decoders ignore case.
class UrEncoder {
  UrEncoder(this.ur, {int maxFragmentLength = kKeystoneFragmentLength})
    : _fountain = FountainEncoder(ur.cbor, maxFragmentLength) {
    if (!UR.isValidType(ur.type)) {
      throw ArgumentError.value(ur.type, 'ur.type', 'not a valid UR type');
    }
  }

  final UR ur;
  final FountainEncoder _fountain;

  bool get isSinglePart => _fountain.isSinglePart;

  /// The number of pure fragments (1 for a single-part UR).
  int get fragmentCount => _fountain.seqLen;

  /// The next part, uppercase.
  String nextPart() => nextPartLowercase().toUpperCase();

  /// The next part in the canonical lowercase form the reference vectors use.
  String nextPartLowercase() {
    final part = _fountain.nextPart();
    if (isSinglePart) return encodeSinglePart(ur);
    final body = Bytewords.encode(BytewordsStyle.minimal, part.toCbor());
    return 'ur:${ur.type}/${part.seqNum}-${part.seqLen}/$body';
  }

  /// The single-part form of [ur], lowercase.
  static String encodeSinglePart(UR ur) =>
      'ur:${ur.type}/${Bytewords.encode(BytewordsStyle.minimal, ur.cbor)}';
}

/// Reassembles a [UR] from scanned QR strings, single- or multi-part, received
/// in any order, any case, with duplicates and gaps.
class UrDecoder {
  UrDecoder({
    Set<String>? expectedTypes,
    this.maxSequenceLength = 2048,
    this.maxMessageLength = 65536 + 4096,
  }) : expectedTypes = expectedTypes == null ? null : Set.unmodifiable(expectedTypes);

  /// The UR types this decoder accepts; null accepts any (but every part must
  /// still share the first part's type).
  final Set<String>? expectedTypes;

  /// The largest fragment count a multi-part UR may declare.
  final int maxSequenceLength;

  /// The largest CBOR body, in bytes, a UR may carry.
  final int maxMessageLength;

  final FountainDecoder _fountain = FountainDecoder();
  String? _type;
  UR? _result;

  bool get isComplete => _result != null;

  /// The decoded UR, once [isComplete].
  UR? get result => _result;

  /// A 0..1 progress estimate for a progress bar. It counts recovered pure
  /// fragments, or bc-ur's parts-processed estimate when that is higher, and
  /// stays below 1 until the message is complete and verified.
  double get progress {
    if (_result != null) return 1;
    final seqLen = _fountain.expectedSeqLen;
    if (seqLen == null) return 0;
    final byFragments = _fountain.receivedFragmentCount / seqLen;
    final estimate = _fountain.estimatedPercentComplete;
    final p = byFragments > estimate ? byFragments : estimate;
    return p < 0.99 ? p : 0.99;
  }

  /// The number of pure fragments the message declares, once a multi-part
  /// part has been seen.
  int? get expectedFragmentCount => _fountain.expectedSeqLen;

  /// Feeds one scanned string.
  ///
  /// Returns true if it was a valid UR part and was accepted (including a
  /// duplicate, or a consistent part arriving after completion), and false if
  /// it is not a UR at all — some other QR code — which callers can ignore.
  ///
  /// Throws [UrDecodeException] for a UR of a type not in [expectedTypes] or
  /// differing from earlier parts, a malformed UR, a part inconsistent with
  /// earlier parts, a limit exceeded, or a checksum failure. A fountain CRC
  /// failure is terminal: every subsequent call throws [UrDecodeException];
  /// start a new decoder to scan again.
  bool receivePart(String part) {
    try {
      return _receivePart(part);
    } on UrDecodeException {
      rethrow;
    } on Object {
      // Defence in depth: every known failure is already a
      // UrDecodeException, but a scanned code must never crash the caller.
      throw UrDecodeException('malformed UR', kind: UrDecodeErrorKind.malformed);
    }
  }

  bool _receivePart(String part) {
    if (_fountain.isFailure) {
      throw UrDecodeException('UR checksum mismatch', kind: UrDecodeErrorKind.checksumMismatch);
    }
    final s = part.trim().toLowerCase();
    if (!s.startsWith('ur:')) return false;

    // A minimal-bytewords body is two characters per byte, plus a few dozen
    // bytes of fountain header and CRC; anything far longer is rejected before
    // any allocation proportional to it.
    if (s.length > 2 * (maxMessageLength + 64) + 512) {
      throw UrDecodeException('UR is too long', kind: UrDecodeErrorKind.limitExceeded);
    }

    final components = s.substring(3).split('/');
    if (components.length < 2) {
      throw UrDecodeException('malformed UR: missing body', kind: UrDecodeErrorKind.malformed);
    }
    final type = components.first;
    if (!UR.isValidType(type)) {
      throw UrDecodeException('malformed UR: invalid type', kind: UrDecodeErrorKind.malformed);
    }
    final allowed = expectedTypes;
    if (allowed != null && !allowed.contains(type)) {
      throw UrDecodeException('unexpected UR type "$type"', kind: UrDecodeErrorKind.unexpectedType);
    }
    if (_type != null && _type != type) {
      throw UrDecodeException(
        'UR type changed from "$_type" to "$type" mid-scan',
        kind: UrDecodeErrorKind.inconsistentPart,
      );
    }

    if (components.length == 2) {
      final cbor = _decodeBytewords(components[1]);
      if (cbor.length > maxMessageLength) {
        throw UrDecodeException(
          'UR body exceeds $maxMessageLength bytes',
          kind: UrDecodeErrorKind.limitExceeded,
        );
      }
      _type = type;
      _result ??= UR(type, cbor);
      return true;
    }
    if (components.length != 3) {
      throw UrDecodeException(
        'malformed UR: too many path components',
        kind: UrDecodeErrorKind.malformed,
      );
    }

    final (seqNum, seqLen) = _parseSequence(components[1]);
    if (seqLen > maxSequenceLength) {
      throw UrDecodeException(
        'UR declares $seqLen fragments; the limit is $maxSequenceLength',
        kind: UrDecodeErrorKind.limitExceeded,
      );
    }
    final FountainPart fp;
    try {
      fp = FountainPart.fromCbor(_decodeBytewords(components[2]));
    } on InvalidFountainPart catch (e) {
      throw UrDecodeException('malformed UR part: ${e.message}', kind: UrDecodeErrorKind.malformed);
    }
    if (fp.seqNum != seqNum || fp.seqLen != seqLen) {
      throw UrDecodeException(
        'UR part header disagrees with its sequence component',
        kind: UrDecodeErrorKind.inconsistentPart,
      );
    }
    if (fp.messageLen > maxMessageLength) {
      throw UrDecodeException(
        'UR body exceeds $maxMessageLength bytes',
        kind: UrDecodeErrorKind.limitExceeded,
      );
    }
    if (!_fountain.isConsistent(fp)) {
      throw UrDecodeException(
        _fountain.expectedSeqLen == null
            ? 'malformed UR part: inconsistent header'
            : 'UR part does not belong to the message being scanned',
        kind: _fountain.expectedSeqLen == null
            ? UrDecodeErrorKind.malformed
            : UrDecodeErrorKind.inconsistentPart,
      );
    }
    _type = type;
    if (_result != null) return true;

    _fountain.receivePart(fp);
    final message = _fountain.resultMessage;
    if (message != null) {
      _result = UR(type, message);
    }
    return true;
  }

  static Uint8List _decodeBytewords(String body) {
    try {
      return Bytewords.decode(BytewordsStyle.minimal, body);
    } on BytewordsException catch (e) {
      throw UrDecodeException(
        'malformed UR: ${e.message}',
        kind: e.isChecksumMismatch
            ? UrDecodeErrorKind.checksumMismatch
            : UrDecodeErrorKind.malformed,
      );
    }
  }

  static final RegExp _seqPattern = RegExp(r'^([0-9]{1,10})-([0-9]{1,10})$');

  static (int, int) _parseSequence(String s) {
    final m = _seqPattern.firstMatch(s);
    if (m == null) {
      throw UrDecodeException(
        'malformed UR: bad sequence component',
        kind: UrDecodeErrorKind.malformed,
      );
    }
    final seqNum = int.parse(m.group(1)!);
    final seqLen = int.parse(m.group(2)!);
    if (seqNum < 1 || seqLen < 1 || seqNum > 0xFFFFFFFF || seqLen > 0xFFFFFFFF) {
      throw UrDecodeException(
        'malformed UR: bad sequence component',
        kind: UrDecodeErrorKind.malformed,
      );
    }
    return (seqNum, seqLen);
  }
}
