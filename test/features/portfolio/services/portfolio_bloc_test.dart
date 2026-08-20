import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/network/ledger_verify_controller.dart';
import 'package:mallow_wallet/features/artwork/widgets/add_to_curation_sheet.dart';
import 'package:mallow_wallet/features/curations/data/curation_repository.dart';
import 'package:mallow_wallet/features/curations/services/curations_refresh_signal.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_refresh_signal.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'portfolio_bloc_test.mocks.dart';

PortfolioArtwork _artwork({
  required String mint,
  required String title,
  String artist = 'Artist',
  double aspectRatio = 1.0,
}) {
  return PortfolioArtwork(
    mintAccount: mint,
    title: title,
    imageUrl: 'https://example.com/$mint.png',
    artistName: artist,
    aspectRatio: aspectRatio,
  );
}

ArtGroup _group({
  required String id,
  required ArtGroupType type,
  required String name,
  int count = 1,
  String? artistAddress,
  String? artistUsername,
}) {
  return ArtGroup(
    id: id,
    type: type,
    name: name,
    thumbnailUrl: null,
    artworkCount: count,
    artistAddress: artistAddress,
    artistUsername: artistUsername,
  );
}

@GenerateMocks([
  PortfolioRepository,
  WalletManager,
  CurationRepository,
  AuthService,
  LedgerVerifyController,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockPortfolioRepository mockRepository;
  late MockWalletManager mockWalletManager;
  late MockCurationRepository mockCurationRepository;
  late MockAuthService mockAuthService;
  late MockLedgerVerifyController mockLedgerVerifyController;

  final artworks = [
    _artwork(mint: 'mint1', title: 'Apple'),
    _artwork(mint: 'mint2', title: 'Banana'),
  ];

  final groups = [
    _group(
      id: 'artist:a1',
      type: ArtGroupType.artist,
      name: 'Alice',
      count: 5,
      artistAddress: 'AliceAddr1111',
      artistUsername: 'wonderland',
    ),
    _group(id: 'artist:a2', type: ArtGroupType.artist, name: 'Bob', count: 2),
    _group(
      id: 'collection:c1',
      type: ArtGroupType.collection,
      name: 'CoolCollection',
      count: 3,
    ),
    _group(id: 'curation:cu1', type: ArtGroupType.curation, name: 'Showcase'),
  ];

  PortfolioBloc buildBloc() => PortfolioBloc(
    mockRepository,
    mockCurationRepository,
    mockAuthService,
    mockLedgerVerifyController,
    mockWalletManager,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockRepository = MockPortfolioRepository();
    mockWalletManager = MockWalletManager();
    mockCurationRepository = MockCurationRepository();
    mockAuthService = MockAuthService();
    mockLedgerVerifyController = MockLedgerVerifyController();

    when(
      mockWalletManager.onWalletChanged,
    ).thenAnswer((_) => const Stream<String>.empty());
    when(mockWalletManager.getAddress()).thenAnswer((_) async => 'TestAddr');
    when(
      mockCurationRepository.getCurations(
        mintAccount: anyNamed('mintAccount'),
        ownerAddress: anyNamed('ownerAddress'),
      ),
    ).thenAnswer((_) async => const []);
    when(
      mockAuthService.currentWalletNeedsLedgerVerification(),
    ).thenAnswer((_) async => false);
    when(mockAuthService.currentUser).thenReturn(null);
    when(mockAuthService.currentAddress).thenReturn(null);

    when(mockRepository.getOwnedArtworks(page: anyNamed('page'))).thenAnswer(
      (_) async =>
          PortfolioArtworksResult(artworks: artworks, total: artworks.length),
    );
    when(
      mockRepository.getGroupedPortfolio(),
    ).thenAnswer((_) async => PortfolioGroupsResult(groups: groups));
    // No cached snapshot by default — loads start from the skeleton.
    when(mockRepository.getCachedSnapshot()).thenAnswer((_) async => null);
  });

  group('PortfolioBloc.load', () {
    blocTest<PortfolioBloc, PortfolioState>(
      'emits [loading, loaded] with sorted groups (count desc) on success',
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      expect: () => [
        isA<PortfolioLoading>(),
        isA<PortfolioLoaded>()
            .having((s) => s.totalArtworks, 'totalArtworks', 2)
            .having((s) => s.allArtworks, 'allArtworks', artworks)
            .having(
              (s) => s.activeSort,
              'activeSort',
              PortfolioSortOption.count,
            )
            .having((s) => s.groups.length, 'groups.length', 4)
            // Sort by count descending: Alice (5), CoolCollection (3),
            // Bob (2), Showcase (1).
            .having(
              (s) => s.groups.map((g) => g.name).toList(),
              'group order',
              ['Alice', 'CoolCollection', 'Bob', 'Showcase'],
            ),
      ],
    );

    // Encodes the cache-first contract: a load with a cached snapshot must
    // paint it immediately (marked refreshing, so the UI can show content
    // instead of skeletons) and then replace it with the fresh fetch — the
    // Art tab never blocks on the network when a snapshot exists.
    blocTest<PortfolioBloc, PortfolioState>(
      'paints the cached snapshot immediately, then the fresh fetch',
      setUp: () {
        when(mockRepository.getCachedSnapshot()).thenAnswer(
          (_) async => PortfolioSnapshot(
            artworks: PortfolioArtworksResult(
              artworks: [_artwork(mint: 'cachedMint', title: 'Cached')],
              total: 1,
            ),
            groups: PortfolioGroupsResult(
              groups: [
                _group(
                  id: 'artist:a1',
                  type: ArtGroupType.artist,
                  name: 'Alice',
                  count: 5,
                ),
              ],
            ),
          ),
        );
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      expect: () => [
        isA<PortfolioLoaded>()
            .having((s) => s.isRefreshing, 'isRefreshing', true)
            .having(
              (s) => s.allArtworks.single.mintAccount,
              'cached mint',
              'cachedMint',
            ),
        isA<PortfolioLoaded>()
            .having((s) => s.isRefreshing, 'isRefreshing', false)
            .having((s) => s.allArtworks, 'fresh artworks', artworks),
      ],
    );

    // With a cached paint on screen, a failed revalidation must keep the
    // cached content (clearing the refresh flag) instead of replacing it
    // with a full-screen error.
    blocTest<PortfolioBloc, PortfolioState>(
      'keeps the cached snapshot when the fresh fetch fails',
      setUp: () {
        when(mockRepository.getCachedSnapshot()).thenAnswer(
          (_) async => PortfolioSnapshot(
            artworks: PortfolioArtworksResult(
              artworks: [_artwork(mint: 'cachedMint', title: 'Cached')],
              total: 1,
            ),
            groups: const PortfolioGroupsResult(groups: []),
          ),
        );
        when(
          mockRepository.getOwnedArtworks(page: anyNamed('page')),
        ).thenThrow(Exception('Network down'));
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.isRefreshing,
          'isRefreshing',
          true,
        ),
        isA<PortfolioLoaded>()
            .having((s) => s.isRefreshing, 'isRefreshing', false)
            .having(
              (s) => s.allArtworks.single.mintAccount,
              'cached mint kept',
              'cachedMint',
            ),
      ],
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'emits [loading, error] when getOwnedArtworks throws',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(page: anyNamed('page')),
        ).thenThrow(Exception('Network down'));
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      expect: () => [
        isA<PortfolioLoading>(),
        isA<PortfolioError>().having(
          (e) => e.message,
          'message',
          contains('Failed to load portfolio'),
        ),
      ],
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'restores both saved view-mode preferences into loaded state',
      setUp: () {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'artwork_view_mode': 'detail',
          'portfolio_view_mode': 'list',
        });
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      skip: 1,
      expect: () => [
        isA<PortfolioLoaded>()
            .having(
              (s) => s.artworkViewMode,
              'artworkViewMode',
              ArtworkViewMode.detail,
            )
            .having(
              (s) => s.groupViewMode,
              'groupViewMode',
              PortfolioViewMode.list,
            ),
      ],
    );

    // Pre-split installs stored the artwork layout as a masonry bool plus a
    // list/grid string under the key that now belongs to art-groups. Users
    // must keep the layout they picked rather than being reset to masonry.
    blocTest<PortfolioBloc, PortfolioState>(
      'migrates the legacy masonry/list pair to the artwork view mode',
      setUp: () {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'portfolio_view_mode': 'list',
          'portfolio_prefers_masonry': false,
        });
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      skip: 1,
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.artworkViewMode,
          'artworkViewMode',
          ArtworkViewMode.detail,
        ),
      ],
    );
  });

  group('PortfolioBloc.artworkRemoved', () {
    // Optimistic removal: a confirmed transfer/burn drops the item from the
    // flat list on the spot, so it doesn't linger until the reindex refetch.
    // Encodes that the tile disappears AND the count decrements together —
    // a removal that left totalArtworks stale would misreport the portfolio.
    blocTest<PortfolioBloc, PortfolioState>(
      'drops the mint from allArtworks and decrements totalArtworks',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await bloc.stream.firstWhere((s) => s is PortfolioLoaded);
        bloc.add(const PortfolioEvent.artworkRemoved('mint1'));
      },
      skip: 2,
      expect: () => [
        isA<PortfolioLoaded>()
            .having(
              (s) => s.allArtworks.map((a) => a.mintAccount).toList(),
              'remaining mints',
              ['mint2'],
            )
            .having((s) => s.totalArtworks, 'totalArtworks', 1),
      ],
    );

    // A removal for a mint the list doesn't hold must be a no-op — otherwise a
    // stray signal (e.g. an item already gone) would emit a needless rebuild
    // and, worse, decrement the count below the true holdings.
    blocTest<PortfolioBloc, PortfolioState>(
      'is a no-op when the mint is not in the list',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await bloc.stream.firstWhere((s) => s is PortfolioLoaded);
        bloc.add(const PortfolioEvent.artworkRemoved('notPresent'));
      },
      skip: 2,
      expect: () => <PortfolioState>[],
    );
  });

  group('PortfolioBloc.setArtworkFilter', () {
    final filtered = [_artwork(mint: 'mint2', title: 'Banana')];

    // WHY: the sliders sheet must drive a server-side refetch of the flat
    // "Artworks" list — the filter has to reach the repository (not just live in
    // the UI) and the returned subset must replace the list, with the filter
    // mirrored onto state so the badge/seed reflect it.
    blocTest<PortfolioBloc, PortfolioState>(
      'refetches owned artworks with the filter and stores it on state',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
          ),
        ).thenAnswer((invocation) async {
          final filter =
              invocation.namedArguments[#filter] as api.ExploreFilter?;
          return filter == null
              ? PortfolioArtworksResult(
                  artworks: artworks,
                  total: artworks.length,
                )
              : PortfolioArtworksResult(
                  artworks: filtered,
                  total: filtered.length,
                );
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await bloc.stream.firstWhere(
          (s) => s is PortfolioLoaded && !s.isRefreshing,
        );
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(tags: ['pfp']),
          ),
        );
      },
      skip: 2,
      expect: () => [
        // Shimmer: list cleared, filter recorded, refreshing.
        isA<PortfolioLoaded>()
            .having((s) => s.allArtworks, 'allArtworks', isEmpty)
            .having((s) => s.artworkFilter?.tags, 'filter.tags', ['pfp'])
            .having((s) => s.isRefreshing, 'isRefreshing', true),
        // Filtered result replaces the list.
        isA<PortfolioLoaded>()
            .having((s) => s.allArtworks, 'allArtworks', filtered)
            .having((s) => s.totalArtworks, 'totalArtworks', 1)
            .having((s) => s.artworkFilter?.tags, 'filter.tags', ['pfp'])
            .having((s) => s.isRefreshing, 'isRefreshing', false),
      ],
      verify: (_) {
        verify(
          mockRepository.getOwnedArtworks(
            filter: argThat(
              isA<api.ExploreFilter>().having((f) => f.tags, 'tags', ['pfp']),
              named: 'filter',
            ),
          ),
        ).called(1);
      },
    );

    // WHY: applying an all-empty filter means "clear" — it must normalize to a
    // null filter so page-0 caching resumes and the badge shows nothing.
    blocTest<PortfolioBloc, PortfolioState>(
      'normalizes an empty filter to null (cleared)',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
          ),
        ).thenAnswer(
          (_) async => PortfolioArtworksResult(
            artworks: artworks,
            total: artworks.length,
          ),
        );
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await bloc.stream.firstWhere(
          (s) => s is PortfolioLoaded && !s.isRefreshing,
        );
        bloc.add(
          const PortfolioEvent.setArtworkFilter(filter: api.ExploreFilter()),
        );
      },
      skip: 2,
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.artworkFilter,
          'artworkFilter',
          isNull,
        ),
        isA<PortfolioLoaded>().having(
          (s) => s.artworkFilter,
          'artworkFilter',
          isNull,
        ),
      ],
    );

    // WHY (bug): the shimmer emit collapses the flat list, which fires the
    // pagination scroll listener. If it leaves the pre-filter cursor and
    // `hasMoreAllArt` in place, a concurrent load-more pages the stale cursor
    // with the new filter and splices mismatched pages onto the list. The
    // shimmer must reset pagination to the fresh-load baseline (no next page).
    blocTest<PortfolioBloc, PortfolioState>(
      'the filter shimmer emit resets pagination state',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
          ),
        ).thenAnswer((invocation) async {
          final filter =
              invocation.namedArguments[#filter] as api.ExploreFilter?;
          // Unfiltered load advertises another page (live cursor); the
          // filtered result has none, so pagination must end up reset.
          if (filter == null) {
            return PortfolioArtworksResult(
              artworks: artworks,
              total: artworks.length,
              nextPage: 1,
            );
          }
          return PortfolioArtworksResult(
            artworks: filtered,
            total: filtered.length,
          );
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        final loaded =
            await bloc.stream.firstWhere(
                  (s) => s is PortfolioLoaded && !s.isRefreshing,
                )
                as PortfolioLoaded;
        // Precondition: the load left a live cursor to page against.
        expect(loaded.hasMoreAllArt, true);
        expect(loaded.nextAllArtPage, 1);
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(tags: ['pfp']),
          ),
        );
      },
      skip: 2,
      expect: () => [
        // Shimmer: list cleared and pagination reset so a concurrent load-more
        // can't page the stale pre-filter cursor.
        isA<PortfolioLoaded>()
            .having((s) => s.allArtworks, 'allArtworks', isEmpty)
            .having((s) => s.hasMoreAllArt, 'hasMoreAllArt', false)
            .having((s) => s.nextAllArtPage, 'nextAllArtPage', isNull)
            .having((s) => s.isRefreshing, 'isRefreshing', true),
        // Filtered result restores real pagination (this page has no next).
        isA<PortfolioLoaded>()
            .having((s) => s.allArtworks, 'allArtworks', filtered)
            .having((s) => s.hasMoreAllArt, 'hasMoreAllArt', false)
            .having((s) => s.isRefreshing, 'isRefreshing', false),
      ],
    );

    // WHY (bug): a failed filter refetch must roll back to a fully usable
    // pre-filter state. Two wedge classes guard here: (1) the shimmer collapse
    // can fire a load-more that sets isLoadingMoreAllArt, and the in-flight
    // load-more's own cleanup bails on the generation bump — the failure emit
    // is the only place left to clear it; (2) the shimmer emit resets the
    // cursor, so the rollback must restore hasMoreAllArt/nextAllArtPage or the
    // restored unfiltered list silently loses infinite scroll. Either wedge
    // kills pagination until a pull-to-refresh.
    blocTest<PortfolioBloc, PortfolioState>(
      'a failed filter refetch clears isLoadingMoreAllArt and restores the '
      'pre-filter pagination cursor',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
          ),
        ).thenThrow(Exception('Filter failed'));
      },
      build: buildBloc,
      // Pre-filter state has a live cursor (more pages at page 3).
      seed: () => const PortfolioState.loaded(
        groups: [],
        totalArtworks: 0,
        activeTab: PortfolioTab.allArt,
        isLoadingMoreAllArt: true,
        nextAllArtPage: 3,
      ),
      act: (bloc) => bloc.add(
        const PortfolioEvent.setArtworkFilter(
          filter: api.ExploreFilter(tags: ['pfp']),
        ),
      ),
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        expect(state.isLoadingMoreAllArt, false);
        expect(state.isRefreshing, false);
        // The rollback restores the complete pagination snapshot, not just
        // the list — infinite scroll must survive a failed filter apply.
        expect(state.hasMoreAllArt, true);
        expect(state.nextAllArtPage, 3);
      },
    );

    // WHY: THE reported bug. Applying a filter fires a fetch; tapping a
    // chip/tab while it is in flight must not be reverted when the response
    // lands — the fetch completion may only write the artwork-list fields,
    // never the selection.
    blocTest<PortfolioBloc, PortfolioState>(
      'a tab change during the filter refetch is not reverted',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
          ),
        ).thenAnswer((invocation) async {
          final filter =
              invocation.namedArguments[#filter] as api.ExploreFilter?;
          if (filter == null) {
            return PortfolioArtworksResult(
              artworks: artworks,
              total: artworks.length,
            );
          }
          // Slow filtered fetch so the tab change lands mid-flight.
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return PortfolioArtworksResult(
            artworks: filtered,
            total: filtered.length,
          );
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await bloc.stream.firstWhere(
          (s) => s is PortfolioLoaded && !s.isRefreshing,
        );
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(tags: ['pfp']),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.artists));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      },
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        // The mid-flight tab selection survives the fetch landing...
        expect(state.activeTab, PortfolioTab.artists);
        expect(state.activeSort, PortfolioSortOption.count);
        expect(state.groups.map((g) => g.type).toSet(), {ArtGroupType.artist});
        // ...and the fetch result is still applied.
        expect(state.allArtworks, filtered);
        expect(state.artworkFilter?.tags, ['pfp']);
        expect(state.isRefreshing, false);
      },
    );

    // WHY: rapid re-filtering must be last-issued-wins, not
    // last-network-completion-wins — a slow superseded response landing after
    // a newer one must be discarded, not splash its stale list on screen.
    blocTest<PortfolioBloc, PortfolioState>(
      'a newer filter fetch supersedes a still-in-flight older one',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
          ),
        ).thenAnswer((invocation) async {
          final filter =
              invocation.namedArguments[#filter] as api.ExploreFilter?;
          if (filter == null) {
            return PortfolioArtworksResult(
              artworks: artworks,
              total: artworks.length,
            );
          }
          if (filter.tags.contains('slow')) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return PortfolioArtworksResult(
              artworks: [_artwork(mint: 'slowMint', title: 'Slow')],
              total: 1,
            );
          }
          return PortfolioArtworksResult(
            artworks: [_artwork(mint: 'fastMint', title: 'Fast')],
            total: 1,
          );
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await bloc.stream.firstWhere(
          (s) => s is PortfolioLoaded && !s.isRefreshing,
        );
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(tags: ['slow']),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(tags: ['fast']),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
      },
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        expect(state.artworkFilter?.tags, ['fast']);
        expect(state.allArtworks.single.mintAccount, 'fastMint');
        expect(state.isRefreshing, false);
      },
    );
  });

  group('PortfolioBloc refresh signal', () {
    late PortfolioRefreshSignal signal;

    setUp(() {
      signal = PortfolioRefreshSignal();
      if (sl.isRegistered<PortfolioRefreshSignal>()) {
        sl.unregister<PortfolioRefreshSignal>();
      }
      sl.registerSingleton<PortfolioRefreshSignal>(signal);
    });

    tearDown(() async {
      signal.dispose();
      if (sl.isRegistered<PortfolioRefreshSignal>()) {
        await sl.unregister<PortfolioRefreshSignal>();
      }
    });

    // Encodes the product intent + the exact success criterion: after a
    // send/buy/edit/burn/list reports its indexer ack via the global signal,
    // the My Art tab — mounted under the pushed route — refetches so the
    // change is reflected on pop-back. Here the backend drops an artwork on
    // the second read (as a transfer would), and the bloc must surface the
    // smaller set. A regression that drops the subscription leaves the stale
    // two-artwork state in place.
    blocTest<PortfolioBloc, PortfolioState>(
      'refetches owned artworks when the refresh signal fires, '
      'dropping a removed artwork',
      setUp: () {
        var fetchCount = 0;
        when(
          mockRepository.getOwnedArtworks(page: anyNamed('page')),
        ).thenAnswer((_) async {
          fetchCount++;
          // First load: both artworks. After the signal: one was removed
          // (e.g. sent out of the wallet).
          final list = fetchCount == 1 ? artworks : [artworks.first];
          return PortfolioArtworksResult(artworks: list, total: list.length);
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        // Let the initial load settle so the refresh is a distinct refetch.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        signal.requestRefresh();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
      // Drop [loading, loaded(2 artworks)] from the initial load; assert the
      // signal flagged the refetch in-flight (drives pull-to-refresh spinner
      // hold) and produced a refetched loaded state with the removed artwork
      // gone.
      skip: 2,
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.isRefreshing,
          'isRefreshing',
          true,
        ),
        isA<PortfolioLoaded>()
            .having((s) => s.isRefreshing, 'isRefreshing', false)
            .having((s) => s.totalArtworks, 'totalArtworks', 1)
            .having((s) => s.allArtworks.length, 'allArtworks.length', 1)
            .having(
              (s) => s.allArtworks.single.mintAccount,
              'remaining mint',
              'mint1',
            ),
      ],
      verify: (_) {
        verify(
          mockRepository.getOwnedArtworks(page: anyNamed('page')),
        ).called(2);
      },
    );
  });

  group('PortfolioBloc curations refresh signal', () {
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

    // Encodes the delete-curation flow: the user deletes a curation from
    // CurationScreen (pushed over the Curations tab), the repository fires
    // the curations signal, and the still-mounted tab must drop the deleted
    // curation on pop-back without a manual pull-to-refresh.
    blocTest<PortfolioBloc, PortfolioState>(
      'refetches curation groups when the curations signal fires, '
      'dropping a deleted curation from the active Curations tab',
      setUp: () {
        var fetchCount = 0;
        when(
          mockCurationRepository.getCurations(
            mintAccount: anyNamed('mintAccount'),
            ownerAddress: anyNamed('ownerAddress'),
          ),
        ).thenAnswer((_) async {
          fetchCount++;
          // First load: one curation. After the signal: it was deleted.
          return fetchCount == 1
              ? const [UserCuration(id: 'cu9', name: 'Doomed', artworkCount: 1)]
              : const <UserCuration>[];
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.curations));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        curationsSignal.requestRefresh();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
      // Skip [loading, loaded] from the initial load and the changeTab emit.
      skip: 3,
      expect: () => [
        isA<PortfolioLoaded>()
            .having((s) => s.activeTab, 'activeTab', PortfolioTab.curations)
            .having(
              (s) => s.groups.where((g) => g.name == 'Doomed'),
              'deleted curation groups',
              isEmpty,
            ),
      ],
      verify: (_) {
        verify(
          mockCurationRepository.getCurations(
            mintAccount: anyNamed('mintAccount'),
            ownerAddress: anyNamed('ownerAddress'),
          ),
        ).called(2);
      },
    );
  });

  group('PortfolioBloc private-curations verify CTA', () {
    // The backend gates private curations profile-wide: /v1/curations lists
    // across every wallet on the login profile and includes the private ones
    // when ANY of them holds a valid wallet-sig, and the auth interceptor
    // sends every cached wallet-sig cookie. So a verified linked wallet has
    // already unlocked them — offering to "verify wallet to see private
    // curations" next to curations that are already on screen is wrong, and
    // verifying the Ledger would return exactly the same list.
    blocTest<PortfolioBloc, PortfolioState>(
      'stays hidden when a linked profile wallet is already verified, '
      'even though the active Ledger is not',
      setUp: () {
        when(
          mockAuthService.currentWalletNeedsLedgerVerification(),
        ).thenAnswer((_) async => true);
        when(
          mockAuthService.currentUser,
        ).thenReturn(const api.User(addresses: ['LedgerAddr', 'ImportedAddr']));
        when(
          mockAuthService.hasValidWalletSigForAny(any),
        ).thenAnswer((_) async => true);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      skip: 1,
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.showVerifyPrivateCurationsCta,
          'showVerifyPrivateCurationsCta',
          isFalse,
        ),
      ],
    );

    // The other half of the gate: with no wallet-sig anywhere on the profile
    // the backend really is withholding private curations, so the CTA must
    // still surface — widening the check must not mute it outright.
    blocTest<PortfolioBloc, PortfolioState>(
      'shows when no wallet on the profile holds a valid signature',
      setUp: () {
        when(
          mockAuthService.currentWalletNeedsLedgerVerification(),
        ).thenAnswer((_) async => true);
        when(mockAuthService.currentUser).thenReturn(
          const api.User(addresses: ['LedgerAddr', 'WatchOnlyAddr']),
        );
        when(
          mockAuthService.hasValidWalletSigForAny(any),
        ).thenAnswer((_) async => false);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      skip: 1,
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.showVerifyPrivateCurationsCta,
          'showVerifyPrivateCurationsCta',
          isTrue,
        ),
      ],
    );
  });

  group('PortfolioBloc curations refresh during load', () {
    // Encodes the account-switch race: onWalletChanged fires a full load
    // while the app-level listener re-logins. The load's curations fetch
    // runs against the cleared session (empty result), and the auth
    // listener's refreshCurations lands mid-load. The later-issued refresh
    // must win — the load's raced (empty) curation result must not clobber
    // the new user's curations, or they silently disappear until a manual
    // pull-to-refresh.
    blocTest<PortfolioBloc, PortfolioState>(
      'a mid-load curations refresh wins over the load\'s raced curation '
      'fetch',
      setUp: () {
        var fetchCount = 0;
        when(
          mockCurationRepository.getCurations(
            mintAccount: anyNamed('mintAccount'),
            ownerAddress: anyNamed('ownerAddress'),
          ),
        ).thenAnswer((_) async {
          fetchCount++;
          // First fetch (from the in-flight load) races the re-login and
          // gets nothing; the mid-load refresh sees the settled session.
          return fetchCount == 1
              ? const <UserCuration>[]
              : const [UserCuration(id: 'cu2', name: 'Fresh', artworkCount: 1)];
        });
        // Slow the portfolio calls so the refresh arrives mid-load, and
        // strip curation groups so curations come only from getCurations.
        final nonCurationGroups = groups
            .where((g) => g.type != ArtGroupType.curation)
            .toList();
        when(
          mockRepository.getOwnedArtworks(page: anyNamed('page')),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return PortfolioArtworksResult(
            artworks: artworks,
            total: artworks.length,
          );
        });
        when(mockRepository.getGroupedPortfolio()).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return PortfolioGroupsResult(groups: nonCurationGroups);
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        // The re-login lands while the load is still fetching — the auth
        // listener fires refreshCurations against a still-loading state.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(const PortfolioEvent.refreshCurations());
        await Future<void>.delayed(const Duration(milliseconds: 120));
      },
      expect: () => [
        isA<PortfolioLoading>(),
        // The load's own raced (empty) curation fetch was discarded in favor
        // of the refresh's settled-session result.
        isA<PortfolioLoaded>().having(
          (s) => s.groups.map((g) => g.name),
          'group names after the load settles',
          contains('Fresh'),
        ),
      ],
      verify: (_) {
        verify(
          mockCurationRepository.getCurations(
            mintAccount: anyNamed('mintAccount'),
            ownerAddress: anyNamed('ownerAddress'),
          ),
        ).called(2);
      },
    );

    // The profile-switch variant: with a cached snapshot on screen the load
    // reaches PortfolioLoaded *immediately*, with the previous profile's
    // stale curation painted. The mid-load refresh must still win over the
    // load's raced curation fetch, and the stale cached curation must be
    // replaced — not resurrected when the load completes.
    blocTest<PortfolioBloc, PortfolioState>(
      'a mid-load curations refresh survives the load completing, even with '
      'a cached paint on screen',
      setUp: () {
        final nonCurationGroups = groups
            .where((g) => g.type != ArtGroupType.curation)
            .toList();
        // Cached snapshot from the previous profile: a stale curation is on
        // screen the instant the load starts.
        when(mockRepository.getCachedSnapshot()).thenAnswer(
          (_) async => PortfolioSnapshot(
            artworks: PortfolioArtworksResult(
              artworks: artworks,
              total: artworks.length,
            ),
            groups: PortfolioGroupsResult(
              groups: [
                ...nonCurationGroups,
                _group(
                  id: 'curation:stale',
                  type: ArtGroupType.curation,
                  name: 'Stale',
                ),
              ],
            ),
          ),
        );

        var fetchCount = 0;
        when(
          mockCurationRepository.getCurations(
            mintAccount: anyNamed('mintAccount'),
            ownerAddress: anyNamed('ownerAddress'),
          ),
        ).thenAnswer((_) async {
          fetchCount++;
          // The load's fetch races the re-login and gets nothing; the
          // mid-load refresh sees the settled new-profile session.
          return fetchCount == 1
              ? const <UserCuration>[]
              : const [UserCuration(id: 'cu2', name: 'Fresh', artworkCount: 1)];
        });
        // Slow the portfolio calls so the refresh arrives mid-load, and strip
        // curation groups so curations come only from getCurations.
        when(
          mockRepository.getOwnedArtworks(page: anyNamed('page')),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return PortfolioArtworksResult(
            artworks: artworks,
            total: artworks.length,
          );
        });
        when(mockRepository.getGroupedPortfolio()).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return PortfolioGroupsResult(groups: nonCurationGroups);
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(const PortfolioEvent.refreshCurations());
        await Future<void>.delayed(const Duration(milliseconds: 120));
      },
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        final curationNames = state.groups
            .where((g) => g.type == ArtGroupType.curation)
            .map((g) => g.name);
        // The refresh's settled-session curations are on screen; neither the
        // cached stale curation nor the load's raced empty result survive.
        expect(curationNames, ['Fresh']);
        expect(state.isRefreshing, false);
        verify(
          mockCurationRepository.getCurations(
            mintAccount: anyNamed('mintAccount'),
            ownerAddress: anyNamed('ownerAddress'),
          ),
        ).called(2);
      },
    );
  });

  // The portfolio's Listed tab must only surface art the SESSION is selling —
  // it reads the holdings endpoint narrowed to listed listing types, never the
  // profile route (which also matches art the user merely created and someone
  // else listed).
  group('PortfolioBloc listed tab', () {
    final listed = [_artwork(mint: 'listedMint', title: 'For sale')];

    void stubListedFetch() {
      when(
        mockRepository.getOwnedArtworks(
          page: anyNamed('page'),
          filter: anyNamed('filter'),
        ),
      ).thenAnswer(
        (_) async =>
            PortfolioArtworksResult(artworks: listed, total: listed.length),
      );
    }

    blocTest<PortfolioBloc, PortfolioState>(
      'is not fetched until the tab is opened',
      setUp: stubListedFetch,
      build: buildBloc,
      act: (bloc) => bloc.add(const PortfolioEvent.load()),
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        expect((bloc.state as PortfolioLoaded).listedArtworks, isNull);
        // The plain load fetches the unfiltered holdings only — no listed
        // (listing-type-filtered) query goes out until the tab is opened.
        final filters = verify(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: captureAnyNamed('filter'),
          ),
        ).captured;
        expect(filters, everyElement(isNull));
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'opening the tab fetches held artworks narrowed to listed listing types',
      setUp: stubListedFetch,
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.listed));
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        expect((bloc.state as PortfolioLoaded).listedArtworks, listed);
        final captured =
            verify(
                  mockRepository.getOwnedArtworks(
                    page: anyNamed('page'),
                    filter: captureAnyNamed('filter'),
                  ),
                ).captured.last
                as api.ExploreFilter;
        expect(captured.listingTypes, listedListingTypes);
      },
    );

    // A listing type picked in the filters sheet is already a subset of
    // "listed", so it must win rather than being widened back to all types.
    blocTest<PortfolioBloc, PortfolioState>(
      'keeps a user-picked listing type instead of widening it',
      setUp: stubListedFetch,
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(listingTypes: ['auction']),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.listed));
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        final filters = verify(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: captureAnyNamed('filter'),
          ),
        ).captured.cast<api.ExploreFilter>();
        expect(filters.last.listingTypes, ['auction']);
      },
    );

    // WHY (bug): the filter object is shared across tabs and the filters sheet
    // offers an 'unlisted' option, so a listing-type set on another tab can
    // reach the Listed tab. The Listed tab must NEVER fetch unlisted art — an
    // 'unlisted'-only pick has no overlap with the listed set, so the fetch
    // falls back to the full listed set rather than passing 'unlisted' through.
    blocTest<PortfolioBloc, PortfolioState>(
      'sanitizes an unlisted listing-type filter back to the listed set',
      setUp: stubListedFetch,
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(listingTypes: ['unlisted']),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.listed));
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        final filters = verify(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: captureAnyNamed('filter'),
          ),
        ).captured.cast<api.ExploreFilter>();
        // 'unlisted' is dropped; no listed pick survives, so the full listed
        // set is used — the Listed tab never queries unlisted holdings.
        expect(filters.last.listingTypes, listedListingTypes);
      },
    );

    // WHY (bug): a filter mixing listed and unlisted types must keep only the
    // listed intersection — passing 'unlisted' through would surface art the
    // session isn't selling on a tab that means "currently listed".
    blocTest<PortfolioBloc, PortfolioState>(
      'intersects a mixed listing-type filter down to the listed picks',
      setUp: stubListedFetch,
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(listingTypes: ['unlisted', 'auction']),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.listed));
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        final filters = verify(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: captureAnyNamed('filter'),
          ),
        ).captured.cast<api.ExploreFilter>();
        expect(filters.last.listingTypes, ['auction']);
      },
    );

    // WHY (bug): on a failed refetch the failure branch used to zero the
    // `_listedArtworks` mirror while emitting the OLD list — a silent desync.
    // The very next hidden/removal signal re-emits `_listedArtworks` (= []),
    // collapsing the still-visible Listed tab. The mirror must track whatever
    // the failure branch leaves on screen so a later signal preserves it.
    blocTest<PortfolioBloc, PortfolioState>(
      'a hidden signal after a failed listed refetch keeps the visible list',
      setUp: () {
        var listedFetches = 0;
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
          ),
        ).thenAnswer((invocation) async {
          final filter =
              invocation.namedArguments[#filter] as api.ExploreFilter?;
          // Unfiltered allArt load — not the listed slice.
          if (filter == null || filter.listingTypes.isEmpty) {
            return PortfolioArtworksResult(
              artworks: artworks,
              total: artworks.length,
            );
          }
          // Listed slice: first open succeeds, the refetch fails.
          listedFetches++;
          if (listedFetches == 1) {
            return PortfolioArtworksResult(
              artworks: listed,
              total: listed.length,
            );
          }
          throw Exception('Listed refetch down');
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.listed));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // The refetch fails and must keep the visible list on screen.
        bloc.add(const PortfolioEvent.loadListedArtworks());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // A hidden signal now re-emits the listed mirror; a desynced ([]) mirror
        // would wipe the tab here.
        bloc.add(
          const PortfolioEvent.artworkHidden('listedMint', isHidden: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        expect(state.listedArtworks?.map((a) => a.mintAccount).toList(), [
          'listedMint',
        ]);
        // The flip still applied — the item survived AND its badge updated.
        expect(state.listedArtworks?.single.isHidden, true);
      },
    );

    // WHY (bug): applying a filter dispatches a page-0 listed refetch that bumps
    // the listed generation counter. If the stale `hasMoreListed`/
    // `nextListedPage` cursor is left in place, a load-more fired before the
    // refetch lands captures the already-bumped generation, pages the stale
    // pre-filter cursor, and splices its result onto the freshly replaced list.
    // The filter change must zero the listed cursor first so that load-more
    // bails — mirroring the allArt slice's reset.
    blocTest<PortfolioBloc, PortfolioState>(
      'a filter change resets the listed cursor so a stale load-more can\'t '
      'page',
      setUp: () {
        var listedPage0 = 0;
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
          ),
        ).thenAnswer((invocation) async {
          final filter =
              invocation.namedArguments[#filter] as api.ExploreFilter?;
          final page = invocation.namedArguments[#page] as int?;
          // Unfiltered allArt load / filter refetch (no listing types).
          if (filter == null || filter.listingTypes.isEmpty) {
            return PortfolioArtworksResult(
              artworks: artworks,
              total: artworks.length,
            );
          }
          // Listed page 1 is the STALE pre-filter cursor — it must never be
          // requested once the filter reset has zeroed the cursor.
          if (page == 1) {
            return PortfolioArtworksResult(
              artworks: [_artwork(mint: 'stalePage', title: 'Stale')],
              total: 2,
            );
          }
          // Listed page 0. The post-filter refetch is slow so the load-more
          // races the reset window; both pages advertise a live next cursor.
          listedPage0++;
          if (listedPage0 >= 2) {
            await Future<void>.delayed(const Duration(milliseconds: 80));
          }
          return PortfolioArtworksResult(
            artworks: listed,
            total: 2,
            nextPage: 1,
          );
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.listed));
        // First listed page-0 settles with a live cursor (hasMoreListed, page 1).
        await Future<void>.delayed(const Duration(milliseconds: 30));
        bloc.add(
          const PortfolioEvent.setArtworkFilter(
            filter: api.ExploreFilter(tags: ['pfp']),
          ),
        );
        // Filter's allArt refetch done; listed cursor reset + slow listed
        // refetch dispatched and still in flight.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Races the in-flight refetch — must bail on the zeroed cursor.
        bloc.add(const PortfolioEvent.loadMoreListedArtworks());
        await Future<void>.delayed(const Duration(milliseconds: 120));
      },
      verify: (bloc) {
        // The cursor reset made the racing load-more bail, so the stale
        // pre-filter page was never requested...
        verifyNever(
          mockRepository.getOwnedArtworks(page: 1, filter: anyNamed('filter')),
        );
        // ...and no stale page leaked into the list.
        final state = bloc.state as PortfolioLoaded;
        expect(
          state.listedArtworks?.any((a) => a.mintAccount == 'stalePage'),
          false,
        );
      },
    );
  });

  group('PortfolioBloc.changeTab', () {
    blocTest<PortfolioBloc, PortfolioState>(
      'switching to artists tab restricts groups and applies count sort',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.artists));
      },
      wait: const Duration(milliseconds: 100),
      skip: 2,
      expect: () => [
        isA<PortfolioLoaded>()
            .having((s) => s.activeTab, 'activeTab', PortfolioTab.artists)
            .having(
              (s) => s.activeSort,
              'activeSort',
              PortfolioSortOption.count,
            )
            .having((s) => s.groups.map((g) => g.type).toSet(), 'group types', {
              ArtGroupType.artist,
            })
            .having((s) => s.groups.length, 'groups.length', 2),
      ],
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'switching to allArt tab uses recent sort',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.allArt));
      },
      wait: const Duration(milliseconds: 100),
      skip: 2,
      expect: () => [
        isA<PortfolioLoaded>()
            .having((s) => s.activeTab, 'activeTab', PortfolioTab.allArt)
            .having(
              (s) => s.activeSort,
              'activeSort',
              PortfolioSortOption.recent,
            ),
      ],
    );
  });

  group('PortfolioBloc.setGroupSearch', () {
    // WHY: group tabs have no server-side filter — the sliders sheet's name
    // search must narrow the already-loaded groups client-side and mirror the
    // query on state so the badge reflects it.
    blocTest<PortfolioBloc, PortfolioState>(
      'filters the active tab\'s groups by name (case-insensitive)',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.artists));
        bloc.add(const PortfolioEvent.setGroupSearch(query: 'ali'));
      },
      wait: const Duration(milliseconds: 100),
      skip: 3,
      expect: () => [
        isA<PortfolioLoaded>()
            .having((s) => s.groupSearch, 'groupSearch', 'ali')
            .having((s) => s.groups.map((g) => g.name).toList(), 'groups', [
              'Alice',
            ]),
      ],
    );

    // WHY: the Artists tab searches "username, display name, or address" —
    // a handle or address fragment must match even when the display name
    // doesn't contain it.
    blocTest<PortfolioBloc, PortfolioState>(
      'matches artist username and address, not just display name',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.artists));
        bloc.add(const PortfolioEvent.setGroupSearch(query: 'wonder'));
        bloc.add(const PortfolioEvent.setGroupSearch(query: 'aliceaddr'));
      },
      wait: const Duration(milliseconds: 100),
      skip: 3,
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.groups.map((g) => g.name).toList(),
          'username match',
          ['Alice'],
        ),
        isA<PortfolioLoaded>().having(
          (s) => s.groups.map((g) => g.name).toList(),
          'address match',
          ['Alice'],
        ),
      ],
    );

    // WHY: the search is tab-specific (a collection name typed on the
    // Collections tab means nothing on Artists) — switching tabs must drop
    // it rather than silently filtering the next tab.
    blocTest<PortfolioBloc, PortfolioState>(
      'clears the search on tab change',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.artists));
        bloc.add(const PortfolioEvent.setGroupSearch(query: 'ali'));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.collections));
      },
      wait: const Duration(milliseconds: 100),
      skip: 4,
      expect: () => [
        isA<PortfolioLoaded>()
            .having((s) => s.groupSearch, 'groupSearch', null)
            .having((s) => s.groups.map((g) => g.name).toList(), 'groups', [
              'CoolCollection',
            ]),
      ],
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'an empty query clears the search and restores the full tab',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.artists));
        bloc.add(const PortfolioEvent.setGroupSearch(query: 'ali'));
        bloc.add(const PortfolioEvent.setGroupSearch(query: '  '));
      },
      wait: const Duration(milliseconds: 100),
      skip: 4,
      expect: () => [
        isA<PortfolioLoaded>()
            .having((s) => s.groupSearch, 'groupSearch', null)
            .having((s) => s.groups.length, 'groups.length', 2),
      ],
    );
  });

  group('PortfolioBloc.setSort', () {
    // Deliberately NOT in title order. The route orders the whole verified set
    // before cutting the page, so whatever it answers IS the order — a client
    // that re-sorts what it was handed would only ever sort the pages it has
    // scrolled, and this list is what catches it doing so.
    final routeOrdered = [
      _artwork(mint: 'mint2', title: 'Banana'),
      _artwork(mint: 'mint1', title: 'Apple'),
    ];

    void stubNameSort({int? nextPage}) {
      when(
        mockRepository.getOwnedArtworks(
          page: anyNamed('page'),
          filter: anyNamed('filter'),
          sort: PortfolioSortOption.name,
        ),
      ).thenAnswer(
        (_) async => PortfolioArtworksResult(
          artworks: routeOrdered,
          total: routeOrdered.length,
          nextPage: nextPage,
        ),
      );
    }

    Future<void> openArtworksTab(PortfolioBloc bloc) async {
      bloc.add(const PortfolioEvent.load());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.allArt));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    blocTest<PortfolioBloc, PortfolioState>(
      'Name on an artwork tab refetches and shows the route order verbatim',
      setUp: stubNameSort,
      build: buildBloc,
      act: (bloc) async {
        await openArtworksTab(bloc);
        bloc.add(const PortfolioEvent.setSort(sort: PortfolioSortOption.name));
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        expect(state.activeSort, PortfolioSortOption.name);
        expect(state.allArtworks, routeOrdered);
        verify(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
            sort: PortfolioSortOption.name,
          ),
        ).called(1);
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'a sort chosen on a group view spends no round trip on the artworks',
      setUp: stubNameSort,
      build: buildBloc,
      act: (bloc) async {
        // No pill selected: every group type, and no artwork list on screen.
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.setSort(sort: PortfolioSortOption.name));
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        // The groups re-sort in memory; the artwork list nobody is looking at
        // stays as fetched.
        expect(
          (bloc.state as PortfolioLoaded).groups.map((g) => g.name).toList(),
          ['Alice', 'Bob', 'CoolCollection', 'Showcase'],
        );
        verifyNever(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
            sort: PortfolioSortOption.name,
          ),
        );
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'returning to an artwork tab puts the list back in the routes order',
      setUp: stubNameSort,
      build: buildBloc,
      act: (bloc) async {
        await openArtworksTab(bloc);
        bloc.add(const PortfolioEvent.setSort(sort: PortfolioSortOption.name));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // A detour through a group tab resets the sort to that tab's default…
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.artists));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // …and coming back resets it to Recent, which the list must match:
        // the label would otherwise name an ordering the list no longer has.
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.allArt));
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        expect(state.activeSort, PortfolioSortOption.recent);
        expect(state.allArtworks, artworks);
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'pages under the active sort, not the default one',
      setUp: () {
        stubNameSort(nextPage: 1);
      },
      build: buildBloc,
      act: (bloc) async {
        await openArtworksTab(bloc);
        bloc.add(const PortfolioEvent.setSort(sort: PortfolioSortOption.name));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.loadMoreAllArtworks());
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        // A page fetched under the default ordering would splice rows into a
        // list they were never ranked against.
        verify(
          mockRepository.getOwnedArtworks(
            page: 1,
            filter: anyNamed('filter'),
            sort: PortfolioSortOption.name,
          ),
        ).called(1);
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'a failed reorder restores both the list and the label',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(
            page: anyNamed('page'),
            filter: anyNamed('filter'),
            sort: PortfolioSortOption.name,
          ),
        ).thenThrow(Exception('sort failed'));
      },
      build: buildBloc,
      act: (bloc) async {
        await openArtworksTab(bloc);
        bloc.add(const PortfolioEvent.setSort(sort: PortfolioSortOption.name));
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        // Leaving "Name" on the button over the recency-ordered list that is
        // still on screen would make the failure look like a working sort.
        expect(state.activeSort, PortfolioSortOption.recent);
        expect(state.allArtworks, artworks);
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'sorts groups alphabetically by name (case-insensitive)',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.setSort(sort: PortfolioSortOption.name));
      },
      wait: const Duration(milliseconds: 100),
      skip: 2,
      expect: () => [
        isA<PortfolioLoaded>()
            .having((s) => s.activeSort, 'activeSort', PortfolioSortOption.name)
            .having(
              (s) => s.groups.map((g) => g.name).toList(),
              'group order',
              ['Alice', 'Bob', 'CoolCollection', 'Showcase'],
            ),
      ],
    );
  });

  group('PortfolioBloc.loadMoreAllArtworks', () {
    final firstPage = [_artwork(mint: 'p0-1', title: 'P0-1')];
    final secondPage = [_artwork(mint: 'p1-1', title: 'P1-1')];

    blocTest<PortfolioBloc, PortfolioState>(
      'appends additional artworks and updates pagination metadata',
      setUp: () {
        when(mockRepository.getOwnedArtworks()).thenAnswer(
          (_) async => PortfolioArtworksResult(
            artworks: firstPage,
            total: 2,
            nextPage: 1,
          ),
        );
        when(mockRepository.getOwnedArtworks(page: 1)).thenAnswer(
          (_) async => PortfolioArtworksResult(artworks: secondPage, total: 2),
        );
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // Pagination is scoped to the flat Artworks tab.
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.allArt));
        bloc.add(const PortfolioEvent.loadMoreAllArtworks());
      },
      wait: const Duration(milliseconds: 100),
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        expect(state.allArtworks.length, 2);
        expect(state.hasMoreAllArt, false);
        expect(state.isLoadingMoreAllArt, false);
        expect(state.nextAllArtPage, isNull);
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'does nothing when there is no next page',
      setUp: () {
        when(mockRepository.getOwnedArtworks()).thenAnswer(
          (_) async => PortfolioArtworksResult(artworks: firstPage, total: 1),
        );
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.allArt));
        bloc.add(const PortfolioEvent.loadMoreAllArtworks());
      },
      wait: const Duration(milliseconds: 100),
      verify: (_) {
        // page=1 should never be requested when nextPage is null.
        verifyNever(mockRepository.getOwnedArtworks(page: 1));
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'ignores the event when a group tab is active',
      setUp: () {
        when(mockRepository.getOwnedArtworks()).thenAnswer(
          (_) async => PortfolioArtworksResult(
            artworks: firstPage,
            total: 2,
            nextPage: 1,
          ),
        );
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.artists));
        bloc.add(const PortfolioEvent.loadMoreAllArtworks());
      },
      wait: const Duration(milliseconds: 100),
      verify: (_) {
        verifyNever(mockRepository.getOwnedArtworks(page: 1));
      },
    );
  });

  group('PortfolioBloc.toggleViewMode', () {
    blocTest<PortfolioBloc, PortfolioState>(
      'group tab toggles list <-> grid',
      build: buildBloc,
      seed: () => const PortfolioState.loaded(
        groups: [],
        totalArtworks: 0,
        activeTab: PortfolioTab.artists,
        groupViewMode: PortfolioViewMode.list,
      ),
      act: (bloc) => bloc.add(const PortfolioEvent.toggleViewMode()),
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.groupViewMode,
          'groupViewMode',
          PortfolioViewMode.grid,
        ),
      ],
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'artwork tab cycles masonry -> detail -> grid -> masonry',
      build: buildBloc,
      seed: () => const PortfolioState.loaded(
        groups: [],
        totalArtworks: 0,
        activeTab: PortfolioTab.allArt,
      ),
      act: (bloc) async {
        bloc.add(const PortfolioEvent.toggleViewMode());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.toggleViewMode());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        bloc.add(const PortfolioEvent.toggleViewMode());
      },
      wait: const Duration(milliseconds: 50),
      expect: () => [
        isA<PortfolioLoaded>().having(
          (s) => s.artworkViewMode,
          'artworkViewMode',
          ArtworkViewMode.detail,
        ),
        isA<PortfolioLoaded>().having(
          (s) => s.artworkViewMode,
          'artworkViewMode',
          ArtworkViewMode.grid,
        ),
        isA<PortfolioLoaded>().having(
          (s) => s.artworkViewMode,
          'artworkViewMode',
          ArtworkViewMode.masonry,
        ),
      ],
    );

    // The Listed tab renders a flat artwork list exactly like Artworks does.
    // It used to fall through to the group branch, so its toggle moved the
    // group layout and left the artwork layout alone.
    blocTest<PortfolioBloc, PortfolioState>(
      'listed tab cycles the artwork mode, not the group mode',
      build: buildBloc,
      seed: () => const PortfolioState.loaded(
        groups: [],
        totalArtworks: 0,
        activeTab: PortfolioTab.listed,
      ),
      act: (bloc) => bloc.add(const PortfolioEvent.toggleViewMode()),
      expect: () => [
        isA<PortfolioLoaded>()
            .having(
              (s) => s.artworkViewMode,
              'artworkViewMode',
              ArtworkViewMode.detail,
            )
            .having(
              (s) => s.groupViewMode,
              'groupViewMode',
              PortfolioViewMode.grid,
            ),
      ],
    );

    // These two encode the whole point of splitting the preferences:
    // re-laying-out the Collections tab must not silently re-lay-out the
    // Artworks tab, or the reverse. Re-merging the keys would still pass every
    // state assertion above, so only these would catch the regression.
    blocTest<PortfolioBloc, PortfolioState>(
      'group toggle leaves the artwork preference untouched',
      setUp: () => SharedPreferences.setMockInitialValues(<String, Object>{}),
      build: buildBloc,
      seed: () => const PortfolioState.loaded(
        groups: [],
        totalArtworks: 0,
        activeTab: PortfolioTab.artists,
      ),
      act: (bloc) => bloc.add(const PortfolioEvent.toggleViewMode()),
      wait: const Duration(milliseconds: 50),
      verify: (_) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(prefs.getString(groupViewModePrefsKey), 'list');
        expect(prefs.getString(artworkViewModePrefsKey), isNull);
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'artwork toggle leaves the group preference untouched',
      setUp: () => SharedPreferences.setMockInitialValues(<String, Object>{
        'portfolio_view_mode': 'list',
      }),
      build: buildBloc,
      seed: () => const PortfolioState.loaded(
        groups: [],
        totalArtworks: 0,
        activeTab: PortfolioTab.allArt,
      ),
      act: (bloc) => bloc.add(const PortfolioEvent.toggleViewMode()),
      wait: const Duration(milliseconds: 50),
      verify: (_) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(prefs.getString(artworkViewModePrefsKey), 'detail');
        expect(prefs.getString(groupViewModePrefsKey), 'list');
      },
    );
  });

  group('PortfolioBloc.refresh', () {
    blocTest<PortfolioBloc, PortfolioState>(
      'preserves tab and sort selection across refresh',
      build: buildBloc,
      seed: () => const PortfolioState.loaded(
        groups: [],
        totalArtworks: 0,
        activeTab: PortfolioTab.collections,
        activeSort: PortfolioSortOption.name,
      ),
      act: (bloc) => bloc.add(const PortfolioEvent.refresh()),
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        // The collections tab restricts groups to one (CoolCollection).
        expect(state.groups.length, 1);
        expect(state.groups.first.name, 'CoolCollection');
        expect(state.activeTab, PortfolioTab.collections);
        expect(state.activeSort, PortfolioSortOption.name);
      },
    );

    // WHY: same race class as the filter sheet — the global refresh signal
    // fires after every buy/mint/burn, so a chip tapped while that refetch is
    // in flight must survive the refetch landing.
    blocTest<PortfolioBloc, PortfolioState>(
      'a tab change during refresh is not reverted',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(page: anyNamed('page')),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return PortfolioArtworksResult(
            artworks: artworks,
            total: artworks.length,
          );
        });
      },
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const PortfolioEvent.load());
        await bloc.stream.firstWhere(
          (s) => s is PortfolioLoaded && !s.isRefreshing,
        );
        bloc.add(const PortfolioEvent.refresh());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(const PortfolioEvent.changeTab(tab: PortfolioTab.collections));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      },
      verify: (bloc) {
        final state = bloc.state as PortfolioLoaded;
        expect(state.activeTab, PortfolioTab.collections);
        expect(state.groups.map((g) => g.type).toSet(), {
          ArtGroupType.collection,
        });
        expect(state.isRefreshing, false);
        // The refresh's data still landed.
        expect(state.allArtworks, artworks);
      },
    );

    blocTest<PortfolioBloc, PortfolioState>(
      'keeps previous loaded state when refresh throws',
      setUp: () {
        when(
          mockRepository.getOwnedArtworks(page: anyNamed('page')),
        ).thenThrow(Exception('Refresh failed'));
      },
      build: buildBloc,
      seed: () => PortfolioState.loaded(
        groups: groups,
        totalArtworks: 2,
        allArtworks: artworks,
      ),
      act: (bloc) => bloc.add(const PortfolioEvent.refresh()),
      verify: (bloc) {
        final state = bloc.state;
        expect(state, isA<PortfolioLoaded>());
        final loaded = state as PortfolioLoaded;
        // Existing groups untouched on refresh failure.
        expect(loaded.groups.length, groups.length);
      },
    );
  });

  group('PortfolioBloc wallet change', () {
    test('reloads when the wallet manager emits a change', () async {
      final controller = StreamController<String>.broadcast();
      addTearDown(controller.close);
      when(
        mockWalletManager.onWalletChanged,
      ).thenAnswer((_) => controller.stream);

      final bloc = buildBloc();
      addTearDown(bloc.close);

      controller.add('new-wallet-address');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      verify(mockRepository.getGroupedPortfolio()).called(1);
    });
  });
}
