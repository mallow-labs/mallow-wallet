import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/utils/address_format.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart'
    show ArtGroupType, PortfolioSortOption;
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'portfolio_repository_test.mocks.dart';

/// Minimum-valid `NftPreviewRender` JSON (required: mintAccount, listingType).
/// Optional fields are added per test.
Map<String, dynamic> _previewJson({
  required String mintAccount,
  String name = 'Untitled',
  String listingType = 'unlisted',
  bool isMasterEdition = false,
  String? imageUrl,
  Map<String, dynamic>? creator,
  String? collectionName,
  double? aspectRatio,
  int? supply,
  int? maxSupply,
  int? editionNumber,
  String? parentEdition,
  String? updateAuth,
  String? chain,
}) {
  return <String, dynamic>{
    'mintAccount': mintAccount,
    'name': name,
    'listingType': listingType,
    'isMasterEdition': isMasterEdition,
    'imageUrl': ?imageUrl,
    'creator': ?creator,
    'collectionName': ?collectionName,
    'aspectRatio': ?aspectRatio,
    'supply': ?supply,
    'maxSupply': ?maxSupply,
    'editionNumber': ?editionNumber,
    'parentEdition': ?parentEdition,
    'updateAuth': ?updateAuth,
    'chain': ?chain,
  };
}

Map<String, dynamic> _creatorJson({
  String address = 'CREATOR_ADDR',
  String? username,
  String? displayName,
  bool isTwitterVerified = false,
  List<String> roles = const [],
}) {
  return <String, dynamic>{
    'address': address,
    'addresses': [address],
    'username': ?username,
    'displayName': ?displayName,
    'isTwitterVerified': isTwitterVerified,
    'roles': roles,
  };
}

api.PortfolioArtworksResponse _artworksResponse(
  List<Map<String, dynamic>> previews, {
  int? total,
  int? nextPage,
}) => api.PortfolioArtworksResponse.fromJson(<String, dynamic>{
  'result': previews,
  'total': total ?? previews.length,
  'nextPage': ?nextPage,
});

api.PortfolioGroupsResponse _groupsResponse(
  List<Map<String, dynamic>> groups, {
  int? total,
  int? nextPage,
}) => api.PortfolioGroupsResponse.fromJson(<String, dynamic>{
  'result': {
    'groups': groups,
    'total': total ?? groups.length,
    'nextPage': ?nextPage,
  },
});

