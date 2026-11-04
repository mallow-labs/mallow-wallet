import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/services/browser_data_clearer.dart';

void main() {
  test(
    'ordinary clear reports failures and still attempts every owner',
    () async {
      final calls = <String>[];
      final clearer = BrowserDataClearer(
        clearSession: (keepBookmarks) async {
          calls.add('session:$keepBookmarks');
          throw StateError('write failed');
        },
        resetSession: () async => calls.add('reset'),
        clearMetadata: () async => calls.add('metadata'),
        clearReceipts: () async => calls.add('receipts'),
        clearGrants: () async => calls.add('grants'),
        clearLookupTables: () async => calls.add('lookup_tables'),
        clearCookies: () async => calls.add('cookies'),
        clearCache: () async => calls.add('cache'),
        clearSiteIcons: () async => calls.add('site_icons'),
        clearSiteStorage: () async => calls.add('site_storage'),
        clearCertificates: () async => calls.add('certificates'),
        clearHttpAuth: () async {
          calls.add('http_auth');
          throw StateError('delete failed');
        },
        clearPlatformHttpAuth: () async => calls.add('platform_http_auth'),
      );

      final failures = await clearer.clearBrowsingData(keepBookmarks: true);

      expect(failures.map((failure) => failure.step), ['session', 'http_auth']);
      expect(calls, [
        'session:true',
        'receipts',
        'grants',
        'lookup_tables',
        'cookies',
        'cache',
        'site_icons',
        'site_storage',
        'certificates',
        'http_auth',
        'platform_http_auth',
      ]);
    },
  );

  test(
    'app reset uses reset and metadata paths without loading a session',
    () async {
      final calls = <String>[];
      final clearer = BrowserDataClearer(
        clearSession: (_) async => calls.add('load_session'),
        resetSession: () async => calls.add('reset'),
        clearMetadata: () async => calls.add('metadata'),
        clearReceipts: () async => calls.add('receipts'),
        clearGrants: () async => calls.add('grants'),
        clearLookupTables: () async => calls.add('lookup_tables'),
        clearCookies: () async => calls.add('cookies'),
        clearCache: () async => calls.add('cache'),
        clearSiteIcons: () async => calls.add('site_icons'),
        clearSiteStorage: () async => calls.add('site_storage'),
        clearCertificates: () async => calls.add('certificates'),
        clearHttpAuth: () async => calls.add('http_auth'),
        clearPlatformHttpAuth: () async => calls.add('platform_http_auth'),
      );

      final failures = await clearer.clearForAppReset();

      expect(failures, isEmpty);
      expect(calls, [
        'reset',
        'metadata',
        'receipts',
        'grants',
        'lookup_tables',
        'cookies',
        'cache',
        'site_icons',
        'site_storage',
        'certificates',
        'http_auth',
        'platform_http_auth',
      ]);
      expect(calls, isNot(contains('load_session')));
    },
  );
}
