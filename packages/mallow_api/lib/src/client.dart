import 'package:dio/dio.dart';
import 'package:retrofit/retrofit.dart';

import 'models/api_response.dart';
import 'models/artwork.dart';
import 'models/auth_token.dart';
import 'models/bulk_user_lookup.dart';
import 'models/collection.dart';
import 'models/create_asset.dart';
import 'models/curation.dart';
import 'models/explore.dart';
import 'models/holders.dart';
import 'models/home.dart';
import 'models/listing.dart';
import 'models/listing_data.dart';
import 'generated/openapi.models.swagger.dart'
    show
        CreateProfileUploadRequest,
        CreateProfileUploadResponse,
        LoginBody,
        ShowNsfwRequest,
        ShowNsfwResponse,
        StakingGetClaimTxRequest,
        UpdateOwnerRequest;
import 'models/login.dart';
import 'models/market.dart';
import 'models/market_event.dart';
import 'models/offer.dart';
import 'models/whitelist.dart';
import 'models/notification.dart';
import 'models/prices.dart';
import 'models/profile.dart';
import 'models/search.dart';
import 'models/staking.dart';
import 'models/unlockable_content.dart';
import 'models/update_profile.dart';
import 'models/user.dart';

part 'client.g.dart';

/// mallow API client for interacting with the mallow marketplace.
///
/// Registered with [Config.apiBaseUrl], so the base URL is whatever the build
/// was configured with — see `docs/backend.md`.
@RestApi()
abstract class MallowApiClient {
  factory MallowApiClient(Dio dio, {String baseUrl, ParseErrorLogger? errorLogger}) =
      _MallowApiClient;

  // --- Home Feed ---

  /// Get home feed data (featured, curated, spotlight, creators).
  ///
  /// Public endpoint — no auth required.
  /// Server-side caches for 300s (Redis key: `home`).
  @GET('/home')
  Future<ApiResponse<HomeFeedResponse>> getHomeFeed();

  /// Get artists for the Discover section.
  @GET('/v1/mobile/home/discover')
  Future<ApiResponse<HomeDiscoverResponse>> getHomeDiscover();

  /// Get popular collections.
  @GET('/v1/mobile/home/popular-collections')
  Future<ApiResponse<HomePopularCollectionsResponse>> getHomePopularCollections();

  /// Get popular curations.
  @GET('/v1/mobile/home/popular-curations')
  Future<ApiResponse<HomePopularCurationsResponse>> getHomePopularCurations();

  // --- Auth ---

  /// Login with wallet address.
  @POST('/v0/login')
  Future<ApiResponse<LoginResult>> login(@Body() LoginBody request);

  // --- Artwork ---

  /// Get artwork details by mint account.
  @GET('/v1/artwork/byMint/{mintAccount}')
  Future<ApiResponse<ArtworkResult>> getArtworkByMint(@Path() String mintAccount);

  /// Listing-eligibility facts for [mint]: whether the artwork (or its
  /// creator) is flagged, and whether it has already had a verified sale.
  /// Same endpoint the webapp's list-artwork page gates on.
  ///
  /// Public endpoint — no auth required.
  @GET('/v0/listingData/{mint}')
  Future<ApiResponse<ListingData>> getListingData(@Path() String mint);

  /// Request the indexer to re-pull on-chain metadata for an artwork
  /// mint. Webapp "Sync token" action. Backend dedupes per mint for
  /// 5 minutes.
  @POST('/v1/artwork/updateMetadata')
  Future<void> updateArtworkMetadata(@Body() Map<String, dynamic> body);

  /// List NFTs owned by [owner] — covers both created and collected
  /// holdings, filtered against Helius DAS to drop burnt/transferred/frozen
  /// assets. Body filters (e.g. [SearchUserNftsRequest.nonPrintableOnly])
  /// scope what counts as "listable" for the caller's flow.
  @POST('/v1/artwork/byOwner/{owner}')
  Future<ArtworksByOwnerResponse> getArtworksByOwner(
    @Path() String owner,
    @Body() SearchUserNftsRequest request,
  );

