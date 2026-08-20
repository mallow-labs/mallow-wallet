import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/utils/address_format.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/user_display.dart';
import '../services/portfolio_bloc.dart';

/// Repository for fetching portfolio data.
///
/// The Artwork Portfolio tab reads the v2 portfolio routes
/// (`POST /v2/portfolio/artworks`, `/groups`, `/groups/:id`), which aggregate
/// across every session wallet and DAS-verify on-chain ownership server-side —
/// so this repository just passes the session's [owners], drains the paginated
/// group responses, and renders the already-merged result. The listing-flow pickers and
/// the import activity counter still use the single-owner v1 routes.
@lazySingleton
class PortfolioRepository {
  PortfolioRepository(
    this._api,
    this._apiV2,
    this._walletManager,
    this._session,
    this._database,
    this._storage,
  );

  final api.MallowApiClient _api;
  final api.MallowApiV2Client _apiV2;
  final WalletManager _walletManager;
  final SessionManager _session;
  final MallowDatabase _database;
  final SecureWalletStorage _storage;

  /// Distinct addresses across the active session — the held wallets of the
  /// active Account, or (in Profile mode) every wallet linked to the active
  /// Profile, in session order, across all chains. The v2 portfolio routes
  /// aggregate over these so the tab surfaces art held by *all* session
  /// wallets, not just the active signer.
  List<String> _sessionAddresses() => _session.apiOwnerAddresses;

  /// Chains the user switched off in Active Networks settings, as the lowercase
  /// wire values (`'ethereum'`/`'tezos'`) the backend filters on. Solana is
  /// never hidden. A network with no stored toggle defaults to enabled, so an
  /// untouched setting yields an empty list → the server filters nothing. Sent
  /// on every v2 portfolio request so hidden chains drop out of the flat list,
  /// groups, and drilldown alike.
  Future<List<String>> _disabledChains() async {
    final scope = await _session.settingsScopeId();
    return [
      if (!await _storage.loadNetworkEnabled(Chain.tezos, scope: scope))
        Chain.tezos.toDbString(),
      if (!await _storage.loadNetworkEnabled(Chain.ethereum, scope: scope))
        Chain.ethereum.toDbString(),
    ];
  }

  /// Map a composite-groupId prefix (`artist` / `collection` / `curation`) to
  /// the contract's [api.PortfolioGroupsRequestGroupBy] enum.
  api.PortfolioGroupsRequestGroupBy _groupByEnum(String groupBy) =>
      switch (groupBy) {
        'artist' => api.PortfolioGroupsRequestGroupBy.artist,
        'collection' => api.PortfolioGroupsRequestGroupBy.collection,
        'curation' => api.PortfolioGroupsRequestGroupBy.curation,
        _ => api.PortfolioGroupsRequestGroupBy.artist,
      };

