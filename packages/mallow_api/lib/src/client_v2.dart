import 'package:dio/dio.dart';
import 'package:retrofit/retrofit.dart';

// The offers-inbox models stay hand-written: `models/offers_inbox.dart` carries
// an `nsfw` flag the spec does not define. Hide the generated twins to keep the
// names unambiguous.
import 'generated/openapi.models.swagger.dart' hide OffersInboxItem, OffersInboxPage;
import 'models/activity.dart';
import 'models/api_response.dart';
import 'models/edit_nft_v2.dart';
import 'models/home.dart';
import 'models/live_market_state.dart';
import 'models/mint_nft_v2.dart';
import 'models/offers_inbox.dart';
import 'models/raw_account_record.dart';

part 'client_v2.g.dart';

/// mallow API client for `/v2` routes. Registered with [Config.apiV2BaseUrl]
/// (which already includes the `/v2` path segment), so method paths here
/// omit the `/v2/` prefix — e.g. `/tx/assets/burn` resolves to
/// `<host>/v2/tx/assets/burn` on the wire.
///
/// Request and response bodies are the models generated from the vendored
/// OpenAPI contract (`openapi/openapi.yaml`, synced from
/// the server's API contract). Two endpoints — `mintNftTx` / `editNftTx` —
/// keep their hand-written request models ([MintNftV2Request] /
/// [EditNftV2Request]) because the mint body is an `allOf` + discriminated
/// union the swagger generator flattens lossily.
///
/// Every tx-builder wraps its payload in the standard `{ result }` envelope
/// ([ApiResponse]); callers read `.result.tx`.
@RestApi()
abstract class MallowApiV2Client {
  factory MallowApiV2Client(Dio dio, {String baseUrl, ParseErrorLogger? errorLogger}) =
      _MallowApiV2Client;

  /// Build an unsigned burn transaction. The backend branches on
  /// [BurnTxRequest.tokenStandard] (`mpl_token_metadata::BurnV1`
  /// for Nft/Pnft singles, `BurnEditionNft` for print editions,
  /// `mpl_core::BurnV1` / `BurnCollectionV1` for Core).
  @POST('/tx/assets/burn')
  Future<ApiResponse<UnsignedTxResponse>> getBurnTx(@Body() BurnTxRequest request);

  /// Build an unsigned transfer transaction. The backend branches on
  /// [TransferTxRequest.tokenStandard]: SPL transfer for `nft`,
  /// `mpl_token_metadata::TransferV1` (with auth-rules accounts) for `pnft`,
  /// `mpl_core::TransferV1` for `core`, and Bubblegum transfer for `cnft`
  /// (the backend resolves leaf data + the canopy-trimmed merkle proof via
  /// DAS, so the client passes only authority/asset/recipient).
  ///
  /// Legacy `nft` transfers are built client-side via
  /// `SolanaRpcService.buildSplTransferTx`; this route covers the
  /// non-legacy standards.
  ///
  /// EVM standards (`erc721`/`erc1155`) return `evm` calldata + tx params
  /// (`{to, data, value, gasLimit}`) instead of a base64 Solana `tx`; the
  /// client fills nonce + EIP-1559 fees, signs, and broadcasts.
  @POST('/tx/assets/transfer')
  Future<ApiResponse<TransferTxResponse>> getTransferTx(@Body() TransferTxRequest request);

  /// Build a mint transaction for a Core asset (1/1), Core master-edition
  /// (editions), or parent Core Collection. The `kind` discriminator in
  /// [MintNftV2Request] selects the flow.
  ///
  /// Uses the hand-written [MintNftV2Request] — the contract body is an
  /// `allOf` + `discriminatedUnion("kind")` the swagger generator can't
  /// faithfully represent (it drops the `kind`/`collection`/`maxSupply`/
  /// `groupSigner` variant fields).
  ///
  /// Finalization stays on v1 (`POST /v1/create/finalize?type=nft|collection`).
  @POST('/tx/nft/mint')
  Future<ApiResponse<UnsignedTxResponse>> mintNftTx(@Body() MintNftV2Request request);

  /// Build an edit-NFT transaction. Uses the hand-written [EditNftV2Request]
  /// so it can share the mint flow's metadata / collection / token-standard
  /// plumbing.
  ///
  /// Finalization stays on v1 (`POST /v1/edit/finalize?type=editNft`).
  @POST('/tx/nft/edit')
  Future<ApiResponse<UnsignedTxResponse>> editNftTx(@Body() EditNftV2Request request);