  /// List NFTs whose on-chain `updateAuth` is [updateAuth] — the art the
  /// signer created (and still controls), regardless of who currently holds
  /// it. Unlike [getArtworksByOwner] this is the set that can actually be
  /// re-collectioned: the collection edit emits `UpdateV2`/verify with the
  /// signer as authority, so an asset the signer merely *owns* but didn't
  /// author reverts on-chain. Body filters ([SearchUserNftsRequest.masterOnly],
  /// [SearchUserNftsRequest.tokenStandards]) scope the result. Unpaginated —
  /// returns the full list.
  @POST('/v1/artwork/byUpdateAuth/{updateAuth}')
  Future<ArtworksByOwnerResponse> getArtworksByUpdateAuth(
    @Path() String updateAuth,
    @Body() SearchUserNftsRequest request,
  );

  /// Build one unsigned `buyEdition` transaction per copy being printed.
  /// Backend returns an array of `(mintAccount, tx)` pairs — one entry
  /// per edition, where `mintAccount` is the freshly-derived print mint.
  @POST('/v1/artwork/getBuyEditionTxs')
  Future<ApiResponse<List<BuyEditionTx>>> getBuyEditionTxs(@Body() GetBuyEditionTxsRequest request);

  @POST('/v1/artwork/getBidTx')
  Future<ApiResponse<BidTxResponse>> getBidTx(@Body() GetBidTxRequest request);

  /// Persist a rewards/physical description; the response `result` is the id
  /// that goes into the auction transaction's memo as `rewards:<id>`. The
  /// raw body is returned (`dynamic`) because the backend's `result` is a
  /// bare string rather than an object, which doesn't fit `ApiResponse<T>`'s
  /// generic `T.fromJson` contract.
  @POST('/v0/rewardsDescription')
  Future<dynamic> postRewardsDescription(@Body() PostRewardsDescriptionRequest request);

  // --- Marketplace Reads ---

  /// Returns the subset of [WhitelistEligibilityRequest.merkleRoots] that
  /// the supplied address is eligible for. Empty list = excluded from
  /// every phase. Requires an authenticated session (the route uses
  /// `isLoggedIn` middleware).
  @POST('/v0/whitelist/checkEligibility')
  Future<ApiResponse<List<String>>> checkWhitelistEligibility(
    @Body() WhitelistEligibilityRequest request,
  );

  /// Resolves an NFT the caller holds that satisfies a listing's holder-only
  /// token gate, or a null `result` when none qualifies (see
  /// [HolderOnlyMintResponse] — a listing with no holder gate is also null).
  ///
  /// This is the second half of a whitelist phase: the webapp ORs a non-null
  /// result with [checkWhitelistEligibility] to decide eligibility
  /// (`useWhitelistConfig`). The returned mint is also what the buy
  /// builder wants as `whitelistMint`.
  @POST('/v0/getHolderOnlyMint')
  Future<HolderOnlyMintResponse> getHolderOnlyMint(@Body() HolderOnlyMintRequest request);

  /// Marketplace event history for an artwork — listings, sales, bids,
  /// offers, claims. Mirrors the webapp's `useEventsByMint`.
  ///
  /// Returns the wire shape directly (not wrapped in `ApiResponse`) — see
  /// `events`.
  @POST('/v0/events/byMint/{mintAccount}')
  Future<MarketActivityEventsPage> getEventsByMint(
    @Path() String mintAccount,
    @Body() EventsByMintRequest request,
  );

  /// Paged offers list. Combine the [OfferFilter.buyer] + [OfferFilter.nftMint]
  /// + `activeOnly: true` to detect whether a connected wallet already has
  /// a live offer on a given mint (drives the
  /// "Make offer" ↔ "Cancel offer" toggle).
  @POST('/v1/offers')
  Future<OffersPage> getOffers(@Body() GetOffersRequest request);

  // --- Like / Unlike ---

