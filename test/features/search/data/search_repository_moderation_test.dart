import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/result/result.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_filter.dart';
import 'package:mallow_wallet/features/search/data/search_repository.dart';
import 'package:mallow_wallet/features/search/models/search_models.dart';
import 'package:mocktail/mocktail.dart';

import '../../moderation/support/moderation_fakes.dart';

// The category, tag and listing drilldowns can return work by a blocked
// account or an artwork the viewer reported. The repository drops both
// itself, and has to keep paging right while it drops items.

class _Api extends Mock implements api.MallowApiClient {}

class _Dio extends Mock implements Dio {}

const _blocked = 'BlockedArtist1111111111111111111111111111111';
const _artist = 'SomeArtist111111111111111111111111111111111';
const _me = 'Viewer1111111111111111111111111111111111111';

Map<String, dynamic> _nft(
  String mint, {
  String creator = _artist,
  String? owner,
}) => {
  'mintAccount': mint,
  'name': mint,
  'imageUrl': 'https://img/$mint.png',
  'creator': {
    'addresses': [creator],
  },
  'owner': ?owner,
};

/// A full explore page: [count] artworks, the first [blockedCount] of them by
/// the blocked artist.
List<Map<String, dynamic>> _fullPage(
  int page, {
  int count = kExplorePageSize,
  int blockedCount = 0,
}) => [
  for (var i = 0; i < count; i++)
    _nft('p$page-$i', creator: i < blockedCount ? _blocked : _artist),
];

