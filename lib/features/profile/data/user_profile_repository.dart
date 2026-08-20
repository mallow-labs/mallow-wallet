import 'package:dio/dio.dart' show DioException;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/data/cache_freshness.dart';
import '../../../core/database/database.dart';
import '../../../core/utils/address_format.dart';
import '../../../shared/utils/user_display.dart';
import '../models/cached_profile_data.dart';
import '../models/user_profile.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import 'profile_image_uploader.dart';

/// Cache TTL for user profiles (5 minutes).
const _staleTtl = Duration(minutes: 5);

/// Repository for fetching user profile data and managing follows.
@lazySingleton
class UserProfileRepository {
  UserProfileRepository(
    this._api,
    this._apiV2,
    this._db,
    this._portfolio,
    this._uploader,
  );

  final api.MallowApiClient _api;
  final api.MallowApiV2Client _apiV2;
  final MallowDatabase _db;
  final PortfolioRepository _portfolio;
  final ProfileImageUploader _uploader;

  /// Get cached profile data if within TTL.
  Future<CachedProfileData?> getCachedProfile(String address) async {
    try {
      final row = await _db.getCachedUserProfile(address);
      if (row == null) return null;

      final cachedAt = CacheFreshness.fromEpochSeconds(row.cachedAt);
      if (CacheFreshness.isStale(cachedAt, _staleTtl)) return null;

      return CachedProfileData.fromJsonString(row.jsonData);
    } catch (e) {
      debugPrint('[UserProfileRepository] Cache read failed: $e');
      return null;
    }
  }

  /// Cache full profile data.
  Future<void> cacheProfile(String address, CachedProfileData data) async {
    try {
      await _db.upsertCachedUserProfile(
        CachedUserProfilesCompanion(
          address: Value(address),
          jsonData: Value(data.toJsonString()),
          cachedAt: Value(CacheFreshness.nowEpochSeconds()),
        ),
      );
    } catch (e) {
      debugPrint('[UserProfileRepository] Cache write failed: $e');
    }
  }

  /// Fetch user info with full details (roles, counts, socials).
  ///
  /// [identifier] may be either a Solana base58 address or a mallow
  /// username — the API rejects usernames passed in `addresses`, so
  /// we route via the `username` field when the input doesn't look
  /// like an on-chain address.
  Future<UserProfile> getUserProfile(String identifier) async {
    final isAddress = isLikelySolanaAddress(identifier);
    final response = await _api.getUserWithDetails(
      api.UserWithDetailsRequest(
        user: isAddress
            ? api.UserWithDetailsUser(addresses: [identifier])
            : api.UserWithDetailsUser(username: identifier),
      ),
    );
    final result = response.result;
    final keyAddress = isAddress
        ? identifier
        : (result.user.primaryAddress ?? '');
    return _mapToUserProfile(keyAddress, result.user, result.userDetails);
  }

  /// Fetch profiles for multiple identifiers in parallel.
  ///
  /// Each entry in [identifiers] may be a Solana base58 address or a
  /// mallow username — see [getUserProfile]. Dedupes the input, runs
  /// one lookup per unique value, and returns a map keyed by the
  /// original input. A failed lookup yields a `null` entry so a
  /// partial failure never breaks the caller.
  Future<Map<String, UserProfile?>> getUserProfiles(
    Iterable<String> identifiers,
  ) async {
    final unique = identifiers
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (unique.isEmpty) return const {};
    final results = await Future.wait(
      unique.map((addr) async {
        try {
          return await getUserProfile(addr);
        } catch (e) {
          debugPrint(
            '[UserProfileRepository] Batch lookup failed for $addr: $e',
          );
          return null;
        }
      }),
    );
    return {for (var i = 0; i < unique.length; i++) unique[i]: results[i]};
  }

  /// Fetch user profile by username. Returns profile + resolved address.
  Future<UserProfile> getUserProfileByUsername(String username) async {
    final response = await _api.getUserWithDetails(
      api.UserWithDetailsRequest(
        user: api.UserWithDetailsUser(username: username),
      ),
    );
    final result = response.result;
    final address = result.user.primaryAddress ?? '';
    return _mapToUserProfile(address, result.user, result.userDetails);
  }