@GenerateMocks([
  api.MallowApiClient,
  api.MallowApiV2Client,
  WalletManager,
  SessionManager,
  SecureWalletStorage,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockMallowApiClient apiClient;
  late MockMallowApiV2Client apiV2;
  late MockWalletManager wallet;
  late MockSessionManager session;
  late MallowDatabase db;
  late MockSecureWalletStorage storage;
  late PortfolioRepository repo;

  const owner = 'OWNER_ADDR';

  setUpAll(() {
    provideDummy<api.ProfileResponse>(const api.ProfileResponse());
    provideDummy<api.ArtworksByOwnerResponse>(
      const api.ArtworksByOwnerResponse(),
    );
    provideDummy<api.PortfolioArtworksResponse>(
      const api.PortfolioArtworksResponse(result: [], total: 0),
    );
    provideDummy<api.PortfolioGroupsResponse>(
      const api.PortfolioGroupsResponse(
        result: api.PortfolioGroupsResult(groups: [], total: 0),
      ),
    );
    provideDummy<api.PortfolioGroupDrilldownResponse>(
      const api.PortfolioGroupDrilldownResponse(
        result: api.PortfolioDrilldownResult(artworks: [], total: 0),
      ),
    );
  });

  setUp(() {
    apiClient = MockMallowApiClient();
    apiV2 = MockMallowApiV2Client();
    wallet = MockWalletManager();
    session = MockSessionManager();
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    storage = MockSecureWalletStorage();
    repo = PortfolioRepository(apiClient, apiV2, wallet, session, db, storage);

    when(wallet.getAddress()).thenAnswer((_) async => owner);
    // Default: a single-wallet session. The v2 routes aggregate server-side,
    // so the repository just forwards the session's owner addresses as `owners`.
    when(session.apiOwnerAddresses).thenReturn([owner]);
    // Default: no Profile scope and every network enabled, so the repository
    // sends an empty `disabledChains` (no chain filtered).
    when(session.settingsScopeId()).thenAnswer((_) async => null);
    when(
      storage.loadNetworkEnabled(any, scope: anyNamed('scope')),
    ).thenAnswer((_) async => true);
  });

  group('getOwnedArtworks', () {
    test('maps the generated preview into PortfolioArtwork records', () async {
      when(apiV2.getPortfolioArtworks(any)).thenAnswer(
        (_) async => _artworksResponse([
          _previewJson(
            mintAccount: 'mint1',
            name: 'First',
            imageUrl: 'https://x/1.png',
            creator: _creatorJson(
              displayName: 'Alice',
              username: 'alice',
              isTwitterVerified: true,
              roles: const ['admin'],
            ),
            aspectRatio: 1.5,
            collectionName: 'Spring',
            maxSupply: 10,
            supply: 3,
          ),
        ], total: 1),
      );

      final result = await repo.getOwnedArtworks();

      expect(result.total, 1);
      expect(result.nextPage, isNull);
      expect(result.artworks, hasLength(1));

      final art = result.artworks.first;
      expect(art.mintAccount, 'mint1');
      expect(art.title, 'First');
      expect(art.imageUrl, 'https://x/1.png');
      expect(art.artistName, 'Alice');
      expect(art.artistUsername, 'alice');
      expect(art.isVerified, true);
      expect(art.isAdmin, true);
      expect(art.collectionName, 'Spring');
      expect(art.aspectRatio, 1.5);
      expect(art.maxSupply, 10);
      expect(art.supply, 3);
      expect(art.supplyLabel, 'Limited edition of 10');
    });

    test('falls back to aspectRatio=1.0 when the field is missing', () async {
      when(apiV2.getPortfolioArtworks(any)).thenAnswer(
        (_) async => _artworksResponse([
          _previewJson(mintAccount: 'm', name: 'N'),
        ], total: 1),
      );

      final result = await repo.getOwnedArtworks();

      expect(result.artworks.single.aspectRatio, 1.0);
    });

    test('decodes the wire listingType string into the enum', () async {
      when(apiV2.getPortfolioArtworks(any)).thenAnswer(
        (_) async => _artworksResponse([
          _previewJson(mintAccount: 'm', name: 'N', listingType: 'buy-now'),
        ], total: 1),
      );

      final result = await repo.getOwnedArtworks();

      expect(result.artworks.single.listingType, api.ListingType.buyNow);
    });

    // `NftPreviewRender.chain` is a decoded `Chain` enum; the mapper unwraps it
    // back to the wire string that EVM/Tezos transfer routing keys on. Guards
    // the enum carrying `ethereum` (not `evm`) — a mismatch would silently drop
    // the chain and break EVM artwork transfers from the portfolio.
    test('unwraps the ethereum chain enum back to its wire string', () async {
      when(apiV2.getPortfolioArtworks(any)).thenAnswer(
        (_) async => _artworksResponse([
          _previewJson(mintAccount: 'm', name: 'N', chain: 'ethereum'),
        ], total: 1),
      );

      final result = await repo.getOwnedArtworks();

      expect(result.artworks.single.chain, 'ethereum');
    });

    test('passes through the server nextPage cursor for pagination', () async {
      when(apiV2.getPortfolioArtworks(any)).thenAnswer(
        (_) async => _artworksResponse(
          [_previewJson(mintAccount: 'm', name: 'N')],
          total: 100,
          nextPage: 2,
        ),
      );

      final result = await repo.getOwnedArtworks(page: 1);

      // The backend paginates globally, so we surface its cursor verbatim.
      expect(result.nextPage, 2);
      final captured =
          verify(apiV2.getPortfolioArtworks(captureAny)).captured.single
              as api.PortfolioArtworksRequest;
      expect(captured.page, 1);
      // Portfolio shows listed/staked (frozen) artworks too, unlike the picker.
      expect(captured.includeFrozen, true);
    });

    test('forwards the session owner addresses as owners to the v2 route', () async {
      // thenAnswer (not thenReturn) so each call yields a fresh list, matching
      // the real accessor — the repo's cache key sorts its copy in place, which
      // would otherwise mutate a shared stub instance and reorder this capture.
      when(
        session.apiOwnerAddresses,
      ).thenAnswer((_) => ['SOL_A', 'ETH_ADDR', 'SOL_B']);
      when(
        apiV2.getPortfolioArtworks(any),
      ).thenAnswer((_) async => _artworksResponse(const []));

      await repo.getOwnedArtworks();

      final captured =
          verify(apiV2.getPortfolioArtworks(captureAny)).captured.single
              as api.PortfolioArtworksRequest;
      expect(captured.owners, ['SOL_A', 'ETH_ADDR', 'SOL_B']);
    });

    test(
      'returns empty without calling the API when no wallets in session',
      () async {
        when(session.apiOwnerAddresses).thenReturn(const []);

        final result = await repo.getOwnedArtworks();

        expect(result.artworks, isEmpty);
        expect(result.total, 0);
        verifyNever(apiV2.getPortfolioArtworks(any));
      },
    );

    // The route orders the whole verified set before cutting the page, so the
    // sort has to travel with the request — the client only ever holds the
    // pages it has scrolled and cannot reorder what it hasn't fetched.
    test('name sort asks the route for alphabetical order', () async {
      when(
        apiV2.getPortfolioArtworks(any),
      ).thenAnswer((_) async => _artworksResponse(const []));

      await repo.getOwnedArtworks(sort: PortfolioSortOption.name);

      final captured =
          verify(apiV2.getPortfolioArtworks(captureAny)).captured.single
              as api.PortfolioArtworksRequest;
      expect(captured.sort, api.PortfolioArtworkSort.alphabetical);
    });

    test('every other sort keeps the route default', () async {
      // `count` orders groups by item count and never reaches this list; it
      // must not be mistaken for an artwork ordering.
      when(
        apiV2.getPortfolioArtworks(any),
      ).thenAnswer((_) async => _artworksResponse(const []));

      await repo.getOwnedArtworks();
      await repo.getOwnedArtworks(sort: PortfolioSortOption.count);

      final captured = verify(
        apiV2.getPortfolioArtworks(captureAny),
      ).captured.cast<api.PortfolioArtworksRequest>();
      expect(
        captured.map((r) => r.sort),
        everyElement(api.PortfolioArtworkSort.recent),
      );
    });

    // Supply-type filter parity with the profile route (mode=1/1 → OneOfOne,
    // mode=editions → open+limited). The v2 portfolio query has no supplyType
    // field, so mode must translate into its supply flags — otherwise the
    // "Your art" Supply type chips are a silent no-op.
    test(
      'mode=1/1 maps to masterOnly + nonPrintableOnly (strictly 1/1)',
      () async {
        when(
          apiV2.getPortfolioArtworks(any),
        ).thenAnswer((_) async => _artworksResponse(const []));

        await repo.getOwnedArtworks(
          filter: const api.ExploreFilter(mode: api.ExploreMode.oneOfOne),
        );

        final captured =
            verify(apiV2.getPortfolioArtworks(captureAny)).captured.single
                as api.PortfolioArtworksRequest;
        // masterOnly (≠ edition-print) ∩ nonPrintableOnly ({1/1, edition-print})
        // = strictly 1/1. printableOnly must stay off.
        expect(captured.masterOnly, true);
        expect(captured.nonPrintableOnly, true);
        expect(captured.printableOnly, isNull);
      },
    );

    test('mode=editions maps to printableOnly (open + limited)', () async {
      when(
        apiV2.getPortfolioArtworks(any),
      ).thenAnswer((_) async => _artworksResponse(const []));

      await repo.getOwnedArtworks(
        filter: const api.ExploreFilter(mode: api.ExploreMode.editions),
      );

      final captured =
          verify(apiV2.getPortfolioArtworks(captureAny)).captured.single
              as api.PortfolioArtworksRequest;
      expect(captured.printableOnly, true);
      expect(captured.masterOnly, isNull);
      expect(captured.nonPrintableOnly, isNull);
    });

    test('mode=all sends no supply flags', () async {
      when(
        apiV2.getPortfolioArtworks(any),
      ).thenAnswer((_) async => _artworksResponse(const []));

      await repo.getOwnedArtworks(filter: const api.ExploreFilter());

      final captured =
          verify(apiV2.getPortfolioArtworks(captureAny)).captured.single
              as api.PortfolioArtworksRequest;
      expect(captured.masterOnly, isNull);
      expect(captured.nonPrintableOnly, isNull);
      expect(captured.printableOnly, isNull);
    });
  });

  group('getOwnedArtworksForListing', () {
    // Minimal v1 NftPreview JSON (the listing picker still uses the v1 route).
    Map<String, dynamic> v1Preview(String mint) => <String, dynamic>{
      'mintAccount': mint,
      'name': 'N',
    };

    test(
      'passes nonPrintableOnly=true through to the v1 by-owner endpoint',
      () async {
        when(apiClient.getArtworksByOwner(any, any)).thenAnswer(
          (_) async =>
              api.ArtworksByOwnerResponse(result: [v1Preview('m')], total: 1),
        );

        await repo.getOwnedArtworksForListing(nonPrintableOnly: true);

        final captured =
            verify(
                  apiClient.getArtworksByOwner(owner, captureAny),
                ).captured.single
                as api.SearchUserNftsRequest;
        expect(captured.nonPrintableOnly, true);
        // The listing picker must NOT surface frozen (already-listed) assets.
        expect(captured.includeFrozen, isNull);
      },
    );

    test(
      'omits nonPrintableOnly (sends null) when not in auction flow',
      () async {
        when(
          apiClient.getArtworksByOwner(any, any),
        ).thenAnswer((_) async => const api.ArtworksByOwnerResponse());

        await repo.getOwnedArtworksForListing(nonPrintableOnly: false);

        final captured =
            verify(
                  apiClient.getArtworksByOwner(owner, captureAny),
                ).captured.single
                as api.SearchUserNftsRequest;
        expect(captured.nonPrintableOnly, isNull);
      },
    );
  });

  group('getGroupedPortfolio', () {
    test('maps artist/collection responses with type-prefixed ids', () async {
      when(apiV2.getPortfolioGroups(any)).thenAnswer((invocation) async {
        final req =
            invocation.positionalArguments.first as api.PortfolioGroupsRequest;
        // The session's wallets are forwarded as owners; the backend already
        // merged + summed counts across them.
        expect(req.owners, [owner]);
        switch (req.groupBy) {
          case api.PortfolioGroupsRequestGroupBy.artist:
            return _groupsResponse([
              {
                'id': 'addr1',
                'name': 'Alice',
                'artworkCount': 5,
                'avatarUrl': 'a.png',
              },
            ]);
          case api.PortfolioGroupsRequestGroupBy.collection:
            return _groupsResponse([
              {
                'id': 'col-slug',
                'name': 'CoolCollection',
                'artworkCount': 2,
                // Creator has a display name and a username; the subtitle must
                // surface the @handle, not the display name.
                'creator': _creatorJson(username: 'bob', displayName: 'Bob'),
              },
            ]);
          default:
            throw StateError('unexpected groupBy ${req.groupBy}');
        }
      });

      final result = await repo.getGroupedPortfolio();

      final byId = {for (final g in result.groups) g.id: g};
      expect(
        byId.keys,
        containsAll(<String>['artist:addr1', 'collection:col-slug']),
      );
      expect(
        result.groups.any((g) => g.type == ArtGroupType.curation),
        isFalse,
      );
      expect(byId['artist:addr1']!.type, ArtGroupType.artist);
      expect(byId['artist:addr1']!.thumbnailUrl, 'a.png');
      expect(byId['artist:addr1']!.artistAddress, 'addr1');
      expect(byId['collection:col-slug']!.type, ArtGroupType.collection);
      expect(byId['collection:col-slug']!.collectionMint, 'col-slug');
      // Bare username (no `@`) wins over the creator's display name —
      // consumers like UserHandleText add their own prefix styling.
      expect(byId['collection:col-slug']!.creatorName, 'bob');
    });

    test('drains group pages and requests recent ordering', () async {
      final requests = <api.PortfolioGroupsRequest>[];
      when(apiV2.getPortfolioGroups(any)).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as api.PortfolioGroupsRequest;
        requests.add(request);
        final isArtist =
            request.groupBy == api.PortfolioGroupsRequestGroupBy.artist;
        final prefix = isArtist ? 'artist' : 'collection';
        if (request.page == 0) {
          return _groupsResponse(
            [
              {'id': '$prefix-first', 'name': 'First', 'artworkCount': 1},
            ],
            total: 2,
            nextPage: 1,
          );
        }
        return _groupsResponse([
          {'id': '$prefix-second', 'name': 'Second', 'artworkCount': 0},
        ], total: 2);
      });

      final result = await repo.getGroupedPortfolio();

      expect(requests, hasLength(4));
      expect(
        requests,
        everyElement(
          predicate<api.PortfolioGroupsRequest>(
            (request) =>
                request.sort == api.PortfolioGroupSort.recent &&
                request.pageSize == 40,
          ),
        ),
      );
      expect(
        result.groups.map((group) => group.id),
        containsAll(<String>[
          'artist:artist-second',
          'collection:collection-second',
        ]),
      );
    });

    test(
      'collection creatorName abbreviates an address supplied as the username',
      () async {
        // The backend falls back to the raw wallet address in the `username`
        // field when a creator has no handle. The subtitle must never show a
        // full address, so the repository truncates it before display.
        const addr = 'So11111111111111111111111111111111111111112';
        when(apiV2.getPortfolioGroups(any)).thenAnswer((invocation) async {
          final req =
              invocation.positionalArguments.first
                  as api.PortfolioGroupsRequest;
          switch (req.groupBy) {
            case api.PortfolioGroupsRequestGroupBy.collection:
              return _groupsResponse([
                {
                  'id': 'col-slug',
                  'name': 'CoolCollection',
                  'artworkCount': 2,
                  'creator': _creatorJson(address: addr, username: addr),
                },
              ]);
            default:
              return _groupsResponse(const []);
          }
        });

        final result = await repo.getGroupedPortfolio();
        final collection = result.groups.firstWhere(
          (g) => g.type == ArtGroupType.collection,
        );

        expect(collection.creatorName, truncateAddress(addr));
        expect(collection.creatorName, isNot(addr));
      },
    );

    test(
      'artist name falls back to bare username when display name equals the address',
      () async {
        when(apiV2.getPortfolioGroups(any)).thenAnswer((invocation) async {
          final req =
              invocation.positionalArguments.first
                  as api.PortfolioGroupsRequest;
          if (req.groupBy == api.PortfolioGroupsRequestGroupBy.artist) {
            return _groupsResponse([
              {
                'id': 'addrZZZ',
                'name': 'addrZZZ', // raw-address fallback shape
                'artworkCount': 1,
                'creator': _creatorJson(address: 'addrZZZ', username: 'zee'),
              },
            ]);
          }
          return _groupsResponse(const []);
        });

        final result = await repo.getGroupedPortfolio();

        final artist = result.groups.firstWhere(
          (g) => g.type == ArtGroupType.artist,
        );
        expect(artist.name, 'zee');
      },
    );

    test(
      'artist address labels use the canonical ellipsis abbreviation',
      () async {
        const address = '0x742d35cc6634c0532925a3b844bc454e4438f44e';
        const addressPrefix = '0x742d35cc';
        when(apiV2.getPortfolioGroups(any)).thenAnswer((invocation) async {
          final req =
              invocation.positionalArguments.first
                  as api.PortfolioGroupsRequest;
          if (req.groupBy == api.PortfolioGroupsRequestGroupBy.artist) {
            return _groupsResponse([
              {
                'id': address,
                'name': addressPrefix,
                'artworkCount': 1,
                'creator': _creatorJson(
                  address: address,
                  username: addressPrefix,
                ),
              },
            ]);
          }
          return _groupsResponse(const []);
        });

        final result = await repo.getGroupedPortfolio();
        final artist = result.groups.firstWhere(
          (g) => g.type == ArtGroupType.artist,
        );

        expect(artist.name, truncateAddress(address));
        expect(artist.artistUsername, isNull);
      },
    );

    test('returns empty list when a grouped call throws', () async {
      when(apiV2.getPortfolioGroups(any)).thenThrow(Exception('boom'));

      final result = await repo.getGroupedPortfolio();

      expect(result.groups, isEmpty);
    });

    test(
      'returns empty without calling the API when no wallets in session',
      () async {
        when(session.apiOwnerAddresses).thenReturn(const []);

        final result = await repo.getGroupedPortfolio();

        expect(result.groups, isEmpty);
        verifyNever(apiV2.getPortfolioGroups(any));
      },
    );
  });

  // Encodes the cache-first contract for the Art tab's instant paint: the
  // page-0 artworks and groups fetches persist their raw responses, and
  // getCachedSnapshot serves them back for the same session — so a relaunch
  // paints the last-known portfolio without waiting on the network.
  group('getCachedSnapshot', () {
    test(
      'serves the last-fetched artworks + groups, mapped like a live fetch',
      () async {
        when(apiV2.getPortfolioArtworks(any)).thenAnswer(
          (_) async => _artworksResponse([
            _previewJson(mintAccount: 'mintA', name: 'Alpha'),
          ], nextPage: 2),
        );
        when(apiV2.getPortfolioGroups(any)).thenAnswer((invocation) async {
          final req =
              invocation.positionalArguments.first
                  as api.PortfolioGroupsRequest;
          return req.groupBy == api.PortfolioGroupsRequestGroupBy.artist
              ? _groupsResponse([
                  {'id': 'addr1', 'name': 'Alice', 'artworkCount': 5},
                ])
              : _groupsResponse(const []);
        });

        // Fetches persist their raw responses as a side effect.
        await repo.getOwnedArtworks();
        await repo.getGroupedPortfolio();

        final snapshot = await repo.getCachedSnapshot();

        expect(snapshot, isNotNull);
        expect(snapshot!.artworks.artworks.single.mintAccount, 'mintA');
        expect(snapshot.artworks.artworks.single.title, 'Alpha');
        expect(snapshot.artworks.nextPage, 2);
        expect(snapshot.groups.groups.single.id, 'artist:addr1');
      },
    );

    test('returns null when nothing is cached for the session', () async {
      expect(await repo.getCachedSnapshot(), isNull);
    });

    test("does not serve another session's snapshot", () async {
      when(apiV2.getPortfolioArtworks(any)).thenAnswer(
        (_) async => _artworksResponse([_previewJson(mintAccount: 'mintA')]),
      );
      await repo.getOwnedArtworks();

      // Session switches to a different wallet — the old wallet's art must
      // not be painted for it.
      when(session.apiOwnerAddresses).thenReturn(['OTHER_ADDR']);

      expect(await repo.getCachedSnapshot(), isNull);
    });

    // The snapshot is the portfolio's resting state, painted before any sort
    // has been chosen. Caching a re-ordered page 0 would make the next cold
    // start paint alphabetically under the "Recent" label it starts on.
    test('a re-ordered page 0 is not cached', () async {
      when(apiV2.getPortfolioArtworks(any)).thenAnswer((invocation) async {
        final req =
            invocation.positionalArguments.first
                as api.PortfolioArtworksRequest;
        return req.sort == api.PortfolioArtworkSort.alphabetical
            ? _artworksResponse([_previewJson(mintAccount: 'alphabetical')])
            : _artworksResponse([_previewJson(mintAccount: 'recent')]);
      });

      await repo.getOwnedArtworks(sort: PortfolioSortOption.name);
      expect(await repo.getCachedSnapshot(), isNull);

      await repo.getOwnedArtworks();
      final snapshot = await repo.getCachedSnapshot();
      expect(snapshot!.artworks.artworks.single.mintAccount, 'recent');
    });

    test('later pages do not overwrite the page-0 snapshot', () async {
      when(apiV2.getPortfolioArtworks(any)).thenAnswer((invocation) async {
        final req =
            invocation.positionalArguments.first
                as api.PortfolioArtworksRequest;
        return req.page == 0
            ? _artworksResponse([_previewJson(mintAccount: 'page0')])
            : _artworksResponse([_previewJson(mintAccount: 'page1')]);
      });

      await repo.getOwnedArtworks();
      await repo.getOwnedArtworks(page: 1);

      final snapshot = await repo.getCachedSnapshot();
      expect(snapshot!.artworks.artworks.single.mintAccount, 'page0');
    });
  });

  group('getGroupArtworks', () {
    test(
      'splits composite groupId into path id + groupBy body and forwards owners',
      () async {
        when(apiV2.getPortfolioGroupArtworks(any, any)).thenAnswer(
          (_) async => api.PortfolioGroupDrilldownResponse.fromJson({
            'result': {
              'artworks': [_previewJson(mintAccount: 'm1', name: 'A1')],
              'total': 1,
              'nextPage': 1,
            },
          }),
        );

        final result = await repo.getGroupArtworks('collection:col-slug');

        final captured = verify(
          apiV2.getPortfolioGroupArtworks(captureAny, captureAny),
        ).captured;
        expect(captured[0], 'col-slug');
        final req = captured[1] as api.PortfolioGroupsRequest;
        expect(req.groupBy, api.PortfolioGroupsRequestGroupBy.collection);
        expect(req.owners, [owner]);

        expect(result.total, 1);
        expect(result.nextPage, 1);
        expect(result.artworks.single.mintAccount, 'm1');
        expect(result.artworks.single.title, 'A1');
      },
    );

    test(
      'handles curation: ids that contain extra colons in the slug',
      () async {
        when(apiV2.getPortfolioGroupArtworks(any, any)).thenAnswer(
          (_) async => api.PortfolioGroupDrilldownResponse.fromJson({
            'result': {'artworks': <dynamic>[], 'total': 0},
          }),
        );

        await repo.getGroupArtworks('curation:weird:slug:with:colons');

        final captured = verify(
          apiV2.getPortfolioGroupArtworks(captureAny, captureAny),
        ).captured;
        // Only the leading 'curation:' is stripped — slug colons survive.
        expect(captured[0], 'weird:slug:with:colons');
        expect(
          (captured[1] as api.PortfolioGroupsRequest).groupBy,
          api.PortfolioGroupsRequestGroupBy.curation,
        );
      },
    );
  });
}