void main() {
  late _Api client;
  late SearchRepository repo;
  late ModerationFilter moderation;
  late List<int> pagesAsked;

  setUpAll(() {
    registerFallbackValue(const api.ExploreRequest());
    registerFallbackValue(() {});
  });

  setUp(() {
    ModerationFilter.resetAttributions();
    client = _Api();
    moderation = moderationOver(blocked: [_blocked], own: [_me]).filter;
    repo = SearchRepository(client, _Dio(), moderation: () => moderation);
    pagesAsked = [];
  });

  /// Serves [pages] by index from the explore route.
  void serve(Map<int, List<Map<String, dynamic>>> pages) {
    when(() => client.explore(any())).thenAnswer((invocation) async {
      final request =
          invocation.positionalArguments.single as api.ExploreRequest;
      pagesAsked.add(request.page);
      return api.ExploreResponse(result: pages[request.page] ?? const []);
    });
  }

  Future<ArtworkResultsPage> fetch({int page = 0}) async {
    final result = await repo.fetchArtworkResults(
      const TagDrilldownTarget('sunset'),
      page: page,
    );
    return (result as ResultSuccess<ArtworkResultsPage, dynamic>).value;
  }

  group('a drilldown', () {
    test('drops a blocked artist\'s work and keeps everyone else\'s', () async {
      serve({
        0: [_nft('a', creator: _blocked), _nft('b'), _nft('c')],
      });

      final page = await fetch();

      expect(page.artworks.map((a) => a.mintAccount), ['b', 'c']);
    });

    test('drops an artwork the viewer reported', () async {
      final m = moderationOver();
      m.hides.hide(api.ReportTargetType.artwork, 'b');
      repo = SearchRepository(client, _Dio(), moderation: () => m.filter);
      serve({
        0: [_nft('a'), _nft('b'), _nft('c')],
      });

      final page = await fetch();

      expect(page.artworks.map((a) => a.mintAccount), ['a', 'c']);
    });

    test('keeps an artwork the viewer owns, whoever made it', () async {
      serve({
        0: [_nft('mine', creator: _blocked, owner: _me), _nft('b')],
      });

      final page = await fetch();

      expect(page.artworks.map((a) => a.mintAccount), ['mine', 'b']);
    });

    // "Is there more" read off the filtered length would end the list at the
    // first page that lost an item.
    test('a full page that lost items still has a successor', () async {
      serve({0: _fullPage(0, blockedCount: 5)});

      final page = await fetch();

      expect(page.artworks, hasLength(kExplorePageSize - 5));
      expect(page.hasMore, isTrue);
      expect(page.page, 0);
    });

    test('a short page is the last one', () async {
      serve({0: _fullPage(0, count: 3)});

      final page = await fetch();

      expect(page.hasMore, isFalse);
    });

    // A page of nothing but the blocked artist's work must not read as "no
    // results" while other people's work sits on the next page.
    test('pages the filter emptied are skipped to the next one with '
        'something on it', () async {
      serve({
        0: _fullPage(0, blockedCount: kExplorePageSize),
        1: _fullPage(1, blockedCount: kExplorePageSize),
        2: _fullPage(2, blockedCount: 1),
        3: _fullPage(3),
      });

      final page = await fetch();

      expect(pagesAsked, [0, 1, 2]);
      expect(page.artworks, hasLength(kExplorePageSize - 1));
      expect(page.artworks.first.mintAccount, 'p2-1');
      expect(page.page, 2, reason: 'the next fetch asks for page 3');
      expect(page.hasMore, isTrue);
    });

    test('a list of nothing but blocked work ends, after a bounded number '
        'of pages', () async {
      serve({
        for (var i = 0; i < 50; i++)
          i: _fullPage(i, blockedCount: kExplorePageSize),
      });

      final page = await fetch();

      expect(pagesAsked, hasLength(kMaxFilteredOutPages));
      expect(page.artworks, isEmpty);
      expect(page.hasMore, isFalse, reason: 'nothing on screen to scroll');
    });

    test('further down, a run of blocked pages hands the cursor back for '
        'the next scroll', () async {
      serve({
        for (var i = 0; i < 50; i++)
          i: _fullPage(i, blockedCount: kExplorePageSize),
      });

      final page = await fetch(page: 3);

      expect(pagesAsked, [3, 4, 5, 6, 7]);
      expect(page.artworks, isEmpty);
      expect(page.hasMore, isTrue);
      expect(page.page, 7);
    });

    test('with nothing blocked or reported a page passes through '
        'whole', () async {
      repo = SearchRepository(
        client,
        _Dio(),
        moderation: () => ModerationFilter(),
      );
      serve({0: _fullPage(0, blockedCount: 7)});

      final page = await fetch();

      expect(page.artworks, hasLength(kExplorePageSize));
      expect(pagesAsked, [0]);
    });
  });

  test('an exhibition drops a blocked artist\'s work', () async {
    when(() => client.getExhibition('show')).thenAnswer(
      (_) async => api.ExhibitionDetailResponse(
        result: api.ExhibitionDetailResult(
          artworks: [
            _nft('a', creator: _blocked),
            _nft('b'),
          ],
        ),
      ),
    );

    final artworks = await repo.fetchExhibitionArtworks('show');

    expect(artworks.map((a) => a.mintAccount), ['b']);
  });

  group('text search', () {
    test('drops blocked users, their collections and their curations, and '
        'reported artworks and curations', () async {
      final m = moderationOver(blocked: [_blocked]);
      m.hides.hide(api.ReportTargetType.artwork, 'reported-mint');
      m.hides.hide(
        api.ReportTargetType.curation,
        'reported-slug',
        alias: 'reported-id',
      );
      final dio = _Dio();
      repo = SearchRepository(client, dio, moderation: () => m.filter);
      when(
        () => dio.get<List<dynamic>>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => Response(requestOptions: RequestOptions(), data: const []),
      );
      when(() => client.search(any())).thenAnswer(
        (_) async => const api.ApiResponse(
          result: api.SearchResponse(
            users: [
              api.SearchUserItem(username: 'blocked', address: _blocked),
              api.SearchUserItem(username: 'artist', address: _artist),
            ],
            artworks: [
              api.SearchArtworkItem(title: 'x', mintAccount: 'reported-mint'),
              api.SearchArtworkItem(title: 'y', mintAccount: 'fine-mint'),
            ],
            collections: [
              api.SearchCollectionItem(
                name: 'theirs',
                curatorAddress: _blocked,
              ),
              api.SearchCollectionItem(name: 'fine', curatorAddress: _artist),
            ],
          ),
        ),
      );
      when(() => client.searchCurations(any())).thenAnswer(
        (_) async => const api.ApiResponse(
          result: api.CurationSearchResponse(
            curations: [
              api.CurationSearchItem(
                id: 'c1',
                name: 'theirs',
                ownerAddress: _blocked,
              ),
              api.CurationSearchItem(
                id: 'reported-id',
                name: 'reported',
                ownerAddress: _artist,
              ),
              api.CurationSearchItem(
                id: 'c3',
                name: 'fine',
                ownerAddress: _artist,
              ),
            ],
          ),
        ),
      );

      final results = await repo.search('art');

      expect(results.users.map((u) => u.username), ['artist']);
      expect(results.artworks.map((a) => a.mintAccount), ['fine-mint']);
      expect(results.collections.map((c) => c.name), ['fine']);
      expect(results.curations.map((c) => c.id), ['c3']);
    });

    // The search shape names no creator address. A blocked artist's work is
    // still recognised when a drilldown showed it with its creator earlier.
    test('drops a blocked artist\'s artwork the app has seen with its '
        'creator', () async {
      final dio = _Dio();
      repo = SearchRepository(client, dio, moderation: () => moderation);
      when(
        () => dio.get<List<dynamic>>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => Response(requestOptions: RequestOptions(), data: const []),
      );
      serve({
        0: [_nft('seen', creator: _blocked), _nft('b')],
      });
      await fetch();
      when(() => client.search(any())).thenAnswer(
        (_) async => const api.ApiResponse(
          result: api.SearchResponse(
            artworks: [
              api.SearchArtworkItem(title: 'x', mintAccount: 'seen'),
              api.SearchArtworkItem(title: 'y', mintAccount: 'b'),
            ],
          ),
        ),
      );
      when(() => client.searchCurations(any())).thenAnswer(
        (_) async =>
            const api.ApiResponse(result: api.CurationSearchResponse()),
      );

      final results = await repo.search('art');

      expect(results.artworks.map((a) => a.mintAccount), ['b']);
    });

    test('token results are never filtered', () async {
      final dio = _Dio();
      repo = SearchRepository(client, dio, moderation: () => moderation);
      when(() => client.search(any())).thenThrow(Exception('offline'));
      when(() => client.searchCurations(any())).thenThrow(Exception('offline'));
      when(
        () => dio.get<List<dynamic>>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(),
          data: [
            {'id': _blocked, 'name': 'Token', 'symbol': 'TKN'},
          ],
        ),
      );

      final results = await repo.search('tkn');

      expect(results.tokens.single.mintAddress, _blocked);
    });
  });
}
