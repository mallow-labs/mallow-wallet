import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_filter.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_hide_store.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/profile/data/profile_image_uploader.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../moderation/support/moderation_fakes.dart';

// Someone else's Collected tab can hold work by an account the viewer
// blocked, and so can a collection page. The repository drops both, and never
// touches the viewer's own profile.

class _Api extends Mock implements api.MallowApiClient {}

class _ApiV2 extends Mock implements api.MallowApiV2Client {}

class _Db extends Mock implements MallowDatabase {}

class _Portfolio extends Mock implements PortfolioRepository {}

class _Uploader extends Mock implements ProfileImageUploader {}

const _blocked = 'BlockedArtist1111111111111111111111111111111';
const _artist = 'SomeArtist111111111111111111111111111111111';
const _me = 'Viewer1111111111111111111111111111111111111';
const _profile = 'Collector11111111111111111111111111111111111';

Map<String, dynamic> _nft(String mint, {String creator = _artist}) => {
  'mintAccount': mint,
  'name': mint,
  'creator': {
    'addresses': [creator],
  },
};

void main() {
  late _Api client;
  late UserProfileRepository repo;
  late ModerationHideStore hides;
  late Map<int, api.ProfileResponse> profilePages;
  late List<int> pagesAsked;

  setUpAll(() {
    registerFallbackValue(
      const api.ProfileRequest(
        tab: api.ApiProfileTab.created,
        profileUserAddresses: [],
      ),
    );
    registerFallbackValue(const api.ExploreRequest());
    registerFallbackValue(() {});
  });

  setUp(() {
    ModerationFilter.resetAttributions();
    final m = moderationOver(blocked: [_blocked], own: [_me]);
    hides = m.hides;
    client = _Api();
    repo = UserProfileRepository(
      client,
      _ApiV2(),
      _Db(),
      _Portfolio(),
      _Uploader(),
      moderation: () => m.filter,
    );
    profilePages = {};
    pagesAsked = [];
    when(() => client.getProfile(any())).thenAnswer((invocation) async {
      final request =
          invocation.positionalArguments.single as api.ProfileRequest;
      pagesAsked.add(request.page);
      return profilePages[request.page] ?? const api.ProfileResponse();
    });
  });

  group('someone else\'s artworks', () {
    test('leave out a blocked artist\'s work and a reported artwork', () async {
      hides.hide(api.ReportTargetType.artwork, 'reported');
      profilePages[0] = api.ProfileResponse(
        result: [
          _nft('theirs', creator: _blocked),
          _nft('reported'),
          _nft('fine'),
        ],
        total: 3,
      );

      final result = await repo.getUserArtworks([
        _profile,
      ], tab: api.ApiProfileTab.collected);

      expect(result.artworks.map((a) => a.mintAccount), ['fine']);
      expect(result.total, 3, reason: 'the server\'s count is left as it is');
    });

    // The cursor is the server's, so a page shortened by the filter does not
    // end the list.
    test('keep the server\'s cursor when a page lost items', () async {
      profilePages[0] = api.ProfileResponse(
        result: [
          _nft('theirs', creator: _blocked),
          _nft('fine'),
        ],
        nextPage: 1,
      );

      final result = await repo.getUserArtworks([_profile]);

      expect(result.artworks, hasLength(1));
      expect(result.nextPage, 1);
    });

    test('skip a page the filter emptied', () async {
      profilePages[0] = api.ProfileResponse(
        result: [_nft('theirs-1', creator: _blocked)],
        nextPage: 1,
      );
      profilePages[1] = api.ProfileResponse(
        result: [_nft('fine')],
        nextPage: 2,
      );

      final result = await repo.getUserArtworks([_profile]);

      expect(pagesAsked, [0, 1]);
      expect(result.artworks.single.mintAccount, 'fine');
      expect(result.nextPage, 2);
    });

    // The visitor went to this profile, so its own work is shown there. A
    // blocked profile is behind its own gate.
    test('show the profile\'s own work even when its owner was '
        'reported', () async {
      hides.hide(api.ReportTargetType.user, _profile);
      hides.hide(api.ReportTargetType.artwork, 'reported');
      profilePages[0] = api.ProfileResponse(
        result: [
          _nft('own-1', creator: _profile),
          _nft('reported', creator: _profile),
        ],
      );

      final result = await repo.getUserArtworks([_profile]);

      expect(result.artworks.map((a) => a.mintAccount), ['own-1']);
    });
  });

  test('the viewer\'s own profile is returned whole', () async {
    hides.hide(api.ReportTargetType.artwork, 'reported');
    profilePages[0] = api.ProfileResponse(
      result: [
        _nft('theirs', creator: _blocked),
        _nft('reported'),
      ],
    );

    final result = await repo.getUserArtworks([
      _me,
    ], tab: api.ApiProfileTab.collected);

    expect(result.artworks.map((a) => a.mintAccount), ['theirs', 'reported']);
  });

  test('someone else\'s collections leave out a blocked creator\'s, and '
      'the viewer\'s own list is whole', () async {
    profilePages[0] = const api.ProfileResponse(
      result: [
        {
          'slug': 'theirs',
          'name': 'Theirs',
          'creator': {
            'addresses': [_blocked],
          },
        },
        {
          'slug': 'fine',
          'name': 'Fine',
          'creator': {
            'addresses': [_artist],
          },
        },
      ],
    );

    final theirs = await repo.getUserCollections([_profile]);
    final mine = await repo.getUserCollections([_me]);

    expect(theirs.map((g) => g.id), ['fine']);
    expect(mine.map((g) => g.id), ['theirs', 'fine']);
  });

  group('a collection page', () {
    void serve(List<Map<String, dynamic>> rows) {
      when(
        () => client.explore(any()),
      ).thenAnswer((_) async => api.ExploreResponse(result: rows));
    }

    test('leaves out a blocked artist\'s work and a reported '
        'artwork', () async {
      hides.hide(api.ReportTargetType.artwork, 'reported');
      serve([
        _nft('theirs', creator: _blocked),
        _nft('reported'),
        _nft('fine'),
      ]);

      final page = await repo.getCollectionArtworksPage('slug');

      expect(page.items.map((a) => a.mintAccount), ['fine']);
      expect(page.hasMore, isTrue);
    });

    // The route has no "more" flag: an empty page is the end. A page the
    // filter emptied is not that.
    test('a page the filter emptied is not the end of the '
        'collection', () async {
      serve([_nft('theirs', creator: _blocked)]);

      final page = await repo.getCollectionArtworksPage('slug');

      expect(page.items, isEmpty);
      expect(page.hasMore, isTrue);
    });

    test('an empty page from the server is the end', () async {
      serve(const []);

      final page = await repo.getCollectionArtworksPage('slug', page: 3);

      expect(page.hasMore, isFalse);
    });
  });
}
