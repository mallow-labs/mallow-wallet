import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/artwork/widgets/add_to_curation_sheet.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_filter.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_hide_store.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/features/profile/models/user_profile.dart';
import 'package:mallow_wallet/features/profile/services/user_profile_bloc.dart';
import 'package:mockito/mockito.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

import '../../moderation/support/moderation_fakes.dart';
import 'user_profile_bloc_test.mocks.dart';

// The repository filters each page of someone else's profile. These cover the
// lists already on screen when the viewer blocks an account or reports
// something from a route pushed on top of the profile, and the rule that the
// viewer's own profile is never filtered.

const _viewer = 'VIEWER_ADDR';
const _profileAddress = 'PROFILE_ADDR';
const _blocked = 'BLOCKED_ARTIST';

UserProfile _profile(String address) => UserProfile(
  address: address,
  username: 'alice',
  handle: 'alice',
  role: '',
  bio: '',
  avatarUrl: '',
  followerCount: 0,
  collectorCount: 0,
  ownedArtworkCount: 0,
  createdArtworkCount: 1,
  collectedArtworkCount: 2,
);

PortfolioArtwork _artwork(String mint) => PortfolioArtwork(
  mintAccount: mint,
  title: mint,
  imageUrl: '',
  artistName: '',
);

void main() {
  late MockUserProfileRepository repository;
  late MockCurationRepository curations;
  late MockAuthService auth;
  late ({ModerationFilter filter, BlockStore blocks, ModerationHideStore hides})
  moderation;
  late List<UserCuration> served;

  setUpAll(() => mocktail.registerFallbackValue(() {}));

  setUp(() {
    ModerationFilter.resetAttributions();
    moderation = moderationOver(own: [_viewer]);
    repository = MockUserProfileRepository();
    curations = MockCurationRepository();
    auth = MockAuthService();
    served = const [
      UserCuration(id: 'c1', name: 'One', artworkCount: 1),
      UserCuration(id: 'c2', name: 'Two', artworkCount: 1),
    ];

    when(auth.currentAddress).thenReturn(_viewer);
    when(auth.isFollowing(any)).thenReturn(false);
    when(
      auth.currentWalletNeedsHardwareVerification(),
    ).thenAnswer((_) async => false);
    when(repository.getCachedProfile(any)).thenAnswer((_) async => null);
    when(repository.cacheProfile(any, any)).thenAnswer((_) async {});
    when(
      repository.getUserCollections(any, page: anyNamed('page')),
    ).thenAnswer((_) async => const []);
    when(repository.getYouOwnArtworks(any)).thenAnswer(
      (_) async => const PortfolioArtworksResult(artworks: [], total: 0),
    );
    when(
      curations.getCurations(
        mintAccount: anyNamed('mintAccount'),
        ownerAddress: anyNamed('ownerAddress'),
      ),
    ).thenAnswer((_) async => served);
  });

  /// Loads [address]'s profile with one created artwork and two collected
  /// ones, the first of them by the account that gets blocked.
  Future<UserProfileBloc> load(String address) async {
    when(
      repository.getUserProfile(any),
    ).thenAnswer((_) async => _profile(address));
    when(
      repository.getUserArtworks(
        any,
        page: anyNamed('page'),
        sort: anyNamed('sort'),
        filter: anyNamed('filter'),
      ),
    ).thenAnswer(
      (_) async =>
          ProfileArtworksResult(artworks: [_artwork('created')], total: 1),
    );
    when(
      repository.getUserArtworks(
        any,
        page: anyNamed('page'),
        tab: api.ApiProfileTab.collected,
        sort: anyNamed('sort'),
        filter: anyNamed('filter'),
      ),
    ).thenAnswer(
      (_) async => ProfileArtworksResult(
        artworks: [_artwork('theirs'), _artwork('fine')],
        total: 2,
      ),
    );
    // What the repository does as the pages pass through it.
    moderation.filter.hidesArtwork('theirs', by: [_blocked]);
    moderation.filter.hidesArtwork('fine', by: ['SOMEONE']);
    moderation.filter.hidesArtwork('created', by: [address]);

    final bloc = UserProfileBloc(
      repository,
      curations,
      auth,
      moderation: () => moderation.filter,
    );
    addTearDown(bloc.close);
    bloc.add(UserProfileEvent.load(address: address));
    await bloc.stream.firstWhere(
      (s) =>
          s is UserProfileLoaded &&
          s.ownedArtworks != null &&
          s.artworks != null &&
          s.groups != null,
    );
    await pumpEventQueue();
    return bloc;
  }

  UserProfileLoaded loaded(UserProfileBloc bloc) =>
      bloc.state as UserProfileLoaded;

  List<String>? mints(List<PortfolioArtwork>? list) =>
      list?.map((a) => a.mintAccount).toList();

  void block(String address) => moderation.blocks.blocked.value = {address};

  test('a block drops that artist\'s work from someone else\'s lists, in '
      'place', () async {
    final bloc = await load(_profileAddress);
    expect(mints(loaded(bloc).ownedArtworks), ['theirs', 'fine']);
    clearInteractions(repository);

    block(_blocked);
    await pumpEventQueue();

    expect(mints(loaded(bloc).ownedArtworks), ['fine']);
    expect(mints(loaded(bloc).artworks), ['created']);
    verifyNever(repository.getUserProfile(any));
  });

  test('a report drops that artwork', () async {
    final bloc = await load(_profileAddress);

    moderation.hides.hide(api.ReportTargetType.artwork, 'fine');
    await pumpEventQueue();

    expect(mints(loaded(bloc).ownedArtworks), ['theirs']);
  });

  // The visitor went to this profile: its own work is shown there. A blocked
  // profile is behind its own gate, in front of this bloc.
  test('reporting the profile\'s owner does not empty their own '
      'page', () async {
    final bloc = await load(_profileAddress);

    moderation.hides.hide(api.ReportTargetType.user, _profileAddress);
    await pumpEventQueue();

    expect(mints(loaded(bloc).artworks), ['created']);
  });

  test('a reported curation leaves their Curations tab', () async {
    final bloc = await load(_profileAddress);
    expect(loaded(bloc).groups!.map((g) => g.id), containsAll(['c1', 'c2']));

    moderation.hides.hide(
      api.ReportTargetType.curation,
      'slug-of-c1',
      alias: 'c1',
    );
    await pumpEventQueue();

    final ids = loaded(bloc).groups!.map((g) => g.id);
    expect(ids, contains('c2'));
    expect(ids, isNot(contains('c1')));
  });

  test('the viewer\'s own profile is never filtered', () async {
    final bloc = await load(_viewer);

    block(_blocked);
    moderation.hides.hide(api.ReportTargetType.artwork, 'fine');
    moderation.hides.hide(
      api.ReportTargetType.curation,
      'slug-of-c1',
      alias: 'c1',
    );
    await pumpEventQueue();

    expect(mints(loaded(bloc).ownedArtworks), ['theirs', 'fine']);
    expect(loaded(bloc).groups!.map((g) => g.id), containsAll(['c1', 'c2']));
  });
}
