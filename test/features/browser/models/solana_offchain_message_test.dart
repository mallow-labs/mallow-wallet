import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/solana_offchain_message.dart';
import 'package:solana/base58.dart';

Uint8List _key(String address) => Uint8List.fromList(base58decode(address));

void main() {
  const system = '11111111111111111111111111111111';
  const wsol = 'So11111111111111111111111111111111111111112';
  const token = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';

  // Encoded by `getOffchainMessageV1Encoder` from @solana/offchain-messages
  // 8.5.0, the reference codec verifiers use.
  const multiSignerVector =
      '/3NvbGFuYSBvZmZjaGFpbgEDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGm4hX'
      '/quBhPtof2NGGMA12sQ53BrrO1WYoPAAAAAAAQbd9uHXZaGT2cvhRs7reawctIXtX1s3kTqM'
      '9YV+/wCpaMOpbGxvIOKckwpsaW5lMg==';
  const singleSignerVector =
      '/3NvbGFuYSBvZmZjaGFpbgEBBpuIV/6rgYT7aH9jRhjANdrEOdwa6ztVmKDwAAAAAAFTaWdu'
      'IGluIHRvIGV4YW1wbGUuY29t';

  test('builds the bytes the reference codec does, sorting the signers', () {
    final multi = SolanaOffchainMessage.build(
      content: 'héllo ✓\nline2',
      requiredSigners: [_key(token), _key(wsol), _key(system)],
    );
    expect(base64Encode(multi.bytes), multiSignerVector);
    expect(multi.signers, [system, wsol, token]);

    final single = SolanaOffchainMessage.build(
      content: 'Sign in to example.com',
      requiredSigners: [_key(wsol)],
    );
    expect(base64Encode(single.bytes), singleSignerVector);
  });

  test('parses what it builds, and nothing else', () {
    final parsed = SolanaOffchainMessage.parse(base64Decode(multiSignerVector));
    expect(parsed.content, 'héllo ✓\nline2');
    expect(parsed.signers, [system, wsol, token]);

    final good = base64Decode(singleSignerVector);
    Uint8List mutate(void Function(Uint8List bytes) change) {
      final copy = Uint8List.fromList(good);
      change(copy);
      return copy;
    }

    for (final (reason, bytes) in [
      ('wrong domain', mutate((b) => b[0] = 0xfe)),
      ('version 0', mutate((b) => b[16] = 0)),
      ('no signers', mutate((b) => b[17] = 0)),
      ('signers overrun the body', mutate((b) => b[17] = 2)),
      ('no content', Uint8List.sublistView(good, 0, 18 + 32)),
      (
        'malformed UTF-8',
        Uint8List.fromList([...Uint8List.sublistView(good, 0, 50), 0xc3]),
      ),
    ]) {
      expect(
        () => SolanaOffchainMessage.parse(bytes),
        throwsFormatException,
        reason: reason,
      );
    }

    // Unsorted signers are not canonical.
    final unsorted = BytesBuilder()
      ..add(solanaOffchainSigningDomain)
      ..add([1, 2])
      ..add(_key(wsol))
      ..add(_key(system))
      ..add(utf8.encode('hi'));
    expect(
      () => SolanaOffchainMessage.parse(unsorted.toBytes()),
      throwsFormatException,
    );
  });

  test('refuses inputs that make no valid message', () {
    void refuses(String content, List<Uint8List> signers, String reason) =>
        expect(
          () => SolanaOffchainMessage.build(
            content: content,
            requiredSigners: signers,
          ),
          throwsFormatException,
          reason: reason,
        );

    refuses('', [_key(wsol)], 'empty content');
    refuses('hi', const [], 'no signers');
    refuses('hi', [_key(wsol), _key(wsol)], 'duplicate signer');
    refuses('hi', [Uint8List(31)], 'short key');
    refuses('x' * (kMaxSolanaOffchainContent + 1), [_key(wsol)], 'too large');
  });

  test('can never be read as a transaction', () {
    final message = SolanaOffchainMessage.build(
      content: 'hi',
      requiredSigners: [_key(wsol)],
    );
    expect(message.bytes.first, 0xff);
  });
}