  /// Build the transaction(s) that add/remove members of a parent collection.
  /// The backend returns a batch ([EditCollectionArtworksResponse.txs]) — one
  /// tx per chunk of asset moves — each of which the authority signs and
  /// sends in order via [TransactionExecutor].
  ///
  /// Uses the generated [EditCollectionArtworksRequest] (a flat body the
  /// swagger generator represents faithfully). Membership edits don't run a v1
  /// finalize — the DAS indexer reconciles the moves.
  @POST('/tx/nft/edit-collection-artworks')
  Future<ApiResponse<EditCollectionArtworksResponse>> editCollectionArtworksTx(
    @Body() EditCollectionArtworksRequest request,
  );

  /// Build an unsigned fixed-price "buy now" transaction for a 1/1 listing.
  /// Handles both native SOL and SPL-token (e.g. USDC) listings.
  ///
  /// 1/1-only server-side — edition (multi-print) buys use [buyEditionTx].
  @POST('/tx/fixed-price/buy')
  Future<ApiResponse<UnsignedTxResponse>> buyFixedPriceTx(@Body() BuyFixedPriceTxRequest request);

  /// Build unsigned "buy now" transactions for `quantity` prints of a master
  /// edition — one partial-signed tx per print. Replaces v1
  /// `POST /v1/artwork/getBuyEditionTxs`; each [BuyEditionTxItem] carries the
  /// ephemeral print-mint key the tx is signed with.
  ///
  /// On-chain whitelist phases ARE supported: the backend derives the
  /// listing's `walletsRoot` itself and, when the buyer's `proofs` PDA is
  /// missing, returns [BuyEditionTxsResponse.setupTx] — an `initProofs`
  /// transaction the caller must confirm *before* broadcasting `result`.
  /// Off-chain Merkle denial still yields a `400`, and non-native currency
  /// without a swap quote is deferred, so the caller keeps the v1 fallback.
  ///
  /// Returns the raw envelope rather than [ApiResponse] because `setupTx` is a
  /// sibling of `result`, not a member of it — see [BuyEditionTxsResponse].
  @POST('/tx/fixed-price/buy-edition')
  Future<BuyEditionTxsResponse> buyEditionTx(@Body() BuyEditionTxsRequest request);

  // ── Marketplace state reads ──────────────────────────────────────────
  //
  // GET equivalents of the retired nodejs `POST /v1/marketplace/get*`
  // reads. These keep their hand-written response models (`AuctionLiveState`
  // etc.) — the models parse ISO timestamps to `DateTime` and carry field
  // defaults the generated response shapes can't express. Hard cutover —
  // no v1 fallback.

  /// Live `AuctionConfig` PDA snapshot. Polled while an auction is active
  /// so the countdown / "Highest bid by …" line stays current. Returns the
  /// `{ viewSlot, auction }` envelope (auction `null` when the account
  /// doesn't exist at the node's view — settled + closed, or never created);
  /// legacy backends return the bare `AuctionLiveState` fields / a `404`.
  /// Raw map so `AuctionLiveRepository` can unwrap either shape.
  @GET('/auctions/{mint}')
  Future<ApiResponse<RawAccountRecord?>> getAuctionState(@Path() String mint);

  /// Read a single decoded on-chain program account directly from the chain
  /// (server derives nothing — pass the account's own address/PDA). Returns
  /// `{ result: { viewSlot, account } }` where `account` is the flat
  /// `{ accountType, ...decodedFields, pubkey, program }` record the
  /// `/v2/ws/accounts` stream pushes (decodable with the same `AccountUpdate`
  /// parser), or `null` when no such account exists at the serving node's
  /// view. `viewSlot` is the RPC context slot the query was evaluated at —
  /// present for both outcomes, so an absence can be ordered against stream
  /// write-slots ("not found as of slot X" only outranks a frame written at
  /// slot W when `X >= W`). A `5xx`/transport error means existence is
  /// undetermined — never clear state on one. Legacy backends return the
  /// bare record / a `404` instead of the envelope; `MarketAccountRepository`
  /// handles both shapes.
  ///
  /// [program] is the kebab label (`market` | `auction`), [accountType] the
  /// kebab account name (`listing` | `auction-config`). u64 amounts in the
  /// record are decimal strings.
  @GET('/accounts/{program}/{accountType}/{address}')
  Future<ApiResponse<RawAccountRecord?>> getProgramAccount(
    @Path() String program,
    @Path() String accountType,
    @Path() String address,
  );

