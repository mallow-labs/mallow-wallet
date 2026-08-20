import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

// Regression coverage for a silent wire mismatch on POST /v1/search.
//
// `UserRenderer.renderSingle` renders through a field whitelist that contains
// `addresses` (plural) and no singular `address`, so reading `address` off the
// rendered user always yielded null. Nothing threw and nothing logged — the
// field simply stayed empty, and the failure only became visible for users with
// no username, whose row then had no label, no identicon seed and no route to
// push. The same whitelist governs the collection render's nested `creator`,
// where the address is carried by the top-level `creatorAddress` instead.
void main() {
  const address = '9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin';

  group('SearchUserItem', () {
    test('reads the address from the rendered `addresses` list', () {
      final item = SearchUserItem.fromJson({
        'user': {
          'addresses': [address],
          'username': 'alice',
          'imageUrl': 'http://avatar',
          'isTwitterVerified': true,
        },
        'userDetails': <String, dynamic>{},
      });

      expect(item.address, address);
      expect(item.username, 'alice');
      expect(item.avatarUrl, 'http://avatar');
      expect(item.isVerified, isTrue);
    });

    test('keeps the address for a user with no username', () {
      // The case the mismatch actually broke. Searching by wallet address
      // matches on `addresses`, so the result can be a profile-less user. Its
      // address is the only identifier left: it is the display label, the
      // identicon seed, and the only way to route to the profile.
      final item = SearchUserItem.fromJson({
        'user': {
          'addresses': [address],
        },
      });

      expect(item.username, isEmpty);
      expect(item.address, address);
    });

    test('takes the first address when a profile links several wallets', () {
      final item = SearchUserItem.fromJson({
        'user': {
          'addresses': [address, '0xabc'],
          'username': 'alice',
        },
      });

      expect(item.address, address);
    });

    test('leaves the address null when `addresses` is absent or empty', () {
      expect(SearchUserItem.fromJson({'user': <String, dynamic>{}}).address, isNull);
      expect(
        SearchUserItem.fromJson({
          'user': {'addresses': <dynamic>[]},
        }).address,
        isNull,
      );
    });
  });

  group('SearchCollectionItem', () {
    test('reads the curator address from the top-level `creatorAddress`', () {
      final item = SearchCollectionItem.fromJson({
        'name': 'Genesis',
        'imageUrl': 'http://thumb',
        'slug': 'genesis',
        'creatorAddress': address,
        'creator': {
          'addresses': [address],
          'username': 'alice',
        },
      });

      expect(item.curatorAddress, address);
      expect(item.curatorUsername, 'alice');
      expect(item.name, 'Genesis');
      expect(item.slug, 'genesis');
    });

    test('keeps the curator address when the creator has no profile', () {
      // `creator` is only rendered when the creator address resolves to a
      // mallow user; `creatorAddress` is always emitted.
      final item = SearchCollectionItem.fromJson({'name': 'Genesis', 'creatorAddress': address});

      expect(item.curatorAddress, address);
      expect(item.curatorUsername, isNull);
    });
  });
}
