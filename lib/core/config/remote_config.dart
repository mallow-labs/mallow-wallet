import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../shared/utils/chain.dart';
part 'remote_config.freezed.dart';

/// The flow axis of the remote kill-switch: one cell per distinct transaction
/// builder. A builder is the unit that breaks, so it's the unit that gets
/// killed — killing broken listing *creation* must not also kill delisting.
///
/// Each value carries two things:
///
/// * [wire] — the string the backend uses for this cell (`MobileFlow` in the
///   OpenAPI contract). Half of the `'<chain>:<flow>'` key in
///   [RemoteConfig.disabledMessages].
/// * [chains] — the chains this build actually implements the flow for. This
///   is deliberately client-side, not a server field: when EVM burn ships, a
///   server-driven support list would have to drop `ethereum:nft-burn` from
///   it, and every older client still in the wild would instantly believe EVM
///   burn is available. What a build implements is a property of that build.
///
/// Only three flows are multi-chain ([nativeSend] ×3, [tokenSend] ×3,
/// [nftTransfer] ×2); the other 29 cells are Solana-only by construction.
///
/// The 🔓 cells below are **escape hatches** — how users get assets back out
/// (`*-cancel`, [auctionSettle], the raffle claims, [withdrawStake],
/// [unstakeNative]). They are separate cells precisely so they can never be
/// collateral damage of killing the create path they pair with; killing one
/// strands user assets and needs a deliberate decision.
enum AppFlow {
  // --- Fungible tokens ---
  /// `buildSolTransferTx` / EVM native / `TezosTransferService`.
  nativeSend('native-send', {Chain.solana, Chain.ethereum, Chain.tezos}),

  /// `buildSplTransferTx` / ERC-20 via `evm_transfer_core` / FA1.2 + FA2
  /// `transfer` via `TezosTransferService`.
  tokenSend('token-send', {Chain.solana, Chain.ethereum, Chain.tezos}),

  /// `buildBurnAndCloseTx` — client-side.
  tokenBurn('token-burn', {Chain.solana}),

  /// Jupiter / Orca.
  tokenSwap('token-swap', {Chain.solana}),

  // --- NFTs ---
  /// `/tx/assets/transfer` + client-side legacy SPL.
  nftTransfer('nft-transfer', {Chain.solana, Chain.ethereum}),

  /// `/tx/assets/burn`.
  nftBurn('nft-burn', {Chain.solana}),

  /// `/tx/nft/mint` — `MintCreateType.oneOfOne`.
  nftMint('nft-mint', {Chain.solana}),

  /// `/tx/nft/mint` — master-edition kind.
  editionMint('edition-mint', {Chain.solana}),

  /// `/tx/nft/mint` — `MintCreateType.collection`.
  collectionMint('collection-mint', {Chain.solana}),

  /// `/tx/nft/edit`.
  nftEdit('nft-edit', {Chain.solana}),

  /// `/tx/nft/edit`, `isCollection`.
  collectionEdit('collection-edit', {Chain.solana}),

  /// `/tx/nft/edit-collection-artworks` (batched).
  collectionArtworksEdit('collection-artworks-edit', {Chain.solana}),

  // --- Marketplace, sell side ---
  /// `/tx/fixed-price/create`.
  fixedPriceCreate('fixed-price-create', {Chain.solana}),

  /// `/tx/fixed-price/update`.
  fixedPriceUpdate('fixed-price-update', {Chain.solana}),

  /// 🔓 `/tx/fixed-price/cancel` — delisting.
  fixedPriceCancel('fixed-price-cancel', {Chain.solana}),

  /// `/tx/auctions/create`.
  auctionCreate('auction-create', {Chain.solana}),

  /// 🔓 `/tx/auctions/cancel`.
  auctionCancel('auction-cancel', {Chain.solana}),

  /// 🔓 `/tx/auctions/settle` — funds and NFT are in escrow until this runs.
  auctionSettle('auction-settle', {Chain.solana}),

  // --- Marketplace, buy side ---
  /// `/tx/fixed-price/buy`.
  fixedPriceBuy('fixed-price-buy', {Chain.solana}),

  /// `/tx/fixed-price/buy-edition` (batched, partial-signed).
  editionBuy('edition-buy', {Chain.solana}),

  /// `/tx/auctions/bid`.
  auctionBid('auction-bid', {Chain.solana}),

  /// `/tx/offers/create`.
  offerCreate('offer-create', {Chain.solana}),

  /// `/tx/offers/accept`.
  offerAccept('offer-accept', {Chain.solana}),

  /// 🔓 `/tx/offers/cancel` — reclaims the escrowed bid.
  offerCancel('offer-cancel', {Chain.solana}),

  // --- Raffles ---
  /// `/tx/raffles/buy-tickets`.
  raffleBuyTickets('raffle-buy-tickets', {Chain.solana}),

  /// 🔓 `/tx/raffles/cancel`.
  raffleCancel('raffle-cancel', {Chain.solana}),

  /// 🔓 `/tx/raffles/claim-prize`.
  raffleClaimPrize('raffle-claim-prize', {Chain.solana}),

  /// 🔓 `/tx/raffles/claim-proceeds`.
  raffleClaimProceeds('raffle-claim-proceeds', {Chain.solana}),

  // --- Staking ---
  /// `buildNativeStakeTx`.
  stakeNative('stake-native', {Chain.solana}),

  /// 🔓 `buildNativeUnstakeTx`.
  unstakeNative('unstake-native', {Chain.solana}),

  /// 🔓 `buildWithdrawStakeTx` — moves lamports out of a deactivated account.
  withdrawStake('withdraw-stake', {Chain.solana}),

