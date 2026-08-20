import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../config/environment.dart';

/// Subset of rewards-store product metadata used in activity / token history
/// rows. Mirrors the webapp's `StoreProductMetadata` shape (see
/// `storeProductMetadata`) but only keeps
/// the fields the wallet displays today.
class RewardsStoreProduct {
  const RewardsStoreProduct({
    required this.sku,
    required this.name,
    required this.image,
  });

  factory RewardsStoreProduct.fromJson(String sku, Map<String, dynamic> json) {
    return RewardsStoreProduct(
      sku: sku,
      name: (json['name'] as String?) ?? sku,
      image: (json['image'] as String?) ?? '',
    );
  }

  final String sku;
  final String name;
  final String image;
}

/// In-memory cache for rewards-store metadata, fetched from the CDN at
/// `${Config.storeCdnBaseUrl}/{sku}.json`.
///
/// Mirrors the webapp's `["storeProductMetadata", sku]` React Query cache:
/// each SKU is fetched at most once per app session, concurrent callers share
/// the same in-flight future, and failures are sticky-cached as `null` so
/// scroll thrash doesn't refetch a 404.
///
/// Use [looksLikeSku] to gate the lookup — the backend stamps rewards-item
/// SKUs into the `mint` slot of activity rows, distinguishable by the `.`
/// separator (e.g. `merch.shirt.skitchism`).
@lazySingleton
class RewardsStoreService {
  RewardsStoreService(this._dio);

  final Dio _dio;

  final Map<String, RewardsStoreProduct?> _cache = {};
  final Map<String, Future<RewardsStoreProduct?>> _inFlight = {};

  /// SKU detector — rewards SKUs use a dotted namespace (`merch.shirt.foo`),
  /// while Solana mint addresses are base58 and never contain `.`.
  static bool looksLikeSku(String? value) =>
      value != null && value.contains('.');

  /// Synchronous accessor — returns the cached product if already fetched, or
  /// `null` if unknown / not yet fetched / known-missing.
  RewardsStoreProduct? cached(String sku) => _cache[sku];

  /// Fetches (or returns cached) metadata for [sku]. Returns `null` when the
  /// CDN has no entry for this SKU; the negative result is cached too.
  Future<RewardsStoreProduct?> getBySku(String sku) {
    if (_cache.containsKey(sku)) return Future.value(_cache[sku]);
    final existing = _inFlight[sku];
    if (existing != null) return existing;
    // NB: a block body, not `() => _inFlight.remove(sku)`. `remove` returns the
    // very future this callback is attached to, and whenComplete awaits a
    // returned future — an arrow body would make it wait on itself and
    // deadlock, so getBySku would never complete.
    final future = _fetch(sku).whenComplete(() {
      _inFlight.remove(sku);
    });
    _inFlight[sku] = future;
    return future;
  }

  Future<RewardsStoreProduct?> _fetch(String sku) async {
    // No CDN configured means no store metadata — never a relative path. This
    // Dio is the shared client whose base URL is the API host and whose
    // interceptors attach the client-id, api-key and app-version headers, so
    // `/$sku.json` would send a credentialed GET to the backend, once per SKU,
    // for a route it does not serve.
    final base = Config.storeCdnBaseUrl;
    if (base.isEmpty) return null;
    final url = '$base/$sku.json';
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        url,
        options: Options(responseType: ResponseType.json),
      );
      final data = response.data;
      if (data == null) {
        _cache[sku] = null;
        return null;
      }
      final product = RewardsStoreProduct.fromJson(sku, data);
      _cache[sku] = product;
      return product;
    } catch (e) {
      debugPrint('[RewardsStoreService] fetch failed for $sku: $e');
      _cache[sku] = null;
      return null;
    }
  }
}