  /// Fetch all owned artworks (flat list) via `POST /v2/portfolio/artworks`.
  ///
  /// The backend unions every session wallet's holdings, DAS-verifies on-chain
  /// ownership (dropping burnt/transferred), and returns one globally-sorted,
  /// globally-paginated page — `nextPage` is the server's cursor, so infinite
  /// scroll drains the whole session. `includeFrozen` is set so listed/staked
  /// artworks (frozen on-chain) stay visible in the portfolio.
  ///
  /// [sort] is applied by the backend across the whole verified set before the
  /// page is cut, so alphabetical order spans every page — not just the ones
  /// already scrolled, which is all a client-side sort could reach.
  Future<PortfolioArtworksResult> getOwnedArtworks({
    int page = 0,
    api.ExploreFilter? filter,
    PortfolioSortOption sort = PortfolioSortOption.recent,
  }) async {
    final owners = _sessionAddresses();
    if (owners.isEmpty) {
      return const PortfolioArtworksResult(artworks: [], total: 0);
    }
    final disabledChains = await _disabledChains();

    // Supply-type parity with the profile route's ExploreMode. The portfolio
    // query exposes no `mode`/`supplyType` field, but its supply flags compose
    // to the same sets: `printableOnly` = open + limited editions, and
    // `masterOnly` (supplyType != edition-print) ∩ `nonPrintableOnly`
    // (supplyType ∈ {1/1, edition-print}) = strictly 1/1 — matching
    // `/v1/profile` (mode=1/1 → OneOfOne). `all` sends no supply flag.
    final mode = filter?.mode ?? api.ExploreMode.all;
    final oneOfOne = mode == api.ExploreMode.oneOfOne;
    final editions = mode == api.ExploreMode.editions;

    final response = await _apiV2.getPortfolioArtworks(
      api.PortfolioArtworksRequest(
        owners: owners,
        page: page,
        sort: _artworkSort(sort),
        includeFrozen: true,
        // ExploreFilter parity with the profile screen (same filters sheet).
        // Empty lists are treated as "no filter" server-side, so passing the
        // filter's defaults is harmless; a null filter omits them entirely.
        search: filter?.search,
        listingTypes: filter?.listingTypes,
        mediaTypes: filter?.mediaTypes,
        tags: filter?.tags,
        priceRange: _mapPriceRange(filter?.priceRange),
        masterOnly: oneOfOne ? true : null,
        nonPrintableOnly: oneOfOne ? true : null,
        printableOnly: editions ? true : null,
        disabledChains: disabledChains,
      ),
    );

    // Persist page 0 so the next load paints instantly from cache (see
    // [getCachedSnapshot]); later pages belong to a scroll session, not the
    // first paint. Only the UNFILTERED default snapshot backs the first paint —
    // a filtered result is a query session, not the portfolio's resting state.
    // Best-effort and off the critical path: the fetch result must not wait
    // on the cache write.
    // A re-ordered page 0 is a query session too: caching it would make the
    // next cold start paint alphabetically under a "Recent" label.
    if (page == 0 && filter == null && sort == PortfolioSortOption.recent) {
      unawaited(_cacheSection(_artworksSection, response.toJson()));
    }

    return _mapArtworksResponse(response);
  }

  /// Wire value for the artwork list's ordering. The route serves two of the
  /// sheet's three options; `count` sorts groups by item count and never
  /// reaches this list, so it falls in with the server's default.
  api.PortfolioArtworkSort _artworkSort(PortfolioSortOption sort) =>
      switch (sort) {
        PortfolioSortOption.name => api.PortfolioArtworkSort.alphabetical,
        PortfolioSortOption.recent ||
        PortfolioSortOption.count => api.PortfolioArtworkSort.recent,
      };

  /// Map the sheet's [api.PriceRange] onto the generated request's nested
  /// price-range type (SOL-denominated server-side, matching the profile query).
  api.PortfolioArtworksRequest$PriceRange? _mapPriceRange(
    api.PriceRange? range,
  ) {
    if (range == null) return null;
    return api.PortfolioArtworksRequest$PriceRange(
      min: range.min,
      max: range.max,
    );
  }

  /// Map a raw artworks page into the UI result model.
  PortfolioArtworksResult _mapArtworksResponse(
    api.PortfolioArtworksResponse response,
  ) {
    return PortfolioArtworksResult(
      artworks: [for (final p in response.result) ?_tryPreviewToArtwork(p)],
      total: response.total,
      nextPage: response.nextPage,
    );
  }

  /// Map one preview, dropping it (rather than failing the whole page) if its
  /// auction/buy-now metadata doesn't round-trip cleanly into the hand-written
  /// types — one malformed item shouldn't blank the entire Artwork tab.
  PortfolioArtwork? _tryPreviewToArtwork(api.NftPreviewRender p) {
    try {
      return _previewToArtwork(p);
    } catch (e) {
      debugPrint('[PortfolioRepository] skipping preview ${p.mintAccount}: $e');
      return null;
    }
  }