  /// `buildLiquidSwapTx` — Jupiter.
  stakeLiquid('stake-liquid', {Chain.solana});

  const AppFlow(this.wire, this.chains);

  /// The backend's string for this cell (`MobileFlow` on the wire).
  final String wire;

  /// Chains this build implements the flow for.
  final Set<Chain> chains;

  /// Whether *this build* can do [flow] on [c] at all — independent of
  /// whether an operator has killed it. See [RemoteConfig.isFlowAvailable]
  /// for the combined check.
  bool isImplemented(Chain c) => chains.contains(c);

  /// Reverse lookup by [wire] string. Null for a cell this build doesn't know
  /// (a newer server enum value) — such entries are dropped at parse time
  /// rather than guessed at.
  static AppFlow? fromWire(String? wire) => _byWire[wire];

  static final Map<String, AppFlow> _byWire = {
    for (final flow in AppFlow.values) flow.wire: flow,
  };
}

/// One cell of the kill-switch matrix: the chain a transaction lands on plus
/// the flow that built it.
///
/// Threaded (required, never optional) through the signing layers —
/// `signSendConfirm` -> `TransactionPipeline.signAndBroadcast` ->
/// `TransactionExecutor.execute` -> `MarketplaceActionFlow.execute` — so the
/// `TransactionAuthGate` backstop can look the cell up before anything is
/// signed. Required so the compiler enumerates every signing site; a missed
/// cell is a hole in the backstop.
@immutable
class FlowKey {
  const FlowKey(this.chain, this.flow);

  /// Convenience for the 29 Solana-only cells, which are most call sites.
  const FlowKey.solana(this.flow) : chain = Chain.solana;

  final Chain chain;
  final AppFlow flow;

  @override
  bool operator ==(Object other) =>
      other is FlowKey && other.chain == chain && other.flow == flow;

  @override
  int get hashCode => Object.hash(chain, flow);

  /// The `'<chain>:<flow>'` wire key — also what Sentry and log lines show.
  @override
  String toString() => '${chain.toDbString()}:${flow.wire}';
}

/// In-memory snapshot of `GET /v2/config/mobile`.
///
/// Deliberately not the generated wire type: the app wants the folded
/// `disabledMessages` map and the app-local [Chain], not the generated one.
/// [RemoteConfig.fromWire] is the single boundary where the two are
/// reconciled — the generated `Chain` / `MobileFlow` enums never travel past
/// it.
///
/// The payload is **sparse**: only currently-disabled cells appear in
/// [disabledMessages]. Absent means enabled, so an empty response and a failed
/// fetch behave identically — which is exactly the fail-open semantics this
/// feature wants. [permissive] is that same "nothing is killed" state.
@freezed
sealed class RemoteConfig with _$RemoteConfig {
  const factory RemoteConfig({
    /// `'<chain>:<flow>'` (wire strings, e.g. `'ethereum:native-send'`) ->
    /// the operator's message explaining why the cell is off.
    @Default(<String, String>{}) Map<String, String> disabledMessages,

    /// Lowest app version the backend still accepts, or null when unset.
    String? minimumVersion,

    /// Server's verdict on the `App-Version` header. Gate the force-upgrade
    /// wall on this **and** a local semver comparison against
    /// [minimumVersion] — a bad edit here would otherwise wall out every user
    /// until a backend fix.
    @Default(false) bool updateRequired,

    /// Copy for the force-upgrade wall, when the server supplied any.
    String? updateMessage,
  }) = _RemoteConfig;

  const RemoteConfig._();

  /// Fold the wire payload into the app's shape. Entries naming a chain or
  /// flow this build doesn't know are dropped — an unrecognised cell can't be
  /// gated anywhere, and guessing (e.g. [Chain.fromDbString]'s Solana
  /// fallback) would kill the wrong cell.
  factory RemoteConfig.fromWire(api.MobileConfigResponse response) {
    final messages = <String, String>{};
    for (final entry in response.disabledFlows) {
      final chain = _chainFromWire(entry.chain.value);
      final flow = AppFlow.fromWire(entry.flow.value);
      if (chain == null || flow == null) continue;
      messages['${chain.toDbString()}:${flow.wire}'] = entry.message;
    }
    return RemoteConfig(
      disabledMessages: Map.unmodifiable(messages),
      minimumVersion: response.minimumVersion,
      updateRequired: response.updateRequired,
      updateMessage: response.updateMessage,
    );
  }

  /// Nothing killed, no update required. The cold-start value, and what a
  /// failed first fetch leaves in place.
  static const permissive = RemoteConfig();

  /// The operator's message for a killed cell, or null when it isn't killed.
  String? disabledMessage(Chain chain, AppFlow flow) =>
      disabledMessages['${chain.toDbString()}:${flow.wire}'];

  /// Effective availability: this build implements the cell **and** no
  /// operator has killed it. Entry gates read this; the signing backstop
  /// reads [disabledMessage] so it can surface the server's copy.
  bool isFlowAvailable(Chain chain, AppFlow flow) =>
      flow.isImplemented(chain) && disabledMessage(chain, flow) == null;
}

/// Generated-[api.Chain] -> app-local [Chain], by wire string. Null for an
/// unknown value (including the generator's `swaggerGeneratedUnknown`, whose
/// value is null). Deliberately not [Chain.fromDbString], which defaults
/// unknown input to Solana — here that would kill a Solana flow because the
/// server named a chain we've never heard of.
Chain? _chainFromWire(String? wire) => switch (wire) {
  'solana' => Chain.solana,
  'ethereum' => Chain.ethereum,
  'tezos' => Chain.tezos,
  _ => null,
};
