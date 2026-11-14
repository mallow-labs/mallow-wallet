// Models barrel export
export '../generated/openapi.models.swagger.dart'
    show
        MagicEdenBuyQuote,
        MagicEdenBuyQuoteResponse,
        MagicEdenBuyTxRequest,
        MagicEdenBuyTxResponse,
        $MagicEdenBuyQuoteExtension,
        $MagicEdenBuyQuoteResponseExtension,
        $MagicEdenBuyTxRequestExtension,
        $MagicEdenBuyTxResponseExtension;
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
        BuyFixedPriceTxResponse,
        BuyEditionTxsRequest,
        BuyEditionTxItem,
        BuyEditionTxsResponse,
        CreateOfferTxRequest,
        CancelOfferTxRequest,
        WithdrawBidRefundTxRequest,
        BidRefund,
        BidRefundsResponse,
        BidRefundClaim,
        BidRefundClaimsResponse,
        CloseBidRefundClaimTxRequest,
        PushSolBidRefundTxRequest,
        PushBidRefundTxRequest,
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
        UnsignedTxWithSetupResponse,
        EvmUnsignedTx,
        TransferTxResponse;

// Generated v2 artwork-portfolio request + response models (synced from
// the server's API contract). Used by `MallowApiV2Client` for the
// `/v2/portfolio/*` reads and the `/v2/portfolio/received` report. The shared `NftPreviewRender` (+ nested
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
        PortfolioDrilldownResult,
        PortfolioReceivedRequest,
        PortfolioReceivedResult;

// Generated `/v2/config/mobile` models (the mobile kill-switch + force-upgrade
// payload). Parsed once, at `RemoteConfig.fromWire`, which takes the
// force-upgrade fields from the model and folds `disabledFlows` into a keyed
// map from the raw JSON: the generated enums collapse every value they do not
// list into one valueless member, so a cell read through them could be lost.
// The generated `Chain` enum is deliberately NOT re-exported: the barrel is
// imported unprefixed in a dozen files that also use the app-local `Chain`
// (`lib/shared/utils/chain.dart`), and exporting the generated one would make
// those imports ambiguous.
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
        PortfolioGroupsRequestGroupBy,
        PortfolioReceivedChain,
        PortfolioReceivedStatus;

export '../generated/openapi.models.swagger.dart'
    show
        OpenSeaPurchaseQuote,
        OpenSeaPurchaseQuoteRequest,
        OpenSeaPurchasePrepareRequest,
        OpenSeaPurchasePrepareResponse,
        OpenSeaPurchasePrepareResponse$Result,
        OpenSeaPurchaseConfirmRequest,
        $OpenSeaPurchaseQuoteExtension,
        $OpenSeaPurchasePrepareResponse$ResultExtension;

// Generated social-vault models: the encrypted store behind Google and Apple
// sign-in. Every field is ciphertext, a wrapped key, a public key or a public
// identifier — no request or response here can carry a secret.
export '../generated/openapi.models.swagger.dart'
    show
        SocialVault,
        SocialVaultSlot,
        SocialVaultNewSlot,
        SocialVaultOpenRequest,
        SocialVaultOpenResponse,
        SocialVaultCreateRequest,
        SocialVaultAddSlotRequest,
        SocialVaultRemoveSlotRequest,
        SocialVaultRenameSlotRequest,
        SocialVaultDeleteRequest,
        SocialVaultRotateRequest,
        SocialVaultStatusRequest,
        SocialVaultCancelDeletionRequest,
        SocialVaultPendingDeletion;

export '../generated/openapi.enums.swagger.dart' show SocialVaultSlotKind, SocialVaultProvider;
