// Dart port of src/fountain-decoder.cpp from the Blockchain Commons bc-ur
// reference implementation (https://github.com/BlockchainCommons/bc-ur,
// commit 4479fb8).
//
// Copyright © 2020 by Blockchain Commons, LLC
// Licensed under the BSD-2-Clause Plus Patent License
// (SPDX-License-Identifier: BSD-2-Clause-Patent). See this package's LICENSE
// and NOTICE files.
//
// Dart port: Copyright © 2026 mallow labs LLC, under the same licence.
//
// Changes from the reference, all on the rejection side: a part must be
// structurally sane (seqNum ≥ 1, seqLen = ceil(messageLen / fragmentLen)) before
// it can set the expectations later parts are checked against, and the number
// and total degree of stored mixed parts are capped so an untrusted stream
// cannot grow memory or reduction work without bound. Excess mixed equations
// are ignored; pure fragments can still complete a scan.

import 'dart:collection';
import 'dart:typed_data';

import '../ur.dart' show UrDecodeErrorKind, UrDecodeException;
import 'crc32.dart';
import 'fountain_encoder.dart';
import 'fountain_utils.dart';

class _Part {
  _Part(this.indexes, this.data) : hashCode = Object.hashAll(indexes);

  /// Sorted, distinct fragment indexes XORed into [data].
  final List<int> indexes;
  final Uint8List data;

  bool get isSimple => indexes.length == 1;
  int get index => indexes.first;

  // Identity depends on the canonical sorted indexes, not the fragment data.
  // Cache the hash once instead of allocating a string on every lookup.
  @override
  final int hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _Part || hashCode != other.hashCode || indexes.length != other.indexes.length) {
      return false;
    }
    for (var i = 0; i < indexes.length; i++) {
      if (indexes[i] != other.indexes[i]) return false;
    }
    return true;
  }
}

/// Reassembles a message from fountain parts received in any order, with
/// duplicates and gaps.
class FountainDecoder {
  final Set<int> _receivedPartIndexes = {};
  final Map<int, _Part> _simpleParts = {};
  final Map<_Part, _Part> _mixedParts = {};
  int _storedMixedIndexCount = 0;
  final Queue<_Part> _queuedParts = Queue();

  int? _expectedSeqLen;
  int? _expectedMessageLen;
  int? _expectedChecksum;
  int? _expectedFragmentLen;

  Uint8List? _result;
  bool _checksumFailed = false;
  int _processedPartsCount = 0;

  /// The fragment count every part must agree on, once the first is seen.
  int? get expectedSeqLen => _expectedSeqLen;
  int? get expectedMessageLen => _expectedMessageLen;
  int? get expectedChecksum => _expectedChecksum;
  int? get expectedFragmentLen => _expectedFragmentLen;

  /// The number of distinct pure fragments recovered so far.
  int get receivedFragmentCount => _receivedPartIndexes.length;

  /// The number of parts accepted (including ones that added nothing new).
  int get processedPartsCount => _processedPartsCount;

  /// The number of unreduced mixed equations retained.
  int get storedMixedPartCount => _mixedParts.length;

  /// The total number of indexes retained in mixed equations.
  int get storedMixedIndexCount => _storedMixedIndexCount;

  bool get isComplete => _result != null || _checksumFailed;
  bool get isSuccess => _result != null;

  /// True when every fragment arrived but the reassembled message failed its
  /// CRC-32 check.
  bool get isFailure => _checksumFailed;

  /// The reassembled message, once [isSuccess].
  Uint8List? get resultMessage => _result;

  /// bc-ur's estimate: parts processed against ~1.75 × the fragment count,
  /// capped at 0.99 until complete.
  double get estimatedPercentComplete {
    if (isComplete) return 1;
    final seqLen = _expectedSeqLen;
    if (seqLen == null) return 0;
    final estimate = _processedPartsCount / (seqLen * 1.75);
    return estimate < 0.99 ? estimate : 0.99;
  }

  /// True if [p] is self-consistent and agrees with the parts seen so far.
  bool isConsistent(FountainPart p) {
    if (p.seqNum < 1 || p.seqLen < 1 || p.messageLen < 1 || p.data.isEmpty) return false;
    if ((p.messageLen + p.data.length - 1) ~/ p.data.length != p.seqLen) return false;
    if (_expectedSeqLen == null) return true;
    return _expectedSeqLen == p.seqLen &&
        _expectedMessageLen == p.messageLen &&
        _expectedChecksum == p.checksum &&
        _expectedFragmentLen == p.data.length;
  }

  /// Adds [encoderPart]. Returns false if decoding already succeeded or
  /// the part is inconsistent with the earlier ones (it is then ignored).
  /// A CRC failure throws [UrDecodeException], including on every later call.
  bool receivePart(FountainPart encoderPart) {
    if (isFailure) {
      throw UrDecodeException('UR checksum mismatch', kind: UrDecodeErrorKind.checksumMismatch);
    }
    if (isComplete) return false;
    if (!isConsistent(encoderPart)) return false;
    if (_expectedSeqLen == null) {
      _expectedSeqLen = encoderPart.seqLen;
      _expectedMessageLen = encoderPart.messageLen;
      _expectedChecksum = encoderPart.checksum;
      _expectedFragmentLen = encoderPart.data.length;
    }

    final indexes = chooseFragments(encoderPart.seqNum, encoderPart.seqLen, encoderPart.checksum);
    _queuedParts.add(_Part(indexes, Uint8List.fromList(encoderPart.data)));

    while (!isComplete && _queuedParts.isNotEmpty) {
      _processQueueItem();
    }

    _processedPartsCount += 1;
    if (isFailure) {
      throw UrDecodeException('UR checksum mismatch', kind: UrDecodeErrorKind.checksumMismatch);
    }
    return true;
  }

