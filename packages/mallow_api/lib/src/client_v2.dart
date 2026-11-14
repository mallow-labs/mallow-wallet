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
/// Transaction builders normally wrap their payload in the standard
/// `{ result }` envelope ([ApiResponse]). [buyEditionTx] is the exception:
/// its optional setup transaction is a sibling of the result array.
@RestApi()
abstract class MallowApiV2Client {
  factory MallowApiV2Client(Dio dio, {String baseUrl, ParseErrorLogger? errorLogger}) =
      _MallowApiV2Client;

  @GET('/magic-eden/quote')
  Future<ApiResponse<MagicEdenBuyQuoteResponse>> quoteMagicEdenBuy(
    @Query('mintAccount') String mintAccount,
    @Query('buyer') String buyer,
  );

  @POST('/tx/magic-eden/buy')
  Future<ApiResponse<MagicEdenBuyTxResponse>> buyMagicEdenTx(@Body() MagicEdenBuyTxRequest request);

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
  ///
  /// A compressed NFT's edit can need an address lookup table that does not
  /// exist yet, in which case the response carries
  /// [UnsignedTxWithSetupResponse.setupTx] — sign and confirm it *before*
  /// broadcasting `tx`, which is compiled against the table it creates.
  @POST('/tx/nft/edit')
  Future<ApiResponse<UnsignedTxWithSetupResponse>> editNftTx(@Body() EditNftV2Request request);

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
  ///
  /// Exactly one of [BuyFixedPriceTxResponse.tx] and
  /// [BuyFixedPriceTxResponse.swapTx] is present: `swapTx` means the Jupiter
  /// swap has to land on its own first, after which the caller re-requests
  /// without a quote. A compressed NFT's purchase can additionally carry
  /// [BuyFixedPriceTxResponse.setupTx] — an address-lookup-table transaction
  /// to sign and confirm before `tx`.
  @POST('/tx/fixed-price/buy')
  Future<ApiResponse<BuyFixedPriceTxResponse>> buyFixedPriceTx(
    @Body() BuyFixedPriceTxRequest request,
  );

  /// Build unsigned "buy now" transactions for `quantity` prints of a master
  /// edition — one partial-signed tx per print. Replaces v1
  /// `POST /v1/artwork/getBuyEditionTxs`; each [BuyEditionTxItem] carries the
  /// ephemeral print-mint key the tx is signed with.
  ///
  /// On-chain whitelist phases ARE supported: the backend derives the
  /// listing's `walletsRoot` itself and, when the buyer's `proofs` PDA is
  /// missing, returns [BuyEditionTxsResponse.setupTx] — an `initProofs`
  /// transaction the caller must confirm *before* broadcasting `result`.
  /// Off-chain Merkle denial still yields a `400` ("User is not whitelisted"),
  /// which is why the caller keeps the v1 fallback. A non-native currency is
  /// NOT deferred: with no swap quote the buy simply settles in the listing's
  /// own currency.
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

  /// Average time between Solana slots, measured by the backend from the
  /// RPC's performance samples at most once a day. Turns a blockhash's
  /// remaining blocks into seconds for the transaction-review countdown.
  @GET('/solana/slot-time')
  Future<ApiResponse<SolanaSlotTime>> getSolanaSlotTime();

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

  /// Read the bidder's available currency refunds.
  @GET('/auctions/bid-refunds/{bidder}')
  Future<ApiResponse<BidRefundsResponse>> getBidRefunds(@Path('bidder') String bidder);

  /// Read the refund claims whose account deposits this wallet paid.
  @GET('/auctions/bid-refund-claims/{rentPayer}')
  Future<ApiResponse<BidRefundClaimsResponse>> getBidRefundClaims(
    @Path('rentPayer') String rentPayer,
  );

  /// Build an unsigned bid-refund withdrawal transaction.
  @POST('/tx/auctions/withdraw-bid-refund')
  Future<ApiResponse<UnsignedTxResponse>> withdrawBidRefundTx(
    @Body() WithdrawBidRefundTxRequest request,
  );

  /// Build an unsigned transaction releasing a SOL refund to its recorded bidder.
  @POST('/tx/auctions/push-sol-bid-refund')
  Future<ApiResponse<UnsignedTxResponse>> pushSolBidRefundTx(
    @Body() PushSolBidRefundTxRequest request,
  );

