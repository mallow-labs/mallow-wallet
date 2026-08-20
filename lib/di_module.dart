import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_api/mallow_api.dart';

import 'core/config/environment.dart';
import 'core/network/api_base_url_interceptor.dart';
import 'core/network/api_key_interceptor.dart';
import 'core/network/app_version_interceptor.dart';
import 'core/network/client_id_interceptor.dart';
import 'core/network/logging_interceptor.dart';
import 'core/network/parse_error_logger.dart';
import 'core/services/preferences_service.dart';
import 'features/cast/services/airplay_cast_service.dart';
import 'features/cast/services/cast_bloc.dart';
import 'features/cast/services/cast_service.dart';
import 'features/cast/services/chromecast_cast_service.dart';
import 'features/cast/services/ios_chromecast_cast_service.dart';
import 'features/cast/services/local_cast_service.dart';
import 'features/cast/services/multi_cast_service.dart';

/// Dependency injection module for external dependencies.
///
/// This module provides instances that cannot be auto-injected
/// by injectable (third-party packages, platform-specific implementations).
@module
abstract class RegisterModule {
  /// Provides FlutterSecureStorage instance.
  @lazySingleton
  FlutterSecureStorage get secureStorage => const FlutterSecureStorage();

  /// Provides Dio HTTP client with base configuration.
  @lazySingleton
  Dio get dio {
    // The only hosts this client may send build-identifying request headers to
    // (client-id, App-Version). Deliberately NOT the set the session-cookie
    // interceptor uses: AuthService gates those on Config.sessionHosts, which
    // is the derived API hosts only and cannot be widened by build config.
    final mallowHosts = Config.firstPartyHosts;

    final dio = Dio(
      BaseOptions(
        baseUrl: Config.apiBaseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ),
    );

    // Identify the build to the backend. Host-guarded rather than set in
    // BaseOptions: this header stands in for an API key on the open /v2
    // routes, and this shared Dio also carries third-party traffic (Jupiter
    // token search, the rewards CDN) that must not receive it.
    // First in the chain on purpose: an unconfigured build should fail on the
    // missing variable, before any credential is attached to a request that was
    // never going to resolve anywhere.
    dio.interceptors.add(const ApiBaseUrlInterceptor());

    dio.interceptors.add(ClientIdInterceptor(mallowHosts: mallowHosts));

    // Authenticate against a mallow-operated backend when the build carries a
    // MALLOW_API_KEY. Deliberately NOT given `mallowHosts`: it gates itself on
    // Config.sessionHosts (the derived API hosts, which build config cannot
    // widen), because unlike the client-id header this key is spendable.
    dio.interceptors.add(ApiKeyInterceptor());

    // Send the App-Version header on backend requests. Host-guarded to the
    // v1/v2 API hosts so it never leaks to the cross-origin traffic this
    // shared Dio also serves (e.g. the rewards CDN, or any request-level URL
    // override to a third party).
    dio.interceptors.add(AppVersionInterceptor(mallowHosts: mallowHosts));

    // Add pretty logging interceptor (only logs in debug mode)
    dio.interceptors.add(PrettyLoggingInterceptor());

    return dio;
  }

  /// Provides MallowApiClient instance.
  ///
  /// Takes Dio as a parameter so injectable injects the DI singleton
  /// rather than calling the dio getter directly (which would create
  /// a separate instance).
  @lazySingleton
  MallowApiClient mallowApi(Dio dio) => MallowApiClient(
    dio,
    baseUrl: Config.apiBaseUrl,
    errorLogger: const NetworkParseErrorLogger(),
  );

  /// Provides MallowApiV2Client instance routed at [Config.apiV2BaseUrl]
  /// (which already includes the `/v2` segment). Used for routes under
  /// `/v2/tx/*` which in dev are served by a separate `:8090` process.
  @lazySingleton
  MallowApiV2Client mallowApiV2(Dio dio) => MallowApiV2Client(
    dio,
    baseUrl: Config.apiV2BaseUrl,
    errorLogger: const NetworkParseErrorLogger(),
  );

  /// Ultra Jupiter API (`/ultra/v1`). The base URL is passed explicitly rather
  /// than left to the package default so all three Jupiter clients follow the
  /// one `JUPITER_BASE_URL` override together.
  @lazySingleton
  JupiterAggregatorClient get jupiterClient =>
      JupiterAggregatorClient(baseUrl: '${Config.jupiterBaseUrl}/ultra/v1');

  @lazySingleton
  JupiterPriceClient get jupiterPriceClient =>
      JupiterPriceClient(baseUrl: '${Config.jupiterBaseUrl}/');

  /// Classic Jupiter swap API (`/swap/v1`) — used by staking to compose its
  /// own v0 transaction (swap-instructions + fee marker), unlike the Ultra
  /// client above which returns pre-compiled transactions.
  @lazySingleton
  JupiterSwapInstructionsClient get jupiterSwapInstructionsClient =>
      JupiterSwapInstructionsClient(
        baseUrl: '${Config.jupiterBaseUrl}/swap/v1',
      );

  /// Cast service — platform-dispatched:
  ///   Android → ChromecastCastService
  ///   iOS     → MultiCastService([AirPlay, Chromecast]) — picker shows both
  ///   Other   → LocalCastService (macOS dev / testing)
  @lazySingleton
  CastService castService() {
    if (Platform.isAndroid) return ChromecastCastService();
    if (Platform.isIOS) {
      return MultiCastService([
        AirPlayCastService(),
        IosChromecastCastService(),
      ]);
    }
    return LocalCastService();
  }

  /// Global cast bloc — singleton so the "Now Casting" bar persists across routes.
  @lazySingleton
  CastBloc castBloc(CastService castService, PreferencesService prefs) =>
      CastBloc(castService, prefs);

  /// PreferencesService — requires async init via SharedPreferences.
  /// `@preResolve` makes injectable await the future during `configureDependencies()`.
  @preResolve
  @singleton
  Future<PreferencesService> preferencesService() =>
      PreferencesService.create();
}
