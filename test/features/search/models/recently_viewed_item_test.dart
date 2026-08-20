import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/search/models/recently_viewed_item.dart';
import 'package:mallow_wallet/features/search/models/search_models.dart';

void main() {
  group('RecentlyViewedItem', () {
    group('toJson / fromJson roundtrip', () {
      test('user — with address', () {
        final item = RecentlyViewedItem.user(
          const SearchUserResult(
            username: 'alice',
            address: '4Nd1...',
            avatarUrl: 'https://cdn/alice.jpg',
            isVerified: true,
          ),
        );
        final decoded = RecentlyViewedItem.fromJson(item.toJson());
        expect(decoded, item);
        expect(decoded?.user?.username, 'alice');
        expect(decoded?.user?.isVerified, true);
      });

      test('user — nullable fields preserved as null', () {
        final item = RecentlyViewedItem.user(
          const SearchUserResult(username: 'bob'),
        );
        final decoded = RecentlyViewedItem.fromJson(item.toJson())!;
        expect(decoded.user?.address, isNull);
        expect(decoded.user?.avatarUrl, isNull);
      });

      test('artwork — roundtrip', () {
        final item = RecentlyViewedItem.artwork(
          const SearchArtworkResult(
            title: 'Genesis',
            mintAccount: 'mint123',
            thumbnailUrl: 'https://cdn/t.jpg',
            artistUsername: 'artist',
            editionNumber: 3,
          ),
        );
        final decoded = RecentlyViewedItem.fromJson(item.toJson());
        expect(decoded, item);
        expect(decoded?.artwork?.mintAccount, 'mint123');
        expect(decoded?.artwork?.editionNumber, 3);
      });

      test('collection — roundtrip with null slug', () {
        final item = RecentlyViewedItem.collection(
          const SearchCollectionResult(
            name: 'My Collection',
            curatorUsername: 'curator',
          ),
        );
        final decoded = RecentlyViewedItem.fromJson(item.toJson())!;
        expect(decoded.collection?.slug, isNull);
        expect(decoded.collection?.name, 'My Collection');
      });

      test('curation — roundtrip', () {
        final item = RecentlyViewedItem.curation(
          const SearchCurationResult(
            id: 'curation-id-1',
            name: 'Summer Show',
            artworkCount: 12,
            thumbnailUrls: ['https://cdn/1.jpg', 'https://cdn/2.jpg'],
            ownerAddress: 'ownerAddr',
            ownerUsername: 'owner',
          ),
        );
        final decoded = RecentlyViewedItem.fromJson(item.toJson())!;
        expect(decoded.curation?.id, 'curation-id-1');
        expect(decoded.curation?.thumbnailUrls, hasLength(2));
        expect(decoded.curation?.artworkCount, 12);
      });

      test('token — roundtrip with nullable price', () {
        final item = RecentlyViewedItem.token(
          const SearchTokenResult(
            mintAddress: 'So11...1112',
            name: 'Solana',
            symbol: 'SOL',
          ),
        );
        final decoded = RecentlyViewedItem.fromJson(item.toJson())!;
        expect(decoded.token?.mintAddress, 'So11...1112');
        expect(decoded.token?.usdPrice, isNull);
      });

      test('token — preserves price doubles', () {
        final item = RecentlyViewedItem.token(
          const SearchTokenResult(
            mintAddress: 'addr',
            name: 'USDC',
            symbol: 'USDC',
            usdPrice: 1.001,
            priceChange24h: -0.05,
          ),
        );
        final decoded = RecentlyViewedItem.fromJson(item.toJson())!;
        expect(decoded.token?.usdPrice, closeTo(1.001, 1e-9));
        expect(decoded.token?.priceChange24h, closeTo(-0.05, 1e-9));
      });
    });

    group('fromJson forward-compatibility', () {
      test('unknown type returns null', () {
        final result = RecentlyViewedItem.fromJson({
          'type': 'futureType',
          'futureType': {'id': 'xyz'},
        });
        expect(result, isNull);
      });

      test('missing type key returns null', () {
        final result = RecentlyViewedItem.fromJson({
          'artwork': <String, dynamic>{},
        });
        expect(result, isNull);
      });
    });

    group('dedupeKey', () {
      test('user with address uses address', () {
        final item = RecentlyViewedItem.user(
          const SearchUserResult(username: 'alice', address: '4Nd1...'),
        );
        expect(item.dedupeKey, 'user:4Nd1...');
      });

      test('user without address falls back to username', () {
        final item = RecentlyViewedItem.user(
          const SearchUserResult(username: 'alice'),
        );
        expect(item.dedupeKey, 'user:alice');
      });

      test('user with empty address falls back to username', () {
        final item = RecentlyViewedItem.user(
          const SearchUserResult(username: 'alice', address: ''),
        );
        expect(item.dedupeKey, 'user:alice');
      });

      test('artwork uses mintAccount', () {
        final item = RecentlyViewedItem.artwork(
          const SearchArtworkResult(title: 'T', mintAccount: 'mint-xyz'),
        );
        expect(item.dedupeKey, 'artwork:mint-xyz');
      });

      test('collection with slug uses slug', () {
        final item = RecentlyViewedItem.collection(
          const SearchCollectionResult(name: 'My Coll', slug: 'my-coll'),
        );
        expect(item.dedupeKey, 'collection:my-coll');
      });

      test('collection without slug falls back to name', () {
        final item = RecentlyViewedItem.collection(
          const SearchCollectionResult(name: 'No Slug'),
        );
        expect(item.dedupeKey, 'collection:No Slug');
      });

      test('curation uses id', () {
        final item = RecentlyViewedItem.curation(
          const SearchCurationResult(id: 'cur-99', name: 'Summer'),
        );
        expect(item.dedupeKey, 'curation:cur-99');
      });

      test('token uses mintAddress', () {
        final item = RecentlyViewedItem.token(
          const SearchTokenResult(
            mintAddress: 'So11...1112',
            name: 'SOL',
            symbol: 'SOL',
          ),
        );
        expect(item.dedupeKey, 'token:So11...1112');
      });
    });

    group('equality via encoded', () {
      test('same content is equal', () {
        final a = RecentlyViewedItem.token(
          const SearchTokenResult(
            mintAddress: 'addr',
            name: 'SOL',
            symbol: 'SOL',
          ),
        );
        final b = RecentlyViewedItem.token(
          const SearchTokenResult(
            mintAddress: 'addr',
            name: 'SOL',
            symbol: 'SOL',
          ),
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('different mintAddress is not equal', () {
        final a = RecentlyViewedItem.token(
          const SearchTokenResult(
            mintAddress: 'addr1',
            name: 'SOL',
            symbol: 'SOL',
          ),
        );
        final b = RecentlyViewedItem.token(
          const SearchTokenResult(
            mintAddress: 'addr2',
            name: 'SOL',
            symbol: 'SOL',
          ),
        );
        expect(a, isNot(b));
      });
    });
  });
}
