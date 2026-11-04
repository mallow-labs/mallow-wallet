// Dart port of src/crc32.c from the Blockchain Commons bc-ur reference
// implementation (https://github.com/BlockchainCommons/bc-ur, commit 4479fb8).
//
// Original: Copyright © 2020 by Blockchain Commons, LLC. The file's header
// puts it under the BSD-2-Clause Plus Patent License
// (SPDX-License-Identifier: BSD-2-Clause-Patent); bc-ur's README lists it as
// BSD-3-Clause, copyright 2020 Wolf McNally for Blockchain Commons. This
// package's LICENSE reproduces both texts (parts A and C), and NOTICE gives
// the attribution.
//
// Dart port: Copyright © 2026 mallow labs LLC, under the same licence.

import 'dart:typed_data';

/// The reflected IEEE 802.3 polynomial, as used by zlib and by BCR-2020-005.
const int _polynomial = 0xEDB88320;

final Uint32List _table = _buildTable();

Uint32List _buildTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var j = 0; j < 8; j++) {
      c = (c & 1) == 0 ? (c >>> 1) : (_polynomial ^ (c >>> 1));
    }
    table[i] = c;
  }
  return table;
}

/// CRC-32 (IEEE) of [bytes], as an unsigned 32-bit integer.
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// CRC-32 (IEEE) of [bytes], as four big-endian bytes — the form bytewords
/// appends to every UR body.
Uint8List crc32Bytes(List<int> bytes) => uint32ToBytes(crc32(bytes));

/// [n] as four big-endian bytes (bc-ur's `int_to_bytes`).
Uint8List uint32ToBytes(int n) => Uint8List(4)
  ..[0] = (n >>> 24) & 0xFF
  ..[1] = (n >>> 16) & 0xFF
  ..[2] = (n >>> 8) & 0xFF
  ..[3] = n & 0xFF;
