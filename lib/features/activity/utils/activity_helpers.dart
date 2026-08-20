import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/data/mallow_tokens.dart';
import '../../../core/services/token_metadata_service.dart';
import '../../../core/utils/address_format.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_colors.dart';
import '../../../shared/utils/chain.dart';

/// Whether this activity type represents an outgoing transaction (asset left the wallet).
bool isOutgoing(api.ActivityType type) {
  switch (type) {
    case api.ActivityType.buy:
    case api.ActivityType.mint:
    case api.ActivityType.send:
    case api.ActivityType.offer:
    // Staking funds a stake account: the SOL genuinely leaves the wallet.
    // Unstaking is deliberately absent — deactivation moves nothing until the
    // stake is claimed, so the row must read neutral.
    case api.ActivityType.stake:
      return true;
    default:
      return false;
  }
}

/// Whether this activity type represents an incoming transaction (asset entered the wallet).
///
/// `offer-received` is deliberately absent: a bid someone placed on the
/// viewer's listing moves no money into their wallet — the bidder's funds stay
/// in their own escrow until the offer is accepted — so the row must render
/// neutral (no sign, no directional colour) rather than as a credit.
bool isIncoming(api.ActivityType type) {
  switch (type) {
    case api.ActivityType.sale:
    case api.ActivityType.receive:
    // The claim that returns deactivated stake to the wallet.
    case api.ActivityType.stakeWithdraw:
      return true;
    default:
      return false;
  }
}

/// True when the server flagged this row as money coming back to the viewer.
///
/// Bid refunds (you were outbid, your escrowed bid was returned) are emitted
/// with the same `offer` type as the bid that created them, so type alone reads
/// them as a debit. The server stamps `data.isRefund` on exactly those rows;
/// only refunds carry it.
bool isRefund(api.Activity activity) => activity.data['isRefund'] == true;

/// [isOutgoing] for a full activity row. A refund reverses its own type, so a
/// refunded bid never counts as outgoing however the row is typed.
bool isActivityOutgoing(api.Activity activity) =>
    !isRefund(activity) && isOutgoing(activity.type);

/// [isIncoming] for a full activity row — see [isRefund] for why a refunded
/// row is incoming regardless of its [api.ActivityType].
bool isActivityIncoming(api.Activity activity) =>
    isRefund(activity) || isIncoming(activity.type);

/// Get the directional color for an activity type.
///
/// Red for outgoing, green for incoming, null for neutral. Prefer
/// [activityDirectionColor] when the whole [api.Activity] is available — this
/// type-only form can't see the refund flag.
Color? directionColor(api.ActivityType type, MallowColors colors) {
  if (isOutgoing(type)) return colors.negative;
  if (isIncoming(type)) return colors.positive;
  return null;
}

/// [directionColor] for a full activity row, honouring the refund flag.
Color? activityDirectionColor(api.Activity activity, MallowColors colors) {
  if (isActivityOutgoing(activity)) return colors.negative;
  if (isActivityIncoming(activity)) return colors.positive;
  return null;
}

/// Get the preview border color based on asset direction.
///
/// Red if the asset left the wallet, green if it entered.
/// For swaps this is determined per-side, not here.
Color? previewBorderColor(api.ActivityType type, MallowColors colors) {
  switch (type) {
    // Asset left wallet
    case api.ActivityType.send:
    case api.ActivityType.list:
    case api.ActivityType.stake:
      return colors.negative;
    // Asset entered wallet
    case api.ActivityType.receive:
    case api.ActivityType.mint:
    case api.ActivityType.delist:
    case api.ActivityType.stakeWithdraw:
      return colors.positive;
    // Buy: user spent SOL (outgoing) but received NFT (incoming) — detail view uses split
    case api.ActivityType.buy:
      return colors.negative;
    // Sale: user sent NFT (outgoing) but received SOL (incoming) — detail view uses split
    case api.ActivityType.sale:
      return colors.positive;
    default:
      return null;
  }
}

