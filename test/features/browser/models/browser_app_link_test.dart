import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/services/deep_link_service.dart';
import 'package:mallow_wallet/features/browser/models/browser_app_link.dart';

void main() {
  const web = 'https://example.com/drop/abc?ref=page';
  final encoded = Uri.encodeComponent(web);

  Uri? read(String raw) => browserAppLink(Uri.parse(raw));

  group('browserAppLink', () {
    test('passes a link in the app scheme through unchanged', () {
      final raw = 'mallowwallet://open?url=$encoded';
      expect(read(raw), Uri.parse(raw));
      expect(read(raw)!.queryParameters['url'], web);
    });

    test('reads the Android intent form as the plain link', () {
      final fallback = Uri.encodeComponent(
        'https://play.google.com/store/apps/details?id=x',
      );
      final link = read(
        'intent://open?url=$encoded'
        '#Intent;scheme=mallowwallet;S.browser_fallback_url=$fallback;end',
      );
      expect(link, Uri.parse('mallowwallet://open?url=$encoded'));
      expect(link!.queryParameters['url'], web);
    });

    test('keeps a path-only link the route map understands', () {
      final link = read('mallowwallet:///artwork/abc123');
      expect(link, isNotNull);
      expect(DeepLinkService.mapToLocation(link!), isNotNull);
    });

    test('refuses an intent for another app or a malformed intent', () {
      expect(read('intent://open#Intent;scheme=other;end'), isNull);
      expect(read('intent://open#Intent;package=x;end'), isNull);
      expect(read('intent://open#Intent;scheme=mallowwallet'), isNull);
      expect(
        read('intent://open#Intent;scheme=mallowwallet;scheme=x;end'),
        isNull,
      );
      expect(read('intent://open'), isNull);
    });

    test('never hands over the login, pairing or share hosts', () {
      expect(read('mallowwallet://auth?code=x'), isNull);
      expect(read('mallowwallet://wc?uri=x'), isNull);
      expect(read('mallowwallet://browser/open?url=$encoded'), isNull);
      expect(
        read('intent://auth?code=x#Intent;scheme=mallowwallet;end'),
        isNull,
      );
    });

    test('ignores websites and other schemes', () {
      expect(read(web), isNull);
      expect(read('http://example.com/drop/abc'), isNull);
      expect(read('mailto:a@b.c'), isNull);
      expect(read('mallowwallet://user@open'), isNull);
    });
  });
}
