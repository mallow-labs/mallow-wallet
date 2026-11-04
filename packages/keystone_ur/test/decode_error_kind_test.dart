import 'dart:typed_data';

import 'package:keystone_ur/keystone_ur.dart';
import 'package:keystone_ur/src/bc_ur/bytewords.dart';
import 'package:keystone_ur/src/bc_ur/fountain_encoder.dart';
import 'package:keystone_ur/src/registry/cbor_util.dart';
import 'package:test/test.dart';

Matcher throwsKind(UrDecodeErrorKind kind) =>
    throwsA(isA<UrDecodeException>().having((e) => e.kind, 'kind', kind));

String partString(FountainPart part) =>
    'ur:bytes/${part.seqNum}-${part.seqLen}/'
    '${Bytewords.encode(BytewordsStyle.minimal, part.toCbor())}';

void main() {
  test('message-only construction stays compatible', () {
    final error = UrDecodeException('caller diagnostic');
    expect(error.kind, UrDecodeErrorKind.generic);
    expect(error.message, 'caller diagnostic');
    expect(error.toString(), 'UrDecodeException: caller diagnostic');
    expect(
      UrDecodeException('different wording', kind: UrDecodeErrorKind.unexpectedType).kind,
      UrDecodeErrorKind.unexpectedType,
    );
  });

  test('unexpected types are distinguished from a type change mid-scan', () {
    final encoder = UrEncoder(UR('bytes', Uint8List(60)), maxFragmentLength: 20);
    expect(
      () => UrDecoder(expectedTypes: {'sol-signature'}).receivePart(encoder.nextPart()),
      throwsKind(UrDecodeErrorKind.unexpectedType),
    );
    final decoder = UrDecoder()..receivePart(encoder.nextPart());
    expect(
      () => decoder.receivePart(UrEncoder.encodeSinglePart(UR('other', Uint8List(1)))),
      throwsKind(UrDecodeErrorKind.inconsistentPart),
    );
  });

  test('malformed UR syntax, bytewords and fountain CBOR have a typed reason', () {
    for (final raw in [
      'ur:bytes',
      'ur:by_tes/ae',
      'ur:bytes/1-2/extra/ae',
      'ur:bytes/x-2/ae',
      'ur:bytes/0-2/ae',
      'ur:bytes/ae',
      'ur:bytes/zzzzzzzzzz',
      'ur:bytes/1-1/${Bytewords.encode(BytewordsStyle.minimal, [0xa0])}',
    ]) {
      expect(
        () => UrDecoder().receivePart(raw),
        throwsKind(UrDecodeErrorKind.malformed),
        reason: raw,
      );
    }
  });

  test('message, fragment and input length caps have a typed reason', () {
    final ur = UR('bytes', Uint8List(60));
    final encoder = UrEncoder(ur, maxFragmentLength: 20);
    for (final receive in <void Function()>[
      () => UrDecoder(maxMessageLength: 59).receivePart(UrEncoder.encodeSinglePart(ur)),
      () => UrDecoder(maxMessageLength: 59).receivePart(encoder.nextPart()),
      () => UrDecoder(maxSequenceLength: 2).receivePart(encoder.nextPart()),
      () => UrDecoder(maxMessageLength: 1).receivePart('ur:bytes/${'ae' * 400}'),
    ]) {
      expect(receive, throwsKind(UrDecodeErrorKind.limitExceeded));
    }
  });

  test('inconsistent parts are distinguished from malformed first headers', () {
    final encoder = FountainEncoder(Uint8List(60), 20);
    final first = encoder.nextPart();
    final decoder = UrDecoder()..receivePart(partString(first));
    final other = FountainPart(
      seqNum: first.seqNum,
      seqLen: first.seqLen,
      messageLen: first.messageLen,
      checksum: first.checksum ^ 1,
      data: first.data,
    );
    expect(
      () => decoder.receivePart(partString(other)),
      throwsKind(UrDecodeErrorKind.inconsistentPart),
    );
    final raw = partString(first).replaceFirst('/1-', '/2-');
    expect(() => UrDecoder().receivePart(raw), throwsKind(UrDecodeErrorKind.inconsistentPart));
    final impossible = FountainPart(
      seqNum: 1,
      seqLen: 2,
      messageLen: 60,
      checksum: 0,
      data: Uint8List(20),
    );
    expect(
      () => UrDecoder().receivePart(partString(impossible)),
      throwsKind(UrDecodeErrorKind.malformed),
    );
  });

  test('bytewords CRC mismatch has a typed reason', () {
    final raw = UrEncoder.encodeSinglePart(UR('bytes', Uint8List(2)));
    final corrupted = '${raw.substring(0, raw.length - 2)}${raw.endsWith('ae') ? 'ad' : 'ae'}';
    expect(
      () => UrDecoder().receivePart(corrupted),
      throwsKind(UrDecodeErrorKind.checksumMismatch),
    );
  });

  test('fountain CRC mismatch retains its reason on every later call', () {
    final encoder = FountainEncoder(Uint8List(60), 20);
    final parts = [for (var i = 0; i < encoder.seqLen; i++) encoder.nextPart()];
    parts.last.data[0] ^= 1;
    final decoder = UrDecoder();
    for (final part in parts.take(parts.length - 1)) {
      decoder.receivePart(partString(part));
    }
    expect(
      () => decoder.receivePart(partString(parts.last)),
      throwsKind(UrDecodeErrorKind.checksumMismatch),
    );
    for (final raw in [
      partString(parts.first),
      'other QR',
      UrEncoder.encodeSinglePart(UR('bytes', Uint8List(1))),
    ]) {
      expect(() => decoder.receivePart(raw), throwsKind(UrDecodeErrorKind.checksumMismatch));
    }
  });

  test('registry decoders use unexpectedType independently of their wording', () {
    final ur = UR('bytes', Uint8List(1));
    for (final decode in <void Function()>[
      () => SolSignature.fromUr(ur),
      () => SolSignRequest.fromUr(ur),
      () => EthSignature.fromUr(ur),
      () => EthSignRequest.fromUr(ur),
      () => KeystoneMultiAccounts.fromUr(ur),
      () => KeystoneHdKey.fromUr(ur),
      () => KeystoneKeypath.fromUr(ur),
      () => ethStandardXpubFromUr(ur),
    ]) {
      expect(decode, throwsKind(UrDecodeErrorKind.unexpectedType));
    }
  });

  test('registry CBOR, schema and account validation failures are malformed', () {
    for (final decode in <void Function()>[
      () => SolSignature.fromCbor([0xff]),
      () => SolSignature.fromCbor([0xa0]),
      () => EthSignature.fromCbor([0xa0]),
      () => KeystoneHdKey.fromCbor([0xa0]),
      () => KeystoneKeypath.fromCbor([0xa0]),
      () => solanaAccountsFromExport(const KeystoneMultiAccounts(masterFingerprint: 0, keys: [])),
    ]) {
      expect(decode, throwsKind(UrDecodeErrorKind.malformed));
    }
  });

  test('registry key and output caps have a typed reason', () {
    final export = KeystoneMultiAccounts(
      masterFingerprint: 1,
      keys: [KeystoneHdKey(keyData: Uint8List(32))],
    );
    expect(
      () => KeystoneMultiAccounts.fromUr(export.toUr(), maxKeys: 0),
      throwsKind(UrDecodeErrorKind.limitExceeded),
    );
    final outputs = Uint8List.fromList([
      0xa2,
      0x01,
      0x01,
      0x02,
      0x98,
      65,
      ...List.filled(65, 0xa0),
    ]);
    expect(
      () => classifyEthExport(UR('crypto-account', outputs)),
      throwsKind(UrDecodeErrorKind.limitExceeded),
    );
  });

  test('decode guards classify unexpected failures and preserve typed errors', () {
    expect(
      () => guardDecode<void>('test', () => throw StateError('bad input')),
      throwsKind(UrDecodeErrorKind.malformed),
    );
    final error = UrDecodeException('diagnostic', kind: UrDecodeErrorKind.limitExceeded);
    expect(() => guardDecode<void>('test', () => throw error), throwsA(same(error)));
  });
}
