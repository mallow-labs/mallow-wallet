import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/home/data/home_feed_repository.dart';
import 'package:mallow_wallet/features/home/services/home_bloc.dart';
import 'package:mockito/annotations.dart';

import 'home_feed_repository_test.mocks.dart';

/// Unit tests for the pure mapping methods on [HomeFeedRepository].
///
/// These mappers translate raw `mallow_api` wire models into the UI models
/// consumed by [HomeBloc]. They carry the home screen's price-priority chain,
/// fallback/label logic, image-URL filtering, and section caps — all
/// fund-/correctness-sensitive surfaces that long went untested.
///
/// The API client and database collaborators are mocked only to satisfy the
/// constructor; none of the methods under test touch them, so no stubbing is
/// required.
@GenerateMocks([
  api.MallowApiClient,
  api.MallowApiV2Client,
  MallowDatabase,
  SessionManager,
])
void main() {
  late HomeFeedRepository repo;

  setUp(() {
    repo = HomeFeedRepository(
      MockMallowApiClient(),
      MockMallowApiV2Client(),
      MockMallowDatabase(),
      MockSessionManager(),
    );
  });

  // ---- builders -----------------------------------------------------------

  api.ApiUserRef creator({
    String? address,
    String? username,
    String? displayName,
    List<String> addresses = const [],
  }) => api.ApiUserRef(
    address: address,
    username: username,
    displayName: displayName,
    addresses: addresses,
  );

  api.NftPreview preview({
    String mintAccount = 'MINT',
    String name = 'Untitled',
    String? imageUrl = 'https://img/a.png',
    api.ApiUserRef? creatorRef,
    int? editionNumber,
    api.BuyNowMetadata? buyNow,
    api.AuctionMetadata? auction,
    api.LastSale? lastSale,
  }) => api.NftPreview(
    mintAccount: mintAccount,
    name: name,
    imageUrl: imageUrl,
    creator: creatorRef,
    editionNumber: editionNumber,
    buyNowMetadata: buyNow,
    auctionMetadata: auction,
    lastSale: lastSale,
  );

  api.ItemRender item(api.NftPreview? p) =>
      api.ItemRender(contentType: 'nft', nftPreview: p);

  api.HomeFeedResponse feed({
    List<api.ItemRender> featured = const [],
    List<api.ItemRender> smores = const [],
  }) => api.HomeFeedResponse(featured: featured, smores: smores);

  group('mapFeaturedListings price-priority chain', () {
    test('buy-now amount wins over auction and last sale', () {
      final result = repo.mapFeaturedListings(
        feed(
          featured: [
            item(
              preview(
                buyNow: const api.BuyNowMetadata(
                  amount: 100,
                  currencyMint: 'USDC',
                ),
                auction: const api.AuctionMetadata(
                  currentBidAmount: 50,
                  bidMint: 'SOL',
                ),
                lastSale: const api.LastSale(price: 25, currencyMint: 'BONK'),
              ),
            ),
          ],
        ),
      );

      expect(result, hasLength(1));
      expect(result.single.priceRawAmount, 100);
      expect(result.single.currencyMint, 'USDC');
    });

    test('live bid (currentBidAmount > 0) wins over reserve', () {
      final result = repo.mapFeaturedListings(
        feed(
          featured: [
            item(
              preview(
                auction: const api.AuctionMetadata(
                  currentBidAmount: 50,
                  reservePrice: 10,
                  bidMint: 'SOL',
                ),
              ),
            ),
          ],
        ),
      );

      expect(result.single.priceRawAmount, 50);
      expect(result.single.currencyMint, 'SOL');
    });

    test('reserve price is used when there is no live bid (amount 0)', () {
      final result = repo.mapFeaturedListings(
        feed(
          featured: [
            item(
              preview(
                auction: const api.AuctionMetadata(
                  currentBidAmount: 0,
                  reservePrice: 10,
                  bidMint: 'SOL',
                ),
              ),
            ),
          ],
        ),
      );

      expect(result.single.priceRawAmount, 10);
      expect(result.single.currencyMint, 'SOL');
    });

    test('reserve price is used when currentBidAmount is null', () {
      final result = repo.mapFeaturedListings(
        feed(
          featured: [
            item(
              preview(
                auction: const api.AuctionMetadata(
                  reservePrice: 10,
                  bidMint: 'SOL',
                ),
              ),
            ),
          ],
        ),
      );

      expect(result.single.priceRawAmount, 10);
      expect(result.single.currencyMint, 'SOL');
    });

    test('falls back to last sale when no buy-now or auction', () {
      final result = repo.mapFeaturedListings(
        feed(
          featured: [
            item(
              preview(
                lastSale: const api.LastSale(price: 25, currencyMint: 'BONK'),
              ),
            ),
          ],
        ),
      );

      expect(result.single.priceRawAmount, 25);
      expect(result.single.currencyMint, 'BONK');
    });

    test('an empty auction (no bid, no reserve) defers to last sale', () {
      // auctionPrice resolves to null, so neither the price nor the bidMint
      // currency are taken from the auction.
      final result = repo.mapFeaturedListings(
        feed(
          featured: [
            item(
              preview(
                auction: const api.AuctionMetadata(bidMint: 'SOL'),
                lastSale: const api.LastSale(price: 25, currencyMint: 'BONK'),
              ),
            ),
          ],
        ),
      );

      expect(result.single.priceRawAmount, 25);
      expect(result.single.currencyMint, 'BONK');
    });

    test('price and currency are null when no listing data exists', () {
      final result = repo.mapFeaturedListings(
        feed(featured: [item(preview())]),
      );

      expect(result.single.priceRawAmount, isNull);
      expect(result.single.currencyMint, isNull);
    });
  });

  group('mapFeaturedListings filtering, caps and labels', () {
    test('skips items with a null preview or blank image', () {
      final result = repo.mapFeaturedListings(
        feed(
          featured: [
            item(null),
            item(preview(imageUrl: null)),
            item(preview(imageUrl: '')),
            item(preview(mintAccount: 'KEEP')),
          ],
        ),
      );

      expect(result, hasLength(1));
      expect(result.single.mintAccount, 'KEEP');
    });

    test('caps the result at 20 listings', () {
      final result = repo.mapFeaturedListings(
        feed(
          featured: List.generate(25, (i) => item(preview(mintAccount: 'M$i'))),
        ),
      );

      expect(result, hasLength(20));
    });

    test('ignores the smores section entirely', () {
      final result = repo.mapFeaturedListings(
        feed(smores: [item(preview(mintAccount: 'SMORE'))]),
      );

      expect(result, isEmpty);
    });

    test('appends the edition number to the title', () {
      final withEdition = repo.mapFeaturedListings(
        feed(featured: [item(preview(name: 'Sunset', editionNumber: 7))]),
      );
      expect(withEdition.single.title, 'Sunset #7');

      final withoutEdition = repo.mapFeaturedListings(
        feed(featured: [item(preview(name: 'Sunset'))]),
      );
      expect(withoutEdition.single.title, 'Sunset');
    });

    test('artist label prefers displayName, then username, then address', () {
      api.NftPreview withCreator(api.ApiUserRef ref) =>
          preview(creatorRef: ref);

      expect(
        repo
            .mapFeaturedListings(
              feed(
                featured: [
                  item(
                    withCreator(
                      creator(
                        displayName: 'Vincent',
                        username: 'vinny',
                        address: 'So1aNaAddr111',
                      ),
                    ),
                  ),
                ],
              ),
            )
            .single
            .artistName,
        'Vincent',
      );

      expect(
        repo
            .mapFeaturedListings(
              feed(
                featured: [
                  item(
                    withCreator(creator(username: 'vinny', address: 'addr')),
                  ),
                ],
              ),
            )
            .single
            .artistName,
        'vinny',
      );

      // No name/username → truncated address label (non-empty).
      final addrOnly = repo
          .mapFeaturedListings(
            feed(
              featured: [
                item(
                  withCreator(creator(address: 'So1aNaAddrLongEnough111111')),
                ),
              ],
            ),
          )
          .single;
      expect(addrOnly.artistName, isNotEmpty);
      expect(addrOnly.artistAddress, 'So1aNaAddrLongEnough111111');
    });
  });

  group('mapTrendingForSpotlight', () {
    test('includes both featured and smores, featured first', () {
      final result = repo.mapTrendingForSpotlight(
        feed(
          featured: [item(preview(mintAccount: 'F1'))],
          smores: [item(preview(mintAccount: 'S1'))],
        ),
      );

      expect(result.map((a) => a.mintAccount), ['F1', 'S1']);
    });

    test('drops entries with null or blank image urls', () {
      final result = repo.mapTrendingForSpotlight(
        feed(
          featured: [
            item(preview(mintAccount: 'OK')),
            item(preview(mintAccount: 'NO_IMG', imageUrl: null)),
            item(preview(mintAccount: 'BLANK_IMG', imageUrl: '')),
            item(null),
          ],
        ),
      );

      expect(result.map((a) => a.mintAccount), ['OK']);
    });

    test('caps the result at 30 entries', () {
      final result = repo.mapTrendingForSpotlight(
        feed(
          featured: List.generate(20, (i) => item(preview(mintAccount: 'F$i'))),
          smores: List.generate(20, (i) => item(preview(mintAccount: 'S$i'))),
        ),
      );

      expect(result, hasLength(30));
    });
  });

  group('mapSpotlight', () {
    test('returns null for a null spotlight', () {
      expect(repo.mapSpotlight(null), isNull);
    });

    test('maps fields and uses username before displayName for artist', () {
      final result = repo.mapSpotlight(
        const api.SpotlightResult(
          nftPreview: api.NftPreview(
            mintAccount: 'MINT',
            name: 'Aurora',
            imageUrl: 'https://img/s.png',
          ),
          creator: api.SpotlightCreator(
            username: 'nova',
            displayName: 'Nova Display',
            addresses: ['ADDR1', 'ADDR2'],
          ),
        ),
      );

      expect(result, isNotNull);
      expect(result!.mintAccount, 'MINT');
      expect(result.title, 'Aurora');
      expect(result.imageUrl, 'https://img/s.png');
      // mapSpotlight intentionally prefers username over displayName.
      expect(result.artistName, 'nova');
      expect(result.artistAddress, 'ADDR1');
    });

    test('falls back to empty strings when fields are absent', () {
      final result = repo.mapSpotlight(const api.SpotlightResult());

      expect(result, isNotNull);
      expect(result!.mintAccount, '');
      expect(result.title, '');
      expect(result.imageUrl, '');
      expect(result.artistName, '');
      expect(result.artistAddress, '');
    });
  });

  group('mapCreators', () {
    test('uses username, then displayName, then "Unknown"', () {
      final result = repo.mapCreators([
        const api.User(addresses: ['A1'], username: 'alice'),
        const api.User(addresses: ['A2'], displayName: 'Bob'),
        const api.User(addresses: ['A3']),
      ]);

      expect(result.map((a) => a.username), ['alice', 'Bob', 'Unknown']);
      expect(result.map((a) => a.address), ['A1', 'A2', 'A3']);
    });

    test('featured artwork url prefers banner, then image, then empty', () {
      final result = repo.mapCreators([
        const api.User(bannerUrl: 'banner', imageUrl: 'img'),
        const api.User(imageUrl: 'img'),
        const api.User(),
      ]);

      expect(result.map((a) => a.featuredArtworkUrl), ['banner', 'img', '']);
    });

    test('address falls back to empty when there are no wallets', () {
      final result = repo.mapCreators([const api.User()]);
      expect(result.single.address, '');
    });
  });

  group('mapDiscoverArtists', () {
    test('maps fields with username/displayName/Unknown fallback', () {
      final result = repo.mapDiscoverArtists(
        const api.HomeDiscoverResponse(
          artists: [
            api.HomeDiscoverArtist(
              address: 'A1',
              username: 'alice',
              featuredArtworkUrl: 'art',
            ),
            api.HomeDiscoverArtist(address: 'A2', displayName: 'Bob'),
            api.HomeDiscoverArtist(address: 'A3'),
          ],
        ),
      );

      expect(result.map((a) => a.username), ['alice', 'Bob', 'Unknown']);
      expect(result.map((a) => a.featuredArtworkUrl), ['art', '', '']);
    });
  });

  group('mapPopularCollections', () {
    test('drops collections without an image url', () {
      final result = repo.mapPopularCollections(
        const api.HomePopularCollectionsResponse(
          collections: [
            api.HomePopularCollectionItem(
              slug: 's1',
              name: 'Keep',
              imageUrl: 'img',
            ),
            api.HomePopularCollectionItem(slug: 's2', name: 'NoImg'),
            api.HomePopularCollectionItem(
              slug: 's3',
              name: 'BlankImg',
              imageUrl: '',
            ),
          ],
        ),
      );

      expect(result.map((c) => c.name), ['Keep']);
      expect(result.single.id, 's1');
    });

    test('derives artist label from the creator ref', () {
      final result = repo.mapPopularCollections(
        api.HomePopularCollectionsResponse(
          collections: [
            api.HomePopularCollectionItem(
              slug: 's1',
              name: 'Keep',
              imageUrl: 'img',
              creator: creator(username: 'curator', address: 'CADDR'),
            ),
          ],
        ),
      );

      expect(result.single.artistName, 'curator');
      expect(result.single.artistAddress, 'CADDR');
    });
  });

  group('mapPopularCurations', () {
    test('drops curations with no preview images', () {
      final result = repo.mapPopularCurations(
        const api.HomePopularCurationsResponse(
          curations: [
            api.HomePopularCurationItem(
              name: 'Keep',
              id: 'id1',
              previewImageUrls: ['https://img/1.png'],
              owner: api.HomePopularCurationOwner(
                address: 'OADDR',
                username: 'owner',
              ),
            ),
            api.HomePopularCurationItem(name: 'Drop'),
          ],
        ),
      );

      expect(result, hasLength(1));
      expect(result.single.name, 'Keep');
      expect(result.single.id, 'id1');
      expect(result.single.curatorName, 'owner');
    });

    test('owner label falls back to a truncated address', () {
      final result = repo.mapPopularCurations(
        const api.HomePopularCurationsResponse(
          curations: [
            api.HomePopularCurationItem(
              name: 'Keep',
              id: 'id1',
              previewImageUrls: ['https://img/1.png'],
              owner: api.HomePopularCurationOwner(
                address: 'So1aNaOwnerAddress1234567',
              ),
            ),
          ],
        ),
      );

      expect(result.single.curatorName, isNotEmpty);
      expect(result.single.curatorName, isNot('So1aNaOwnerAddress1234567'));
    });

    test('id falls back to name when the id is empty', () {
      final result = repo.mapPopularCurations(
        const api.HomePopularCurationsResponse(
          curations: [
            api.HomePopularCurationItem(
              name: 'FallbackName',
              previewImageUrls: ['https://img/1.png'],
            ),
          ],
        ),
      );

      expect(result.single.id, 'FallbackName');
    });
  });

  group('mapRecommendedCategories', () {
    api.ItemRender recItem({
      String? mint,
      String? imageUrl,
      String name = 'Art',
      api.ApiUserRef? creatorRef,
    }) => api.ItemRender(
      contentType: 'nft',
      nftPreview: mint == null
          ? null
          : api.NftPreview(
              mintAccount: mint,
              name: name,
              imageUrl: imageUrl,
              creator: creatorRef,
            ),
    );

    test('imageUrls collects only non-empty urls; artworks require a mint', () {
      final result = repo.mapRecommendedCategories(
        api.HomeRecommendedResponse(
          curations: [
            api.HomeRecommendedCuration(
              name: 'Trending',
              artistUsernames: const ['a', 'b'],
              artworks: [
                recItem(mint: 'M1', imageUrl: 'https://img/1.png'),
                recItem(mint: 'M2', imageUrl: ''), // blank image dropped
                recItem(imageUrl: 'https://img/3.png'), // no mint
              ],
            ),
          ],
        ),
      );

      expect(result, hasLength(1));
      final category = result.single;
      expect(category.label, 'Trending');
      expect(category.artistUsernames, ['a', 'b']);
      // Only the well-formed entry survives the artwork filter.
      expect(category.artworks.map((a) => a.mintAccount), ['M1']);
      // imageUrls keeps the non-empty url(s) from items that carried one.
      expect(category.imageUrls, ['https://img/1.png']);
    });

    test('artist identity uses the username, never the display name', () {
      // These artworks are handed straight to CurationScreen, whose cards
      // format artistUsername as a handle. The data model keeps artistName
      // bare and preserves artistUsername separately, matching the same card
      // reached through CurationRepository.
      final result = repo.mapRecommendedCategories(
        api.HomeRecommendedResponse(
          curations: [
            api.HomeRecommendedCuration(
              name: 'Trending',
              artworks: [
                recItem(
                  mint: 'M1',
                  imageUrl: 'https://img/1.png',
                  creatorRef: creator(
                    username: 'nova',
                    displayName: 'Nova Display',
                    address: 'CADDR',
                  ),
                ),
                recItem(
                  mint: 'M2',
                  imageUrl: 'https://img/2.png',
                  creatorRef: creator(
                    displayName: 'No Handle',
                    address: 'ABCDEFGHIJKLMNOP',
                  ),
                ),
              ],
            ),
          ],
        ),
      );

      final artworks = result.single.artworks;
      expect(artworks[0].artistName, 'nova');
      expect(artworks[0].artistUsername, 'nova');
      // No username — fall back to the truncated address, not the display name.
      expect(artworks[1].artistName, isNot(contains('No Handle')));
      expect(artworks[1].artistName, contains('ABCD'));
    });
  });
}
