/// Constants for the on-chain MallowMarket program. Mirror the values the
/// webapp's SDK compiles in.
library;

/// MallowMarket program id.
const kMallowMarketProgramId = 'MMA7VebX8Pi5JrrvaTBBm7nW81sfCww7ZtLBBT1YCy8';

/// Marketplace authority — the wallet that signs marketplace-config updates.
/// Mirrors the webapp's `Constants.MARKETPLACE_AUTH_ADDRESS`.
const kMallowMarketplaceAuthority =
    'AUTH8n3RY3JH38j19r1TrZi88zf5pUnAGh4tFkhcnptZ';

/// PDA seed prefix for the [MarketplaceConfig] account.
/// Mirrors the webapp's `Pdas.marketplaceConfig`.
const kMarketplaceConfigSeed = 'marketplace_config';

/// PDA seed prefix for a fixed-price `Listing` account. The canonical PDA is
/// `["listing", mint]` under [kMallowMarketProgramId] — verified against the
/// backend's `derive_listing` (the legacy 3-seed
/// `[mint, "listing", auth]` scheme is retired). Seed order is **prefix
/// first, then mint**.
const kListingSeed = 'listing';

/// MallowAuction program id — owns the `AuctionConfig` PDA. Distinct from
/// [kMallowMarketProgramId]. Mirrors the backend's
/// `MALLOW_AUCTION_PROGRAM_ID`.
const kMallowAuctionProgramId = 'MAUsg1KhgYQV2Kxr9ccAkv7bUod88Qi3AKe5nUN41oe';

/// PDA seed prefix for an `Offer` account. The canonical PDA is the codama
/// 3-seed scheme `["offer", buyer, asset]` under [kMallowMarketProgramId]
/// (the legacy 4-seed scheme that appended the marketplace auth is retired) —
/// mirrors the backend's `ClientOffer::find_pda`.
const kOfferSeed = 'offer';

/// PDA seed suffix for an `AuctionConfig` account. The canonical PDA is
/// `[mint, "auction_config"]` under [kMallowAuctionProgramId] — verified
/// against the backend's `derive_auction_config`. Seed order is **mint
/// first, then suffix**.
const kAuctionConfigSeed = 'auction_config';

/// Default fee bps applied when the on-chain `MarketplaceConfig` cannot be
/// read (network failure, decode failure). Mirrors the webapp's
/// `DEFAULT_PRIMARY_BPS = 500` / `DEFAULT_SECONDARY_BPS = 250` in
/// `Constants`.
const kDefaultPrimaryFeeBps = 500;
const kDefaultSecondaryFeeBps = 250;

/// Default print (edition) fee in lamports applied when the on-chain
/// `MarketplaceConfig` cannot be read. Mirrors the webapp's
/// `feeConfig.printFee?.toNumber() ?? 11_000_000` fallback in
/// `useBuyNow`. This is the flat per-print
/// "mallow fee" the buyer pays on top of the listing price.
const kDefaultPrintFeeLamports = 11000000;

/// Byte offsets of the fee fields within the on-chain `MarketplaceConfig`
/// account. Layout (Anchor account):
/// ```
/// 0..8    discriminator
/// 8..9    bump (u8 array len 1)
/// 9..10   version (u8)
/// 10..42  marketplaceAuthority (publicKey)
/// 42..74  feeConfig.feeAccount  (publicKey)
/// 74..76  feeConfig.primaryBps  (u16 LE)        ← here
/// 76..78  feeConfig.secondaryBps (u16 LE)       ← here
/// 78..80  feeConfig.tokenDiscountBps (u16 LE)
/// 80..88  feeConfig.printFee (u64)
/// 88..120 feeConfig.discountToken (publicKey)
/// 120..152 rewardsConfig (publicKey)
/// ```
/// Source: `mallow_market`, struct definitions for
/// `marketplaceConfig` and `FeeConfig`.
const kPrimaryBpsOffset = 74;
const kSecondaryBpsOffset = 76;
const kPrintFeeOffset = 80;