  /// Like an artwork (requires authenticated session).
  @POST('/v0/like')
  Future<void> like(@Body() Map<String, dynamic> body);

  /// Unlike an artwork (requires authenticated session).
  @POST('/v0/unlike')
  Future<void> unlike(@Body() Map<String, dynamic> body);

  // --- Follow / Unfollow ---

  /// Follow a user (requires signed login).
  @POST('/v0/follow')
  Future<void> follow(@Body() Map<String, dynamic> body);

  /// Bulk follow users (requires signed login).
  /// Body: {'addresses': [...]} — max 100 per request.
  @POST('/v0/followAll')
  Future<void> followAll(@Body() Map<String, dynamic> body);

  /// Unfollow a user (requires signed login).
  @POST('/v0/unfollow')
  Future<void> unfollow(@Body() Map<String, dynamic> body);

  // --- User Profile ---

  /// Get public user info by address.
  @GET('/v1/user/{address}')
  Future<ApiResponse<UserPreview>> getUserByAddress(@Path() String address);

  /// Get user with full details (roles, follower counts, social accounts).
  @POST('/v0/userWithDetails')
  Future<ApiResponse<UserWithDetailsResult>> getUserWithDetails(
    @Body() UserWithDetailsRequest request,
  );

  /// Get profile content (artworks, collections, etc.) with pagination.
  ///
  /// Note: Returns ProfileResponse directly without ApiResponse wrapper.
  @POST('/v1/profile')
  Future<ProfileResponse> getProfile(@Body() ProfileRequest request);

  // --- Edit Profile ---

  /// Check whether a username is available.
  ///
  /// Public endpoint. Returns `true` when the username is free to claim.
  @GET('/v0/checkUsername')
  Future<ApiResponse<bool>> checkUsername(@Query('username') String username);

  /// Presign a direct-to-S3 upload of a profile image.
  ///
  /// Requires a signed login (wallet signature). Returns the S3 endpoint, the
  /// form fields that must precede the file part, and the `path` to hand back
  /// to [updateProfile] as `pfpPath` / `bannerPath`. The image itself never
  /// transits the API — see `ProfileImageUploader`, which owns the S3 leg.
  ///
  /// The key, the content type and the size ceiling are all conditions of the
  /// signed policy, so the backend rejects a mismatched [request] (non-image
  /// mime type, or `image/gif` without the gif-pfp perk) with a 400 and S3
  /// rejects a tampered-with form.
  @POST('/v1/user/createProfileUpload')
  Future<ApiResponse<CreateProfileUploadResponse>> createProfileUpload(
    @Body() CreateProfileUploadRequest request,
  );

  /// Update the logged-in user's profile.
  ///
  /// Requires a signed login (wallet signature). [body] is the
  /// `UpdateProfileRequest` envelope: the editable fields (username,
  /// displayName, bio, website, marketingUpdates, disableEmailNotifications)
  /// under `user`, plus the optional `pfpPath` / `bannerPath` returned by
  /// [createProfileUpload]. Returns the updated user and details.
  ///
  /// Sent as a raw map rather than the generated `UpdateProfileRequest`
  /// because the wire distinguishes absent from null on both levels: `user`
  /// must carry an explicit `email: null` to detach an address, while the
  /// backend's `pfpPath`/`bannerPath` are `z.string().optional()` — an
  /// explicit null is a 400. The generated `toJson` always emits both.
  @POST('/v1/user/updateProfile')
  Future<ApiResponse<UserWithDetailsResult>> updateProfile(@Body() Map<String, dynamic> body);

  /// Update the signed-in user's settings.
  ///
  /// Requires a signed login. [body] carries `disabledChains` — the full set
  /// of chain wire-ids (e.g. `['tezos']`) the user has switched off. Returns
  /// the updated user and details.
  @POST('/v1/user/updateSettings')
  Future<ApiResponse<UserWithDetailsResult>> updateSettings(@Body() Map<String, dynamic> body);