/// The verb label for each activity type, shown in editorial italic.
String activityVerb(api.ActivityType type) {
  switch (type) {
    case api.ActivityType.sale:
      return 'Sold';
    case api.ActivityType.buy:
      return 'Bought';
    case api.ActivityType.list:
      return 'Listed';
    case api.ActivityType.delist:
      return 'Delisted';
    case api.ActivityType.offer:
      return 'Offer made';
    case api.ActivityType.offerReceived:
      return 'Offer received';
    case api.ActivityType.mint:
      return 'Minted';
    case api.ActivityType.swap:
      return 'Token swap';
    case api.ActivityType.send:
      return 'Transferred';
    case api.ActivityType.receive:
      return 'Received';
    case api.ActivityType.gumballCreate:
      return 'Create Gumball';
    case api.ActivityType.gumballUpdate:
      return 'Update Gumball';
    case api.ActivityType.altCreate:
      return 'Create Lookup Table';
    case api.ActivityType.stake:
      return 'Staked';
    case api.ActivityType.unstake:
      return 'Unstaked';
    case api.ActivityType.stakeWithdraw:
      return 'Claimed stake';
    case api.ActivityType.unknown:
      return 'Unknown transaction';
  }
}

/// Sink addresses whose received tokens are provably destroyed. A `send` to one
/// of these is a burn, not a transfer to another wallet. Covers the EVM zero
/// address and the conventional `0x…dEaD` burn sink (both stored lowercase for
/// case-insensitive comparison).
const _burnAddresses = <String>{
  '0x0000000000000000000000000000000000000000',
  '0x000000000000000000000000000000000000dead',
};

/// True when this activity is an outgoing transfer to a burn address — the
/// asset was destroyed rather than sent to another wallet.
bool isBurn(api.Activity activity) {
  if (activity.type != api.ActivityType.send) return false;
  final transfer = activity.transferData;
  if (transfer == null) return false;
  return _burnAddresses.contains(transfer.counterparty.address.toLowerCase());
}

/// The label shown for an activity in the list row and detail header.
///
/// A send to a burn address always renders as "Burned", overriding the server
/// label. Otherwise prefers the server-provided [api.Activity.displayLabel],
/// falling back to the typed [activityVerb] when that field is null, blank, *or*
/// whitespace-only. The server field is free-form `String?`, and an empty string
/// is a common "no label" serialization that must not render as an empty [Text].
/// The returned label is trimmed so surrounding whitespace never leaks into the
/// UI.
String activityDisplayLabel(api.Activity activity) {
  if (isBurn(activity)) return 'Burned';
  final label = activity.displayLabel?.trim();
  if (label != null && label.isNotEmpty) return label;
  return activityVerb(activity.type);
}

/// The chain an activity settled on, inferred from the shapes the row itself
/// carries, or null when nothing in the row establishes one.
///
/// The detail screen is handed the chain by its caller; list rows are not (the
/// global feed renders every chain in one list, and adding a required
/// constructor argument would break both call sites), so anything that renders
/// a chain-denominated value here has to read the row. EVM (`0x…` signature,
/// `0x…` / `0x…-<tokenId>` mint) and Tezos (`KT1…` contract, `tz…`
/// counterparty) are prefix-detectable; a base58 mint is Solana by the same
/// convention as [Chain.fromAddress]. Callers must treat null as
/// "unknown" and render without a ticker rather than assuming SOL.
Chain? inferActivityChain(api.Activity activity) {
  if (activity.signature.startsWith('0x')) return Chain.ethereum;

  final transfer = activity.transferData;
  final mint = transfer?.token.mint ?? activity.marketData?.artwork.mintAccount;
  if (mint == null) return null;
  if (isTezosAsset(mint)) return Chain.tezos;
  if (isEthereumAsset(mint) || isEthereumAddress(mint)) return Chain.ethereum;

  final counterparty = transfer?.counterparty.address;
  if (counterparty != null && isTezosAddress(counterparty)) return Chain.tezos;
  return Chain.solana;
}

/// The symbol shown for a token in activity rows and detail views.
///
/// Unindexed tokens come back from the server with an empty [api.TokenInfo.symbol].
/// The local registry is consulted before giving up: a token the app itself
/// knows about (SOL, mallowSOL, USDC…) has a symbol whether or not the indexer
/// resolved one, and rendering its mint instead is strictly worse. Only a mint
/// neither side can name falls through to the truncated address, which keeps an
/// amount from rendering bare. Same class of server-free-form normalization as
/// [activityDisplayLabel] — it lives here so every activity surface renders an
/// unindexed token identically.
String tokenDisplaySymbol(api.TokenInfo token) {
  if (token.symbol.isNotEmpty) return token.symbol;
  final known = tokenByMint(token.mint)?.symbol;
  if (known != null && known.isNotEmpty) return known;
  return truncateAddress(token.mint);
}

