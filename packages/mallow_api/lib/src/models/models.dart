// Models barrel export
export 'activity.dart';
export 'api_response.dart';
export 'api_user_ref.dart';
export 'artwork.dart';
export 'auth_token.dart';
export 'bulk_user_lookup.dart';
export 'collection.dart';
export 'create_asset.dart';
export 'curation.dart';
export 'edit_nft_v2.dart';
export 'explore.dart';
export 'holders.dart';
export 'home.dart';
export 'listing.dart';
export 'listing_data.dart';
export 'login.dart';
export 'market.dart';
export 'market_event.dart';
export 'live_market_state.dart';
export 'mint_nft_v2.dart';
export 'moderation.dart';
export 'offer.dart';
export 'offers_inbox.dart';
export 'whitelist.dart';
export 'notification.dart';
export 'prices.dart';
export 'profile.dart';
export 'raw_account_record.dart';
export 'search.dart';
export 'staking.dart';
export 'supply_type.dart';
export 'unlockable_content.dart';
export 'update_profile.dart';
export 'user.dart';

// Generated /v1/showNsfw request/response — the signed-login toggle for the
// user's NSFW visibility.
export '../generated/openapi.models.swagger.dart' show ShowNsfwRequest, ShowNsfwResponse;

// Generated /v1/artwork/updateOwner request — forces the backend to persist a
// mint's new on-chain owner after a transfer (see `MallowApiClient.updateOwner`).
export '../generated/openapi.models.swagger.dart' show UpdateOwnerRequest;

// Generated /v1/staking/getClaimTx request — season SMORES rewards claim. The
// response is hand-rolled in staking.dart (the spec types it inline).
export '../generated/openapi.models.swagger.dart' show StakingGetClaimTxRequest;

// Generated /v1/user/createProfileUpload request/response — the presigned
// direct-to-S3 POST that profile images go through instead of the API.
//
// The sibling `UpdateProfileRequest` is deliberately NOT exported: its
// generated `toJson` always emits `pfpPath`/`bannerPath`, and the backend
// declares them `z.string().optional()`, which rejects an explicit null. That
// body is built as a map — see `MallowApiClient.updateProfile`.
export '../generated/openapi.models.swagger.dart'
    show CreateProfileUploadRequest, CreateProfileUploadResponse;

// Generated v2 EVM balance + verified-token-list models (synced from
// the server's API contract). `EvmHolding` is the `/v2/evm/balances` (and
// reused `/v2/tezos/balances`) row; `EvmTokenListResponse`/`EvmTokenListEntry`
// are the `/v2/evm/token-list` verified-list payload. Parsed via their
// `.fromJson` factories in the portfolio EVM services so the response shape
// stays tied to the spec instead of hand-rolled map access.
export '../generated/openapi.models.swagger.dart'
    show EvmHolding, EvmTokenListResponse, EvmTokenListEntry;

// Generated v2 tx-builder request/response models (synced from
// the server's API contract). Used by `MallowApiV2Client` for all `/v2/tx`
// endpoints except mint/edit, whose discriminated-union bodies the generator
// can't represent faithfully.
export '../generated/openapi.models.swagger.dart'
    show
        BurnTxRequest,
        TransferTxRequest,
        BuyFixedPriceTxRequest,
        BuyEditionTxsRequest,
        BuyEditionTxItem,
        BuyEditionTxsResponse,
        CreateOfferTxRequest,
        CancelOfferTxRequest,
        AcceptOfferTxRequest,
        CreateFixedPriceTxRequest,
        CreateFixedPriceTxResponse,
        CancelFixedPriceTxRequest,
        UpdateFixedPriceTxRequest,
        CreateAuctionTxRequest,
        CancelAuctionTxRequest,
        SettleAuctionTxRequest,
        BidTxRequest,
        BuyTicketsTxRequest,
        CancelRaffleTxRequest,
        ClaimRafflePrizeTxRequest,
        ClaimRaffleProceedsTxRequest,
        EditCollectionArtworksRequest,
        EditCollectionArtworksResponse,
        UnsignedTxResponse,
        EvmUnsignedTx,
        TransferTxResponse;

// Generated v2 artwork-portfolio request + response models (synced from
// the server's API contract). Used by `MallowApiV2Client` for the
// `/v2/portfolio/*` reads. The shared `NftPreviewRender` (+ nested
// `NftPreview*` metadata/creator types) carries the full rich shape the
// portfolio renders. The group drilldown shares that shape:
// `PortfolioDrilldownResult.artworks` is a `List<NftPreviewRender>`, the same
// type the flat list returns.
export '../generated/openapi.models.swagger.dart'
    show
        PortfolioArtworksRequest,
        PortfolioArtworksRequest$PriceRange,
        PortfolioGroupsRequest,
        PortfolioArtworksResponse,
        NftPreviewRender,
        NftPreviewCreator,
        NftPreviewLastSale,
        NftPreviewAuctionMetadata,
        NftPreviewBuyNowMetadata,
        PortfolioGroupsResponse,
        PortfolioGroupsResult,
        PortfolioGroupSummary,
        PortfolioGroupDrilldownResponse,
        PortfolioDrilldownResult;

// Generated `/v2/config/mobile` models (the mobile kill-switch + force-upgrade
// payload). Parsed once, at `RemoteConfig.fromWire`, which folds `disabledFlows`
// into a keyed map. The generated `Chain` / `MobileFlow` enums are deliberately
// NOT re-exported: the barrel is imported unprefixed in a dozen files that also
// use the app-local `Chain` (`lib/shared/utils/chain.dart`), and exporting the
// generated one would make those imports ambiguous. The parse boundary reads
// `.value` (the wire string) off it instead, which is all it needs.
//
// `MobileFlow` has no such clash and is exported so the client's `AppFlow` can
// be drift-tested against the contract's cell list; app code uses `AppFlow`.
export '../generated/openapi.models.swagger.dart'
    show MobileConfigResponse, MobileConfigDisabledFlow;

// Generated moderation models — the block list row, the two write bodies, and
// the report taxonomy. `ReportContext` (the free-form `ReportRequest.context`
// blob) stays hand-written in `models/moderation.dart`; see the note there.
//
// The generated enums carry an extra `swaggerGeneratedUnknown` member for
// values the spec doesn't list. Never send it — app code must filter it out of
// `.values` before rendering a picker, and handle it in exhaustive switches.
export '../generated/openapi.models.swagger.dart' show BlockedAccount, BlockRequest, ReportRequest;

export '../generated/openapi.enums.swagger.dart'
    show
        CreateProfileUploadRequestType,
        MobileFlow,
        ReportTargetType,
        ReportReason,
        PortfolioArtworkSort,
        PortfolioGroupSort,
        PortfolioGroupsRequestGroupBy;
