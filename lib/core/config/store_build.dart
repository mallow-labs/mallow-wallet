/// Build-time visibility flags for store submissions.
///
/// These hide UI for features that exist in the tree but must not be *visible*
/// in a public store build, because showing them is a store-policy rejection
/// risk. A raffle reads as a lottery to both stores, which is a rejection risk
/// the flag exists to remove from a submitted build.
///
/// **The code stays.** Every flag here gates a widget's *visibility*, never the
/// underlying bloc, repository or service — so flipping a flag back on is a
/// one-line change, not a re-implementation.
///
/// Two rules that make the App Review notes true (Apple 2.3.1 prohibits
/// revealing features review never saw):
///
/// 1. **Compile-time, not remote.** A store build cannot be made to reveal one
///    of these surfaces by a remote-config change. Where a `RemoteConfigService`
///    gate also exists for the same flow, the two compose with `&&` — the remote
///    gate can only disable further, never re-enable.
/// 2. **Default to hidden in release.** Every flag is `kDebugMode`-derived, so a
///    release archive hides the surface unless someone deliberately overrides it
///    with `--dart-define`.
///
/// Two flags break rule 2 on purpose: [kShowNftCommerce] and [kShowSwap] each
/// hide a surface for **one** store's policy, so their default is the Android
/// truth — shown — and the iOS release lane is the side that opts out. The
/// fail-safe for that inversion is not the default but the lane itself: it
/// passes both defines as literals and runs `store_build_ios_gate_test.dart`
/// under the same strings before archiving, so a dropped or renamed define
/// fails the lane rather than the review.
///
/// [storeHidesFlow] folds every platform-scoped flag into the one predicate
/// the three store gates read. A flag added here reaches all of them through
/// it; nothing else should test a flag against an [AppFlow] directly.
library;

import 'package:flutter/foundation.dart';

import 'remote_config.dart';

/// Overridable at build time: `--dart-define=SHOW_UNRELEASED=true`.
///
/// Debug builds default to showing everything so development and QA are not
/// blocked by store-policy hiding.
const bool _showUnreleased = bool.fromEnvironment(
  'SHOW_UNRELEASED',
  defaultValue: kDebugMode,
);

/// In-app raffle **entry** (ticket purchase).
///
/// Consideration + chance + prize is a lottery under Apple 5.3 and Play's
/// Real-Money Gambling/Contests policy, and shipping it requires developer
/// sponsorship, in-app rules text, an approved Play application and a country
/// allowlist. None of that is in place.
///
/// Claim paths (`claimNft`, `claimProceeds`) are deliberately NOT gated by this
/// flag — users holding tickets in a live raffle must still be able to claim.
const bool kShowRaffleEntry = _showUnreleased;

// ---------------------------------------------------------------------------
// Platform-scoped, default-shown — NFT commerce
// ---------------------------------------------------------------------------

/// In-app NFT commerce — buy, bid, make/accept offer, sell/list, update a
/// listing, mint, raffle entry.
///
/// Hidden on iOS: App Store Guideline 3.1.1 treats buying, selling, listing
/// and minting NFTs outside in-app purchase as a rejection, and the
/// marketplace settles in crypto on-chain, which IAP cannot express. The iOS
/// release lane passes `--dart-define=SHOW_NFT_COMMERCE=false`; every other
/// build — Android release included — shows it.
///
/// What this hides is the [kStoreCommerceFlows] set below, plus the outlinks
/// that would land on a purchase page. What it must never hide is an escape
/// hatch: cancelling a listing or offer, settling or claiming an auction or
/// raffle, transfers, burns, staking and metadata edits all stay. Swap is not
/// this flag's business either — it answers a different guideline under
/// [kShowSwap].
const bool kShowNftCommerce = bool.fromEnvironment(
  'SHOW_NFT_COMMERCE',
  defaultValue: true,
);

/// Test seam for the hidden branch of [kShowNftCommerce]. `flutter test` runs
/// with the define unset, so the flag is `true` there; widget tests set this
/// to `false` in `setUp` and clear it in `tearDown`. Production never writes
/// it — the release value is the compile-time constant.
@visibleForTesting
bool? debugShowNftCommerceOverride;

/// What widgets and gates read. Outside tests this is [kShowNftCommerce].
bool get showNftCommerce => debugShowNftCommerceOverride ?? kShowNftCommerce;