  /// Map a contract-generated [api.NftPreviewRender] to the portfolio tile
  /// model. The auction/buy-now metadata are carried through as the generated
  /// types (the bloc reads them directly); `listingType` and `chain` arrive as
  /// decoded (generated) enums, so we re-decode `listingType`'s wire value into
  /// the hand-written app enum and unwrap `chain` back to its wire string for
  /// EVM/Tezos transfer routing.
  PortfolioArtwork _previewToArtwork(api.NftPreviewRender p) {
    return PortfolioArtwork(
      mintAccount: p.mintAccount,
      title: p.name ?? '',
      imageUrl: p.imageUrl ?? '',
      artistName: formatDisplayLabel(
        displayName: p.creator?.displayName,
        username: p.creator?.username,
        address: p.creator?.address,
      ),
      artistUsername: p.creator?.username,
      isVerified: p.creator?.isTwitterVerified ?? false,
      isAdmin: p.creator?.roles.contains('admin') ?? false,
      collectionName: p.collectionName,
      aspectRatio: p.aspectRatio ?? 1.0,
      lastPrice: p.lastSale?.price,
      listingType: _listingType(p.listingType.value ?? ''),
      supply: p.supply,
      maxSupply: p.maxSupply,
      editionNumber: p.editionNumber,
      parentEdition: p.parentEdition,
      // The tile model + bloc render the hand-written metadata types (which
      // parse `startsAt` to DateTime); the generated preview carries the same
      // byte-identical wire shape, so a JSON round-trip converts cleanly.
      auctionMetadata: p.auctionMetadata == null
          ? null
          : api.AuctionMetadata.fromJson(p.auctionMetadata!.toJson()),
      buyNowMetadata: p.buyNowMetadata == null
          ? null
          : api.BuyNowMetadata.fromJson(p.buyNowMetadata!.toJson()),
      raffleMetadata: p.raffleMetadata == null
          ? null
          : api.RaffleMetadata.fromJson(p.raffleMetadata!.toJson()),
      updateAuth: p.updateAuth,
      animationUrl: p.videoUrl,
      playbackId: p.playbackId,
      clipPlaybackId: p.clipPlaybackId,
      nsfw: p.nsfw ?? false,
      chain: p.chain?.value,
      tokenStandard: p.tokenStandard,
      isHidden: p.isOwnerHidden ?? false,
    );
  }

  /// Decode the wire `listingType` string into the app enum (mirrors the
  /// `@JsonValue` mapping on [api.ListingType]). Unknown/absent → unlisted.
  api.ListingType _listingType(String wire) => switch (wire) {
    'buy-now' => api.ListingType.buyNow,
    'auction' => api.ListingType.auction,
    'raffle' => api.ListingType.raffle,
    'store' => api.ListingType.store,
    'gumball' => api.ListingType.gumball,
    'airdrop' => api.ListingType.airdrop,
    'jellybean' => api.ListingType.jellybean,
    _ => api.ListingType.unlisted,
  };

  /// Number of artworks owned by an arbitrary [address], on any chain.
  ///
  /// Used by the wallet pickers to populate per-account activity chips, for
  /// addresses that may not be imported (or in the session) yet. Requests a
  /// single small page — only the `total` count is read, the result list is
  /// discarded.
  ///
  /// Goes through the v2 portfolio read rather than v1 `byOwner`, which is
  /// Solana-only and silently returns 0 for Ethereum/Tezos addresses. The route
  /// is public and takes arbitrary owners — proving control of an address only
  /// unlocks its `isOwnerHidden` flag, never the count.
  Future<int> artworkCountForOwner(String address) async {
    final response = await _apiV2.getPortfolioArtworks(
      api.PortfolioArtworksRequest(
        owners: [apiOwnerAddress(address)],
        page: 0,
        pageSize: 1,
        includeFrozen: true,
      ),
    );
    return response.total;
  }

