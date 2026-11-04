import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/security/secure_storage.dart';
import '../../../di.dart';
import '../../../shared/widgets/mallow_image_cache_manager.dart';
import 'browser_certificate_exceptions.dart';
import 'browser_http_auth_service.dart';
import 'browser_services.dart';
import 'browser_session.dart';
import 'browser_transaction_tracker.dart';
import 'solana_lookup_table_cache.dart';
import 'tezos_beacon_transport.dart';

class BrowserDataClearFailure {
  const BrowserDataClearFailure(this.step, this.errorType);

  final String step;
  final String errorType;
}

typedef BrowserSessionClearAction = Future<void> Function(bool keepBookmarks);

/// Clears every process and platform owner of browser data. Each owner is
/// attempted independently so one platform failure cannot leave the other
/// stores untouched.
class BrowserDataClearer {
  BrowserDataClearer({
    required BrowserSessionClearAction clearSession,
    required Future<void> Function() resetSession,
    required Future<void> Function() clearMetadata,
    required Future<void> Function() clearReceipts,
    required Future<void> Function() clearGrants,
    Future<void> Function()? clearBeacon,
    Future<void> Function()? clearLookupTables,
    required Future<void> Function() clearCookies,
    required Future<void> Function() clearCache,
    required Future<void> Function() clearSiteIcons,
    required Future<void> Function() clearSiteStorage,
    required Future<void> Function() clearCertificates,
    required Future<void> Function() clearHttpAuth,
    required Future<void> Function() clearPlatformHttpAuth,
  }) : _clearSession = clearSession,
       _resetSession = resetSession,
       _clearMetadata = clearMetadata,
       _clearReceipts = clearReceipts,
       _clearGrants = clearGrants,
       _clearBeacon = clearBeacon ?? _nothing,
       _clearLookupTables = clearLookupTables ?? _nothing,
       _clearCookies = clearCookies,
       _clearCache = clearCache,
       _clearSiteIcons = clearSiteIcons,
       _clearSiteStorage = clearSiteStorage,
       _clearCertificates = clearCertificates,
       _clearHttpAuth = clearHttpAuth,
       _clearPlatformHttpAuth = clearPlatformHttpAuth;

  factory BrowserDataClearer.platform() => BrowserDataClearer(
    clearSession: (keepBookmarks) =>
        BrowserSession.instance.clearAndFlush(keepBookmarks: keepBookmarks),
    resetSession: BrowserSession.resetForAppWipe,
    clearMetadata: () => sl<SecureWalletStorage>().deleteBrowserMetadata(),
    clearReceipts: () async => BrowserTransactionTracker.instance.clear(),
    clearGrants: browserPermissions.clear,
    clearBeacon: TezosBeaconTransport.instance.clear,
    // Which tables a wallet used says which programs it called.
    clearLookupTables: SolanaLookupTableCache.instance.clear,
    clearCookies: () async {
      // False means there were no cookies to remove, not that deletion failed.
      await CookieManager.instance().deleteAllCookies();
    },
    clearCache: InAppWebViewController.clearAllCache,
    // Icons are cached by the URL of each site shown, a visit list that
    // would otherwise outlive the clear.
    clearSiteIcons: MallowImageCacheManager.browserSiteIcons.emptyCache,
    clearSiteStorage: () => Platform.isIOS
        ? WebStorageManager.instance().removeDataModifiedSince(
            dataTypes: WebsiteDataType.ALL,
            date: DateTime.fromMillisecondsSinceEpoch(0),
          )
        : WebStorageManager.instance().deleteAllData(),
    clearCertificates: BrowserCertificateExceptions.instance.clear,
    clearHttpAuth: BrowserHttpAuthService.instance.clear,
    clearPlatformHttpAuth: () =>
        HttpAuthCredentialDatabase.instance().clearAllAuthCredentials(),
  );

  final BrowserSessionClearAction _clearSession;
  final Future<void> Function() _resetSession;
  final Future<void> Function() _clearMetadata;
  final Future<void> Function() _clearReceipts;
  final Future<void> Function() _clearGrants;
  final Future<void> Function() _clearBeacon;
  final Future<void> Function() _clearLookupTables;
  static Future<void> _nothing() async {}
  final Future<void> Function() _clearCookies;
  final Future<void> Function() _clearCache;
  final Future<void> Function() _clearSiteIcons;
  final Future<void> Function() _clearSiteStorage;
  final Future<void> Function() _clearCertificates;
  final Future<void> Function() _clearHttpAuth;
  final Future<void> Function() _clearPlatformHttpAuth;

  Future<List<BrowserDataClearFailure>> clearBrowsingData({
    required bool keepBookmarks,
  }) => _clear([
    ('session', () => _clearSession(keepBookmarks)),
    ('receipts', _clearReceipts),
    ('grants', _clearGrants),
    ('beacon', _clearBeacon),
    ('lookup_tables', _clearLookupTables),
    ('cookies', _clearCookies),
    ('cache', _clearCache),
    ('site_icons', _clearSiteIcons),
    ('site_storage', _clearSiteStorage),
    ('certificates', _clearCertificates),
    ('http_auth', _clearHttpAuth),
    ('platform_http_auth', _clearPlatformHttpAuth),
  ]);

  /// Clears browser state during an app reset without loading or constructing
  /// a session that has never been opened.
  Future<List<BrowserDataClearFailure>> clearForAppReset() => _clear([
    ('session', _resetSession),
    ('metadata', _clearMetadata),
    ('receipts', _clearReceipts),
    ('grants', _clearGrants),
    ('beacon', _clearBeacon),
    ('lookup_tables', _clearLookupTables),
    ('cookies', _clearCookies),
    ('cache', _clearCache),
    ('site_icons', _clearSiteIcons),
    ('site_storage', _clearSiteStorage),
    ('certificates', _clearCertificates),
    ('http_auth', _clearHttpAuth),
    ('platform_http_auth', _clearPlatformHttpAuth),
  ]);

  Future<List<BrowserDataClearFailure>> _clear(
    List<(String, Future<void> Function())> steps,
  ) async {
    final failures = <BrowserDataClearFailure>[];
    for (final (name, clear) in steps) {
      try {
        await clear();
      } catch (error) {
        failures.add(
          BrowserDataClearFailure(name, error.runtimeType.toString()),
        );
      }
    }
    return failures;
  }
}