  /// Toggle the signed-in user's NSFW visibility.
  ///
  /// Requires a signed login. Returns the persisted value; the backend
  /// rejects the change with a 400 when the account's NSFW setting is locked
  /// by moderation (`User.disableNsfwSetting`).
  @POST('/v1/showNsfw')
  Future<ShowNsfwResponse> setShowNsfw(@Body() ShowNsfwRequest request);

  /// Send an email OTP. Requires a logged-in session.
  @POST('/v1/otp')
  Future<ApiResponse<bool>> createOtp(@Body() CreateOtpRequest request);

  /// Verify an email OTP. On success the email is attached to the account.
  @POST('/v1/otp/verify')
  Future<ApiResponse<bool>> verifyOtp(@Body() VerifyOtpRequest request);

  // --- Followers / Following ---

  /// Get followers for user addresses.
  @POST('/v1/followers')
  Future<FollowListResponse> getFollowers(@Body() FollowListRequest request);

  /// Get following for user addresses.
  @POST('/v1/following')
  Future<FollowListResponse> getFollowing(@Body() FollowListRequest request);

  // --- Curations ---

  /// List curations.
  ///
  /// With no [owner], returns the authenticated caller's own curations
  /// (private items included only when a valid signed-login session is
  /// present). Pass [owner] to list another user's `public`/`featured`
  /// curations by wallet address. Pass [mintAccount] to include a
  /// `containsArtwork` flag on each curation for that artwork.
  @GET('/v1/curations')
  Future<CurationListResponse> getCurations({
    @Query('mintAccount') String? mintAccount,
    @Query('owner') String? owner,
  });

  /// Fetch a single curation by id with its full artwork list.
  ///
  /// Anonymous callers can read public/featured curations. Owners with a
  /// valid signed-login session can also read their own private curations.
  /// Any other case returns 404.
  @GET('/v1/curations/{id}')
  Future<ApiResponse<CurationDetail>> getCurationById(@Path() String id);

  /// Create a new curation.
  @POST('/v1/curations')
  Future<ApiResponse<CurationItem>> createCuration(@Body() CreateCurationRequest request);

  /// Update a curation's name and/or visibility. New curations are created
  /// with `private` visibility server-side.
  @PATCH('/v1/curations/{id}')
  Future<void> patchCuration(@Path() String id, @Body() PatchCurationRequest request);

  /// Delete a curation. Owner-only.
  @DELETE('/v1/curations/{id}')
  Future<void> deleteCuration(@Path() String id);

  /// Add an artwork to a curation.
  @POST('/v1/curations/{id}/artworks')
  Future<void> addArtworkToCuration(@Path() String id, @Body() AddArtworkToCurationRequest request);

  /// Remove an artwork from a curation.
  @DELETE('/v1/curations/{id}/artworks/{mintAccount}')
  Future<void> removeArtworkFromCuration(@Path() String id, @Path() String mintAccount);

  // --- Signature-Based Auth ---

  /// Request an auth token for message signing.
  ///
  /// Returns a token string to be included in the signed message.
  @POST('/v0/authToken')
  Future<ApiResponse<String>> getAuthToken(@Body() AuthTokenRequest request);

  /// Verify a signed auth token.
  ///
  /// Returns expiry information on success.
  @POST('/v0/authToken/verify')
  Future<ApiResponse<AuthTokenVerifyResult>> verifyAuthToken(
    @Body() AuthTokenVerifyRequest request,
  );

  // --- Bulk User Lookup ---

  /// Bulk-lookup wallet addresses to find linked user profiles.
  ///
  /// Public endpoint — no auth required.
  /// Returns matched user profiles and any unlinked addresses.
  @POST('/v1/user/bulk')
  Future<BulkUserLookupResponse> bulkLookupUsers(@Body() BulkUserLookupRequest request);

  // --- Explore ---

  /// Explore artworks with filtering, sorting, and pagination.
  @POST('/v1/explore')
  Future<ExploreResponse> explore(@Body() ExploreRequest request);