  /// DAS-derived edition state — `isPrintableMasterEdition` + live supply
  /// info. Drives the dispatcher's `BuyEditionSheet` ↔ `BuySheet` routing
  /// plus the live supply progress bar. Public (no auth).
  @GET('/editions/{mint}')
  Future<ApiResponse<EditionLiveState?>> getEditionState(@Path() String mint);

  /// `BuyEditionHistory` + `WhitelistConfig` PDAs in one round-trip —
  /// drives the edition wallet-cap / not-allowlisted gating. Takes the
  /// master-edition [mint] (the backend fetches the listing internally).
  @GET('/editions/{mint}/buyers/{buyer}')
  Future<ApiResponse<EditionPurchaseStats>> getEditionPurchaseStats(
    @Path() String mint,
    @Path() String buyer,
  );

  /// Live `Rafffle` PDA snapshot. Authoritative draw / claim state. Returns
  /// the `{ viewSlot, raffle }` envelope (raffle `null` when the account is
  /// gone at the node's view — cancelled or fully settled); legacy backends
  /// return the bare `RaffleLiveState` fields / `null`. Raw map so
  /// `RaffleRepository` can unwrap either shape.
  @GET('/raffles/{raffleKey}')
  Future<ApiResponse<RawAccountRecord?>> getRaffleState(@Path() String raffleKey);

  /// Aggregated active offers + auction bids the session is involved in —
  /// both received (on the viewer's art) and placed (by the viewer) — across
  /// every wallet in [GetOffersInboxRequest.owners]. Backs the Offers screen.
  @POST('/offers/inbox')
  Future<ApiResponse<OffersInboxPage>> getOffersInbox(@Body() GetOffersInboxRequest request);

  // ── Offer tx-builders ────────────────────────────────────────────────

  /// Build an unsigned "make offer" transaction. Handles native SOL and
  /// SPL-token (e.g. USDC) offers.
  @POST('/tx/offers/create')
  Future<ApiResponse<UnsignedTxResponse>> createOfferTx(@Body() CreateOfferTxRequest request);

  /// Build an unsigned cancel-offer transaction.
  @POST('/tx/offers/cancel')
  Future<ApiResponse<UnsignedTxResponse>> cancelOfferTx(@Body() CancelOfferTxRequest request);

  /// Build an unsigned seller-signed accept-offer transaction. The seller is
  /// verified server-side as the asset owner; the body carries the offer's
  /// buyer. A mallow listing on the asset is delisted in the same tx.
  @POST('/tx/offers/accept')
  Future<ApiResponse<UnsignedTxResponse>> acceptOfferTx(@Body() AcceptOfferTxRequest request);

  // ── Fixed-price (listing) tx-builders ────────────────────────────────

  /// Build an unsigned listing transaction. The response can also carry a
  /// [CreateFixedPriceTxResponse.setupTx] (the LUT-bootstrap tx for non-Core
  /// master editions), which the caller must sign first.
  ///
  /// Non-native currency listings are not yet ported to v2 — the backend
  /// rejects them with a `BadRequest` ("use v1").
  @POST('/tx/fixed-price/create')
  Future<ApiResponse<CreateFixedPriceTxResponse>> createFixedPriceTx(
    @Body() CreateFixedPriceTxRequest request,
  );

  /// Build an unsigned cancel-listing transaction.
  @POST('/tx/fixed-price/cancel')
  Future<ApiResponse<UnsignedTxResponse>> cancelFixedPriceTx(
    @Body() CancelFixedPriceTxRequest request,
  );

  /// Build an unsigned price-only update-listing transaction.
  @POST('/tx/fixed-price/update')
  Future<ApiResponse<UnsignedTxResponse>> updateFixedPriceTx(
    @Body() UpdateFixedPriceTxRequest request,
  );

  // ── Auction tx-builders ──────────────────────────────────────────────

  /// Build an unsigned create-auction transaction. 1/1-only (parity with v1).
  @POST('/tx/auctions/create')
  Future<ApiResponse<UnsignedTxResponse>> createAuctionTx(@Body() CreateAuctionTxRequest request);