  /// Release a token refund to a bidder-owned account without their signature.
  @POST('/tx/auctions/push-bid-refund')
  Future<ApiResponse<UnsignedTxResponse>> pushBidRefundTx(
    @Body(nullToAbsent: true) PushBidRefundTxRequest request,
  );

  /// Build an unsigned transaction returning an empty claim's deposit to its payer.
  @POST('/tx/auctions/close-bid-refund-claim')
  Future<ApiResponse<UnsignedTxResponse>> closeBidRefundClaimTx(
    @Body() CloseBidRefundClaimTxRequest request,
  );

  /// Build an unsigned cancel-offer transaction.
  @POST('/tx/offers/cancel')
  Future<ApiResponse<UnsignedTxResponse>> cancelOfferTx(@Body() CancelOfferTxRequest request);

  /// Build an unsigned seller-signed accept-offer transaction. The seller is
  /// verified server-side as the asset owner; the body carries the offer's
  /// buyer. A mallow listing on the asset is delisted in the same tx.
  ///
  /// A compressed NFT's accept can need an address lookup table that does not
  /// exist yet — see [UnsignedTxWithSetupResponse.setupTx], which must be
  /// signed and confirmed before `tx`.
  @POST('/tx/offers/accept')
  Future<ApiResponse<UnsignedTxWithSetupResponse>> acceptOfferTx(
    @Body() AcceptOfferTxRequest request,
  );

  // ── Fixed-price (listing) tx-builders ────────────────────────────────

  /// Build an unsigned listing transaction. The response can also carry a
  /// [CreateFixedPriceTxResponse.setupTx] (the LUT-bootstrap tx for non-Core
  /// master editions), which the caller must sign first.
  ///
  /// Non-native currency listings go through this route unchanged — the
  /// handler threads `currencyMint` into the listing ix and defaults to SOL
  /// when it is omitted. Only an unregistered mint is refused, with a
  /// `BadRequest` ("Unsupported currency mint: …").
  @POST('/tx/fixed-price/create')
  Future<ApiResponse<CreateFixedPriceTxResponse>> createFixedPriceTx(
    @Body() CreateFixedPriceTxRequest request,
  );

  /// Build an unsigned cancel-listing transaction. A compressed NFT's delist
  /// can carry [UnsignedTxWithSetupResponse.setupTx] — sign and confirm it
  /// before `tx`.
  @POST('/tx/fixed-price/cancel')
  Future<ApiResponse<UnsignedTxWithSetupResponse>> cancelFixedPriceTx(
    @Body() CancelFixedPriceTxRequest request,
  );

  /// Build an unsigned price-only update-listing transaction.
  @POST('/tx/fixed-price/update')
  Future<ApiResponse<UnsignedTxResponse>> updateFixedPriceTx(
    @Body() UpdateFixedPriceTxRequest request,
  );

  // ── Auction tx-builders ──────────────────────────────────────────────

  /// Build an unsigned create-auction transaction. 1/1-only (parity with v1).
  ///
  /// A compressed NFT's auction can carry
  /// [UnsignedTxWithSetupResponse.setupTx] — the lookup table the eventual
  /// settle is compiled against. Sign and confirm it before `tx`.
  @POST('/tx/auctions/create')
  Future<ApiResponse<UnsignedTxWithSetupResponse>> createAuctionTx(
    @Body() CreateAuctionTxRequest request,
  );

  /// Build an unsigned cancel-auction (also reclaim-no-bids) transaction. A
  /// compressed NFT's cancel can carry [UnsignedTxWithSetupResponse.setupTx] —
  /// sign and confirm it before `tx`.
  @POST('/tx/auctions/cancel')
  Future<ApiResponse<UnsignedTxWithSetupResponse>> cancelAuctionTx(
    @Body() CancelAuctionTxRequest request,
  );