  /// Fetch user's created artworks (paginated).
  Future<ProfileArtworksResult> getUserArtworks(
    List<String> addresses, {
    int page = 0,
    api.ApiProfileTab tab = api.ApiProfileTab.created,
    api.ExploreSort sort = api.ExploreSort.recentActivity,
    api.ExploreFilter? filter,
  }) async {
    // Always post a filter object, never `null`. The v1 `listed` branch
    // dereferences `filter.listingTypes` before it defaults it, so a null (or
    // absent) filter 500s — the Listed tab then swallows the error into an
    // empty list and every artwork the user *created* that someone else has
    // listed disappears. An all-defaults filter is a server-side no-op
    // (verified: identical totals on created/collected).
    //
    // `hidePrints` is then set per tab rather than taken from the caller —
    // webapp parity (`ProfileMarketplace`), and the filter sheet never
    // exposes it, so there is no user choice to preserve. Prints fold into
    // their master tile on the creator-facing tabs; the ownership tabs keep
    // them because a collector holds the print, not the master. Server-side
    // this is `supplyType != 'edition-print'` and it only applies while the
    // mode filter is All/Following.
    final effectiveFilter = (filter ?? const api.ExploreFilter()).copyWith(
      hidePrints:
          tab != api.ApiProfileTab.collected && tab != api.ApiProfileTab.pinned,
    );

    final response = await _api.getProfile(
      api.ProfileRequest(
        page: page,
        tab: tab,
        sort: sort,
        filter: effectiveFilter,
        profileUserAddresses: addresses,
      ),
    );

    final artworks = response.result
        .map((json) {
          try {
            final preview = api.NftPreview.fromJson(json);
            return PortfolioArtwork(
              mintAccount: preview.mintAccount,
              title: preview.name,
              imageUrl: preview.imageUrl ?? '',
              playbackId: preview.playbackId,
              clipPlaybackId: preview.clipPlaybackId,
              // Profile cells show the username (not display name) so the
              // creator label matches across the Created/Collections/
              // Curations tabs.
              artistName: formatUsernameOrAddress(
                username: preview.creator?.username,
                address: preview.creator?.effectiveAddress,
              ),
              artistUsername: preview.creator?.username,
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

    return ProfileArtworksResult(
      artworks: artworks,
      total: response.total,
      nextPage: response.nextPage,
    );
  }

  /// Fetch user's collections.
  Future<List<ArtGroup>> getUserCollections(
    List<String> addresses, {
    int page = 0,
  }) async {
    final response = await _api.getProfile(
      api.ProfileRequest(
        page: page,
        tab: api.ApiProfileTab.collections,
        filter: const api.ExploreFilter(),
        profileUserAddresses: addresses,
      ),
    );

    return response.result
        .map((json) {
          try {
            final collection = api.CollectionRender.fromJson(json);
            return ArtGroup(
              id: collection.slug ?? '',
              type: ArtGroupType.collection,
              name: collection.name ?? '',
              thumbnailUrl: collection.imageUrl,
              artworkCount: collection.itemCount ?? 0,
              collectionMint: collection.slug,
              // Username (not display name) — see getUserArtworks.
              creatorName: formatUsernameOrAddress(
                username: collection.creator?.username,
                address: collection.creator?.effectiveAddress,
              ),
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<ArtGroup>()
        .toList();
  }

  /// Returns the first collected artwork image URL for banner fallback.
  Future<String?> getFirstCollectedArtworkUrl(String address) async {
    final result = await getUserArtworks([
      address,
    ], tab: api.ApiProfileTab.collected);
    return result.artworks
        .map((a) => a.imageUrl)
        .where((url) => url.isNotEmpty)
        .firstOrNull;
  }

  /// Fetch artworks the active session owns where [artistAddress] is the
  /// updateAuth — i.e. the "You own N artworks" banner on another artist's
  /// profile.
  ///
  /// Delegates to the v2 grouped portfolio drilldown
  /// (`POST /v2/portfolio/groups/:id`, groupBy=artist), which aggregates across
  /// every wallet in the active session and reuses the portfolio's tested
  /// `NftPreviewRender` mapper. Replaces the deprecated single-owner v1
  /// `POST /v1/mobile/portfolio/group/:groupId` route.
  /// Returns the first drilldown page ([PortfolioArtworksResult.artworks], for
  /// the banner thumbnails + preloaded grid) together with the group's true
  /// server [PortfolioArtworksResult.total] — the banner count must use `total`,
  /// not `artworks.length`, which is capped at one page (`pageSize`).
  Future<PortfolioArtworksResult> getYouOwnArtworks(
    String artistAddress,
  ) async {
    try {
      return await _portfolio.getGroupArtworks('artist:$artistAddress');
    } catch (e) {
      debugPrint('[UserProfileRepository] getYouOwnArtworks failed: $e');
      return const PortfolioArtworksResult(artworks: [], total: 0);
    }
  }

  /// Fetch all artworks belonging to a collection, scoped to the
  /// collection itself (not a single user). Mirrors the webapp's
  /// `CollectionMarketplace` call: POST `/v1/explore` with
  /// `filter.collections = [slug]`. The user-scoped `/v1/profile`
  /// endpoint returns empty unless the queried address has actually
  /// created or collected within the collection — wrong for a public
  /// collection page.
  Future<List<PortfolioArtwork>> getCollectionArtworks(
    String collectionSlug, {
    int page = 0,
    api.ExploreSort sort = api.ExploreSort.recentActivity,
  }) async {
    final response = await _api.explore(
      api.ExploreRequest(
        page: page,
        sort: sort,
        filter: api.ExploreFilter(
          collections: [collectionSlug],
          hidePrints: true,
        ),
      ),
    );
    return response.result
        .map((json) {
          try {
            final preview = api.NftPreview.fromJson(json);
            return PortfolioArtwork(
              mintAccount: preview.mintAccount,
              title: preview.name,
              imageUrl: preview.imageUrl ?? '',
              playbackId: preview.playbackId,
              clipPlaybackId: preview.clipPlaybackId,
              artistName: formatUsernameOrAddress(
                username: preview.creator?.username,
                address: preview.creator?.effectiveAddress,
              ),
              artistUsername: preview.creator?.username,
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

  /// Fetch full collection detail (description, stats, royalties, tags)
  /// for the collection-detail screen. Returns `null` on error so the UI
  /// can degrade gracefully without blocking on a network failure.
  Future<api.CollectionFullRender?> getCollectionByMint(String mint) async {
    try {
      final response = await _api.getCollectionByMint(mint);
      return response.result;
    } catch (e) {
      debugPrint('[UserProfileRepository] getCollectionByMint failed: $e');
      return null;
    }
  }

  /// Mint accounts currently indexed as members of the collection [mint].
  /// Seeds the pre-selected set in the manage-collection-artworks flow. Keyed
  /// by mint (not slug), so it resolves collections whose slug isn't indexed
  /// yet.
  ///
  /// A 404 means the collection isn't indexed at all (e.g. a brand-new
  /// collection) — that's a legitimate empty/add-only case, so it yields an
  /// empty list. Any other failure rethrows: silently dropping members would
  /// make removals structurally impossible (removed = members − selected) and
  /// hide a transient outage as "empty collection".
  Future<List<String>> getCollectionMintAccounts(String mint) async {
    try {
      final response = await _api.getCollectionMintAccounts(mint);
      return response.result;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const [];
      rethrow;
    }
  }

  /// Ask the backend to reconcile [mint]'s artwork-membership tables right
  /// after an edit-collection-artworks tx lands. The async webhook indexer
  /// that otherwise updates them lags (on devnet often never fires), and the
  /// collection screen refetches on return — without this the edit looks like
  /// it failed. Mirrors the reference web client, which POSTs only the collection mint.
  Future<void> reindexCollectionArtworks(String mint) async {
    await _api.updateCollectionArtworks({'mintAccount': mint});
  }

  // --- Edit profile ---

  /// Check whether [username] is available to claim. Returns `true` when free.
  Future<bool> isUsernameAvailable(String username) async {
    final response = await _api.checkUsername(username);
    return response.result;
  }

  /// Update the logged-in user's profile and return the fresh user + details.
  ///
  /// Only non-null fields are sent (the backend treats omitted fields as
  /// unchanged). Pass [clearEmail] to detach the current email. Email itself
  /// is attached only through the OTP flow, never here.
  ///
  /// [pfp] and [banner] go straight to S3 through [ProfileImageUploader]
  /// first; only the resulting storage paths ride along with the profile
  /// write, which the backend turns back into CDN URLs. An image that fails to
  /// upload aborts the whole save rather than committing the text fields
  /// against a picture that isn't there.
  Future<api.UserWithDetailsResult> updateProfile({
    String? username,
    String? displayName,
    String? bio,
    String? website,
    bool? marketingUpdates,
    bool? disableEmailNotifications,
    bool clearEmail = false,
    ({Uint8List bytes, String fileName})? pfp,
    ({Uint8List bytes, String fileName})? banner,
  }) async {
    final fields = <String, dynamic>{};
    if (username != null) fields['username'] = username;
    if (displayName != null) fields['displayName'] = displayName;
    if (bio != null) fields['bio'] = bio;
    if (website != null) fields['website'] = website;
    if (marketingUpdates != null) fields['marketingUpdates'] = marketingUpdates;
    if (disableEmailNotifications != null) {
      fields['disableEmailNotifications'] = disableEmailNotifications;
    }
    // The backend only clears the email when it is explicitly present and null.
    if (clearEmail) fields['email'] = null;

    final body = <String, dynamic>{'user': fields};
    // Absent, never null — the backend's `pfpPath`/`bannerPath` are
    // `z.string().optional()`, which rejects an explicit null with a 400.
    if (pfp != null) {
      body['pfpPath'] = await _uploader.upload(
        bytes: pfp.bytes,
        fileName: pfp.fileName,
        type: api.CreateProfileUploadRequestType.pfp,
      );
    }
    if (banner != null) {
      body['bannerPath'] = await _uploader.upload(
        bytes: banner.bytes,
        fileName: banner.fileName,
        type: api.CreateProfileUploadRequestType.banner,
      );
    }

    final response = await _api.updateProfile(body);
    return response.result;
  }

  /// Push the signed-in user's active-network preference to the backend.
  ///
  /// [disabledChains] is the full set of chain wire-ids the user has switched
  /// off (e.g. `['tezos']`); Solana can never be disabled. Only meaningful in
  /// a Profile (signed-login) session. Returns the fresh user + details.
  Future<api.UserWithDetailsResult> updateSettings(
    List<String> disabledChains,
  ) async {
    final response = await _api.updateSettings({
      'disabledChains': disabledChains,
    });
    return response.result;
  }

  /// Push the signed-in user's NSFW visibility to their profile.
  ///
  /// Only meaningful in a Profile (signed-login) session. Returns the value
  /// the backend persisted; throws when the account's NSFW setting is locked
  /// by moderation (`disableNsfwSetting` → 400).
  Future<bool> setShowNsfw(bool value) async {
    final response = await _api.setShowNsfw(api.ShowNsfwRequest(value: value));
    return response.result;
  }

  /// Send a verification OTP to [email]. Requires a logged-in session.
  Future<void> sendEmailOtp(String email) async {
    await _api.createOtp(api.CreateOtpRequest(email: email));
  }

  /// Confirm an email OTP [code]. On success the email is attached server-side.
  Future<void> verifyEmailOtp(String code) async {
    await _api.verifyOtp(api.VerifyOtpRequest(code: code));
  }

  /// Get the X (Twitter) OAuth authorize URL. Requires a signed login.
  /// Served by the `/v2` connect flow (mobile-ready app-link callback).
  Future<String> getTwitterAuthUrl() async {
    final response = await _apiV2.getTwitterAuthUrl();
    return response.result;
  }

  /// Disconnect the linked X (Twitter) account. Requires a signed login.
  Future<void> disconnectTwitter() async {
    await _apiV2.disconnectTwitter();
  }

  /// Follow a user by address (requires authenticated session).
  Future<void> followUser(String address) async {
    await _api.follow({'address': address});
  }

  /// Unfollow a user by address (requires authenticated session).
  Future<void> unfollowUser(String address) async {
    await _api.unfollow({'address': address});
  }

  /// Bulk follow users in one request per 100 addresses (the backend cap
  /// for POST /v0/followAll).
  Future<void> followAllUsers(List<String> addresses) async {
    const maxPerRequest = 100;
    for (var i = 0; i < addresses.length; i += maxPerRequest) {
      final end = i + maxPerRequest < addresses.length
          ? i + maxPerRequest
          : addresses.length;
      await _api.followAll({'addresses': addresses.sublist(i, end)});
    }
  }

  /// Fetch a page of users following the profile (newest first).
  Future<FollowListResult> getFollowers(
    List<String> addresses, {
    int page = 0,
  }) async {
    final response = await _api.getFollowers(
      api.FollowListRequest(page: page, profileUserAddresses: addresses),
    );
    return _parseFollowList(response);
  }

  /// Fetch a page of users the profile follows (newest first).
  Future<FollowListResult> getFollowing(
    List<String> addresses, {
    int page = 0,
  }) async {
    final response = await _api.getFollowing(
      api.FollowListRequest(page: page, profileUserAddresses: addresses),
    );
    return _parseFollowList(response);
  }

  FollowListResult _parseFollowList(api.FollowListResponse response) {
    final users = response.result
        .map((json) {
          try {
            return api.FollowUser.fromJson(json);
          } catch (_) {
            return null;
          }
        })
        .whereType<api.FollowUser>()
        .toList();
    return FollowListResult(
      users: users,
      total: response.total,
      nextPage: response.nextPage,
    );
  }

  /// Ask the indexer to re-pull on-chain metadata for a collection mint.
  Future<void> syncCollection(String mintAccount) async {
    await _api.updateCollectionMetadata({'mintAccount': mintAccount});
  }

  /// Hide a collection (or any mint) from the current user's feeds.
  Future<void> hideMint(String mintAccount) async {
    await _api.hideMint({'mintAccount': mintAccount});
  }

  /// Reverse of [hideMint].
  Future<void> unhideMint(String mintAccount) async {
    await _api.unhideMint({'mintAccount': mintAccount});
  }

  /// Detailed holders list for a collection. Used by the export-holders
  /// flow on the collection screen.
  Future<List<api.HolderEntry>> getDetailedHolders(
    String collectionSlug,
  ) async {
    final response = await _api.getDetailedHolders(
      api.DetailedHoldersRequest(collectionKey: collectionSlug),
    );
    return response.result;
  }

  /// Map API [User] + [UserDetails] to UI [UserProfile].
  UserProfile _mapToUserProfile(
    String address,
    api.User user,
    api.UserDetails? details,
  ) {
    final instagramUsername = details?.instagram?.username;
    return UserProfile(
      address: address,
      username: user.username ?? user.displayName ?? '',
      handle: user.username ?? '',
      displayName: user.displayName,
      role: '', // Determined in BLoC from roles + context
      roles: user.roles,
      bio: details?.bio ?? '',
      avatarUrl: user.imageUrl ?? '',
      followerCount: user.followerCount,
      followingCount: user.followingCount,
      collectorCount: details?.collectorsCount ?? 0,
      ownedArtworkCount: 0,
      createdArtworkCount: details?.createdCount ?? 0,
      collectedArtworkCount: details?.collectedCount ?? 0,
      bannerUrl: user.bannerUrl,
      isVerified: user.isTwitterVerified,
      twitterUrl: details?.twitter?.username != null
          ? 'https://twitter.com/${details!.twitter!.username}'
          : null,
      instagramUrl: instagramUsername != null
          ? 'https://instagram.com/$instagramUsername'
          : null,
      websiteUrl: details?.website,
      linkedAddresses: user.addresses,
    );
  }
}

/// Result from fetching a page of followers or following.
class FollowListResult {
  const FollowListResult({
    required this.users,
    required this.total,
    this.nextPage,
  });

  final List<api.FollowUser> users;
  final int total;
  final int? nextPage;
}

/// Result from fetching profile artworks.
class ProfileArtworksResult {
  const ProfileArtworksResult({
    required this.artworks,
    required this.total,
    this.nextPage,
  });

  final List<PortfolioArtwork> artworks;
  final int total;
  final int? nextPage;
}
