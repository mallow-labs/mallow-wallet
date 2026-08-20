import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the FormData-rewind fix in `_SignatureRetryInterceptor`/
/// `_handleLoginRetry`: when a 401 triggers a Ledger/HD signature refresh, the
/// original multipart request (e.g. an `uploadUnlockableContent` asset) is
/// re-sent. Dio's [FormData] is single-use — its byte stream is finalized on
/// the first send — so the retry MUST swap in `clone()`. If someone drops the
/// clone, the first assertion documents the failure mode and the second proves
/// the clone is the fix.
void main() {
  // Mirrors how a multipart upload builds its body: a
  // `MultipartFile.fromBytes` part inside a FormData.
  FormData buildMultipartBody() => FormData.fromMap({
    'fileName': 'asset.png',
    'assetFile': MultipartFile.fromBytes(
      Uint8List.fromList(List<int>.generate(64, (i) => i)),
      filename: 'asset.png',
    ),
  });

  test('a FormData cannot be sent twice — second finalize throws', () async {
    final body = buildMultipartBody();

    // First send drains/finalizes the stream.
    await body.finalize().drain<void>();

    expect(
      () => body.finalize(),
      throwsA(isA<StateError>()),
      reason: 'this is the "FormData has already been finalized" crash',
    );
  });

  test('clone() yields a re-sendable body with identical bytes', () async {
    final body = buildMultipartBody();

    final firstBytes = await _collect(body.finalize());
    // Clone AFTER the original was finalized — exactly what the retry does.
    final retryBytes = await _collect(body.clone().finalize());

    expect(retryBytes, firstBytes, reason: 'retry must send the same payload');
    expect(retryBytes, isNotEmpty);
  });
}

Future<List<int>> _collect(Stream<Uint8List> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}
