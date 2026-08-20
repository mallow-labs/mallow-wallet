import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/ledger_verify_controller.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/artwork/widgets/add_to_curation_sheet.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/curations/data/curation_repository.dart';
import 'package:mallow_wallet/features/curations/services/curations_refresh_signal.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/features/profile/models/cached_profile_data.dart';
import 'package:mallow_wallet/features/profile/models/user_profile.dart';
import 'package:mallow_wallet/features/profile/services/user_profile_bloc.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'user_profile_bloc_test.mocks.dart';

@GenerateMocks([
  UserProfileRepository,
  CurationRepository,
  AuthService,
  LedgerVerifyController,
  SessionManager,
])
void main() {
  late MockUserProfileRepository mockRepository;
  late MockCurationRepository mockCurationRepository;
  late MockAuthService mockAuthService;
  late MockLedgerVerifyController mockLedgerVerifyController;

  const testAddress = 'PROFILE_ADDR';

  UserProfile profile({
    int created = 5,
    int collected = 3,
    String address = testAddress,
    String? displayName,
    List<String> linkedAddresses = const [],
    int followers = 0,
  }) => UserProfile(
    address: address,
    username: 'alice',
    handle: 'alice',
    displayName: displayName,
    role: '',
    bio: '',
    avatarUrl: '',
    followerCount: followers,
    collectorCount: 0,
    ownedArtworkCount: 0,
    createdArtworkCount: created,
    collectedArtworkCount: collected,
    linkedAddresses: linkedAddresses,
  );

  PortfolioArtwork artwork(String mint, {String title = 'art'}) =>
      PortfolioArtwork(
        mintAccount: mint,
        title: title,
        imageUrl: '',
        artistName: '',
      );

  /// Stub the four parallel content fetches and the cache write so
  /// `_onLoad` can run end-to-end. Does NOT stub `getCachedProfile` —
  /// callers either rely on the global `setUp` (no cache) or override it.
  void stubLoadHappyPath({
    required UserProfile loadedProfile,
    List<PortfolioArtwork> created = const [],
    List<PortfolioArtwork> owned = const [],
  }) {
    when(
      mockRepository.getUserProfile(any),
    ).thenAnswer((_) async => loadedProfile);
    // Created tab fetch (default tab argument)
    when(
      mockRepository.getUserArtworks(
        any,
        page: anyNamed('page'),
        sort: anyNamed('sort'),
        filter: anyNamed('filter'),
      ),
    ).thenAnswer(
      (_) async =>
          ProfileArtworksResult(artworks: created, total: created.length),
    );
    // Owned tab fetch (collected)
    when(
      mockRepository.getUserArtworks(
        any,
        page: anyNamed('page'),
        tab: api.ApiProfileTab.collected,
        sort: anyNamed('sort'),
        filter: anyNamed('filter'),
      ),
    ).thenAnswer(
      (_) async => ProfileArtworksResult(artworks: owned, total: owned.length),
    );
    when(
      mockRepository.getUserCollections(any, page: anyNamed('page')),
    ).thenAnswer((_) async => const []);
    when(mockRepository.getYouOwnArtworks(any)).thenAnswer(
      (_) async => const PortfolioArtworksResult(artworks: [], total: 0),
    );
    when(mockRepository.cacheProfile(any, any)).thenAnswer((_) async {});
  }

  setUp(() {
    mockRepository = MockUserProfileRepository();
    mockCurationRepository = MockCurationRepository();
    mockAuthService = MockAuthService();
    mockLedgerVerifyController = MockLedgerVerifyController();

    // Default: viewing own profile (skips youOwn fetch).
    when(mockAuthService.currentAddress).thenReturn(testAddress);
    when(mockAuthService.isFollowing(any)).thenReturn(false);
    when(
      mockAuthService.currentWalletNeedsLedgerVerification(),
    ).thenAnswer((_) async => false);

    // Default: no curations (loads fetch them — own profile with no owner
    // arg, other profiles with an owner address).
    when(
      mockCurationRepository.getCurations(
        mintAccount: anyNamed('mintAccount'),
        ownerAddress: anyNamed('ownerAddress'),
      ),
    ).thenAnswer((_) async => const []);

    // Default cache miss; tests that need a cached profile override this.
    when(mockRepository.getCachedProfile(any)).thenAnswer((_) async => null);
  });

  group('UserProfileBloc', () {
    group('initial tab selection', () {
      blocTest<UserProfileBloc, UserProfileState>(
        'defaults to Created when createdArtworkCount > 0',
        setUp: () => stubLoadHappyPath(loadedProfile: profile(collected: 0)),
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state;
          expect(state, isA<UserProfileLoaded>());
          expect((state as UserProfileLoaded).activeTab, ProfileTab.created);
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'defaults to Owned when only collectedArtworkCount > 0',
        setUp: () =>
            stubLoadHappyPath(loadedProfile: profile(created: 0, collected: 4)),
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.activeTab, ProfileTab.owned);
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'falls back to Created when both counts are 0',
        setUp: () =>
            stubLoadHappyPath(loadedProfile: profile(created: 0, collected: 0)),
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.activeTab, ProfileTab.created);
        },
      );
    });

    // Regression: `_buildResolvedProfile` rebuilds the UserProfile field by
    // field, so any field it forgets to copy is silently dropped before the
    // header renders. displayName drives the profile header's top row (it
    // reads as the user's real name; the @handle carries the username), so
    // losing it makes the header fall back to the username for every user who
    // set a display name.
    blocTest<UserProfileBloc, UserProfileState>(
      'preserves displayName through _buildResolvedProfile',
      setUp: () =>
          stubLoadHappyPath(loadedProfile: profile(displayName: 'mallow Dev')),
      build: () => UserProfileBloc(
        mockRepository,
        mockCurationRepository,
        mockAuthService,
        mockLedgerVerifyController,
      ),
      act: (bloc) =>
          bloc.add(const UserProfileEvent.load(address: testAddress)),
      wait: const Duration(milliseconds: 50),
      verify: (bloc) {
        final state = bloc.state as UserProfileLoaded;
        expect(state.profile.displayName, 'mallow Dev');
      },
    );

    group('_onLoad fetches owned artworks in parallel', () {
      final ownedArtworks = [artwork('mint1'), artwork('mint2')];

      blocTest<UserProfileBloc, UserProfileState>(
        'calls getUserArtworks with collected tab and lands in state.ownedArtworks',
        setUp: () =>
            stubLoadHappyPath(loadedProfile: profile(), owned: ownedArtworks),
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          verify(
            mockRepository.getUserArtworks(
              any,
              page: anyNamed('page'),
              tab: api.ApiProfileTab.collected,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).called(1);
          final state = bloc.state as UserProfileLoaded;
          expect(state.ownedArtworks, ownedArtworks);
        },
      );
    });

    group('artworkRemoved (optimistic transfer/burn removal)', () {
      // The item just left the viewer's wallets: it must drop from the
      // ownership-based Owned list, but stay on the Created list — "Created"
      // is provenance (works the artist minted), independent of who owns them
      // now. Removing it from Created would wrongly erase authorship history.
      blocTest<UserProfileBloc, UserProfileState>(
        'removes from Owned but leaves Created untouched',
        setUp: () => stubLoadHappyPath(
          loadedProfile: profile(),
          created: [artwork('shared'), artwork('c2')],
          owned: [artwork('shared'), artwork('o2')],
        ),
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await bloc.stream.firstWhere((s) => s is UserProfileLoaded);
          bloc.add(const UserProfileEvent.artworkRemoved('shared'));
        },
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.ownedArtworks?.map((a) => a.mintAccount).toList(), [
            'o2',
          ]);
          expect(state.artworks?.map((a) => a.mintAccount).toList(), [
            'shared',
            'c2',
          ]);
        },
      );
    });

    group('_onLoadMoreArtworks branches by active tab', () {
      final initialCreated = [artwork('c1'), artwork('c2')];
      final initialOwned = [artwork('o1'), artwork('o2')];
      final pageTwoCreated = [artwork('c3')];
      final pageTwoOwned = [artwork('o3')];

      // Bootstrap the bloc's private _allArtworks / _allOwnedArtworks via a
      // cache hit, then dispatch the user-driven event. Pagination merges
      // new pages onto those private lists, so we must seed via load.
      Future<void> loadThenLoadMore(
        UserProfileBloc bloc, {
        required ProfileTab tab,
      }) async {
        when(mockRepository.getCachedProfile(any)).thenAnswer(
          (_) async => CachedProfileData(
            profile: profile(),
            artworks: initialCreated,
            groups: const [],
            youOwnArtworks: const [],
            ownedArtworks: initialOwned,
          ),
        );
        bloc.add(const UserProfileEvent.load(address: testAddress));
        // Let the cache emit settle so _allArtworks is populated.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        // Switch to the tab we want to paginate (also resets sort).
        bloc.add(UserProfileEvent.changeTab(tab: tab));
        // Manually set the next-page cursors via a no-op setSort emit
        // would be circular; instead rely on copyWith via load completion.
        // Simpler: directly add load-more — the bloc reads next*Page from
        // state. We need that field set, which Phase 2's emit will do.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      blocTest<UserProfileBloc, UserProfileState>(
        'paginates Created tab using ApiProfileTab.created',
        setUp: () {
          stubLoadHappyPath(
            loadedProfile: profile(),
            created: initialCreated,
            owned: initialOwned,
          );
          // Phase 2 fetch returns nextPage=1 so load-more has a cursor.
          when(
            mockRepository.getUserArtworks(
              any,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).thenAnswer(
            (_) async => ProfileArtworksResult(
              artworks: initialCreated,
              total: initialCreated.length,
              nextPage: 1,
            ),
          );
          when(
            mockRepository.getUserArtworks(
              any,
              page: 1,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).thenAnswer(
            (_) async =>
                ProfileArtworksResult(artworks: pageTwoCreated, total: 3),
          );
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          await loadThenLoadMore(bloc, tab: ProfileTab.created);
          bloc.add(const UserProfileEvent.loadMoreArtworks());
        },
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          verify(
            mockRepository.getUserArtworks(
              any,
              page: 1,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).called(1);
          verifyNever(
            mockRepository.getUserArtworks(
              any,
              page: 1,
              tab: api.ApiProfileTab.collected,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          );
          final state = bloc.state as UserProfileLoaded;
          expect(state.artworks, [...initialCreated, ...pageTwoCreated]);
          expect(state.ownedArtworks, initialOwned); // untouched
          expect(state.isLoadingMore, false);
          expect(state.hasMoreArtworks, false); // page 1 returned no nextPage
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'paginates Owned tab using ApiProfileTab.collected',
        setUp: () {
          stubLoadHappyPath(
            loadedProfile: profile(),
            created: initialCreated,
            owned: initialOwned,
          );
          // Phase 2 owned fetch returns nextPage=1 so load-more has a cursor.
          when(
            mockRepository.getUserArtworks(
              any,
              tab: api.ApiProfileTab.collected,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).thenAnswer(
            (_) async => ProfileArtworksResult(
              artworks: initialOwned,
              total: initialOwned.length,
              nextPage: 1,
            ),
          );
          when(
            mockRepository.getUserArtworks(
              any,
              page: 1,
              tab: api.ApiProfileTab.collected,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).thenAnswer(
            (_) async =>
                ProfileArtworksResult(artworks: pageTwoOwned, total: 3),
          );
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          await loadThenLoadMore(bloc, tab: ProfileTab.owned);
          bloc.add(const UserProfileEvent.loadMoreArtworks());
        },
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          verify(
            mockRepository.getUserArtworks(
              any,
              page: 1,
              tab: api.ApiProfileTab.collected,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).called(1);
          verifyNever(
            mockRepository.getUserArtworks(
              any,
              page: 1,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          );
          final state = bloc.state as UserProfileLoaded;
          expect(state.ownedArtworks, [...initialOwned, ...pageTwoOwned]);
          expect(state.artworks, initialCreated); // untouched
          expect(state.isLoadingMoreOwned, false);
          expect(state.hasMoreOwned, false);
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'is a no-op on group tabs (collections / curations)',
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        seed: () =>
            UserProfileState.loaded(
                  profile: profile(),
                  artworks: const [],
                  ownedArtworks: const [],
                  activeTab: ProfileTab.collections,
                  nextArtworksPage: 1,
                  nextOwnedPage: 1,
                )
                as UserProfileLoaded,
        act: (bloc) => bloc.add(const UserProfileEvent.loadMoreArtworks()),
        expect: () => const <UserProfileState>[],
        verify: (_) {
          verifyNever(
            mockRepository.getUserArtworks(
              any,
              page: anyNamed('page'),
              tab: anyNamed('tab'),
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          );
        },
      );
    });

    group('_onSetSort re-sorts both Created and Owned lists', () {
      // Pre-load via cache so the bloc's _allArtworks/_allOwnedArtworks
      // are populated before the sort fires.
      final createdItems = [
        artwork('a', title: 'Charlie'),
        artwork('b', title: 'Alpha'),
        artwork('c', title: 'Bravo'),
      ];
      final ownedItems = [
        artwork('x', title: 'Zulu'),
        artwork('y', title: 'Mike'),
      ];

      blocTest<UserProfileBloc, UserProfileState>(
        'sorts both lists alphabetically when sort = name',
        setUp: () {
          // Stub the cache hit AND the Phase 2 fetches to return the same
          // items, so _allArtworks/_allOwnedArtworks end up populated
          // regardless of which finishes last before the sort fires.
          stubLoadHappyPath(
            loadedProfile: profile(),
            created: createdItems,
            owned: ownedItems,
          );
          when(mockRepository.getCachedProfile(any)).thenAnswer(
            (_) async => CachedProfileData(
              profile: profile(),
              artworks: createdItems,
              groups: const [],
              youOwnArtworks: const [],
              ownedArtworks: ownedItems,
            ),
          );
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          // Let the cache hit emit, then dispatch the sort.
          await Future<void>.delayed(const Duration(milliseconds: 10));
          bloc.add(
            const UserProfileEvent.setSort(sort: PortfolioSortOption.name),
          );
        },
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.activeSort, PortfolioSortOption.name);
          expect(state.artworks!.map((a) => a.title).toList(), [
            'Alpha',
            'Bravo',
            'Charlie',
          ]);
          expect(state.ownedArtworks!.map((a) => a.title).toList(), [
            'Mike',
            'Zulu',
          ]);
        },
      );
    });

    group('_onChangeTab default sort', () {
      UserProfileLoaded seedCreated() =>
          UserProfileState.loaded(
                profile: profile(),
                artworks: const [],
                ownedArtworks: const [],
                activeTab: ProfileTab.collections,
                activeSort: PortfolioSortOption.count,
              )
              as UserProfileLoaded;

      blocTest<UserProfileBloc, UserProfileState>(
        'switching to Owned uses recent sort (artwork-list semantics)',
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        seed: seedCreated,
        act: (bloc) =>
            bloc.add(const UserProfileEvent.changeTab(tab: ProfileTab.owned)),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.activeTab, ProfileTab.owned);
          expect(state.activeSort, PortfolioSortOption.recent);
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'switching to Collections uses count sort (group semantics)',
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        seed: () =>
            UserProfileState.loaded(profile: profile()) as UserProfileLoaded,
        act: (bloc) => bloc.add(
          const UserProfileEvent.changeTab(tab: ProfileTab.collections),
        ),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.activeTab, ProfileTab.collections);
          expect(state.activeSort, PortfolioSortOption.count);
        },
      );
    });

    // The profile's Listed tab is the server-side `listed` profile tab —
    // artwork the user listed OR created and someone else listed (webapp
    // parity) — and it is lazily fetched, unlike Created/Owned.
    group('listed tab', () {
      final listed = [artwork('listedMint')];

      void stubListedFetch() {
        when(
          mockRepository.getUserArtworks(
            any,
            page: anyNamed('page'),
            tab: api.ApiProfileTab.listed,
            sort: anyNamed('sort'),
            filter: anyNamed('filter'),
          ),
        ).thenAnswer(
          (_) async =>
              ProfileArtworksResult(artworks: listed, total: listed.length),
        );
      }

      blocTest<UserProfileBloc, UserProfileState>(
        'is not fetched by the initial load',
        setUp: () {
          stubLoadHappyPath(loadedProfile: profile());
          stubListedFetch();
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          expect((bloc.state as UserProfileLoaded).listedArtworks, isNull);
          verifyNever(
            mockRepository.getUserArtworks(
              any,
              page: anyNamed('page'),
              tab: api.ApiProfileTab.listed,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          );
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'opening the tab fetches every linked address, widened with the '
        'session wallets on your OWN profile',
        setUp: () {
          stubLoadHappyPath(
            loadedProfile: profile(linkedAddresses: const ['A1', 'A2']),
          );
          stubListedFetch();
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(const UserProfileEvent.changeTab(tab: ProfileTab.listed));
        },
        wait: const Duration(milliseconds: 100),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.activeTab, ProfileTab.listed);
          expect(state.activeSort, PortfolioSortOption.recent);
          expect(state.listedArtworks, listed);
          // Why the extra address: the backend may not have every seed-derived
          // wallet linked into one account, so on your own profile the query
          // widens to the local session wallets (here the active address,
          // `testAddress`) on top of the linked set. Without that, art held on
          // a wallet the backend hasn't linked never appears on your profile
          // even though the portfolio shows it.
          verify(
            mockRepository.getUserArtworks(
              const ['A1', 'A2', testAddress],
              page: anyNamed('page'),
              tab: api.ApiProfileTab.listed,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).called(1);
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        "another user's profile is NOT widened — it queries only their "
        'linked addresses',
        setUp: () {
          // Not our profile: neither the owner address nor a linked address is
          // in the session.
          when(mockAuthService.currentAddress).thenReturn('SOMEONE_ELSE');
          stubLoadHappyPath(
            loadedProfile: profile(linkedAddresses: const ['A1', 'A2']),
          );
          stubListedFetch();
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(const UserProfileEvent.changeTab(tab: ProfileTab.listed));
        },
        wait: const Duration(milliseconds: 100),
        verify: (bloc) {
          // Why: the own-profile widening must never leak our wallets into
          // someone else's query — that would attribute our art to their
          // profile. Their linked set is the whole scope.
          verify(
            mockRepository.getUserArtworks(
              const ['A1', 'A2'],
              page: anyNamed('page'),
              tab: api.ApiProfileTab.listed,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).called(1);
        },
      );

      // A failed fetch must settle the tab on its empty state rather than
      // leaving it shimmering forever.
      blocTest<UserProfileBloc, UserProfileState>(
        'a failed fetch settles on an empty list',
        setUp: () {
          stubLoadHappyPath(loadedProfile: profile());
          when(
            mockRepository.getUserArtworks(
              any,
              page: anyNamed('page'),
              tab: api.ApiProfileTab.listed,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).thenThrow(Exception('boom'));
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(const UserProfileEvent.changeTab(tab: ProfileTab.listed));
        },
        wait: const Duration(milliseconds: 100),
        verify: (bloc) {
          expect((bloc.state as UserProfileLoaded).listedArtworks, isEmpty);
        },
      );

      // The own-profile test above only works because the session address and
      // the profile's linked address are byte-identical. EVM breaks that: the
      // API returns owner addresses lowercased while local wallets hold the
      // EIP-55 checksummed form, so a raw compare says "not your profile" and
      // the widening silently stops firing for an EVM-only-linked profile —
      // exactly the case the widening exists for (an imported Ethereum wallet
      // the backend hasn't linked). Both sides must be normalised.
      group('EVM address casing', () {
        const evmLower = '0xabcdef0123456789abcdef0123456789abcdef01';
        const evmChecksummed = '0xAbCdEf0123456789aBcDeF0123456789AbCdEf01';

        late MockSessionManager mockSessionManager;

        setUp(() {
          mockSessionManager = MockSessionManager();
          if (sl.isRegistered<SessionManager>()) {
            sl.unregister<SessionManager>();
          }
          sl.registerSingleton<SessionManager>(mockSessionManager);
        });

        tearDown(() async {
          if (sl.isRegistered<SessionManager>()) {
            await sl.unregister<SessionManager>();
          }
        });

        blocTest<UserProfileBloc, UserProfileState>(
          'a checksummed session wallet still matches the lowercased linked '
          'EVM address, so the own-profile widening fires',
          setUp: () {
            when(mockAuthService.currentAddress).thenReturn(evmChecksummed);
            when(
              mockSessionManager.sessionAddresses,
            ).thenReturn({evmChecksummed, 'SOL_ADDR'});
            // Not what this test is about — keep the private-curations gate
            // inert (no session wallet to sign with).
            when(mockSessionManager.sessionWallets).thenReturn(const []);
            when(
              mockAuthService.hasValidWalletSigForAny(any),
            ).thenAnswer((_) async => false);
            stubLoadHappyPath(
              loadedProfile: profile(
                address: evmLower,
                linkedAddresses: const [evmLower],
              ),
            );
            stubListedFetch();
          },
          build: () => UserProfileBloc(
            mockRepository,
            mockCurationRepository,
            mockAuthService,
            mockLedgerVerifyController,
          ),
          act: (bloc) async {
            bloc.add(const UserProfileEvent.load(address: evmLower));
            await Future<void>.delayed(const Duration(milliseconds: 50));
            bloc.add(const UserProfileEvent.changeTab(tab: ProfileTab.listed));
          },
          wait: const Duration(milliseconds: 100),
          verify: (bloc) {
            // `SOL_ADDR` only appears if the profile was recognised as ours;
            // the EVM address is sent lowercased because that is the form the
            // backend matches on.
            verify(
              mockRepository.getUserArtworks(
                const [evmLower, 'SOL_ADDR'],
                page: anyNamed('page'),
                tab: api.ApiProfileTab.listed,
                sort: anyNamed('sort'),
                filter: anyNamed('filter'),
              ),
            ).called(1);
          },
        );
      });
    });

    // Regressions for the Listed slice's backing-list / staleness bugs. Both
    // encode WHY they matter: the Listed tab caches its unsorted full list in
    // the bloc's private `_allListedArtworks`, which sort re-emits verbatim and
    // which load-more appends to — so it must never drift from what the filter
    // actually left on screen.
    group('listed slice staleness', () {
      // Filter that reads as "active" (non-empty listingTypes) so the Listed
      // tab refetches page 0 on apply.
      const activeFilter = api.ExploreFilter(listingTypes: ['buy-now']);

      // FINDING 1: a failed listed refetch settles the tab on its empty state,
      // but the private `_allListedArtworks` used to keep its stale pre-filter
      // contents. A later sort emits `sortArtworks(_allListedArtworks)` (because
      // `listedArtworks != null`), which would resurrect the filtered-out items
      // under a filter badge that says they're gone. The backing list must be
      // synced to what the catch actually emitted.
      blocTest<UserProfileBloc, UserProfileState>(
        'sort after a failed listed refetch does not resurrect filtered-out '
        'items',
        setUp: () {
          // Created is non-empty so the sort guard (all-lists-empty short
          // circuit) doesn't fire and the listed re-sort branch actually runs.
          stubLoadHappyPath(
            loadedProfile: profile(),
            created: [artwork('created1')],
          );
          // Listed page 0: succeeds on first open (2 pre-filter items), then
          // throws on the post-filter refetch.
          var call = 0;
          when(
            mockRepository.getUserArtworks(
              any,
              page: anyNamed('page'),
              tab: api.ApiProfileTab.listed,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).thenAnswer((_) async {
            call++;
            if (call == 1) {
              return ProfileArtworksResult(
                artworks: [artwork('pf1'), artwork('pf2')],
                total: 2,
              );
            }
            throw Exception('refetch boom');
          });
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          bloc.add(const UserProfileEvent.changeTab(tab: ProfileTab.listed));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          // Apply a filter: nulls Listed to shimmer, refetch throws -> empty.
          bloc.add(const UserProfileEvent.setFilter(filter: activeFilter));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          // Change sort: must NOT bring the two pre-filter items back.
          bloc.add(
            const UserProfileEvent.setSort(sort: PortfolioSortOption.name),
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
        },
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.activeSort, PortfolioSortOption.name);
          // The failed refetch left the tab empty; the sort keeps it empty
          // rather than resurrecting pf1/pf2.
          expect(state.listedArtworks, isEmpty);
        },
      );

      // FINDING 2: a listed load-more in flight across a filter change appends a
      // stale old-cursor page onto the (now replaced) list. A generation guard —
      // captured before the load-more's await, bumped by the refetch — must
      // discard the stale page when it lands.
      blocTest<UserProfileBloc, UserProfileState>(
        'stale load-more across a filter change is discarded',
        setUp: () {
          stubLoadHappyPath(loadedProfile: profile());
          // Listed page 0: first open returns [l1, l2] with a next page; the
          // post-filter refetch (delayed) returns the filtered [f1].
          var page0Call = 0;
          when(
            mockRepository.getUserArtworks(
              any,
              page: anyNamed('page'),
              tab: api.ApiProfileTab.listed,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).thenAnswer((_) async {
            page0Call++;
            if (page0Call == 1) {
              return ProfileArtworksResult(
                artworks: [artwork('l1'), artwork('l2')],
                total: 2,
                nextPage: 1,
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return ProfileArtworksResult(artworks: [artwork('f1')], total: 1);
          });
          // Listed page 1 (load-more): lands LAST, after the filter's refetch,
          // so the generation guard is what must drop it.
          when(
            mockRepository.getUserArtworks(
              any,
              page: 1,
              tab: api.ApiProfileTab.listed,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).thenAnswer((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 150));
            return ProfileArtworksResult(
              artworks: [artwork('stale')],
              total: 3,
            );
          });
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          bloc.add(const UserProfileEvent.changeTab(tab: ProfileTab.listed));
          await Future<void>.delayed(const Duration(milliseconds: 40));
          // Kick off the load-more (page 1, slow), then change the filter while
          // it's still in flight.
          bloc.add(const UserProfileEvent.loadMoreArtworks());
          await Future<void>.delayed(const Duration(milliseconds: 10));
          bloc.add(const UserProfileEvent.setFilter(filter: activeFilter));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        },
        wait: const Duration(milliseconds: 300),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          // The filter's page-0 result stands alone; the stale load-more page
          // was fetched but discarded, never spliced on. (PortfolioArtwork uses
          // identity equality, so compare by mint.)
          final mints = state.listedArtworks!
              .map((a) => a.mintAccount)
              .toList();
          expect(mints, ['f1']);
          expect(mints, isNot(contains('stale')));
          expect(state.isLoadingMoreListed, false);
          // Prove the race actually happened: the stale page-1 fetch WAS issued.
          verify(
            mockRepository.getUserArtworks(
              any,
              page: 1,
              tab: api.ApiProfileTab.listed,
              sort: anyNamed('sort'),
              filter: anyNamed('filter'),
            ),
          ).called(1);
        },
      );
    });

    group('_onSetGroupSearch', () {
      UserProfileLoaded seedCollections() =>
          UserProfileState.loaded(
                profile: profile(),
                groups: const [
                  ArtGroup(
                    id: 'collection:c1',
                    type: ArtGroupType.collection,
                    name: 'CoolCollection',
                    thumbnailUrl: null,
                    artworkCount: 3,
                  ),
                ],
                activeTab: ProfileTab.collections,
                activeSort: PortfolioSortOption.count,
              )
              as UserProfileLoaded;

      // WHY: group tabs filter client-side off state.groupSearch — the query
      // must land on state (normalized: trimmed, empty → null) for the
      // rendering layer and the filter badge to react.
      blocTest<UserProfileBloc, UserProfileState>(
        'stores the trimmed query and normalizes an empty one to null',
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        seed: seedCollections,
        act: (bloc) {
          bloc.add(const UserProfileEvent.setGroupSearch(query: ' cool '));
          bloc.add(const UserProfileEvent.setGroupSearch(query: '   '));
        },
        expect: () => [
          isA<UserProfileLoaded>().having(
            (s) => s.groupSearch,
            'groupSearch',
            'cool',
          ),
          isA<UserProfileLoaded>().having(
            (s) => s.groupSearch,
            'groupSearch',
            null,
          ),
        ],
      );

      // WHY: the search is tab-specific (collection names vs curation names)
      // — switching tabs must drop it rather than filtering the next tab.
      blocTest<UserProfileBloc, UserProfileState>(
        'clears the search on tab change',
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        seed: seedCollections,
        act: (bloc) {
          bloc.add(const UserProfileEvent.setGroupSearch(query: 'cool'));
          bloc.add(const UserProfileEvent.changeTab(tab: ProfileTab.curations));
        },
        skip: 1,
        expect: () => [
          isA<UserProfileLoaded>()
              .having((s) => s.activeTab, 'activeTab', ProfileTab.curations)
              .having((s) => s.groupSearch, 'groupSearch', null),
        ],
      );
    });

    // Curations merge into the groups list as curation-typed ArtGroups
    // (keyed by curation id, which CurationScreen uses to fetch artworks).
    // Own profile fetches the signed-in user's curations (no owner arg);
    // other profiles fetch that user's public curations by owner address.
    group('curations merge into groups', () {
      const curation = UserCuration(
        id: 'cur-1',
        name: 'My Picks',
        artworkCount: 2,
        thumbnailUrls: ['https://img/1.png'],
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'own profile: curations land in groups as curation ArtGroups',
        setUp: () {
          stubLoadHappyPath(loadedProfile: profile());
          // Own profile now fetches scoped to the viewed profile's owner
          // (never null) so the backend resolves the private-read gate against
          // THIS profile rather than the login wallet's.
          when(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).thenAnswer((_) async => const [curation]);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          final curations = state.groups!
              .where((g) => g.type == ArtGroupType.curation)
              .toList();
          expect(curations, hasLength(1));
          expect(curations.single.id, 'cur-1');
          expect(curations.single.name, 'My Picks');
          expect(curations.single.artworkCount, 2);
          expect(curations.single.thumbnailUrl, 'https://img/1.png');
          // The tile subtitle renders "Curation • {creatorName}" — the
          // profile's username, matching the Collections tab's label.
          expect(curations.single.creatorName, 'alice');
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        "other user's profile: fetches that user's public curations by owner address",
        setUp: () {
          when(mockAuthService.currentAddress).thenReturn('SOMEONE_ELSE');
          stubLoadHappyPath(loadedProfile: profile());
          when(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).thenAnswer((_) async => const [curation]);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          // The viewed user's address is passed as the owner filter.
          verify(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).called(1);
          final state = bloc.state as UserProfileLoaded;
          final curations = state.groups!
              .where((g) => g.type == ArtGroupType.curation)
              .toList();
          expect(curations.single.id, 'cur-1');
        },
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'curations fetch failure still delivers collections',
        setUp: () {
          stubLoadHappyPath(loadedProfile: profile());
          when(
            mockRepository.getUserCollections(any, page: anyNamed('page')),
          ).thenAnswer(
            (_) async => const [
              ArtGroup(
                id: 'col-1',
                type: ArtGroupType.collection,
                name: 'Col',
                thumbnailUrl: null,
                artworkCount: 1,
              ),
            ],
          );
          when(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).thenThrow(Exception('401'));
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.groups!.map((g) => g.id), ['col-1']);
        },
      );
    });

    // Private curations are readable when ANY session wallet presents a valid
    // wallet-sig — the gate spans the whole session, not just the active signer
    // (backend gates profile-wide; the Dio interceptor attaches every sig).
    // These encode the three own-profile branches of `_resolvePrivateCurationsGate`.
    group('private curations session gate', () {
      const curation = UserCuration(
        id: 'cur-private',
        name: 'Private Picks',
        artworkCount: 2,
        thumbnailUrls: ['https://img/p.png'],
      );

      late MockSessionManager mockSessionManager;

      WalletInfo wallet(String address, WalletType type) => WalletInfo(
        id: 'id-$address',
        address: address,
        name: address,
        walletType: type,
        chain: 'solana',
      );

      setUp(() {
        mockSessionManager = MockSessionManager();
        if (sl.isRegistered<SessionManager>()) {
          sl.unregister<SessionManager>();
        }
        sl.registerSingleton<SessionManager>(mockSessionManager);
      });

      tearDown(() async {
        if (sl.isRegistered<SessionManager>()) {
          await sl.unregister<SessionManager>();
        }
      });

      // A verified NON-active session wallet that BELONGS to the viewed profile
      // (wallet B linked to this profile while A is active) already carries an
      // attached cookie, so the private fetch authorizes with no prompt and no
      // auto-sign, and the private curation lands in groups.
      blocTest<UserProfileBloc, UserProfileState>(
        'verified non-active session wallet → no CTA, private groups included',
        setUp: () {
          stubLoadHappyPath(
            loadedProfile: profile(
              linkedAddresses: const [testAddress, 'WALLET_B'],
            ),
          );
          when(
            mockSessionManager.sessionAddresses,
          ).thenReturn({testAddress, 'WALLET_B'});
          when(mockSessionManager.sessionWallets).thenReturn([
            wallet(testAddress, WalletType.ledger),
            wallet('WALLET_B', WalletType.hd),
          ]);
          when(
            mockAuthService.hasValidWalletSigForAny(any),
          ).thenAnswer((_) async => true);
          when(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).thenAnswer((_) async => const [curation]);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.showVerifyPrivateCurationsCta, isFalse);
          final curations = state.groups!
              .where((g) => g.type == ArtGroupType.curation)
              .toList();
          expect(curations.single.id, 'cur-private');
          // No wallet needs verifying — nothing was auto-signed.
          verifyNever(mockAuthService.verifySessionWallet(any));
        },
      );

      // No session wallet verified yet, but a locally-signable (HD) wallet is
      // present: silently sign it so the fetch authorizes on this same load —
      // no prompt, no active-wallet switch — and hide the CTA. The post-sign
      // re-check sees the freshly-attached sig, so no CTA.
      blocTest<UserProfileBloc, UserProfileState>(
        'no verified wallet but HD present, sign succeeds → no CTA',
        setUp: () {
          stubLoadHappyPath(
            loadedProfile: profile(
              linkedAddresses: const [testAddress, 'HD_ADDR'],
            ),
          );
          when(
            mockSessionManager.sessionAddresses,
          ).thenReturn({testAddress, 'HD_ADDR'});
          when(mockSessionManager.sessionWallets).thenReturn([
            wallet(testAddress, WalletType.ledger),
            wallet('HD_ADDR', WalletType.hd),
          ]);
          // A successful silent sign attaches a sig: false before, true after.
          var verified = false;
          // Gate's first (disk-hydrating) check sees no sig yet, so it proceeds
          // to auto-sign; the post-sign in-memory re-check then sees the sig.
          when(
            mockAuthService.hasValidWalletSigForAny(any),
          ).thenAnswer((_) async => verified);
          when(
            mockAuthService.hasAnyVerifiedSession(any),
          ).thenAnswer((_) => verified);
          when(mockAuthService.verifySessionWallet(any)).thenAnswer((_) async {
            verified = true;
          });
          when(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).thenAnswer((_) async => const [curation]);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          // The first HD/imported session wallet is signed, not the (Ledger)
          // active wallet.
          verify(mockAuthService.verifySessionWallet('HD_ADDR')).called(1);
          final state = bloc.state as UserProfileLoaded;
          expect(state.showVerifyPrivateCurationsCta, isFalse);
        },
      );

      // Same setup, but the silent sign fails non-fatally (offline / keystore /
      // 5xx): verifySessionWallet swallows the error and NO sig is attached. The
      // gate must re-check and surface the CTA — private curations shouldn't
      // vanish with no way for the user to retry.
      blocTest<UserProfileBloc, UserProfileState>(
        'no verified wallet, HD present but sign fails → CTA shown',
        setUp: () {
          stubLoadHappyPath(
            loadedProfile: profile(
              linkedAddresses: const [testAddress, 'HD_ADDR'],
            ),
          );
          when(
            mockSessionManager.sessionAddresses,
          ).thenReturn({testAddress, 'HD_ADDR'});
          when(mockSessionManager.sessionWallets).thenReturn([
            wallet(testAddress, WalletType.ledger),
            wallet('HD_ADDR', WalletType.hd),
          ]);
          // Sign is a no-op (swallowed failure) → still no verified session.
          when(
            mockAuthService.hasValidWalletSigForAny(any),
          ).thenAnswer((_) async => false);
          when(mockAuthService.hasAnyVerifiedSession(any)).thenReturn(false);
          when(
            mockAuthService.verifySessionWallet(any),
          ).thenAnswer((_) async {});
          when(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).thenAnswer((_) async => const [curation]);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          verify(mockAuthService.verifySessionWallet('HD_ADDR')).called(1);
          final state = bloc.state as UserProfileLoaded;
          expect(state.showVerifyPrivateCurationsCta, isTrue);
        },
      );

      // Only Ledger / watch-only session wallets remain and none is verified:
      // there is nothing to sign silently, so surface the manual verify CTA.
      blocTest<UserProfileBloc, UserProfileState>(
        'only Ledger session wallets (none verified) → CTA shown',
        setUp: () {
          stubLoadHappyPath(loadedProfile: profile());
          when(mockSessionManager.sessionAddresses).thenReturn({testAddress});
          when(
            mockSessionManager.sessionWallets,
          ).thenReturn([wallet(testAddress, WalletType.ledger)]);
          when(
            mockAuthService.hasValidWalletSigForAny(any),
          ).thenAnswer((_) async => false);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.showVerifyPrivateCurationsCta, isTrue);
          verifyNever(mockAuthService.verifySessionWallet(any));
        },
      );

      // Loading your own profile through a NON-active linked session wallet
      // (active = WALLET_A, viewing WALLET_B, both in session) must still count
      // as own-profile: the curation fetch goes out private-inclusive (no owner
      // filter), not the public-only by-address path used for other users.
      blocTest<UserProfileBloc, UserProfileState>(
        'load via non-active session wallet → own-profile private fetch',
        setUp: () {
          when(mockAuthService.currentAddress).thenReturn('WALLET_A');
          // Same user: WALLET_A (active) and WALLET_B are both linked to this
          // one profile, so viewing it through B still counts as own-profile.
          stubLoadHappyPath(
            loadedProfile: profile(
              address: 'WALLET_B',
              linkedAddresses: const ['WALLET_A', 'WALLET_B'],
            ),
          );
          when(
            mockSessionManager.sessionAddresses,
          ).thenReturn({'WALLET_A', 'WALLET_B'});
          when(mockSessionManager.sessionWallets).thenReturn([
            wallet('WALLET_A', WalletType.ledger),
            wallet('WALLET_B', WalletType.hd),
          ]);
          // A session wallet is already verified → no CTA, no auto-sign.
          when(
            mockAuthService.hasValidWalletSigForAny(any),
          ).thenAnswer((_) async => true);
          when(
            mockCurationRepository.getCurations(ownerAddress: 'WALLET_B'),
          ).thenAnswer((_) async => const [curation]);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: 'WALLET_B')),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          // Own-profile private read now targets the VIEWED profile explicitly
          // (owner = WALLET_B) — never null, which would let the backend fall
          // back to the login wallet A's profile.
          verify(
            mockCurationRepository.getCurations(ownerAddress: 'WALLET_B'),
          ).called(1);
          verifyNever(mockCurationRepository.getCurations());
          final state = bloc.state as UserProfileLoaded;
          expect(state.showVerifyPrivateCurationsCta, isFalse);
          final curations = state.groups!
              .where((g) => g.type == ArtGroupType.curation)
              .toList();
          expect(curations.single.id, 'cur-private');
        },
      );

      // A valid `wallet-sig` that lives only on disk for a NON-active session
      // wallet (cold start, before login hydrates it) must satisfy the gate:
      // the disk-hydrating check honours it, so no CTA and private curations
      // load without an auto-sign. The memory-only check would miss it.
      blocTest<UserProfileBloc, UserProfileState>(
        'disk-only sig on non-active wallet → no CTA, private groups included',
        setUp: () {
          stubLoadHappyPath(
            loadedProfile: profile(
              linkedAddresses: const [testAddress, 'WALLET_B'],
            ),
          );
          when(
            mockSessionManager.sessionAddresses,
          ).thenReturn({testAddress, 'WALLET_B'});
          when(mockSessionManager.sessionWallets).thenReturn([
            wallet(testAddress, WalletType.ledger),
            wallet('WALLET_B', WalletType.hd),
          ]);
          // Disk sig hydrated for the non-active wallet → gate passes.
          when(
            mockAuthService.hasValidWalletSigForAny(any),
          ).thenAnswer((_) async => true);
          when(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).thenAnswer((_) async => const [curation]);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.showVerifyPrivateCurationsCta, isFalse);
          final curations = state.groups!
              .where((g) => g.type == ArtGroupType.curation)
              .toList();
          expect(curations.single.id, 'cur-private');
          // Disk sig already authorizes — nothing was auto-signed.
          verifyNever(mockAuthService.verifySessionWallet(any));
        },
      );

      // Regression (the A/B two-profile bug): active/login wallet A belongs to
      // profile P1; a linked session wallet B belongs to a DIFFERENT profile
      // P2. Viewing P2 counts as own-profile (B is in session), but P2's private
      // curations require a proof for one of *P2's* wallets — A's proof is
      // irrelevant. Two invariants:
      //   1. The curations fetch targets the VIEWED profile (owner = WALLET_B),
      //      never null — a null owner let the backend fall back to login wallet
      //      A and return P1/A's curations (private included) under P2.
      //   2. The verify CTA gate ignores A's valid sig (a different profile) and
      //      keys only off P2's wallets — so with B (Ledger) unverified the CTA
      //      still shows instead of being wrongly suppressed by A's sig.
      blocTest<UserProfileBloc, UserProfileState>(
        'viewing another profile via a linked wallet targets that profile and '
        "ignores the login wallet's sig for the CTA",
        setUp: () {
          when(mockAuthService.currentAddress).thenReturn('WALLET_A');
          // Viewed profile P2: owner WALLET_B, and A is NOT one of its wallets.
          stubLoadHappyPath(
            loadedProfile: profile(
              address: 'WALLET_B',
              linkedAddresses: const ['WALLET_B'],
            ),
          );
          when(
            mockSessionManager.sessionAddresses,
          ).thenReturn({'WALLET_A', 'WALLET_B'});
          when(mockSessionManager.sessionWallets).thenReturn([
            wallet('WALLET_A', WalletType.hd),
            wallet('WALLET_B', WalletType.ledger),
          ]);
          // Only WALLET_A (login, a DIFFERENT profile) carries a valid sig; the
          // viewed profile's wallet B has none. The gate must scope to B and so
          // NOT see A's sig.
          when(mockAuthService.hasValidWalletSigForAny(any)).thenAnswer((
            inv,
          ) async {
            final addrs = inv.positionalArguments.first as Iterable<String>;
            return addrs.contains('WALLET_A');
          });
          when(
            mockCurationRepository.getCurations(ownerAddress: 'WALLET_B'),
          ).thenAnswer((_) async => const []);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: 'WALLET_B')),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          // Invariant 1: fetch is scoped to the viewed profile, never null.
          verify(
            mockCurationRepository.getCurations(ownerAddress: 'WALLET_B'),
          ).called(1);
          verifyNever(mockCurationRepository.getCurations());
          // Invariant 2: A's sig (different profile) doesn't suppress the CTA;
          // B (viewed profile, Ledger, unverified) drives it → CTA shown, and
          // no wallet from a different profile is silently signed.
          final state = bloc.state as UserProfileLoaded;
          expect(state.showVerifyPrivateCurationsCta, isTrue);
          verifyNever(mockAuthService.verifySessionWallet(any));
        },
      );

      // The manual verify CTA can only be satisfied by a Ledger BLE sign. With
      // no Ledger session wallet (here: a social wallet), tapping verify must
      // NOT pop the BLE sheet — it can never succeed for a social/watch-only
      // address — so no Ledger verification is requested.
      blocTest<UserProfileBloc, UserProfileState>(
        'verify event with no Ledger session wallet → no Ledger request',
        setUp: () {
          stubLoadHappyPath(loadedProfile: profile());
          when(mockSessionManager.sessionAddresses).thenReturn({testAddress});
          when(
            mockSessionManager.sessionWallets,
          ).thenReturn([wallet(testAddress, WalletType.social)]);
          when(
            mockAuthService.hasValidWalletSigForAny(any),
          ).thenAnswer((_) async => false);
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          // Let the load settle so _currentAddress is set before verifying.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(const UserProfileEvent.verifyForPrivateCurations());
        },
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          verifyNever(mockLedgerVerifyController.requestVerification(any));
          final state = bloc.state as UserProfileLoaded;
          expect(state.isVerifyingCurations, isFalse);
        },
      );
    });

    group('you own banner count', () {
      // Regression: the "You own N artworks" banner must show the group's
      // server `total`, not the fetched page length. getYouOwnArtworks returns
      // a single drilldown page (capped at pageSize ~20), so deriving the count
      // from `artworks.length` under-reports every collector who owns more than
      // one page — the count must come from PortfolioArtworksResult.total.
      blocTest<UserProfileBloc, UserProfileState>(
        'uses server total, not the fetched page length',
        setUp: () {
          when(mockAuthService.currentAddress).thenReturn('SOMEONE_ELSE');
          stubLoadHappyPath(loadedProfile: profile());
          // 20-item page, but the artist group actually holds 98.
          final page = [for (var i = 0; i < 20; i++) artwork('mint-$i')];
          when(mockRepository.getYouOwnArtworks(any)).thenAnswer(
            (_) async => PortfolioArtworksResult(artworks: page, total: 98),
          );
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.load(address: testAddress)),
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.profile.ownedArtworkCount, 98);
          // The preloaded page (for thumbnails + drilldown) is still the page.
          expect(state.youOwnArtworks!.length, 20);
        },
      );

      // A burn or external transfer of one of this artist's works the viewer
      // owns must tick the banner count down. The removal signal never fires
      // for a move to another session wallet, so reaching the handler already
      // means a genuine loss — the count drops and the item leaves the page.
      blocTest<UserProfileBloc, UserProfileState>(
        'decrements the count when an owned artwork is burnt/transferred out',
        setUp: () {
          when(mockAuthService.currentAddress).thenReturn('SOMEONE_ELSE');
          stubLoadHappyPath(loadedProfile: profile());
          final page = [for (var i = 0; i < 20; i++) artwork('mint-$i')];
          when(mockRepository.getYouOwnArtworks(any)).thenAnswer(
            (_) async => PortfolioArtworksResult(artworks: page, total: 98),
          );
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(const UserProfileEvent.artworkRemoved('mint-3'));
        },
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.profile.ownedArtworkCount, 97);
          expect(state.youOwnArtworks!.length, 19);
          expect(
            state.youOwnArtworks!.any((a) => a.mintAccount == 'mint-3'),
            isFalse,
          );
        },
      );

      // An artwork removed while this profile is on screen that isn't in the
      // viewer's owned set for this artist (e.g. a different artist's piece, or
      // beyond the loaded page — unattributable) must NOT touch the count; the
      // next full reload reconciles it against the server total.
      blocTest<UserProfileBloc, UserProfileState>(
        'leaves the count untouched when the removed mint is not owned here',
        setUp: () {
          when(mockAuthService.currentAddress).thenReturn('SOMEONE_ELSE');
          stubLoadHappyPath(loadedProfile: profile());
          final page = [for (var i = 0; i < 20; i++) artwork('mint-$i')];
          when(mockRepository.getYouOwnArtworks(any)).thenAnswer(
            (_) async => PortfolioArtworksResult(artworks: page, total: 98),
          );
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          bloc.add(const UserProfileEvent.artworkRemoved('not-in-page'));
        },
        wait: const Duration(milliseconds: 50),
        verify: (bloc) {
          final state = bloc.state as UserProfileLoaded;
          expect(state.profile.ownedArtworkCount, 98);
          expect(state.youOwnArtworks!.length, 20);
        },
      );
    });

    group('curations refresh signal', () {
      const curation = UserCuration(
        id: 'cur-1',
        name: 'My Picks',
        artworkCount: 2,
      );

      late CurationsRefreshSignal curationsSignal;

      setUp(() {
        curationsSignal = CurationsRefreshSignal();
        if (sl.isRegistered<CurationsRefreshSignal>()) {
          sl.unregister<CurationsRefreshSignal>();
        }
        sl.registerSingleton<CurationsRefreshSignal>(curationsSignal);
      });

      tearDown(() async {
        curationsSignal.dispose();
        if (sl.isRegistered<CurationsRefreshSignal>()) {
          await sl.unregister<CurationsRefreshSignal>();
        }
      });

      // Encodes the delete/edit-curation flow started FROM the profile page:
      // the mutation fires the app-wide curations signal, and the profile —
      // mounted under the pushed CurationScreen route — must refetch its
      // curation groups so the change shows on pop-back without a manual
      // reload. A regression that drops the subscription leaves the deleted
      // curation on the Curations tab.
      blocTest<UserProfileBloc, UserProfileState>(
        'refetches curation groups when the curations signal fires, '
        'dropping a deleted curation',
        setUp: () {
          stubLoadHappyPath(loadedProfile: profile());
          var fetchCount = 0;
          when(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).thenAnswer((_) async {
            fetchCount++;
            // First load: one curation. After the signal: it was deleted.
            return fetchCount == 1 ? const [curation] : const <UserCuration>[];
          });
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) async {
          bloc.add(const UserProfileEvent.load(address: testAddress));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          curationsSignal.requestRefresh();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        verify: (bloc) {
          verify(
            mockCurationRepository.getCurations(ownerAddress: testAddress),
          ).called(2);
          final state = bloc.state as UserProfileLoaded;
          expect(
            state.groups!.where((g) => g.type == ArtGroupType.curation),
            isEmpty,
          );
        },
      );
    });

    // Error-state coverage for the Result.guard-based load paths. These
    // assertions encode the contract that repository failures classify
    // through AppFailure and land in UserProfileError with a stable
    // "Failed to load profile" prefix the UI keys off.
    group('error states (Result pattern)', () {
      blocTest<UserProfileBloc, UserProfileState>(
        'loadByUsername emits error when repository throws',
        setUp: () {
          when(
            mockRepository.getUserProfileByUsername(any),
          ).thenThrow(Exception('boom'));
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.loadByUsername(username: 'alice')),
        expect: () => [
          const UserProfileState.loading(),
          isA<UserProfileError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Failed to load profile'), contains('boom')),
          ),
        ],
      );

      blocTest<UserProfileBloc, UserProfileState>(
        'loadByUsername emits "User not found" when address is empty',
        setUp: () {
          when(
            mockRepository.getUserProfileByUsername(any),
          ).thenAnswer((_) async => profile(address: ''));
        },
        build: () => UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        ),
        act: (bloc) =>
            bloc.add(const UserProfileEvent.loadByUsername(username: 'ghost')),
        expect: () => [
          const UserProfileState.loading(),
          isA<UserProfileError>().having(
            (e) => e.message,
            'message',
            'User not found',
          ),
        ],
      );
    });

    // Follow is the one social action with a number attached to it. The
    // webapp (`useFollowUser`) moves `followerCount` with the button and puts
    // it back — plus a toast — if the request fails. Mobile flipped only the
    // label, so a successful follow read as a no-op and a failed one was
    // indistinguishable from a tap that never registered.
    group('follow toggle', () {
      Future<void> settle(UserProfileBloc bloc) async {
        bloc.add(const UserProfileEvent.load(address: testAddress));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      test('a successful follow raises the follower count on screen', () async {
        stubLoadHappyPath(loadedProfile: profile(followers: 10));
        when(mockRepository.followUser(any)).thenAnswer((_) async {});
        final bloc = UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        );
        await settle(bloc);

        bloc.add(const UserProfileEvent.toggleFollow());
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final state = bloc.state as UserProfileLoaded;
        expect(state.isFollowing, isTrue);
        expect(state.profile.followerCount, 11);
        await bloc.close();
      });

      test('a failed follow restores the count and says so', () async {
        stubLoadHappyPath(loadedProfile: profile(followers: 10));
        when(mockRepository.followUser(any)).thenThrow(Exception('offline'));
        final bloc = UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        );
        await settle(bloc);

        final errors = <String>[];
        final sub = bloc.transientErrors.listen(errors.add);

        bloc.add(const UserProfileEvent.toggleFollow());
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final state = bloc.state as UserProfileLoaded;
        expect(state.isFollowing, isFalse);
        expect(state.profile.followerCount, 10);
        // Reverting in silence is the Rule-12 violation this replaces.
        expect(errors, ['Failed to follow']);

        await sub.cancel();
        await bloc.close();
      });

      test('a failure landing after the screen is popped stays quiet', () async {
        // Tap Follow, pop the screen, then let the request fail: `close` has
        // already closed `_transientErrors`, so reporting the failure threw
        // "Cannot add event after closing" out of the handler as an unhandled
        // error. Nobody is left to see the message — dropping it is the point.
        stubLoadHappyPath(loadedProfile: profile(followers: 10));
        final inFlight = Completer<void>();
        when(mockRepository.followUser(any)).thenAnswer((_) async {
          await inFlight.future;
          throw Exception('offline');
        });
        final bloc = UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        );
        await settle(bloc);

        bloc.add(const UserProfileEvent.toggleFollow());
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await bloc.close();

        inFlight.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      test('a failed unfollow lowers nothing and names the action', () async {
        stubLoadHappyPath(loadedProfile: profile(followers: 10));
        when(mockAuthService.isFollowing(any)).thenReturn(true);
        when(mockRepository.unfollowUser(any)).thenThrow(Exception('offline'));
        final bloc = UserProfileBloc(
          mockRepository,
          mockCurationRepository,
          mockAuthService,
          mockLedgerVerifyController,
        );
        await settle(bloc);

        final errors = <String>[];
        final sub = bloc.transientErrors.listen(errors.add);

        bloc.add(const UserProfileEvent.toggleFollow());
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final state = bloc.state as UserProfileLoaded;
        expect(state.isFollowing, isTrue);
        expect(state.profile.followerCount, 10);
        expect(errors, ['Failed to unfollow']);

        await sub.cancel();
        await bloc.close();
      });
    });
  });
}
