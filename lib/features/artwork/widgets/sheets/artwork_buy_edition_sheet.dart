import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/price_format.dart';
import '../../../../shared/utils/balance_check.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../../market/data/whitelist_eligibility_repository.dart';
import '../../../portfolio/services/token_balance_bloc.dart';
import '../../../sale/services/edition_mint_fees.dart';
import '../../services/artwork_action_state.dart' show ArtworkBuyBlock;
import '../../services/artwork_bloc.dart';
import 'artwork_funding_source.dart';
import 'artwork_sheet_frame.dart';
import 'listing_disclosures.dart';

/// Bottom sheet for limited-edition / open-edition listings (printable
/// master). Shows price, supply progress, and an optional countdown.
///
/// Triggered by `viewer` × `buyNow` × (`limitedEdition` ∨ `openEdition`) — see
/// `docs/artwork_state.md`.
class ArtworkBuyEditionSheet extends StatelessWidget {
  const ArtworkBuyEditionSheet({
    required this.artwork,
    required this.onBuyEdition,
    required this.onMakeOffer,
    this.purchaseStats,
    this.editionState,
    this.isLoading = false,
    this.block,
    this.onChainAllowlisted,
    this.holdsGatingNft,
    super.key,
  });

  /// Wallet-allowlist half of the on-chain whitelist phase: is this wallet on
  /// `purchaseStats.whitelistConfig.walletsRoot`? See
  /// [WhitelistEligibilityRepository.isWalletAllowlisted]. **null = unknown**
  /// (still in flight, or the check failed) and must not block.
  final bool? onChainAllowlisted;

  /// Holder-only half of the same phase: does this wallet own an NFT from the
  /// config's `collectionsOrCreators`? See
  /// [WhitelistEligibilityRepository.holdsGatingNft]. **null = unknown** and
  /// must not block.
  ///
  /// The two halves are ORed by [isWhitelistPhaseBlocked], exactly as the
  /// webapp does — either one qualifies the buyer. Both are distinct from
  /// [ArtworkDetails.offChainWhitelistDenied], which stays its own OR term.
  final bool? holdsGatingNft;

  /// Non-null when the listing must not be bought — sale window not open, or
  /// (for a 1/1 misrouted here by a master-edition override) a currency the
  /// single-tx builder rejects. See [ArtworkBuyBlock].
  final ArtworkBuyBlock? block;

  final ArtworkDetails artwork;

  /// Live wallet-cap + allowlist state from `MarketListingRepository`.
  /// Null until the fetch completes (or when the wallet isn't connected).
  final EditionPurchaseStats? purchaseStats;

  /// DAS-derived edition state. When present, its `supplyInfo` is used
  /// for the progress bar in preference to the indexed
  /// `quantitySold` / `quantityTotal` from `/byMint`.
  final EditionLiveState? editionState;

