// Dart port of src/bytewords.cpp from the Blockchain Commons bc-ur reference
// implementation (https://github.com/BlockchainCommons/bc-ur, commit 4479fb8).
// Bytewords are specified in BCR-2020-012.
//
// Copyright © 2020 by Blockchain Commons, LLC
// Licensed under the BSD-2-Clause Plus Patent License
// (SPDX-License-Identifier: BSD-2-Clause-Patent). See this package's LICENSE
// and NOTICE files.
//
// Dart port: Copyright © 2026 mallow labs LLC, under the same licence.

import 'dart:typed_data';

import 'crc32.dart';

/// The three bytewords encodings.
enum BytewordsStyle {
  /// Four-letter words separated by spaces.
  standard,

  /// Four-letter words separated by dashes.
  uri,

  /// The first and last letter of each word, unseparated — the UR form.
  minimal,
}

/// Thrown by [Bytewords.decode] on any malformed input or checksum mismatch.
class BytewordsException implements Exception {
  BytewordsException(this.message, {this.isChecksumMismatch = false});

  final String message;
  final bool isChecksumMismatch;

  @override
  String toString() => 'BytewordsException: $message';
}

const String _bytewords =
    'ableacidalsoapexaquaarchatomauntawayaxisbackbaldbarnbeltbetabiasbluebodybragbrewbulbbuzz'
    'calmcashcatschefcityclawcodecolacookcostcruxcurlcuspcyandarkdatadaysdelidicedietdoordown'
    'drawdropdrumdulldutyeacheasyechoedgeepicevenexamexiteyesfactfairfernfigsfilmfishfizzflap'
    'flewfluxfoxyfreefrogfuelfundgalagamegeargemsgiftgirlglowgoodgraygrimgurugushgyrohalfhang'
    'hardhawkheathelphighhillholyhopehornhutsicedideaidleinchinkyintoirisironitemjadejazzjoin'
    'joltjowljudojugsjumpjunkjurykeepkenokeptkeyskickkilnkingkitekiwiknoblamblavalazyleaflegs'
    'liarlimplionlistlogoloudloveluaulucklungmainmanymathmazememomenumeowmildmintmissmonknail'
    'navyneednewsnextnoonnotenumbobeyoboeomitonyxopenovalowlspaidpartpeckplaypluspoempoolpose'
    'puffpumapurrquadquizraceramprealredorichroadrockroofrubyruinrunsrustsafesagascarsetssilk'
    'skewslotsoapsolosongstubsurfswantacotasktaxitenttiedtimetinytoiltombtoystriptunatwinugly'
    'undouniturgeuservastveryvetovialvibeviewvisavoidvowswallwandwarmwaspwavewaxywebswhatwhen'
    'whizwolfworkyankyawnyellyogayurtzapszerozestzinczonezoom';

const int _a = 0x61; // 'a'
const int _dim = 26;

/// (first letter, last letter) → byte value, or -1. The first and last letters
/// of every byteword are a unique pair, which is what makes the two-letter
/// minimal style decodable.
final Int16List _lookup = _buildLookup();

Int16List _buildLookup() {
  final table = Int16List(_dim * _dim)..fillRange(0, _dim * _dim, -1);
  for (var i = 0; i < 256; i++) {
    final x = _bytewords.codeUnitAt(i * 4) - _a;
    final y = _bytewords.codeUnitAt(i * 4 + 3) - _a;
    table[y * _dim + x] = i;
  }
  return table;
}

int _lower(int c) => (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c;

/// Bytewords encoding with the trailing CRC-32 that BCR-2020-012 appends.
abstract final class Bytewords {
  /// Encodes [bytes] (plus their CRC-32) in [style].
  static String encode(BytewordsStyle style, List<int> bytes) {
    final withCrc = <int>[...bytes, ...crc32Bytes(bytes)];
    switch (style) {
      case BytewordsStyle.standard:
        return withCrc.map(_word).join(' ');
      case BytewordsStyle.uri:
        return withCrc.map(_word).join('-');
      case BytewordsStyle.minimal:
        final sb = StringBuffer();
        for (final b in withCrc) {
          sb
            ..writeCharCode(_bytewords.codeUnitAt(b * 4))
            ..writeCharCode(_bytewords.codeUnitAt(b * 4 + 3));
        }
        return sb.toString();
    }
  }

  /// Decodes [s] in [style], verifies and strips the CRC-32, and returns the
  /// body. Case-insensitive. Throws [BytewordsException] on any error.
  static Uint8List decode(BytewordsStyle style, String s) {
    final List<int> buf;
    switch (style) {
      case BytewordsStyle.standard:
        buf = _decodeWords(s.split(' '));
      case BytewordsStyle.uri:
        buf = _decodeWords(s.split('-'));
      case BytewordsStyle.minimal:
        if (s.length.isOdd) {
          throw BytewordsException('Invalid Bytewords: odd length.');
        }
        buf = Uint8List(s.length ~/ 2);
        for (var i = 0; i < buf.length; i++) {
          buf[i] = _decodeWord(s, i * 2, 2);
        }
    }
    if (buf.length < 5) {
      throw BytewordsException('Invalid Bytewords: too short.');
    }
    final bodyLen = buf.length - 4;
    final body = Uint8List.fromList(buf.sublist(0, bodyLen));
    final expected = crc32(body);
    final actual =
        (buf[bodyLen] << 24) |
        (buf[bodyLen + 1] << 16) |
        (buf[bodyLen + 2] << 8) |
        buf[bodyLen + 3];
    if (expected != actual) {
      throw BytewordsException('Invalid Bytewords: checksum mismatch.', isChecksumMismatch: true);
    }
    return body;
  }

  static String _word(int b) => _bytewords.substring(b * 4, b * 4 + 4);

  static List<int> _decodeWords(List<String> words) {
    final out = Uint8List(words.length);
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      if (w.length != 4) {
        throw BytewordsException('Invalid Bytewords: bad word length.');
      }
      out[i] = _decodeWord(w, 0, 4);
    }
    return out;
  }

  static int _decodeWord(String s, int offset, int wordLen) {
    final x = _lower(s.codeUnitAt(offset)) - _a;
    final y = _lower(s.codeUnitAt(offset + (wordLen == 4 ? 3 : 1))) - _a;
    if (x < 0 || x >= _dim || y < 0 || y >= _dim) {
      throw BytewordsException('Invalid Bytewords: bad character.');
    }
    final value = _lookup[y * _dim + x];
    if (value == -1) {
      throw BytewordsException('Invalid Bytewords: unknown word.');
    }
    if (wordLen == 4) {
      if (_lower(s.codeUnitAt(offset + 1)) != _bytewords.codeUnitAt(value * 4 + 1) ||
          _lower(s.codeUnitAt(offset + 2)) != _bytewords.codeUnitAt(value * 4 + 2)) {
        throw BytewordsException('Invalid Bytewords: unknown word.');
      }
    }
    return value;
  }
}
