import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/home/data/home_feed_repository.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_filter.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_hide_store.dart';
import 'package:mocktail/mocktail.dart';

import '../../moderation/support/moderation_fakes.dart';

// Home paints from a cache of the raw responses before the network answers,
// so a block has to be applied where those responses become cards: in the
// repository's mappers. Every section of Home shows other people's content.

class _Api extends Mock implements api.MallowApiClient {}

class _ApiV2 extends Mock implements api.MallowApiV2Client {}

class _Db extends Mock implements MallowDatabase {}

class _Session extends Mock implements SessionManager {}

const _blocked = 'BlockedArtist1111111111111111111111111111111';
const _artist = 'SomeArtist111111111111111111111111111111111';
const _me = 'Viewer1111111111111111111111111111111111111';

api.NftPreview _nft(String mint, {String creator = _artist, String? owner}) =>
    api.NftPreview(
      mintAccount: mint,
      name: mint,
      imageUrl: 'https://img/$mint.png',
      creator: api.ApiUserRef(address: creator),
      owner: owner == null ? null : api.ApiUserRef(address: owner),
    );

api.ItemRender _item(api.NftPreview nft) =>
    api.ItemRender(contentType: 'nft', nftPreview: nft);

void main() {
  late HomeFeedRepository repo;
  late ModerationHideStore hides;

  setUpAll(() => registerFallbackValue(() {}));

  setUp(() {
    ModerationFilter.resetAttributions();
    final m = moderationOver(blocked: [_blocked], own: [_me]);
    hides = m.hides;
    repo = HomeFeedRepository(
      _Api(),
      _ApiV2(),
      _Db(),
      _Session(),
      moderation: () => m.filter,
    );
  });

  test('featured listings and the trending spotlight leave out a blocked '
      'artist and a reported artwork', () {
    hides.hide(api.ReportTargetType.artwork, 'reported');
    final feed = api.HomeFeedResponse(
      featured: [
        _item(_nft('theirs', creator: _blocked)),
        _item(_nft('reported')),
        _item(_nft('fine')),
      ],
      smores: [_item(_nft('theirs-too', creator: _blocked))],
    );

    expect(repo.mapFeaturedListings(feed).map((l) => l.mintAccount), ['fine']);
    expect(repo.mapTrendingForSpotlight(feed).map((a) => a.mintAccount), [
      'fine',
    ]);
  });

  test('a featured artwork the viewer owns stays, whoever made it', () {
    final feed = api.HomeFeedResponse(
      featured: [_item(_nft('mine', creator: _blocked, owner: _me))],
    );

    expect(repo.mapFeaturedListings(feed).single.mintAccount, 'mine');
  });

  test('artist rows leave out a blocked account', () {
    expect(
      repo
          .mapCreators(const [
            api.User(username: 'blocked', addresses: [_blocked]),
            api.User(username: 'artist', addresses: [_artist]),
          ])
          .map((a) => a.username),
      ['artist'],
    );
    expect(
      repo
          .mapDiscoverArtists(
            const api.HomeDiscoverResponse(
              artists: [
                api.HomeDiscoverArtist(address: _blocked, username: 'blocked'),
                api.HomeDiscoverArtist(address: _artist, username: 'artist'),
              ],
            ),
          )
          .map((a) => a.username),
      ['artist'],
    );
  });

  test('popular curations leave out a blocked curator\'s and a reported '
      'one, by slug or by id', () {
    hides.hide(api.ReportTargetType.curation, 'reported-slug');
    hides.hide(api.ReportTargetType.curation, 'other-slug', alias: 'by-id');
    api.HomePopularCurationItem curation(
      String id, {
      String slug = '',
      String owner = _artist,
    }) => api.HomePopularCurationItem(
      name: id,
      id: id,
      slug: slug,
      owner: api.HomePopularCurationOwner(address: owner),
      previewImageUrls: const ['https://img/c.png'],
    );

    final curations = repo.mapPopularCurations(
      api.HomePopularCurationsResponse(
        curations: [
          curation('theirs', owner: _blocked),
          curation('c2', slug: 'reported-slug'),
          curation('by-id'),
          curation('fine'),
        ],
      ),
    );

    expect(curations.map((c) => c.id), ['fine']);
  });

  test('popular collections leave out a blocked creator\'s', () {
    final collections = repo.mapPopularCollections(
      const api.HomePopularCollectionsResponse(
        collections: [
          api.HomePopularCollectionItem(
            slug: 'theirs',
            name: 'Theirs',
            imageUrl: 'https://img/1.png',
            creator: api.ApiUserRef(addresses: [_artist, _blocked]),
          ),
          api.HomePopularCollectionItem(
            slug: 'fine',
            name: 'Fine',
            imageUrl: 'https://img/2.png',
            creator: api.ApiUserRef(address: _artist),
          ),
        ],
      ),
    );

    expect(collections.map((c) => c.id), ['fine']);
  });

  test('a recommended card drops a blocked artist\'s artworks and their '
      'thumbnails, and a blocked curator\'s card goes whole', () {
    final categories = repo.mapRecommendedCategories(
      api.HomeRecommendedResponse(
        curations: [
          api.HomeRecommendedCuration(
            name: 'Mixed',
            owner: const api.HomePopularCurationOwner(address: _artist),
            artworks: [
              _item(_nft('theirs', creator: _blocked)),
              _item(_nft('fine')),
            ],
          ),
          api.HomeRecommendedCuration(
            name: 'Theirs',
            owner: const api.HomePopularCurationOwner(address: _blocked),
            artworks: [_item(_nft('other'))],
          ),
        ],
      ),
    );

    expect(categories.map((c) => c.label), ['Mixed']);
    expect(categories.single.artworks.map((a) => a.mintAccount), ['fine']);
    expect(categories.single.imageUrls, ['https://img/fine.png']);
  });

  test('with nothing blocked or reported every section passes through', () {
    repo = HomeFeedRepository(
      _Api(),
      _ApiV2(),
      _Db(),
      _Session(),
      moderation: () => ModerationFilter(),
    );
    final feed = api.HomeFeedResponse(
      featured: [
        _item(_nft('theirs', creator: _blocked)),
        _item(_nft('fine')),
      ],
    );

    expect(repo.mapFeaturedListings(feed), hasLength(2));
  });
}