  /// Build an unsigned settle-auction transaction (covers both
  /// seller-payout and winner-NFT-transfer).
  ///
  /// Non-native bid mints settle on this route — the handler shapes the
  /// payout accounts from the auction's own `bidMint`, native or SPL, and
  /// never checks it.
  ///
  /// A compressed NFT's settle can carry
  /// [UnsignedTxWithSetupResponse.setupTx] — sign and confirm it before `tx`.
  @POST('/tx/auctions/settle')
  Future<ApiResponse<UnsignedTxWithSetupResponse>> settleAuctionTx(
    @Body() SettleAuctionTxRequest request,
  );

  /// Build an unsigned bid transaction. Takes an explicit [BidTxRequest.bidder].
  ///
  /// Non-native bid mints ride this route too — the handler derives the
  /// currency accounts from the auction's `bidMint`. Off-chain-whitelisted
  /// auctions are enforced here, not deferred: a bidder outside the allowlist
  /// gets a final `BadRequest` ("User is not allowlisted").
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
  /// `POST`: the `GET` form could be triggered cross-site.
  @POST('/twitter/disconnect')
  Future<void> disconnectTwitter();

  /// Finish an X (Twitter) connect. Requires a signed login.
  ///
  /// The callback does not link the account. It redirects to the
  /// `?twitter=confirm&token=…` app link, and this call, with
  /// `{"token": <that token>}`, links it — only for the wallet that started
  /// the flow. `200` carries `{"result": {"username": …}}`; `403` means another
  /// wallet started it, `400` that the token is unknown or expired, `409` that
  /// the X account is on another profile. The token is spent on every outcome.
  @POST('/twitter/complete')
  Future<ApiResponse<TwitterCompleteResponse>> completeTwitterConnect(
    @Body() Map<String, dynamic> body,
  );

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