  /// Build an unsigned cancel-auction (also reclaim-no-bids) transaction.
  @POST('/tx/auctions/cancel')
  Future<ApiResponse<UnsignedTxResponse>> cancelAuctionTx(@Body() CancelAuctionTxRequest request);

  /// Build an unsigned settle-auction transaction (covers both
  /// seller-payout and winner-NFT-transfer).
  ///
  /// Non-native bid mints are not yet ported to v2 — the backend rejects
  /// them with a `BadRequest` ("use v1").
  @POST('/tx/auctions/settle')
  Future<ApiResponse<UnsignedTxResponse>> settleAuctionTx(@Body() SettleAuctionTxRequest request);

  /// Build an unsigned bid transaction. Takes an explicit [BidTxRequest.bidder].
  ///
  /// Non-native bid mints and off-chain-whitelisted auctions are not yet
  /// ported to v2 — the backend rejects them with a `BadRequest` ("use v1").
  @POST('/tx/auctions/bid')
  Future<ApiResponse<UnsignedTxResponse>> bidTx(@Body() BidTxRequest request);

  // ── Raffle tx-builders ───────────────────────────────────────────────
  //
  // The only raffle tx-builders. The `/v1/raffle/*` routes these used to defer
  // holder-gated and pNFT-prize raffles to are gone, so a `400` here is final —
  // callers surface it instead of retrying elsewhere.

  /// Build an unsigned `buyTickets` transaction.
  @POST('/tx/raffles/buy-tickets')
  Future<ApiResponse<UnsignedTxResponse>> buyRaffleTicketsTx(@Body() BuyTicketsTxRequest request);

  /// Build an unsigned `cancelRaffle` transaction.
  @POST('/tx/raffles/cancel')
  Future<ApiResponse<UnsignedTxResponse>> cancelRaffleTx(@Body() CancelRaffleTxRequest request);

  /// Build an unsigned `claimPrize` transaction (winners + creators reclaiming
  /// after no-winner draws).
  @POST('/tx/raffles/claim-prize')
  Future<ApiResponse<UnsignedTxResponse>> claimRafflePrizeTx(
    @Body() ClaimRafflePrizeTxRequest request,
  );

  /// Build an unsigned `collectProceeds` transaction.
  @POST('/tx/raffles/claim-proceeds')
  Future<ApiResponse<UnsignedTxResponse>> claimRaffleProceedsTx(
    @Body() ClaimRaffleProceedsTxRequest request,
  );

  // --- X (Twitter) connect ---

  /// Get the X (Twitter) OAuth2 (PKCE) authorize URL to begin connecting an
  /// account. Requires a signed login. The backend mints a single-use state
  /// token (PKCE verifier + address cached server-side), so the round trip
  /// completes via the `/v2/twitter/callback` app-link redirect rather than a
  /// browser session — i.e. it is mobile-ready.
  @GET('/twitter/authenticate')
  Future<ApiResponse<String>> getTwitterAuthUrl();

  /// Disconnect the linked X (Twitter) account. Requires a signed login.
  @GET('/twitter/disconnect')
  Future<void> disconnectTwitter();

  // --- Artwork portfolio (aggregated across all session wallets) ---

  /// Flat owned-artworks list, aggregated server-side across every wallet in
  /// [PortfolioArtworksRequest.owners] (DAS-verified, globally paginated).
  /// Replaces the v1 single-owner `POST /v1/artwork/byOwner/:owner`.
  @POST('/portfolio/artworks')
  Future<PortfolioArtworksResponse> getPortfolioArtworks(@Body() PortfolioArtworksRequest request);

  /// Portfolio grouped by artist/collection/curation, aggregated across all
  /// session [PortfolioGroupsRequest.owners]. Replaces the v1 single-owner
  /// `POST /v1/mobile/portfolio/grouped`.
  @POST('/portfolio/groups')
  Future<PortfolioGroupsResponse> getPortfolioGroups(@Body() PortfolioGroupsRequest request);

  /// Drilldown of one group's artworks, aggregated across all session owners.
  /// Replaces the v1 single-owner `POST /v1/mobile/portfolio/group/:groupId`.
  @POST('/portfolio/groups/{groupId}')
  Future<PortfolioGroupDrilldownResponse> getPortfolioGroupArtworks(
    @Path('groupId') String groupId,
    @Body() PortfolioGroupsRequest request,
  );

