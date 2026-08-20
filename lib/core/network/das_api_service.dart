import 'package:dio/dio.dart';
import 'package:injectable/injectable.dart';

import '../config/environment.dart';
import '../../features/artwork/models/on_chain_asset.dart';

/// Service for querying the DAS (Digital Asset Standard) API.
///
/// Uses a dedicated Dio instance that talks to the RPC proxy (separate from
/// the main API client). The proxy fronts the DAS provider and identifies the
/// caller with [Config.clientIdHeadersFor] — this Dio has no interceptor
/// chain, so the header is host-gated once here against the endpoint every
/// method below posts to. It is withheld unless that host is configured
/// first-party, because the same setting can point at a public DAS provider.
@lazySingleton
class DasApiService {
  DasApiService()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'Content-Type': 'application/json',
            ...Config.clientIdHeadersFor(Uri.parse(Config.solanaRpcUrl)),
          },
        ),
      );

  final Dio _dio;

  /// Fetch on-chain asset data for [mintAccount] via the DAS getAsset method.
  ///
  /// Throws on network error or if the RPC response contains an error field.
  Future<DigitalAsset> getAsset(String mintAccount) async =>
      DigitalAsset.fromJson(await getAssetRaw(mintAccount));

  /// The unparsed DAS `getAsset` result object.
  ///
  /// [DigitalAsset] models the NFT-shaped fields only; fungible mints carry
  /// their symbol/decimals under `token_info`, which no model covers. Rather
  /// than widen [DigitalAsset] with fields every NFT caller would ignore, the
  /// token-metadata lookup reads the raw map through here so the JSON-RPC
  /// envelope, proxy headers and error handling stay in one place.
  ///
  /// Throws on network error or if the RPC response contains an error field.
  Future<Map<String, dynamic>> getAssetRaw(String mintAccount) async {
    final response = await _dio.post<Map<String, dynamic>>(
      Config.solanaRpcUrl,
      data: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'getAsset',
        'params': {'id': mintAccount},
      },
    );

    final body = response.data!;
    if (body.containsKey('error')) {
      throw Exception('DAS getAsset error: ${body['error']}');
    }

    return body['result'] as Map<String, dynamic>;
  }

  /// Fetch on-chain data for up to 1000 mints in one DAS getAssetBatch call.
  /// Unknown mints come back as null from the RPC and are dropped; assets
  /// that fail to parse are dropped too (bulk callers tolerate gaps).
  ///
  /// Throws on network error or if the RPC response contains an error field.
  Future<List<DigitalAsset>> getAssetBatch(List<String> mintAccounts) async {
    if (mintAccounts.isEmpty) return const [];
    final response = await _dio.post<Map<String, dynamic>>(
      Config.solanaRpcUrl,
      data: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'getAssetBatch',
        'params': {'ids': mintAccounts},
      },
    );

    final body = response.data!;
    if (body.containsKey('error')) {
      throw Exception('DAS getAssetBatch error: ${body['error']}');
    }

    final result = (body['result'] as List<dynamic>?) ?? const [];
    final assets = <DigitalAsset>[];
    for (final item in result) {
      if (item is! Map<String, dynamic>) continue;
      try {
        assets.add(DigitalAsset.fromJson(item));
      } catch (_) {
        // Skip malformed entries — one bad asset never fails the batch.
      }
    }
    return assets;
  }
}
