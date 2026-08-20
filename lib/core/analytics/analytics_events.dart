/// Central registry for the mobile analytics taxonomy.
///
/// Single source of truth for every event name, property key, and controlled
/// vocabulary. Call sites MUST use
/// these constants/enums instead of raw strings so the taxonomy can't drift
/// (typos, casing, `tokenDetail` vs `token_detail`).
///
/// Convention: event names are Title Case verb-object; property keys and enum
/// wire values are snake_case.
library;

import '../result/app_failure.dart';

import '../../shared/utils/chain.dart';

/// Event names. Title Case verb-object.
abstract final class AnalyticsEvent {
  // Lifecycle
  static const appOpened = 'App Opened';
  static const appInstalled = 'App Installed';

  // Onboarding
  static const walletCreated = 'Wallet Created';
  static const walletImported = 'Wallet Imported';
  static const walletImportFailed = 'Wallet Import Failed';

  // Auth. Throttled to one per [AnalyticsService.loginThrottle] — login runs on
  // every startup, wallet switch and session refresh, so an unthrottled event
  // counts plumbing rather than logins.
  static const loggedIn = 'Logged In';

  // Transactions (Completed + Failed; on-chain rows set is_onchain_tx=true).
  // Emit these through [AnalyticsService.trackTransaction], which requires the
  // [TxType] and carries the signature.
  static const sendCompleted = 'Send Completed';
  static const sendFailed = 'Send Failed';
  static const swapCompleted = 'Swap Completed';
  static const swapFailed = 'Swap Failed';
  static const nftTransferCompleted = 'NFT Transfer Completed';
  static const nftTransferFailed = 'NFT Transfer Failed';
  static const burnCompleted = 'Burn Completed';
  static const burnFailed = 'Burn Failed';

  // Marketplace / Mint
  static const mintCompleted = 'Mint Completed';
  static const mintFailed = 'Mint Failed';
  static const listingCreated = 'Listing Created';
  static const listingFailed = 'Listing Failed';
  static const purchaseCompleted = 'Purchase Completed';
  static const purchaseFailed = 'Purchase Failed';
  static const offerMade = 'Offer Made';
  static const bidPlaced = 'Bid Placed';

  // Remote config / kill switch. Measures incident reach — a kill hit is NOT
  // a failure and never becomes a [FailureReason].
  static const flowDisabledHit = 'Flow Disabled Hit';

  // Settings
  static const networkSwitched = 'Network Switched';
  static const currencyChanged = 'Currency Changed';
  static const analyticsDisabled = 'Analytics Disabled';
}

/// Property keys. snake_case. (Mixpanel `$`-prefixed reserved keys — `$os`,
/// `$insert_id`, etc. — are stamped by the backend or the service, not here.)
abstract final class AnalyticsProp {
  static const chain = 'chain';
  static const assetKind = 'asset_kind';
  static const reason = 'reason';
  static const entryPoint = 'entry_point';
  static const isOnchainTx = 'is_onchain_tx';
  // Transaction dimensions, stamped by [AnalyticsService.trackTransaction]:
  // `tx_type` is a [TxType] wire value, `signature` the on-chain tx id (null
  // until broadcast, e.g. on a build/sign failure).
  static const txType = 'tx_type';
  static const signature = 'signature';
  static const network = 'network';
  static const sessionId = 'session_id';
  static const usdValue = 'usd_value';
  static const mint = 'mint';
  static const symbol = 'symbol';
  static const inputMint = 'input_mint';
  static const outputMint = 'output_mint';
  static const inputSymbol = 'input_symbol';
  static const outputSymbol = 'output_symbol';
  static const collectionId = 'collection_id';
  static const collectionName = 'collection_name';
  static const auctionId = 'auction_id';
  static const method = 'method';
  static const currency = 'currency';
  static const coldStart = 'cold_start';
  static const optOut = 'opt_out';
  static const source = 'source';
  // Kill-switch dimensions: `flow` is the `'<chain>:<flow>'` wire key
  // (`FlowKey.toString()`), `surface` a [FlowDisabledSurface] wire value.
  static const flow = 'flow';
  static const surface = 'surface';
  static const campaign = 'campaign';
  static const referrer = 'referrer';
  // Wallet address rides as a raw property (device is the identity).
  static const walletAddress = 'wallet_address';

  // Context props stamped on every event by the service.
  static const platform = 'platform';
  static const osVersion = 'os_version';
  static const appVersion = 'app_version';
  static const buildNumber = 'build_number';
  static const deviceModel = 'device_model';
}