  /// Fetch artworks the user currently holds for the listing-flow picker.
  ///
  /// Backed by `POST /v1/artwork/byOwner/:owner`, which unions created and
  /// collected NFTs (cross-checked against the indexer to drop burnt or
  /// transferred assets) — the same source as [getOwnedArtworks], but filtered
  /// to what the listing flow can sell.
  ///
  /// [nonPrintableOnly] is true for the auction flow — limits results to
  /// 1/1s and already-minted edition prints. False for fixed-price, which
  /// also accepts master editions with remaining supply.
  Future<PortfolioArtworksResult> getOwnedArtworksForListing({
    required bool nonPrintableOnly,
    int page = 0,
    int pageSize = 50,
  }) async {
    final address = await _walletManager.getAddress();

    final response = await _api.getArtworksByOwner(
      address,
      api.SearchUserNftsRequest(
        nonPrintableOnly: nonPrintableOnly ? true : null,
        page: page,
        pageSize: pageSize,
      ),
    );

    return _resultFromPreviewJson(
      result: response.result,
      total: response.total,
      nextPage: response.nextPage,
    );
  }

  /// Fetch artworks the signer **created** (their `updateAuth`), for the
  /// manage-collection-artworks picker.
  ///
  /// Backed by `POST /v1/artwork/byUpdateAuth/:updateAuth` — the same source
  /// the reference web client's SelectArtworks uses. Unlike [getOwnedArtworksForListing]
  /// (an *ownership* query) this returns the full, unpaginated set of art the
  /// signer can actually add to a collection: the collection edit signs with
  /// the signer as authority, so art the wallet merely holds but didn't author
  /// would revert on-chain.
  ///
  /// [tokenStandards] scopes to the parent collection's standard — a
  /// mismatched-standard asset 400s the whole edit batch server-side.
  /// [masterOnly] drops individual edition prints (leaving 1/1s + masters),
  /// matching React.
  Future<List<PortfolioArtwork>> getArtworksByUpdateAuth({
    bool masterOnly = true,
    List<String>? tokenStandards,
  }) async {
    final address = await _walletManager.getAddress();

    final response = await _api.getArtworksByUpdateAuth(
      address,
      api.SearchUserNftsRequest(
        masterOnly: masterOnly ? true : null,
        tokenStandards: tokenStandards,
      ),
    );

    return _artworksFromPreviewJson(response.result);
  }

  PortfolioArtworksResult _resultFromPreviewJson({
    required List<Map<String, dynamic>> result,
    required int total,
    required int? nextPage,
  }) {
    return PortfolioArtworksResult(
      artworks: _artworksFromPreviewJson(result),
      total: total,
      nextPage: nextPage,
    );
  }

