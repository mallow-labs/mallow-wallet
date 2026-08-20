part of '../artwork_detail_screen.dart';

/// Map a resolved [ArtworkActionState] to the corresponding sheet widget.
/// Returns null when no sheet should be pinned (collection view, owner
/// who can't list, no-action state). The dispatcher itself lives in
/// [resolveArtworkActionState] — see `docs/artwork_state.md`.
///
/// All side-effect callbacks are passed in so this helper stays free of
/// `setState`, instance state, and bloc reads.
Widget? _buildArtworkActionSheet({
  required BuildContext context,
  required ArtworkActionState state,
  required ArtworkDetails artwork,
  required bool isMarketLoading,
  required Map<String, String?> creatorUsernames,
  required EditionPurchaseStats? editionStats,
  required EditionLiveState? editionLive,

  /// The two halves of the on-chain whitelist phase for the connected
  /// wallet — wallet allowlist and holder-only token gate. Either qualifies;
  /// null = unknown, which must not block. See
  /// [ArtworkBuyEditionSheet.onChainAllowlisted] / `.holdsGatingNft`.
  required bool? editionOnChainAllowlisted,
  required bool? editionHoldsGatingNft,
  required ValueChanged<ArtworkDetails> onBuy,
  required ValueChanged<ArtworkDetails> onMakeOffer,
  required VoidCallback onCancelOffer,
  required OfferRender? highestOffer,
  required ValueChanged<OfferRender> onAcceptHighestOffer,
  required ValueChanged<ArtworkDetails> onListUnlisted,
  required ValueChanged<ArtworkDetails> onSendArtwork,
  required ValueChanged<ArtworkDetails> onUpdateListing,
  required ValueChanged<ArtworkDetails> onPlaceBid,
  required void Function({bool reclaim}) onCancelAuction,
  required VoidCallback onSettleAuction,
  required VoidCallback onAuctionEnded,
  required ValueChanged<ArtworkDetails> onBuyRaffleTickets,
  required ValueChanged<String> onCancelRaffle,
  required ValueChanged<String> onClaimRaffleNft,
  required ValueChanged<String> onClaimRaffleProceeds,
}) {
  // Resolved usernames for auction / raffle participants — populated by
  // the parent's `_maybeLoadCreatorUsernames` from the same address pool
  // as the creators row, so the lookup is shared.
  final currentBidder = artwork.auctionMetadata?.currentBidder;
  final raffleWinner = artwork.raffleMetadata?.winner;
  final bidderUsername = currentBidder == null
      ? null
      : creatorUsernames[currentBidder];
  final winnerUsername = raffleWinner == null
      ? null
      : creatorUsernames[raffleWinner];
  final me = sl<AuthService>().currentAddress;
  final isHighestBidder =
      me != null && currentBidder != null && me == currentBidder;
  final raffleKey = artwork.raffleMetadata?.raffleAccount;

  return switch (state) {
    ArtworkNoAction() => null,
    ArtworkConnectWalletAction(:final label, :final subtitle) =>
      ArtworkConnectWalletSheet(label: label, subtitle: subtitle),
    ArtworkBuyAction(:final userOwnOffer, :final block) => ArtworkBuySheet(
      artwork: artwork,
      onBuy: () => onBuy(artwork),
      onMakeOffer: () => onMakeOffer(artwork),
      onCancelOffer: onCancelOffer,
      isLoading: isMarketLoading,
      userOwnOffer: userOwnOffer,
      block: block,
    ),
    ArtworkBuyEditionAction(:final block) => ArtworkBuyEditionSheet(
      artwork: artwork,
      purchaseStats: editionStats,
      editionState: editionLive,
      onChainAllowlisted: editionOnChainAllowlisted,
      holdsGatingNft: editionHoldsGatingNft,
      onBuyEdition: () => onBuy(artwork),
      onMakeOffer: () => onMakeOffer(artwork),
      isLoading: isMarketLoading,
      block: block,
    ),
    ArtworkOwnerUnlistedAction(:final canList, :final canSend) =>
      ArtworkOwnerSheet(
        artwork: artwork,
        canList: canList,
        canSend: canSend,
        onList: () => onListUnlisted(artwork),
        onSend: () => onSendArtwork(artwork),
        highestOffer: highestOffer,
        onAcceptOffer: onAcceptHighestOffer,
        isLoading: isMarketLoading,
      ),
    ArtworkOwnerListedAction() => ArtworkOwnerListedSheet(
      artwork: artwork,
      onUpdateListing: () => onUpdateListing(artwork),
      highestOffer: highestOffer,
      editionState: editionLive,
      onAcceptOffer: onAcceptHighestOffer,
      isLoading: isMarketLoading,
    ),
    ArtworkUnlistedViewerAction(:final userOwnOffer) =>
      ArtworkUnlistedViewerSheet(
        artwork: artwork,
        highestOffer: highestOffer,
        userOwnOffer: userOwnOffer,
        onMakeOffer: () => onMakeOffer(artwork),
        onCancelOffer: onCancelOffer,
        isLoading: isMarketLoading,
      ),
    ArtworkAuctionBidAction(:final unknownCurrency) => ArtworkAuctionBidSheet(
      artwork: artwork,
      currentBidderUsername: bidderUsername,
      isCurrentUserHighestBidder: isHighestBidder,
      unknownCurrency: unknownCurrency,
      onPlaceBid: () => onPlaceBid(artwork),
      onAuctionEnded: onAuctionEnded,
      isLoading: isMarketLoading,
    ),
    ArtworkAuctionOwnerAction() => ArtworkAuctionOwnerSheet(
      artwork: artwork,
      currentBidderUsername: bidderUsername,
      onCancelAuction: () => onCancelAuction(),
      onAuctionEnded: onAuctionEnded,
      isLoading: isMarketLoading,
    ),
    ArtworkAuctionClaimAction(:final role) => ArtworkAuctionClaimSheet(
      artwork: artwork,
      role: role,
      winnerUsername: bidderUsername,
      onMakeOffer: () => onMakeOffer(artwork),
      onSettle: () {
        // Single ix covers all three paths — settleAuction does both
        // seller-payout and winner-NFT-transfer; reclaim-no-bids uses
        // cancelAuction (which the program permits after `endsAt`).
        final hasBids = (artwork.auctionMetadata?.bidCount ?? 0) > 0;
        if (role == AuctionEndedRole.seller && !hasBids) {
          onCancelAuction(reclaim: true);
        } else {
          onSettleAuction();
        }
      },
      isLoading: isMarketLoading,
    ),
    ArtworkRaffleAction(
      :final role,
      :final subState,
      :final raffle,
      :final gate,
    ) =>
      ArtworkRaffleSheet(
        artwork: artwork,
        role: role,
        subState: subState,
        raffle: raffle,
        gate: gate,
        winnerUsername: winnerUsername,
        onBuyTickets: () => onBuyRaffleTickets(artwork),
        onCancelRaffle: () {
          if (raffleKey == null) return;
          onCancelRaffle(raffleKey);
        },
        onClaimNft: () {
          if (raffleKey == null) return;
          onClaimRaffleNft(raffleKey);
        },
        onClaimProceeds: () {
          if (raffleKey == null) return;
          onClaimRaffleProceeds(raffleKey);
        },
      ),
    ArtworkUnclaimedRaffleAction(:final raffle, :final claim) =>
      ArtworkUnclaimedRaffleSheet(
        raffle: raffle,
        claim: claim,
        onClaimNft: () => onClaimRaffleNft(raffle.raffleAccount),
        onClaimProceeds: () => onClaimRaffleProceeds(raffle.raffleAccount),
      ),
    ArtworkExternalLinkAction(:final listingType) => ArtworkExternalLinkSheet(
      listingType: listingType,
    ),
  };
}
