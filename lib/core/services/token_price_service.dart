import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';

import '../data/mallow_tokens.dart';

/// In-memory cache of mint → USD price, refreshed on a 5-minute timer.
///
/// Mirrors the webapp's `useReferenceData` query (`/v0/getTokenPrices`,
/// 5-minute `refetchInterval`) so listing prices can render a live USD
/// equivalent without each call site fetching its own copy.
///
/// [prices] is a [ValueListenable] so widgets can rebuild reactively when
/// the first fetch lands or a refresh comes in. Use [usdValueOfRaw] to
/// convert an on-chain (atomic) amount in a given mint to USD.
@lazySingleton
class TokenPriceService {
  TokenPriceService(this._api);

  final MallowApiClient _api;

  static const _refreshInterval = Duration(minutes: 5);

  final ValueNotifier<Map<String, double>> _prices = ValueNotifier(const {});

  Timer? _refreshTimer;
  Future<void>? _inFlight;

  ValueListenable<Map<String, double>> get prices => _prices;

  /// USD price for [mint], or null if unknown/not yet fetched.
  double? priceOf(String? mint) => mint == null ? null : _prices.value[mint];

  /// Convert a raw on-chain amount in [mint]'s smallest unit to USD.
  /// Returns null when the price isn't cached yet or the mint is unknown.
  double? usdValueOfRaw(num? rawAmount, String? mint) {
    if (rawAmount == null) return null;
    final price = priceOf(mint);
    if (price == null) return null;
    final token = tokenByMint(mint);
    final decimals = token?.decimals ?? 9;
    return rawAmount.toDouble() / pow(10, decimals) * price;
  }

  /// Kick off the initial fetch + schedule periodic refreshes. Safe to call
  /// multiple times — subsequent calls are no-ops.
  void start() {
    if (_refreshTimer != null) return;
    _refresh();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  Future<void> _refresh() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _fetch().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<void> _fetch() async {
    try {
      final response = await _api.getTokenPrices();
      _prices.value = Map.unmodifiable(response.result.usdByMint);
    } catch (e) {
      // Price data is best-effort — failures shouldn't disrupt the UI. Keep
      // any previous cache value so an intermittent network hiccup doesn't
      // wipe a working USD display.
      debugPrint('[TokenPriceService] price fetch failed: $e');
    }
  }

  @disposeMethod
  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _prices.dispose();
  }
}