  /// Explore gumball machines.
  @POST('/v1/gumball/explore')
  Future<ExploreResponse> exploreGumballs(@Body() GumballExploreRequest request);

  /// Explore jellybean machines.
  @POST('/v1/jellybean/explore')
  Future<ExploreResponse> exploreJellybeans(@Body() JellybeanExploreRequest request);

  /// Fetch a single exhibition by slug, including its artworks.
  @GET('/exhibitions/{slug}')
  Future<ExhibitionDetailResponse> getExhibition(@Path() String slug);

  /// Explore exhibitions.
  @POST('/exhibitions/explore')
  Future<ExploreResponse> exploreExhibitions(@Body() ExhibitionsExploreRequest request);

  // --- Search ---

  /// Search for users, artworks, and collections.
  ///
  /// Auth is optional.
  @POST('/v1/search')
  Future<ApiResponse<SearchResponse>> search(@Body() Map<String, dynamic> body);

  /// Search curations by name.
  @POST('/v1/search/curations')
  Future<ApiResponse<CurationSearchResponse>> searchCurations(@Body() Map<String, dynamic> body);

  /// Search users by username, display name, twitter handle, or exact address.
  ///
  /// Auth is optional. The backend strips a leading `@` itself and caps
  /// `pageSize` at 30.
  @POST('/v1/search/users')
  Future<ApiResponse<UserSearchResponse>> searchUsers(@Body() Map<String, dynamic> body);

  // --- Bug Report ---

  /// Submit a bug report.
  ///
  /// Auth is optional — picks up login cookie if present.
  @POST('/v1/bugReport')
  Future<void> submitBugReport(@Body() Map<String, dynamic> body);

  // --- Wallet Link / Unlink ---

  /// Link a new wallet address into the caller's profile.
  ///
  /// Requires dual JWT cookies set via authToken/verify:
  /// - wallet-sig-{newAddress} (the wallet being linked)
  /// - wallet-sig-{existingAddress} (an existing profile wallet)
  @POST('/v0/wallet/approveLinkRequestV2')
  Future<void> approveLinkRequestV2(@Body() ApproveLinkRequestV2Body body);

  /// Remove a wallet address from the caller's profile.
  ///
  /// Requires a valid isSignedLogin cookie.
  @POST('/v0/wallet/removeAddress')
  Future<void> removeAddress(@Body() RemoveAddressBody body);

  // --- Notifications ---

  /// Fetch notifications for the signed-in user.
  ///
  /// Returns up to 100 most recent notifications (descending by created date).
  /// Requires isSignedLogin.
  @GET('/v1/notifications')
  Future<NotificationsListResponse> getNotifications();

  /// Get the unread notification count for the current user.
  @GET('/v1/notifications/unread-count')
  Future<NotificationUnreadCountResponse> getNotificationUnreadCount();

  /// Mark all unread notifications as read.
  ///
  /// Requires isSignedLogin.
  @POST('/v1/notifications/acknowledge')
  Future<void> acknowledgeNotifications();

  // --- Create (NFT minting) ---

  /// Finalize a mint after the transaction has landed on-chain. Triggers
  /// server-side indexing so the new asset shows up in portfolio/feeds.
  @POST('/v1/create/finalize')
  Future<void> finalizeMint(@Query('type') String type, @Body() FinalizeMintRequest request);

  /// Finalize an edit after the transaction has landed on-chain. The v2 tx
  /// builder (`POST /v2/tx/nft/edit`) writes the upload record; finalization
  /// stays on v1, matching the webapp (`/v1/edit/finalize?type=editNft`).
  @POST('/v1/edit/finalize')
  Future<void> finalizeEditNft(@Query('type') String type, @Body() FinalizeMintRequest request);

