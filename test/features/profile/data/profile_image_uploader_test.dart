import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/profile/data/profile_image_uploader.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'profile_image_uploader_test.mocks.dart';

/// Guards the S3 leg of the presigned profile-image upload. Everything here is
/// a rule S3 enforces silently — a policy field dropped or reordered comes back
/// as an opaque 403, and a mime type that disagrees with the signature is
/// rejected after the whole file has already been sent.
@GenerateMocks([api.MallowApiClient])
void main() {
  late MockMallowApiClient apiClient;
  late Dio dio;
  late _RecordingAdapter adapter;
  late ProfileImageUploader uploader;

  const presigned = api.CreateProfileUploadResponse(
    url: 'https://cdn-bucket.s3.amazonaws.com/',
    fields: {
      'key': 'images/pfp/ADDR/1700000000',
      'Content-Type': 'image/png',
      'Policy': 'eyJ...',
      'X-Amz-Signature': 'deadbeef',
    },
    path: 'pfp/ADDR/1700000000',
  );

  // A 1x1 PNG is below the resize threshold, so the picked bytes upload as-is
  // and the assertions below stay about the S3 contract, not the encoder.
  final pngBytes = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    ),
  );

  setUpAll(() {
    provideDummy<api.ApiResponse<api.CreateProfileUploadResponse>>(
      const api.ApiResponse(result: presigned),
    );
  });

  setUp(() {
    apiClient = MockMallowApiClient();
    adapter = _RecordingAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    uploader = ProfileImageUploader.withDio(apiClient, dio);
    when(
      apiClient.createProfileUpload(any),
    ).thenAnswer((_) async => const api.ApiResponse(result: presigned));
  });

  Future<String> upload({
    api.CreateProfileUploadRequestType type =
        api.CreateProfileUploadRequestType.pfp,
  }) => uploader.upload(bytes: pngBytes, fileName: 'avatar.png', type: type);

  test(
    'presigns for the type and mime type of what actually uploads',
    () async {
      await upload(type: api.CreateProfileUploadRequestType.banner);

      final request =
          verify(apiClient.createProfileUpload(captureAny)).captured.single
              as api.CreateProfileUploadRequest;
      expect(request.type, api.CreateProfileUploadRequestType.banner);
      // Signed as an exact-match condition — a lie here fails the upload at S3.
      expect(request.mimeType, 'image/png');
    },
  );

  test('posts the file to S3, not to the API', () async {
    await upload();

    expect(adapter.lastRequest?.path, presigned.url);
    expect(adapter.lastRequest?.method, 'POST');
    // No mallow auth interceptors, so no session cookie rides along to a
    // third-party host.
    expect(adapter.lastRequest?.headers.containsKey('Cookie'), isFalse);
  });

  test('sends every signed field, ahead of the file part', () async {
    await upload();

    final body = utf8.decode(adapter.lastBody!, allowMalformed: true);
    for (final entry in presigned.fields.entries) {
      expect(
        body,
        contains('name="${entry.key}"'),
        reason: 'S3 rejects the POST when a policy field is missing',
      );
      expect(body, contains(entry.value as String));
    }
    // S3 ignores every part after the file, so the file has to be last.
    expect(
      body.indexOf('name="file"'),
      greaterThan(body.indexOf('name="X-Amz-Signature"')),
    );
  });

  test('returns the presigned path for updateProfile to store', () async {
    expect(await upload(), presigned.path);
  });

  test('a file that resolves to no image type never reaches S3', () async {
    // Neither magic number nor extension resolves, and the bytes don't decode
    // so the re-encode can't rewrite the type to `image/webp`. Presigning this
    // as `application/octet-stream` is signing for a type the backend
    // whitelist rejects — the user would get that raw 400 scraped for its
    // `message` instead of copy they can act on.
    await expectLater(
      uploader.upload(
        bytes: Uint8List.fromList(const [0, 1, 2, 3, 4, 5, 6, 7]),
        fileName: 'avatar',
        type: api.CreateProfileUploadRequestType.pfp,
      ),
      throwsA(
        isA<ProfileImageUploadException>().having(
          (e) => e.message,
          'message',
          contains('not a recognized image'),
        ),
      ),
    );
    verifyNever(apiClient.createProfileUpload(any));
    expect(adapter.lastRequest, isNull);
  });

  test('an S3 rejection surfaces as a readable failure', () async {
    adapter.statusCode = 403;

    await expectLater(
      upload(),
      throwsA(
        isA<ProfileImageUploadException>().having(
          (e) => e.message,
          'message',
          contains('403'),
        ),
      ),
    );
  });
}

/// Captures the request Dio would have put on the wire and answers with a
/// bodyless 204 — what a successful presigned POST returns.
class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;
  List<int>? lastBody;
  int statusCode = 204;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    lastBody = requestStream == null
        ? null
        : (await requestStream.toList()).expand((c) => c).toList();
    return ResponseBody.fromString('', statusCode);
  }

  @override
  void close({bool force = false}) {}
}