  final VoidCallback onBuyEdition;
  final VoidCallback onMakeOffer;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final buyNow = artwork.buyNowMetadata;
    // Prefer live DAS supply over the indexed snapshot when available —
    // the indexer can lag a few seconds during active mints.
    final liveSupply = editionState?.supplyInfo;
    final sold = liveSupply != null
        ? liveSupply.supply.toDouble()
        : artwork.quantitySold;
    final total = liveSupply?.maxSupply != null
        ? liveSupply!.maxSupply!.toDouble()
        : artwork.quantityTotal;
    final isOpenEdition = artwork.supplyType == SupplyType.openEdition;
    final showProgress =
        !isOpenEdition && sold != null && total != null && total > 0;
    final timingText = _editionTimingText(buyNow);
    final soldOut = !isOpenEdition && (total ?? 0) > 0 && sold == total;
    final notAllowlisted = artwork.offChainWhitelistDenied ?? false;
    final walletLimit = purchaseStats?.walletLimit ?? 0;
    final buyCount = purchaseStats?.buyCount ?? 0;
    final walletCapReached = walletLimit > 0 && buyCount >= walletLimit;
    final whitelistActive = purchaseStats?.whitelistConfig?.isActive ?? false;
    // The ON-CHAIN whitelist phase — the wallet allowlist and the
    // holder-only token gate ORed together, enforced only while the phase is
    // open (once it ends the listing is public). Both are separate from the
    // off-chain root below, which the webapp ORs in on top
    // (`EditionBox`).
    final whitelistBlocked = isWhitelistPhaseBlocked(
      phaseActive: whitelistActive,
      walletAllowlisted: onChainAllowlisted,
      holdsGatingNft: holdsGatingNft,
    );
    final String buyLabel;
    if (soldOut) {
      buyLabel = 'Sold out';
    } else if (block == ArtworkBuyBlock.notStarted) {
      // Sale-window gate: the countdown above used to be the *only*
      // signal, with an enabled Buy behind it building a tx that reverts.
      buyLabel = 'Sale not started';
    } else if (block == ArtworkBuyBlock.ended) {
      buyLabel = 'Sale ended';
    } else if (whitelistBlocked || notAllowlisted) {
      buyLabel = 'Not allowlisted';
    } else if (walletCapReached) {
      buyLabel = 'Wallet limit reached';
    } else {
      buyLabel = 'Buy edition';
    }
    final canBuy =
        !soldOut &&
        block == null &&
        !walletCapReached &&
        !whitelistBlocked &&
        !notAllowlisted;

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ArtworkSheetPriceRow(
                rawAmount: artwork.price,
                currencyMint: artwork.currency,
                buyerSetsPrice: buyNow?.buyerSetsPrice ?? false,
              ),
              const Spacer(),
              if (isOpenEdition && sold != null)
                Text(
                  '${formatCount(sold.toInt())} sold',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                )
              else if (sold != null && total != null)
                Text(
                  '${formatCount(sold.toInt())} / ${formatCount(total.toInt())} sold',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                )
              else if (sold != null)
                Text(
                  '${formatCount(sold.toInt())} sold',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: MallowTheme.spacingMd),
            ArtworkSheetSupplyProgress(sold: sold, total: total),
          ],
          if (timingText != null) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              timingText,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          ListingDisclosures(artwork: artwork),
          const SizedBox(height: MallowTheme.spacingMd),
          ArtworkFundingSource(
            currencyMint: artwork.currency,
            builder: (context, switching) =>
                BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
                  builder: (context, balanceState) {
                    final balanceResult = canBuy
                        ? checkBalanceOrSkip(
                            paymentMint: artwork.currency,
                            requiredRawAmount: artwork.price?.round(),
                            balanceState: balanceState,
                            // A print costs SOL beyond the listing price —
                            // asset rent + Metaplex protocol fee (+ ATA rent on
                            // the legacy standard). Webapp gates the buy on it
                            // (`useBuyNow`'s `requiredSolLamports`), and on
                            // an SPL-priced edition it is the *only* SOL the
                            // buyer needs, so a price-only gate saw none of it.
                            // The marketplace print fee is owed too but is only
                            // known once the on-chain config is read; the
                            // confirm sheet adds it. Quoting the fixed part
                            // here can only under-require, never false-block.
                            additionalSolLamports: editionPrintSolFeeLamports(
                              tokenStandard:
                                  editionState?.tokenStandard ??
                                  artwork.tokenStandard,
                            ),
                          )
                        : const BalanceCheckResult.sufficient();
                    return MallowButton(
                      label: buyLabel,
                      enabled: canBuy && !isLoading && !switching,
                      isLoading: isLoading && canBuy,
                      onPressed: !canBuy || isLoading
                          ? null
                          : () {
                              if (!ensureSufficientBalance(
                                context,
                                balanceResult,
                              )) {
                                return;
                              }
                              onBuyEdition();
                            },
                      isFullWidth: true,
                    );
                  },
                ),
          ),
          // TODO: Unhide when we support master edition offers.
          // const SizedBox(height: MallowTheme.spacingSm),
          // MallowButton(
          //   label: 'Make offer',
          //   variant: MallowButtonVariant.secondary,
          //   onPressed: isLoading ? null : onMakeOffer,
          //   isFullWidth: true,
          // ),
        ],
      ),
    );
  }

  /// Returns "Starts in …" before the sale opens, "Sale ends in …" while it
  /// runs, or null when the listing has no schedule.
  String? _editionTimingText(BuyNowMetadata? buyNow) {
    if (buyNow == null) return null;
    final now = DateTime.now();
    if (buyNow.startsAt != null && buyNow.startsAt!.isAfter(now)) {
      return 'Starts in ${_formatDuration(buyNow.startsAt!.difference(now))}';
    }
    if (buyNow.endsAt != null && buyNow.endsAt!.isAfter(now)) {
      return 'Sale ends in ${_formatDuration(buyNow.endsAt!.difference(now))}';
    }
    return null;
  }
}

String _formatDuration(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours.remainder(24)}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}
