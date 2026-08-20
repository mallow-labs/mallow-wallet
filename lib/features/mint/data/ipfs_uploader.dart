import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';

import '../../../core/config/environment.dart';
import '../../../core/network/logging_interceptor.dart';

/// Uploads NFT media + metadata JSON to the IPFS pinning service configured by
/// [Config.ipfsUploadUrl].
///
/// Authenticates with [Config.clientIdHeadersFor], the same way every other
/// first-party route does — the uploader carries no key of its own. The upload
/// host is fixed per instance, so the gate is applied once here rather than
/// per request; a deployment running its own pinner must list that host in
/// `FIRST_PARTY_HOSTS` or the header is withheld. Returns the pinned CID
/// (`hash`).
@lazySingleton
class IpfsUploader {
  IpfsUploader()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(minutes: 5),
          receiveTimeout: const Duration(minutes: 5),
          headers: {
            ...Config.clientIdHeadersFor(Uri.parse(Config.ipfsUploadUrl)),
          },
        ),
      )..interceptors.add(PrettyLoggingInterceptor());

  /// Test seam: inject a [Dio] whose adapter the caller controls.
  @visibleForTesting
  IpfsUploader.forTest(this._dio);

  final Dio _dio;

  /// Upload raw [bytes] as a multipart file and return the IPFS hash.
  ///
  /// [fileName] is only used for the Content-Disposition part; the
  /// server-side pin uses the CID regardless.
  Future<String> uploadBytes({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: fileName,
        contentType: mimeType != null ? _parseContentType(mimeType) : null,
      ),
    });

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        Config.ipfsUploadUrl,
        data: formData,
        options: Options(responseType: ResponseType.json),
      );

      final data = response.data;
      final hash = data?['hash'] ?? data?['Hash'] ?? data?['cid'];
      if (hash is! String || hash.isEmpty) {
        throw IpfsUploadException(
          'Unexpected upload response: ${response.statusCode} ${response.data}',
        );
      }
      return hash;
    } on DioException catch (e) {
      throw IpfsUploadException(
        'IPFS upload failed: ${e.response?.statusCode} '
        '${e.response?.data ?? e.message} '
        '(env=${Config.environment.name})',
      );
    }
  }

  /// Upload a JSON-encodable [payload] as a file named [fileName]. Returns
  /// the IPFS hash. Convenience wrapper around [uploadBytes].
  Future<String> uploadJson({
    required Map<String, dynamic> payload,
    String fileName = 'metadata.json',
  }) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    return uploadBytes(
      bytes: bytes,
      fileName: fileName,
      mimeType: 'application/json',
    );
  }

  /// Gateway host written into minted metadata. `ipfs.io`, always — see
  /// [gatewayUrl].
  static const String _metadataGatewayOrigin = 'https://ipfs.io';

  /// Returns the gateway URL for a pinned hash, for use as an NFT's `image` /
  /// `animation_url` / metadata `uri`.
  ///
  /// 🛑 **Deliberately a constant, not configuration.** This URL is written
  /// into the token's metadata, so it goes on-chain and outlives the build, the
  /// deployment and this repository — every marketplace and wallet that ever
  /// reads that token resolves it, not just this app. Two consequences:
  ///
  ///  * It must be a gateway that resolves **any** CID from the public DHT, so
  ///    the bytes stay reachable if this deployment's own gateway is ever
  ///    retired. A first-party host here would strand every NFT minted by this
  ///    build on the day that host goes away.
  ///  * It must match what the web client writes (`toIpfsUri`), or the same
  ///    artwork minted from the two clients carries two different URLs forever.
  ///
  /// Neither is a property a build variable should be able to get wrong, which
  /// is why there is no variable.
  String gatewayUrl(String hash) => '$_metadataGatewayOrigin/ipfs/$hash';

  static DioMediaType _parseContentType(String raw) {
    final parts = raw.split('/');
    if (parts.length != 2) {
      return DioMediaType('application', 'octet-stream');
    }
    return DioMediaType(parts[0], parts[1]);
  }
}

class IpfsUploadException implements Exception {
  IpfsUploadException(this.message);
  final String message;

  @override
  String toString() => 'IpfsUploadException: $message';
}