  List<PortfolioArtwork> _artworksFromPreviewJson(
    List<Map<String, dynamic>> result,
  ) {
    return result
        .map((json) {
          try {
            final preview = api.NftPreview.fromJson(json);
            return PortfolioArtwork(
              mintAccount: preview.mintAccount,
              title: preview.name,
              imageUrl: preview.imageUrl ?? '',
              playbackId: preview.playbackId,
              clipPlaybackId: preview.clipPlaybackId,
              artistName: formatDisplayLabel(
                displayName: preview.creator?.displayName,
                username: preview.creator?.username,
                address: preview.creator?.effectiveAddress,
              ),
              artistUsername: preview.creator?.username,
              isVerified: preview.creator?.isTwitterVerified ?? false,
              isAdmin: preview.creator?.roles.contains('admin') ?? false,
              collectionName: preview.collectionName,
              aspectRatio: preview.aspectRatio ?? 1.0,
              lastPrice: preview.lastSale?.price,
              listingType: preview.listingType,
              supply: preview.supply,
              maxSupply: preview.maxSupply,
              editionNumber: preview.editionNumber,
              parentEdition: preview.parentEdition,
              auctionMetadata: preview.auctionMetadata,
              buyNowMetadata: preview.buyNowMetadata,
              raffleMetadata: preview.raffleMetadata,
              updateAuth: preview.updateAuth,
              nsfw: preview.nsfw ?? false,
              isHidden: preview.isOwnerHidden || preview.isCreatorHidden,
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<PortfolioArtwork>()
        .toList();
  }

  /// Fetch grouped portfolio summary via `POST /v2/portfolio/groups`,
  /// aggregated across every wallet in the active session.
  ///
  /// The backend already merges a group (same artist address / collection
  /// slug) held across several session wallets into one entry whose
  /// artworkCount sums the wallets' counts, so this drains and maps the
  /// response. Curations are NOT sourced
  /// here — the Curations tab shows the user's *created* curations, fetched
  /// separately via [CurationRepository.getCurations] (grouping held art by
  /// curation would show a different, unrelated set).
  Future<PortfolioGroupsResult> getGroupedPortfolio() async {
    try {
      final owners = _sessionAddresses();
      if (owners.isEmpty) return const PortfolioGroupsResult(groups: []);
      final disabledChains = await _disabledChains();

      final results = await Future.wait([
        _getAllGroupPages(
          owners: owners,
          groupBy: api.PortfolioGroupsRequestGroupBy.artist,
          disabledChains: disabledChains,
        ),
        _getAllGroupPages(
          owners: owners,
          groupBy: api.PortfolioGroupsRequestGroupBy.collection,
          disabledChains: disabledChains,
        ),
      ]);

      // Persist for the next load's instant paint (see [getCachedSnapshot]);
      // best-effort, so don't hold up the fetch result.
      unawaited(
        _cacheSection(_groupsSection, {
          'artist': results[0].toJson(),
          'collection': results[1].toJson(),
        }),
      );

      return _mapGroupsResponses(results[0], results[1]);
    } catch (e) {
      debugPrint('[PortfolioRepository] Grouped portfolio failed: $e');
      return const PortfolioGroupsResult(groups: []);
    }
  }

  static const _groupPageSize = 40;

  /// Drain the server's group pages into one ordered response. The recent
  /// ordering is requested even though count/name are re-sorted by the bloc:
  /// it gives the bloc a complete, recency-ordered source for its `recent`
  /// option while still allowing the other two options to be applied locally.
  Future<api.PortfolioGroupsResponse> _getAllGroupPages({
    required List<String> owners,
    required api.PortfolioGroupsRequestGroupBy groupBy,
    required List<String> disabledChains,
  }) async {
    var page = 0;
    final groups = <api.PortfolioGroupSummary>[];
    var total = 0;

    while (true) {
      final response = await _apiV2.getPortfolioGroups(
        api.PortfolioGroupsRequest(
          owners: owners,
          groupBy: groupBy,
          sort: api.PortfolioGroupSort.recent,
          page: page,
          pageSize: _groupPageSize,
          disabledChains: disabledChains,
        ),
      );
      final data = response.result;
      groups.addAll(data.groups);
      total = data.total;

      final nextPage = data.nextPage;
      if (nextPage == null) break;
      if (nextPage <= page) {
        throw StateError('Invalid group pagination cursor: $nextPage');
      }
      page = nextPage;
    }

    return api.PortfolioGroupsResponse(
      result: api.PortfolioGroupsResult(groups: groups, total: total),
    );
  }

  /// Map raw grouping responses into the merged UI groups list. Null
  /// responses (failed or never fetched) contribute no groups.
  PortfolioGroupsResult _mapGroupsResponses(
    api.PortfolioGroupsResponse? artist,
    api.PortfolioGroupsResponse? collection,
  ) {
    try {
      final artistData = artist?.result;
      final collectionData = collection?.result;

      final groups = <ArtGroup>[];

      for (final g
          in artistData?.groups ?? const <api.PortfolioGroupSummary>[]) {
        // Prefer the backend-resolved display name; fall back to the bare
        // username if the name is empty or looks like a raw address. EVM
        // addresses may differ only by checksum casing, and some responses
        // contain only the address prefix, so compare against the group id
        // before treating the value as a real display name.
        final nameIsAddress = _isAddressDerivedLabel(g.name, g.id);
        final hasDisplayName = g.name.isNotEmpty && !nameIsAddress;
        final username = g.creator?.username;
        final usernameIsAddress = _isAddressDerivedLabel(username, g.id);
        final artistDisplayName = hasDisplayName
            ? g.name
            : formatUsernameOrAddress(
                username: usernameIsAddress ? null : username,
                address: g.id,
              );
        groups.add(
          ArtGroup(
            id: 'artist:${g.id}',
            type: ArtGroupType.artist,
            name: artistDisplayName,
            thumbnailUrl: g.thumbnailUrl ?? g.avatarUrl,
            avatarUrl: g.avatarUrl,
            artworkCount: g.artworkCount,
            artistAddress: g.id,
            artistUsername: usernameIsAddress ? null : username,
          ),
        );
      }

      for (final g
          in collectionData?.groups ?? const <api.PortfolioGroupSummary>[]) {
        // Subtitle shows the collection creator's bare username (no `@`,
        // matching how UserProfileBloc builds creatorName); empty when the
        // creator has neither a username nor address.
        final creator = g.creator;
        var creatorHandle = creator == null
            ? null
            : formatUsernameOrAddress(
                username: creator.username,
                address: creator.address,
              );
        // The backend uses the raw wallet address as the username fallback,
        // so `formatUsernameOrAddress` can return an un-truncated address via
        // its username branch. Abbreviate it here so the collection subtitle
        // never shows a full address.
        if (creatorHandle != null && isLikelySolanaAddress(creatorHandle)) {
          creatorHandle = truncateAddress(creatorHandle);
        }
        // Unnamed collections come back with `name` equal to the bare mint
        // (`g.id`); show it truncated in the middle rather than the full mint.
        final hasCollectionName = g.name.isNotEmpty && g.name != g.id;
        final collectionDisplayName = hasCollectionName
            ? g.name
            : truncateAddress(g.id);
        groups.add(
          ArtGroup(
            id: 'collection:${g.id}',
            type: ArtGroupType.collection,
            name: collectionDisplayName,
            thumbnailUrl: g.thumbnailUrl,
            artworkCount: g.artworkCount,
            artistAddress: creator?.address,
            collectionMint: g.id,
            creatorName: (creatorHandle == null || creatorHandle.isEmpty)
                ? null
                : creatorHandle,
          ),
        );
      }

      return PortfolioGroupsResult(groups: groups);
    } catch (e) {
      debugPrint('[PortfolioRepository] Grouped portfolio failed: $e');
      return const PortfolioGroupsResult(groups: []);
    }
  }

  /// Whether [label] is the artist address, or a short address prefix, rather
  /// than a profile name. The API uses both forms as the username/name
  /// fallback for address-only artists.
  bool _isAddressDerivedLabel(String? label, String address) {
    if (label == null || label.isEmpty || address.isEmpty) return false;
    if (label == address) return true;

    if (isEthereumAddress(address)) {
      final normalizedAddress = address.toLowerCase();
      final normalizedLabel = label.toLowerCase();
      return normalizedLabel.length >= 6 &&
          normalizedAddress.startsWith(normalizedLabel);
    }

    if (isLikelySolanaAddress(address)) {
      return label.length >= 6 && address.startsWith(label);
    }

    return false;
  }

  /// Fetch artworks within a specific group via `POST /v2/portfolio/groups/:id`,
  /// aggregated across every wallet in the active session (so a group's
  /// drilldown shows every matching artwork the session holds, matching the
  /// summed count on the group tile).
  ///
  /// `groupId` format: `artist:{address}`, `collection:{slug}`, `curation:{id}`.
  /// The backend globally paginates the union, so `nextPage` is its cursor.
  Future<PortfolioArtworksResult> getGroupArtworks(
    String groupId, {
    int page = 0,
    int pageSize = 20,
  }) async {
    final owners = _sessionAddresses();
    if (owners.isEmpty) {
      return const PortfolioArtworksResult(artworks: [], total: 0);
    }

    // Extract groupBy type from the composite groupId
    final groupBy = groupId.split(':').first;
    final actualId = groupId.substring(groupBy.length + 1);

    final response = await _apiV2.getPortfolioGroupArtworks(
      actualId,
      api.PortfolioGroupsRequest(
        owners: owners,
        groupBy: _groupByEnum(groupBy),
        page: page,
        pageSize: pageSize,
        disabledChains: await _disabledChains(),
      ),
    );

    final data = response.result;
    // The drilldown now shares the flat list's full `NftPreviewRender` shape,
    // so the same mapper carries collectionName, creator, listing state, etc.
    final artworks = [for (final p in data.artworks) ?_tryPreviewToArtwork(p)];

    return PortfolioArtworksResult(
      artworks: artworks,
      total: data.total,
      nextPage: data.nextPage,
    );
  }

  static const _artworksSection = 'artworks';
  static const _groupsSection = 'groups';

  /// Cache key for the active session — sorted so wallet ordering changes
  /// don't invalidate, but any membership change does.
  String _sessionCacheKey() => (_sessionAddresses()..sort()).join(',');

  /// Best-effort write of one section's raw wire JSON. A cache failure must
  /// never fail the fetch that produced the data.
  Future<void> _cacheSection(String section, Map<String, dynamic> json) async {
    final key = _sessionCacheKey();
    if (key.isEmpty) return;
    try {
      await _database.upsertPortfolioCache(
        CachedPortfoliosCompanion(
          sessionKey: Value(key),
          section: Value(section),
          jsonData: Value(jsonEncode(json)),
          cachedAt: Value(CacheFreshness.nowEpochSeconds()),
        ),
      );
    } catch (e) {
      debugPrint('[PortfolioRepository] Cache write failed ($section): $e');
    }
  }

  /// The last-fetched portfolio snapshot for the active session, re-mapped
  /// through the same mappers as a live fetch — or null when nothing usable
  /// is cached for these wallets. Groups are optional (empty when their
  /// section is missing); artworks are required for a snapshot to count.
  Future<PortfolioSnapshot?> getCachedSnapshot() async {
    final key = _sessionCacheKey();
    if (key.isEmpty) return null;

    try {
      final artworksRow = await _database.getPortfolioCache(
        key,
        _artworksSection,
      );
      if (artworksRow == null) return null;
      final artworks = _mapArtworksResponse(
        api.PortfolioArtworksResponse.fromJson(
          jsonDecode(artworksRow.jsonData) as Map<String, dynamic>,
        ),
      );

      var groups = const PortfolioGroupsResult(groups: []);
      final groupsRow = await _database.getPortfolioCache(key, _groupsSection);
      if (groupsRow != null) {
        final json = jsonDecode(groupsRow.jsonData) as Map<String, dynamic>;
        groups = _mapGroupsResponses(
          json['artist'] != null
              ? api.PortfolioGroupsResponse.fromJson(
                  json['artist'] as Map<String, dynamic>,
                )
              : null,
          json['collection'] != null
              ? api.PortfolioGroupsResponse.fromJson(
                  json['collection'] as Map<String, dynamic>,
                )
              : null,
        );
      }

      return PortfolioSnapshot(artworks: artworks, groups: groups);
    } catch (_) {
      return null;
    }
  }
}

/// Cached portfolio snapshot for the instant first paint — the same mapped
/// shapes a live fetch produces. Curations are not cached (auth-scoped);
/// they splice in when the background revalidation lands.
class PortfolioSnapshot {
  const PortfolioSnapshot({required this.artworks, required this.groups});

  final PortfolioArtworksResult artworks;
  final PortfolioGroupsResult groups;
}

/// Result from fetching portfolio artworks.
class PortfolioArtworksResult {
  const PortfolioArtworksResult({
    required this.artworks,
    required this.total,
    this.nextPage,
  });

  final List<PortfolioArtwork> artworks;
  final int total;
  final int? nextPage;
}

/// Result from fetching grouped portfolio.
class PortfolioGroupsResult {
  const PortfolioGroupsResult({required this.groups});

  final List<ArtGroup> groups;
}