  /// Ask the backend to refresh the tokens a landed transaction delivered to
  /// [PortfolioReceivedRequest.address]. The backend verifies the transaction
  /// against the chain's indexer, so a purchase reaches the portfolio reads
  /// above in seconds instead of at the next login import. `pending` means
  /// the indexer has not seen the transaction yet.
  @POST('/portfolio/received')
  Future<ApiResponse<PortfolioReceivedResult>> postPortfolioReceived(
    @Body() PortfolioReceivedRequest request,
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
  ///
  /// Returns the raw response beside the parsed one. The parsed model holds
  /// each disabled flow as an enum generated from the vendored contract, which
  /// cannot hold a flow newer than that contract; a caller that must match
  /// every cell reads the wire strings from the raw body.
  @GET('/config/mobile')
  Future<HttpResponse<ApiResponse<MobileConfigResponse>>> getMobileConfig();

  // --- Account deletion ---

  /// Delete (anonymize) the logged-in user's mallow profile. Authenticated by
  /// the `login-token` cookie only — there is no body and no address
  /// parameter, so the caller must be logged in as the account being deleted.
  ///
  /// Scope is the **profile document**: username, display name, bio, avatar,
  /// banner, website, Twitter link and roles are cleared. One role is kept: a
  /// marketplace restriction placed on the account, which deleting the profile
  /// must not lift. Wallets, artworks, curations, listings, offers and on-chain
  /// history are untouched and stay indexed against the raw address. Not
  /// reversible.
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
  ///
  /// Requires a login. [requireProof] (always sent by this app) makes a login
  /// without a valid `wallet-sig` a `401` "Signature required" / "Signature
  /// expired", the refusal re-sign handling acts on. Without it the backend
  /// answers that login with an empty list, for builds that predate it.
  ///
  /// [extras] go on the Dio request's `extra` map, for the app's interceptors
  /// to read (a background load uses it to opt out of re-signing on a 401).
  @GET('/blocks')
  Future<ApiResponse<List<BlockedAccount>>> getBlockedAccounts({
    @Query('requireProof') bool requireProof = true,
    @Extras() Map<String, dynamic> extras = const {},
  });

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

  // --- Social vault ---
  //
  // The encrypted store behind Google and Apple sign-in. The backend holds
  // ciphertext, wrapped data keys and a vault public key, never a secret it
  // can open. These routes carry no login: `open` and `create` are
  // authenticated by the provider's ID token, the writes by a vault-key
  // signature.

  /// Verify a Google or Apple ID token and return its vault, or a null
  /// `vault` when the identity has none. The returned `identityToken` is what
  /// [createSocialVault] takes. `401` (`invalid_id_token`) when the token is
  /// invalid, expired or already used: ID tokens are accepted once.
  ///
  /// Returns the raw response beside the parsed one. The parsed model reads a
  /// missing `vault` field as null, and "no vault" is an answer a caller acts
  /// on (it offers to create a wallet), so the caller checks the raw body for
  /// an explicit `vault` before it believes a null.
  @POST('/social-vault/open')
  Future<HttpResponse<ApiResponse<SocialVaultOpenResponse>>> openSocialVault(
    @Body() SocialVaultOpenRequest request,
  );

  /// Create the identity's only vault. `409` (`vault_exists`) when another
  /// device won a first-sign-in race; the caller opens that vault instead.
  @POST('/social-vault/create')
  Future<ApiResponse<SocialVault>> createSocialVault(@Body() SocialVaultCreateRequest request);

  /// Add a slot. [signature] and [timestamp] are the vault-key signature over
  /// the request message, which covers the SHA-256 of the exact JSON body —
  /// so the caller signs `jsonEncode(request.toJson())`, the bytes this
  /// method sends. `409` carries the current vault ([SocialVaultConflict]).
  @POST('/social-vault/slots/add')
  Future<ApiResponse<SocialVault>> addSocialVaultSlot(
    @Body() SocialVaultAddSlotRequest request, {
    @Header('x-vault-signature') required String signature,
    @Header('x-vault-timestamp') required String timestamp,
  });

  /// Remove a slot. The last live slot cannot be removed (`400`,
  /// `last_slot`). Signed like [addSocialVaultSlot].
  @POST('/social-vault/slots/remove')
  Future<ApiResponse<SocialVault>> removeSocialVaultSlot(
    @Body() SocialVaultRemoveSlotRequest request, {
    @Header('x-vault-signature') required String signature,
    @Header('x-vault-timestamp') required String timestamp,
  });

  /// Replace a live slot's display label; an empty label clears it. Only the
  /// label changes. Signed like [addSocialVaultSlot].
  @POST('/social-vault/slots/rename')
  Future<ApiResponse<SocialVault>> renameSocialVaultSlot(
    @Body() SocialVaultRenameSlotRequest request, {
    @Header('x-vault-signature') required String signature,
    @Header('x-vault-timestamp') required String timestamp,
  });

  /// Replace the vault's payload ciphertext, vault key and whole live slot
  /// set in one write, at revision + 1. Signed by the CURRENT vault key like
  /// [addSocialVaultSlot]; every slot id must be new to the vault.
  @POST('/social-vault/rotate')
  Future<ApiResponse<SocialVault>> rotateSocialVault(
    @Body() SocialVaultRotateRequest request, {
    @Header('x-vault-signature') required String signature,
    @Header('x-vault-timestamp') required String timestamp,
  });

  /// Delete the vault and its slots (`204`). Signed like
  /// [addSocialVaultSlot].
  @POST('/social-vault/delete')
  Future<void> deleteSocialVault(
    @Body() SocialVaultDeleteRequest request, {
    @Header('x-vault-signature') required String signature,
    @Header('x-vault-timestamp') required String timestamp,
  });

  /// Read the current vault without a new sign-in: a signed read. Signed like
  /// [addSocialVaultSlot], over the caller's last known revision, which the
  /// backend does not compare — so this never answers `409`. `404` when the
  /// vault is gone.
  @POST('/social-vault/status')
  Future<ApiResponse<SocialVault>> socialVaultStatus(
    @Body() SocialVaultStatusRequest request, {
    @Header('x-vault-signature') required String signature,
    @Header('x-vault-timestamp') required String timestamp,
  });

  /// Cancel a pending deletion request (one not signed by the vault key) and
  /// record that a holder of the vault key refused it. Signed like
  /// [addSocialVaultSlot]; succeeds when there is no pending request.
  @POST('/social-vault/deletion/cancel')
  Future<ApiResponse<SocialVault>> cancelSocialVaultDeletion(
    @Body() SocialVaultCancelDeletionRequest request, {
    @Header('x-vault-signature') required String signature,
    @Header('x-vault-timestamp') required String timestamp,
  });
}