  // The reference uses subset reduction, not elimination of every dependent
  // equation. Allow two equations per fragment plus slack for small messages.
  int get _maxMixedParts => 2 * (_expectedSeqLen ?? 0) + 32;

  // Typical sparse streams have ample room at 64 indexes per fragment. The
  // fixed ceiling retains at most ~1 MiB of index slots on a 64-bit VM and
  // bounds the work of scanning stored equations even at the fragment limit.
  int get _maxMixedIndexes {
    final scaled = 64 * (_expectedSeqLen ?? 0);
    return scaled < 131072 ? scaled : 131072;
  }

  bool _canStoreMixed(_Part p) =>
      _mixedParts.length < _maxMixedParts &&
      _storedMixedIndexCount + p.indexes.length <= _maxMixedIndexes;

  void _storeMixed(_Part p) {
    if (_mixedParts.containsKey(p)) return;
    _mixedParts[p] = p;
    _storedMixedIndexCount += p.indexes.length;
  }

  void _processQueueItem() {
    final part = _queuedParts.removeFirst();
    if (part.isSimple) {
      _processSimplePart(part);
    } else {
      _processMixedPart(part);
    }
  }

  void _reduceMixedBy(_Part p) {
    final reduced = [for (final m in _mixedParts.values) _reducePartByPart(m, p)];
    _mixedParts.clear();
    _storedMixedIndexCount = 0;
    for (final r in reduced) {
      if (r.isSimple) {
        _queuedParts.add(r);
      } else {
        _storeMixed(r);
      }
    }
  }

  /// If [b]'s fragments are a strict subset of [a]'s, returns a − b
  /// (indexes) with data a XOR b; otherwise returns [a] unchanged.
  _Part _reducePartByPart(_Part a, _Part b) {
    if (b.indexes.length >= a.indexes.length) return a;
    if (b.indexes.first < a.indexes.first || b.indexes.last > a.indexes.last) return a;
    // Both lists are sorted. Check containment without rebuilding hash sets
    // for every pair; allocate a difference only after proving containment.
    var ai = 0;
    for (final index in b.indexes) {
      while (ai < a.indexes.length && a.indexes[ai] < index) {
        ai++;
      }
      if (ai == a.indexes.length || a.indexes[ai] != index) return a;
      ai++;
    }
    final newIndexes = <int>[];
    var bi = 0;
    for (final index in a.indexes) {
      if (bi < b.indexes.length && index == b.indexes[bi]) {
        bi++;
      } else {
        newIndexes.add(index);
      }
    }
    final newData = Uint8List.fromList(a.data);
    xorInto(newData, b.data);
    return _Part(newIndexes, newData);
  }

  void _processSimplePart(_Part p) {
    final fragmentIndex = p.index;
    if (_receivedPartIndexes.contains(fragmentIndex)) return;

    _simpleParts[fragmentIndex] = p;
    _receivedPartIndexes.add(fragmentIndex);

    if (_receivedPartIndexes.length == _expectedSeqLen) {
      final fragmentLen = _expectedFragmentLen!;
      final messageLen = _expectedMessageLen!;
      final joined = Uint8List(_expectedSeqLen! * fragmentLen);
      for (var i = 0; i < _expectedSeqLen!; i++) {
        joined.setRange(i * fragmentLen, (i + 1) * fragmentLen, _simpleParts[i]!.data);
      }
      final message = Uint8List.sublistView(joined, 0, messageLen);
      if (crc32(message) == _expectedChecksum) {
        _result = Uint8List.fromList(message);
      } else {
        _checksumFailed = true;
      }
    } else {
      _reduceMixedBy(p);
    }
  }

  void _processMixedPart(_Part p) {
    if (_mixedParts.containsKey(p)) return;

    // Remove all known pure fragments in one pass. Their XORs commute, so
    // this matches repeated subset reduction without copying for each index.
    final remaining = <int>[];
    Uint8List? reducedData;
    for (final index in p.indexes) {
      final simple = _simpleParts[index];
      if (simple == null) {
        remaining.add(index);
      } else {
        reducedData ??= Uint8List.fromList(p.data);
        xorInto(reducedData, simple.data);
      }
    }
    if (remaining.isEmpty) return;
    var p2 = reducedData == null ? p : _Part(remaining, reducedData);
    if (p2.isSimple) {
      _queuedParts.add(p2);
      return;
    }
    if (_mixedParts.containsKey(p2)) return;
    // Check admission before scanning mixed equations. Otherwise a full
    // decoder would still do expensive reductions for every discarded frame.
    if (!_canStoreMixed(p2)) return;
    for (final m in _mixedParts.values) {
      p2 = _reducePartByPart(p2, m);
    }

    if (p2.isSimple) {
      _queuedParts.add(p2);
    } else {
      _reduceMixedBy(p2);
      _storeMixed(p2);
    }
  }
}
