import 'package:test/test.dart';
import 'package:mallow_api/mallow_api.dart';

// Regression coverage for the production crash
// `[Network] Parse failure: GET /home: type 'Null' is not a subtype of type
// 'String' in type cast`.
//
// `HomeFeedResponse.fromJson` deserializes the entire /home payload in one shot.
// Before this fix, a single null/omitted required `String` anywhere in the tree
// aborted the whole parse, blanking the home screen. The contract these tests
// pin: a malformed field or item degrades to a dropped/empty value, never a
// throw.
void main() {
  group('CuratedSection', () {
    test('parses when the backend omits the title', () {
      // The backend can send a curated section without `title`. This used to
      // throw `Null is not a subtype of String` and take down the whole feed.
      final section = CuratedSection.fromJson({'items': []});

      expect(section.title, '');
      expect(section.items, isEmpty);
    });

    test('parses when title is explicitly null', () {
      final section = CuratedSection.fromJson({'title': null, 'items': []});

      expect(section.title, '');
    });
  });

  group('HomeFeedResponse contentType filtering', () {
    test('filters out a gumball item (unimplemented contentType)', () {
      // The actual production crash: a `gumball` featured item's render has no
      // `name`/`mintAccount` (it carries `publicKey`/`authority`/`items`
      // instead), so parsing it as an NftPreview threw and blanked the feed.
      // We don't render gumballs yet, so the item must be dropped entirely.
      final feed = HomeFeedResponse.fromJson({
        'featured': [
          {
            'contentType': 'gumball',
            'render': {
              'publicKey': 'Gum111111111111111111111111111111111111111',
              'itemPrice': 650000000,
              'items': [],
            },
          },
          {
            'contentType': 'nft',
            'render': {
              'mintAccount': 'Mint222222222222222222222222222222222222222',
              'name': 'Good NFT',
            },
          },
        ],
      });

      // Only the NFT survives; the gumball is gone, not left as a blank tile.
      expect(feed.featured, hasLength(1));
      expect(feed.featured.single.contentType, 'nft');
      expect(feed.featured.single.nftPreview?.name, 'Good NFT');
    });

    test('filters out not-yet-implemented contentTypes (jellybean, unknown)', () {
      final feed = HomeFeedResponse.fromJson({
        'featured': [
          {
            'contentType': 'jellybean', // not ready yet
            'render': {'mintAccount': 'Jelly1', 'name': 'Jellybean'},
          },
          {
            'contentType': 'raffle', // unknown/future type
            'render': {'anything': true},
          },
          {
            'contentType': 'nft',
            'render': {'mintAccount': 'Mint333', 'name': 'Keep'},
          },
        ],
      });

      expect(feed.featured, hasLength(1));
      expect(feed.featured.single.nftPreview?.name, 'Keep');
    });

    test('drops an NFT item whose required fields are null instead of throwing', () {
      // `featured[0]` is missing the required `name` — parsing the NFT preview
      // for it throws internally, so the item is dropped rather than aborting
      // the whole /home parse.
      final feed = HomeFeedResponse.fromJson({
        'featured': [
          {
            'contentType': 'nft',
            'render': {
              // no `name` → NftPreview.fromJson throws
              'mintAccount': 'Mint111111111111111111111111111111111111111',
            },
          },
          {
            'contentType': 'nft',
            'render': {
              'mintAccount': 'Mint222222222222222222222222222222222222222',
              'name': 'Good NFT',
            },
          },
        ],
      });

      // The good item still parses; the unparseable one is dropped.
      expect(feed.featured, hasLength(1));
      expect(feed.featured.single.nftPreview?.name, 'Good NFT');
    });

    test('applies the same filtering to curated.items', () {
      final feed = HomeFeedResponse.fromJson({
        'curated': {
          'title': 'Editor picks',
          'items': [
            {
              'contentType': 'gumball',
              'render': {'publicKey': 'Gum1'},
            },
            {
              'contentType': 'nft',
              'render': {'mintAccount': 'Mint444', 'name': 'Curated NFT'},
            },
          ],
        },
      });

      expect(feed.curated?.title, 'Editor picks');
      expect(feed.curated?.items, hasLength(1));
      expect(feed.curated?.items.single.nftPreview?.name, 'Curated NFT');
    });

    test('drops malformed previews inside a collection render', () {
      // `CollectionRender.nftPreviews` is a generated list — one preview with a
      // null required field used to crash the entire parse.
      final feed = HomeFeedResponse.fromJson({
        'featured': [
          {
            'contentType': 'collection',
            'render': {
              'slug': 'cool-collection',
              'nftPreviews': [
                {'mintAccount': 'MintAAA', 'name': 'Keep me'},
                {'mintAccount': 'MintBBB'}, // no `name` → dropped
              ],
            },
          },
        ],
      });

      final previews = feed.featured.single.collectionRender?.nftPreviews;
      expect(previews, hasLength(1));
      expect(previews?.single.name, 'Keep me');
    });
  });
}