  /// Ping the indexer to ack a newly-confirmed transaction. Returns
  /// `{}` once the tx is indexed/queued; `{ "result": "<reason>" }`
  /// while still pending. Used as a post-confirm gate so feature data
  /// refetches see the tx's effects. Mirrors the webapp's `checkTx`.
  ///
  /// Return type is `dynamic` because retrofit's generator mis-handles
  /// `Map<String, dynamic>` returns by trying to deserialize each value.
  /// The body is always a JSON object — callers cast to `Map`.
  @POST('/v0/checkTx')
  Future<dynamic> checkTx(@Body() Map<String, dynamic> body);

  /// Confirm the marketplace entry (listing/auction/etc.) produced by a
  /// transaction has been indexed. Unlike [checkTx] — which only acks that
  /// the *transaction* was processed — this gates on the derived
  /// marketplace entry landing in the index, so `/byMint` reflects the new
  /// listing. Returns `{}` once the entry is found; `{ "result": "<reason>" }`
  /// (404) while still pending. Mirrors the webapp's `checkEntry`.
  ///
  /// Return type is `dynamic` for the same retrofit reason as [checkTx].
  @POST('/v0/checkEntry')
  Future<dynamic> checkEntry(@Body() Map<String, dynamic> body);

  /// Force the indexer to re-read and persist the on-chain owner of a mint
  /// after a transfer. The backend re-fetches the owner and, if it resolves
  /// to a real (on-curve) wallet, writes it to the store and expires the
  /// cached artwork objects. Mirrors the webapp's post-transfer
  /// `POST /v1/artwork/updateOwner` (`the reference web client` `TransferNftModal`), which
  /// makes ownership flip immediately instead of waiting for the async
  /// ownership flush that `checkTx` merely queues. Solana-only.
  @POST('/v1/artwork/updateOwner')
  Future<void> updateOwner(@Body() UpdateOwnerRequest request);

  /// Request persistent IPFS pinning for a hash the client just uploaded
  /// to the configured IPFS pinning service. Fire-and-forget.
  @POST('/v1/ipfsPin')
  Future<void> pinIpfsHash(@Body() IpfsPinRequest request);

  /// Recent tags suggested for the create flow's tag input.
  @GET('/v1/create/recentTags')
  Future<ApiResponse<List<String>>> getRecentCreateTags();

  /// Protocol fees used for pre-mint cost breakdowns (values in SOL).
  @GET('/v0/txFees')
  Future<ApiResponse<TxFees>> getTxFees();

  /// Latest USD price per supported token, keyed by mint address. Values are
  /// stringified server-side to preserve full precision; the wrapper exposes
  /// them already parsed to `double`.
  @GET('/v0/getTokenPrices')
  Future<ApiResponse<TokenPricesResponse>> getTokenPrices();

  // --- Staking ---

  /// Global + per-user staking data (APYs, totals, the signed-in user's
  /// native/liquid position, current season, and the leaderboard). Mirrors
  /// the webapp `GET /v1/staking`. Auth is applied by the Dio interceptor;
  /// signed-out callers get zero-filled `userData`.
  @GET('/v1/staking')
  Future<ApiResponse<StakingDataResponse>> getStaking();

  /// Build the transaction that claims a finished season's SMORES rewards.
  /// They are airdropped ZK-compressed, so the returned v0 tx creates the
  /// caller's SMORES ATA (idempotent) and decompresses [request.amount] raw
  /// units into it. Mirrors the webapp `useClaimStakingRewards`.
  @POST('/v1/staking/getClaimTx')
  Future<ApiResponse<StakingClaimTxResponse>> getStakingClaimTx(
    @Body() StakingGetClaimTxRequest request,
  );

  /// List Core collections owned by [pubkey] for the collection picker.
  @GET('/v0/collections/byCreator/{pubkey}')
  Future<ApiResponse<List<CollectionPreviewRender>>> getCollectionsByCreator(
    @Path('pubkey') String pubkey, {
    @Query('page') int page = 0,
    @Query('tokenStandard') String? tokenStandard,
  });