/// What the user was transacting. The primary product dimension: every
/// transaction event carries it, so "how many buys / listings / swaps did we
/// do" is one breakdown rather than a union over event names.
///
/// One value per user-facing action, not per program instruction — a Core buy
/// and a Metaplex buy are both [buyArtwork] (`asset_kind` splits those).
enum TxType {
  send('send'),
  swap('swap'),
  transferArtwork('transfer_artwork'),
  burnArtwork('burn_artwork'),
  mint('mint'),
  listArtwork('list_artwork'),
  buyArtwork('buy_artwork'),
  makeOffer('make_offer'),
  placeBid('place_bid');

  const TxType(this.wire);
  final String wire;
}

/// Chains the wallet supports.
enum AnalyticsChain {
  solana('solana'),
  ethereum('ethereum'),
  tezos('tezos');

  const AnalyticsChain(this.wire);
  final String wire;

  /// Map a domain [Chain] onto its analytics counterpart. Exhaustive (and thus
  /// compile-checked) — unlike `AnalyticsChain.values.byName(chain.name)`,
  /// which throws at runtime if the two enums ever drift apart.
  static AnalyticsChain fromChain(Chain chain) => switch (chain) {
    Chain.solana => AnalyticsChain.solana,
    Chain.ethereum => AnalyticsChain.ethereum,
    Chain.tezos => AnalyticsChain.tezos,
  };
}

/// Flat, detailed asset dimension.
enum AssetKind {
  sol('sol'),
  splToken('spl_token'),
  metaplexNft('metaplex_nft'),
  coreNft('core_nft'),
  pnft('pnft'),
  cnft('cnft'),
  eth('eth'),
  evmToken('evm_token'),
  xtz('xtz'),

  /// A Tezos fungible token (FA1.2 or FA2) — the XTZ counterpart of
  /// [splToken] / [evmToken]. Distinct from [fa2Nft], which is an artwork.
  faToken('fa_token'),
  fa2Nft('fa2_nft');

  const AssetKind(this.wire);
  final String wire;
}

/// Bounded failure reasons. Map real exceptions into these buckets; anything
/// unmapped → [unknown]. Watch the `unknown` rate and add buckets deliberately.
enum FailureReason {
  userRejected('user_rejected'),
  insufficientFunds('insufficient_funds'),
  insufficientFees('insufficient_fees'),
  slippageExceeded('slippage_exceeded'),
  networkError('network_error'),
  simulationFailed('simulation_failed'),
  signatureFailed('signature_failed'),
  timeout('timeout'),
  unknown('unknown');

  const FailureReason(this.wire);
  final String wire;

  /// Bucket a classified [AppFailureKind] onto the bounded failure vocabulary.
  /// Kinds without a matching bucket (e.g. a bad key/phrase, a parse error)
  /// fall through to [unknown].
  static FailureReason fromAppFailureKind(AppFailureKind kind) =>
      switch (kind) {
        AppFailureKind.cancelled => FailureReason.userRejected,
        AppFailureKind.network => FailureReason.networkError,
        AppFailureKind.rpc => FailureReason.networkError,
        AppFailureKind.signing => FailureReason.signatureFailed,
        AppFailureKind.validation => FailureReason.unknown,
        // A remote kill is not a failure — it is reported by
        // [AnalyticsEvent.flowDisabledHit]. Reaching here means a surface
        // logged a kill as a transaction failure; bucket it as [unknown] rather
        // than corrupting the rejection metrics with [userRejected].
        AppFailureKind.flowDisabled => FailureReason.unknown,
        AppFailureKind.unknown => FailureReason.unknown,
      };
}

/// Where a kill was presented to the user, for [AnalyticsEvent.flowDisabledHit].
///
/// Only explicit presentations are counted. Reactive row/button disabling
/// (`StakingFormTab`, `SendTokenSelectStep`) is a render-time read that would
/// inflate the count on every rebuild, so it emits nothing.
enum FlowDisabledSurface {
  /// `guardFlowDisabled` blocked a tap handler.
  entryGate('entry_gate'),

  /// `FlowGatedScreen` mounted `FlowUnavailableScreen` instead of the route.
  routeGate('route_gate'),

  /// A sheet fronting one or more cells presented the kill itself.
  sheet('sheet'),

  /// `handleFlowDisabled` presented an `AppFailureKind.flowDisabled` raised
  /// mid-flow by the signing backstop.
  midFlow('mid_flow');

  const FlowDisabledSurface(this.wire);
  final String wire;
}

/// Where a user-initiated action was launched from. Missing → [unknown].
enum EntryPoint {
  portfolioRow('portfolio_row'),
  tokenDetail('token_detail'),
  artworkDetail('artwork_detail'),
  collection('collection'),
  swapTab('swap_tab'),
  sendButton('send_button'),
  receiveButton('receive_button'),
  qrScan('qr_scan'),
  deepLink('deep_link'),
  pushNotification('push_notification'),
  marketplace('marketplace'),
  auctionDetail('auction_detail'),
  settings('settings'),
  unknown('unknown');

  const EntryPoint(this.wire);
  final String wire;
}