  // --- Mobile feeds (public, multi-address) ---
  //
  // Ported from nodejs v1 /v1/mobile/*. Public — no auth. [addresses] is a
  // COMMA-JOINED list of the active session's wallet addresses (from
  // `SessionManager.sessionWallets`); the caller joins with `,`. The backend
  // splits on `,`, so callers must not pass a repeated-key list.

  /// Recommended curations for the mobile home screen. The backend unions each
  /// address's followed-set to personalise the "Recently Listed" curation; an
  /// empty [addresses] yields the non-personalised pool.
  @GET('/home/recommended')
  Future<ApiResponse<HomeRecommendedResponse>> getHomeRecommended({
    @Query('addresses') required String addresses,
  });

  /// Aggregated activity feed across every wallet in [addresses]. The backend
  /// routes each address by chain (Solana/EVM/Tezos), merges by time desc, and
  /// paginates. Returns [ActivityListResponse] directly (no [ApiResponse]).
  @GET('/activity')
  Future<ActivityListResponse> getActivities({
    @Query('addresses') required String addresses,
    @Query('page') int? page,
    @Query('limit') int? limit,
    @Query('types') String? types,
    @Query('before') String? before,
  });

  /// Mobile remote config — the per-`(chain, flow)` kill-switch plus the
  /// force-upgrade fields. `disabledFlows` is sparse (only currently disabled
  /// cells are listed), so an empty list and a failed fetch mean the same
  /// thing: everything is enabled. `updateRequired` is derived server-side
  /// from the `App-Version` header the Dio interceptor already sends.
  ///
  /// Public read — a missing config document or a datastore error still
  /// returns a permissive 200 rather than an error.
  @GET('/config/mobile')
  Future<ApiResponse<MobileConfigResponse>> getMobileConfig();

  // --- Account deletion ---

  /// Delete (anonymize) the logged-in user's mallow profile. Authenticated by
  /// the `login-token` cookie only — there is no body and no address
  /// parameter, so the caller must be logged in as the account being deleted.
  ///
  /// Scope is the **profile document**: username, display name, bio, avatar,
  /// banner, website, Twitter link and roles are cleared. Wallets, artworks,
  /// curations, listings, offers and on-chain history are untouched and stay
  /// indexed against the raw address. Not reversible.
  ///
  /// The backend also clears the `login-token` cookie on the response, so the
  /// caller must drop its own session state (see `AuthService.logout`) rather
  /// than continue against a profile that no longer exists.
  ///
  /// `401` when not logged in; `404` when there is no user document for the
  /// session address (already deleted, or never had a profile) — both surface
  /// as a [DioException] the caller reads `response?.statusCode` off.
  @POST('/user/delete')
  Future<void> deleteUser();

  // --- Moderation: blocking ---
  //
  // Blocking is a one-directional *view filter* for the logged-in user, keyed
  // by the `login-token` address. It is not mutual and cannot stop a blocked
  // account from transacting on-chain.

  /// Block an account. Idempotent — re-blocking an already-blocked address is
  /// a `200`. `400` when [BlockRequest.address] is the caller's own
  /// address (self-block).
  @POST('/blocks')
  Future<void> blockAddress(@Body() BlockRequest request);

  /// Unblock an account. Idempotent — `200` whether or not a block row
  /// existed. [address] may be passed in either casing; the backend applies
  /// the same canonicalisation as [blockAddress].
  @DELETE('/blocks/{address}')
  Future<void> unblockAddress(@Path() String address);

  /// The caller's blocked accounts, newest first, with enough profile data to
  /// render the Blocked Accounts settings screen. Backs the unblock flow.
  @GET('/blocks')
  Future<ApiResponse<List<BlockedAccount>>> getBlockedAccounts();

  // --- Moderation: reporting ---

  /// File a content report against an artwork, user or curation. Requires a
  /// signed login — every report is attributable to the caller.
  ///
  /// Deduped server-side on `(reporter, targetType, targetId)`: re-reporting
  /// the same target updates the existing row.
  ///
  /// **`429` is a soft failure.** The backend caps reports per reporter per
  /// day (20/day) and returns `429` over cap. The UI must still apply the
  /// local hide and still show the "we'll review this within 24 hours"
  /// confirmation — telling a rate-limited spammer how the limit works is the
  /// thing the cap exists to avoid. The status is reachable as
  /// `(e as DioException).response?.statusCode == 429`.
  @POST('/reports')
  Future<void> createReport(@Body() ReportRequest request);
}