/// The logo shown for a token in activity rows and detail views, or null when
/// nothing on device can picture it.
///
/// The counterpart to [tokenDisplaySymbol]: the server's own `logoUrl` first,
/// then whatever [TokenMetadataService] has learned about the mint (its
/// persisted cache, the cached Jupiter verified list, or a DAS read — see
/// [resolveActivityTokenMetadata], which is what puts it there). Registry mints
/// short-circuit: they render from a bundled asset and the service never looks
/// one up.
String? tokenDisplayLogoUrl(api.TokenInfo token) {
  final fromServer = token.logoUrl?.trim();
  if (fromServer != null && fromServer.isNotEmpty) return fromServer;
  if (isRegistryMint(token.mint)) return null;
  // Guarded so a widget test can render a row without standing up DI, the
  // same way the refresh signals are.
  if (!sl.isRegistered<TokenMetadataService>()) return null;
  return sl<TokenMetadataService>().imageUrlFor(token.mint);
}

/// Resolve, on device, the token legs the feed didn't name — completing with
/// true when the caller should rebuild.
///
/// The Solana parsers name almost nothing. `/v2/activity` builds swap legs
/// straight from the transaction's balance deltas (`tx_parser::token_info`) and
/// stamps a plain SPL transfer's `token` from the same place, so every leg but
/// SOL arrives with an empty `symbol` and no `logoUrl` at all; `/v2/transfers`
/// — the token detail sheet's History tab — has no `logoUrl` field on its wire
/// shape whatsoever and fills `symbol` only from its own small static map. A
/// mint neither registry keys therefore renders as a truncated address beside a
/// blank tile, which is most of what people actually hold and swap.
/// [TokenMetadataService] fills both from the cached Jupiter verified list or a
/// DAS `getAsset`, caches the answer for next time, and publishes it where
/// [tokenDisplaySymbol] and [tokenDisplayLogoUrl] read it.
///
/// NFT transfers are deliberately excluded: their name and image come from
/// mallow's own index server-side (`enrich_nft_transfers`) onto fields a
/// fungible-token read can't supply, and the EVM/Tezos feeds already enrich
/// both — [_needsTokenLookup]'s chain test keeps those off DAS too.
///
/// Returns false — without touching the service locator — when every leg is
/// already named, so a SOL → USDC row costs nothing, and false again when no
/// leg actually resolved: a mint DAS can't index is negative-cached for
/// [TokenMetadataService.failureTtl], so the lookup this row and every recycle
/// of it re-runs must not cost a rebuild that renders the same truncated mint.
/// A leg served from the cache still counts as resolved, so a recycled row does
/// re-render from it.
Future<bool> resolveActivityTokenMetadata(api.Activity activity) async {
  final swap = activity.swapData;
  final transfer = activity.transferData;
  final mints = <String>{
    for (final leg in [
      if (swap != null) ...[swap.inputToken, swap.outputToken],
      if (transfer != null && !transfer.isNft) transfer.token,
    ])
      if (_needsTokenLookup(leg)) leg.mint,
  };
  if (mints.isEmpty || !sl.isRegistered<TokenMetadataService>()) return false;
  final service = sl<TokenMetadataService>();
  final resolved = await Future.wait(mints.map(service.resolve));
  return resolved.any((token) => token != null);
}

/// Whether [token] is missing display data only a lookup can supply.
///
/// The chain test keeps a future EVM swap row from firing a DAS request for a
/// `0x…` mint DAS cannot index; `TokenMetadataService.needsLookup` makes the
/// same call but is not consulted here, so a row of registry tokens never
/// reaches for the locator at all.
bool _needsTokenLookup(api.TokenInfo token) =>
    (token.symbol.isEmpty || (token.logoUrl ?? '').trim().isEmpty) &&
    token.mint.isNotEmpty &&
    !isRegistryMint(token.mint) &&
    Chain.fromAddress(token.mint) == Chain.solana;

/// Whether this activity involves an NFT (for showing the dot menu).
bool hasNftData(api.Activity activity) {
  if (activity.marketData != null) return true;
  final transfer = activity.transferData;
  if (transfer != null && transfer.isNft) return true;
  return false;
}

/// Display label for activity status (API commitment level).
String statusLabel(api.ActivityStatus status) {
  switch (status) {
    case api.ActivityStatus.confirmed:
      return 'Confirmed';
    case api.ActivityStatus.finalized:
      return 'Finalized';
    case api.ActivityStatus.failed:
      return 'Failed';
  }
}
