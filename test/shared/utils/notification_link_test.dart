import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/notification_link.dart';

void main() {
  group('resolveNotificationLink', () {
    test('maps artwork links to the in-app artwork route', () {
      // The in-app row carries a relative path; a push carries the same link
      // absolutised by the sender. Both must land on the same screen — that
      // equivalence is the whole point of the shared resolver.
      expect(resolveNotificationLink('/artwork/MINT1'), '/artwork/MINT1');
      expect(
        resolveNotificationLink('https://mallow.art/artwork/MINT1'),
        '/artwork/MINT1',
      );
    });

    test('maps both profile link shapes to a profile route', () {
      expect(resolveNotificationLink('/a/ADDR1'), '/profile/ADDR1');
      // Username links used to dead-end on /activity because an address
      // couldn't be resolved client-side; the app has a username route.
      expect(resolveNotificationLink('/u/artist'), '/profile/u/artist');
    });

    test(
      'degrades a destination with no mobile screen to a mallow.art URL',
      () {
        // Gumball / Jellybean / store / Talk / staking are web-only. Pushing
        // these paths into go_router is what produced "Page not found".
        for (final path in [
          '/gumball/PK1',
          '/gumball/i/PK1',
          '/jellybean/PK1',
          '/product/SKU_1',
          '/p/POST1',
          '/stake',
        ]) {
          final resolved = resolveNotificationLink(path);
          expect(resolved, 'https://mallow.art$path');
          expect(isNotificationWebLink(resolved!), isTrue);
        }
      },
    );

    test('keeps the query on a comment deep link', () {
      // ?commentId= is what anchors the web page on the actual comment.
      expect(
        resolveNotificationLink('https://mallow.art/p/POST1?commentId=abc'),
        'https://mallow.art/p/POST1?commentId=abc',
      );
    });

    test('returns null when there is nothing to open', () {
      expect(resolveNotificationLink(null), isNull);
      expect(resolveNotificationLink(''), isNull);
      expect(resolveNotificationLink('https://mallow.art'), isNull);
    });

    test('an in-app route is never mistaken for a web link', () {
      expect(isNotificationWebLink('/artwork/MINT1'), isFalse);
      expect(isNotificationWebLink('https://mallow.art/gumball/PK1'), isTrue);
    });
  });
}