  /// Get full collection detail (description, stats, creator, royalties,
  /// tags) keyed by collection mint. Mirrors the webapp's
  /// `/v0/collections/fullByMint/{mint}` endpoint.
  @GET('/v0/collections/fullByMint/{mint}')
  Future<ApiResponse<CollectionFullRender>> getCollectionByMint(@Path('mint') String mint);

  /// The mint accounts currently indexed as members of a collection. Mirrors
  /// the webapp's `GET /v0/collections/getMintAccounts/{mint}` — used to seed
  /// the pre-selected set when editing a collection's artworks. Keyed by MINT
  /// (not slug), so it resolves even before the collection's slug is indexed.
  /// Returns 404 when the collection isn't indexed yet.
  @GET('/v0/collections/getMintAccounts/{mint}')
  Future<ApiResponse<List<String>>> getCollectionMintAccounts(@Path('mint') String mint);

  /// Request the indexer to re-pull on-chain metadata for a collection
  /// mint. Webapp "Sync token" action.
  @POST('/v0/collections/updateMetadata')
  Future<void> updateCollectionMetadata(@Body() Map<String, dynamic> body);

  /// Ask the backend to reconcile a collection's artwork-membership tables
  /// after an edit-collection-artworks tx lands. Mirrors the webapp's
  /// `POST /v0/collections/updateArtworks`. Body: `{mintAccount}`. The async
  /// webhook indexer that otherwise updates membership lags (and on devnet
  /// often never fires), so callers hit this synchronously after a successful
  /// edit.
  @POST('/v0/collections/updateArtworks')
  Future<void> updateCollectionArtworks(@Body() Map<String, dynamic> body);

  /// Hide a mint account from the user's feeds. Webapp parity with
  /// `useHideContent`.
  @POST('/v0/hide')
  Future<void> hideMint(@Body() Map<String, dynamic> body);

  /// Reverse of [hideMint].
  @POST('/v0/unhide')
  Future<void> unhideMint(@Body() Map<String, dynamic> body);

  /// Detailed holders list (asset id + owner + edition number). Used by
  /// the Export holders flow.
  @POST('/v1/holders/detailed')
  Future<ApiResponse<List<HolderEntry>>> getDetailedHolders(@Body() DetailedHoldersRequest request);

  // --- Unlockable (exclusive) content ---

  /// List the current user's previously uploaded gated content.
  @GET('/v1/unlockableContent/myContent')
  Future<ApiResponse<List<UnlockableContentPreview>>> getMyUnlockableContent();

  /// Upload one piece of gated content. Returns the created content id(s) —
  /// the route answers with a bare array (`{result: [id]}`), so take the
  /// last element, as the webapp does.
  ///
  /// This is the **single-file** path of `POST /v1/unlockableContent/upload`
  /// (`unlockableContentHelper`). The
  /// route dispatches to it when neither `newAssetFilesCount` nor
  /// `existingAssetUrlsCount` is sent (`unlockableContent`).
  ///
  /// 🛑 [thumbnailFile] is **required by the server**, not optional to it:
  /// `invariant(thumbnailHash != null)` at `unlockableContentHelper`
  /// rejects the upload without one. It is nullable here only because the
  /// server also accepts a `thumbnailUrl` field instead; send exactly one.
  /// Caps: asset 500 MB, thumbnail 5 MB
  /// (`fileType`).
  ///
  /// The **multi-file** path cannot be expressed with retrofit annotations —
  /// it needs dynamic `assetFile_$i` / `fileName_$i` parts plus
  /// `newAssetFilesCount` / `existingAssetUrlsCount`
  /// (`unlockableContentHelper`). A bundle upload needs a
  /// hand-built `FormData` call, not this method.
  @POST('/v1/unlockableContent/upload')
  @MultiPart()
  Future<ApiResponse<List<int>>> uploadUnlockableContent(
    @Part(name: 'assetFile') MultipartFile assetFile, {
    @Part(name: 'thumbnailFile') MultipartFile? thumbnailFile,
    @Part(name: 'thumbnailUrl') String? thumbnailUrl,
    @Part(name: 'fileName') String? fileName,
  });
}