/// The `(flow)` cells [kShowNftCommerce] hides — the paid side of the
/// marketplace. Deliberately **not** here: every 🔓 escape hatch in
/// [AppFlow] (`*-cancel`, [AppFlow.auctionSettle], the raffle claims,
/// [AppFlow.unstakeNative], [AppFlow.withdrawStake]), the metadata edits, and
/// the wallet functions (sends, transfers, burns, staking). Hiding the paid
/// side must never strand an asset a user created or bought on the web.
const Set<AppFlow> kStoreCommerceFlows = {
  AppFlow.fixedPriceBuy,
  AppFlow.editionBuy,
  AppFlow.auctionBid,
  AppFlow.offerCreate,
  AppFlow.fixedPriceCreate,
  AppFlow.fixedPriceUpdate,
  AppFlow.auctionCreate,
  AppFlow.offerAccept,
  AppFlow.nftMint,
  AppFlow.editionMint,
  AppFlow.collectionMint,
  AppFlow.raffleBuyTickets,
};

/// Whether [kShowNftCommerce] governs this cell.
extension StoreCommerceFlow on AppFlow {
  bool get isStoreCommerce => kStoreCommerceFlows.contains(this);
}

// ---------------------------------------------------------------------------
// Platform-scoped, default-shown — token swap
// ---------------------------------------------------------------------------

/// In-app token swap — the Jupiter-backed exchange of one token for another,
/// and the liquid-staking path, which is that same swap wearing a different
/// label.
///
/// Hidden on iOS: App Store Guideline 3.1.5(ii) lets an app facilitate a
/// cryptocurrency exchange only when the exchange itself offers the app. Ours
/// routes through a third-party aggregator, so the swap surface comes out of
/// the App Store build. The iOS release lane passes
/// `--dart-define=SHOW_SWAP=false`; every other build — Android release
/// included — shows it.
///
/// What this hides is [kStoreSwapFlows]: the swap sheet and its three entry
/// points, and the Liquid row of the stake sheet's type selector. Native
/// staking, sends, transfers, burns and the whole marketplace are untouched.
///
/// 🛑 Unlike every other flag here, this one takes an escape hatch with it.
/// A liquid *unstake* (mallowSOL → SOL) is the same [AppFlow.stakeLiquid]
/// builder as a liquid stake, so hiding the path hides redemption too. That is
/// a deliberate call, not an oversight: a CTA that runs an aggregator swap is
/// the exact surface the guideline is about however it is labelled, and
/// mallowSOL is not stranded by hiding it — it stays visible, sendable and
/// transferable like any other SPL token, and redeemable in any build that
/// shows swap.
const bool kShowSwap = bool.fromEnvironment('SHOW_SWAP', defaultValue: true);

/// Test seam for the hidden branch of [kShowSwap], on the same terms as
/// [debugShowNftCommerceOverride]: production never writes it.
@visibleForTesting
bool? debugShowSwapOverride;

/// What widgets and gates read. Outside tests this is [kShowSwap].
bool get showSwap => debugShowSwapOverride ?? kShowSwap;

/// The cells [kShowSwap] hides. Both directions of the liquid staking path are
/// the single [AppFlow.stakeLiquid] cell, so naming it once covers the stake
/// and the unstake alike.
const Set<AppFlow> kStoreSwapFlows = {AppFlow.tokenSwap, AppFlow.stakeLiquid};

/// Whether [kShowSwap] governs this cell.
extension StoreSwapFlow on AppFlow {
  bool get isStoreSwap => kStoreSwapFlows.contains(this);
}

// ---------------------------------------------------------------------------
// The shared predicate
// ---------------------------------------------------------------------------

/// Whether this build deliberately does not offer [flow] for a store policy.
///
/// The one predicate all three store gates read — the tap-level entry gate
/// (`guardFlowDisabled`), the route gate (`FlowGatedScreen`) and the signing
/// backstop (`TransactionAuthGate.authorize`). A flag added to this file must
/// reach all three, and folding them here is what makes that automatic rather
/// than a three-file edit somebody does twice and forgets once.
bool storeHidesFlow(AppFlow flow) =>
    (!showNftCommerce && flow.isStoreCommerce) ||
    (!showSwap && flow.isStoreSwap);
