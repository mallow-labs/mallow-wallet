import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/artwork_preview_header.dart';
import '../../../shared/widgets/fee_details_disclosure.dart';
import '../../../shared/widgets/generic_confirmation_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/transaction_confirmation_sheet_base.dart';
import '../../../shared/widgets/tx_cost_summary.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../services/market_bloc.dart';

/// Action types that transfer payment from the user — gated on balance.
/// `cancel-*`, `update-listing`, and `settle-auction` collect no payment, so
/// they're left alone (gas is enforced by the chain regardless).
const _balanceCheckedActions = {'buy', 'offer', 'bid'};

/// Rent the buyer prepays for the on-chain `Offer` PDA that `initOffer`
/// creates (mallow-market program). The account is `Offer::SPACE` = 326
/// bytes, so its rent-exempt minimum is (128 + 326) * 6960 = 3,160,640
/// lamports. Fully reclaimable: the PDA closes back to the buyer when the
/// offer is accepted or cancelled. SOL offers create no escrow token
/// account, so this is the only rent — and the app only makes SOL offers.
const _kOfferRentLamports = 3160640;

/// Raw amount the confirm step's balance gate must require, in
/// [MarketConfirmationSheet.totalCost]'s smallest unit. Null means "no payment
/// requirement" (the shared gate then only enforces the SOL gas reserve).
///
/// Updating an existing offer re-uses the `offer` action type, but the on-chain
/// `updateOffer` only moves the **difference** — the amount already escrowed in
/// the Offer PDA stays put. Requiring the full new amount in *free* balance
/// makes a legitimate raise impossible (5 SOL escrowed + 1.2 SOL free cannot
/// become 6 SOL), leaving cancel-and-re-offer — which forfeits queue position —
/// as the only route. Webapp parity: `useUpdateOffer` gates on
/// `balanceByMint[mint] > price - offer.price`, i.e. the delta alone, with no
/// fee or rent headroom added.
///
/// Lowering an offer refunds the difference, so the delta is negative and the
/// payment requirement clamps to zero. (Unlike the webapp, the shared
/// [BalanceCheckSpec] still applies the SOL gas reserve on top — a lowering
/// update is a transaction and does cost fees.)
///
/// SOL the confirm step's balance gate must require **on top of** the payment
/// and the gas reserve, in lamports.
///
/// An edition buy mints a fresh asset, so beyond the listing price the
/// buyer pays the standard's rent + Metaplex protocol fee (+ the buyer's ATA
/// rent on the legacy standard) and the flat marketplace print fee — the
/// 0.015–0.033 SOL webapp `useBuyNow` folds into `requiredSolLamports`.
/// These are SOL regardless of the listing currency, which is why they're a
/// separate term from [marketRequiredRawAmount]: on an SPL-priced edition they
/// are the *entire* SOL requirement, and the gate previously saw none of it.
///
/// [prepMallowFeeLamports] is `feeConfig.printFee × quantity`, read from the
/// on-chain marketplace config at prepare time — and doubles as the marker for
/// "this buy prints an edition" (null on every other action, including 1/1
/// buys, which mint nothing). [editionMintFeeLamports] is the per-print
/// rent/protocol part, quoted by the host from the master's token standard.
@visibleForTesting
int marketAdditionalSolLamports({
  required String actionType,
  required int? prepMallowFeeLamports,
  required int editionMintFeeLamports,
}) {
  if (actionType != 'buy' || prepMallowFeeLamports == null) return 0;
  return prepMallowFeeLamports + editionMintFeeLamports;
}

/// The subtraction is skipped when the escrowed offer is denominated in a
/// different mint than the new amount, since the two aren't comparable.
@visibleForTesting
int? marketRequiredRawAmount({
  required String actionType,
  required MarketPrice totalCost,
  MarketPrice? escrowedOfferAmount,
}) {
  if (!_balanceCheckedActions.contains(actionType)) return null;
  final total = totalCost.rawAmount.round();
  if (actionType != 'offer' || escrowedOfferAmount == null) return total;
  if (escrowedOfferAmount.effectiveCurrencyMint !=
      totalCost.effectiveCurrencyMint) {
    return total;
  }
  final delta = total - escrowedOfferAmount.rawAmount.round();
  return delta < 0 ? 0 : delta;
}

/// Bottom sheet for confirming any market transaction the bloc emits via
/// [MarketReadyToSign].
///
/// Shows transaction details, runs simulation, and allows user to confirm or cancel.
/// If simulation fails, shows warning but allows user to proceed anyway.
class MarketConfirmationSheet extends StatelessWidget {
  const MarketConfirmationSheet({
    required this.actionType,
    required this.mintAccount,
    required this.totalCost,
    required this.estimatedFeeLamports,
    required this.tokenBalanceBloc,
    super.key,
    this.artworkTitle,
    this.artworkImageUrl,
    this.artistUsername,
    this.artistName,
    this.creatorAddress,
    this.nsfw = false,
    this.isCollection = false,
    this.onConfirmed,
    this.escrowedOfferAmount,
    this.editionMintFeeLamports = 0,
  });

  /// When provided, the confirm tap dispatches `confirmAndSign` and then calls
  /// this instead of popping the route — used by single-route flow hosts that
  /// morph the confirm step into the in-flight pipeline step in place. When
  /// null, the sheet pops `true` so a separate-route host can take over.
  final VoidCallback? onConfirmed;

  /// True when [mintAccount] is a collection NFT. Only affects the burn
  /// copy: "Burn Collection" title/CTA plus the webapp's disclaimer that
  /// burning a collection leaves its member NFTs untouched.
  final bool isCollection;

  /// Passed explicitly (rather than read from context) so that callers
  /// opening this sheet via a modal route — where screen-scoped
  /// `BlocProvider`s aren't inherited — surface the dependency at compile
  /// time instead of throwing `ProviderNotFoundException` at mount.
  final TokenBalanceBloc tokenBalanceBloc;

  /// One of the action-type strings emitted by `MarketBloc` alongside
  /// [MarketReadyToSign]: `buy`, `offer`, `bid`, `accept-offer`,
  /// `cancel-offer`, `cancel-listing`, `update-listing`, `cancel-auction`,
  /// `reclaim-auction`, `settle-auction`.
  final String actionType;
  final String mintAccount;

  /// Listing-currency-denominated amount the user is committing to
  /// (purchase price, offer/bid amount, new listing price). Solana
  /// network fees ([estimatedFeeLamports]) are always in SOL regardless.
  final MarketPrice totalCost;
  final int estimatedFeeLamports;
  final String? artworkTitle;
  final String? artworkImageUrl;
  final String? artistUsername;
  final String? artistName;

  /// Update authority / signer address for the asset — truncated and shown
  /// as the final fallback when neither [artistUsername] nor [artistName]
  /// is available. Never falls back to the artwork's own mint address.
  final String? creatorAddress;

  /// Moderation flag for the header preview — blurs it (with an eye-icon
  /// reveal) unless the viewer's show-NSFW setting is on.
  final bool nsfw;

  /// The signer's *existing* offer on [mintAccount], when this `offer` confirm
  /// step is an update rather than a new offer. Its amount is already escrowed
  /// on-chain, so only the difference has to come out of free balance — see
  /// [marketRequiredRawAmount]. Null for a first offer and for every other
  /// action.
  final MarketPrice? escrowedOfferAmount;

  /// Per-print rent + Metaplex protocol fee (+ legacy ATA rent) this buy will
  /// spend in SOL, quoted by the host from the master's token standard via
  /// `editionPrintSolFeeLamports`. Folded into the balance gate together with
  /// the prepared print fee; see [marketAdditionalSolLamports]. Zero for every
  /// action that mints nothing.
  final int editionMintFeeLamports;

  @override
  Widget build(BuildContext context) {
    final copy = actionType == 'burn' && isCollection
        ? const _ActionCopy(
            title: 'Burn Collection',
            amountLabel: 'Network Fee',
            confirmLabel: 'Burn Collection',
          )
        : _ActionCopy.of(actionType);
    final showArtworkHeader = artworkTitle != null || artworkImageUrl != null;
    return TransactionConfirmationSheetBase<MarketBloc, MarketState>(
      title: copy.title,
      confirmLabel: copy.confirmLabel,
      confirmVariant: actionType == 'burn'
          ? MallowButtonVariant.danger
          : MallowButtonVariant.primary,
      tokenBalanceBloc: tokenBalanceBloc,
      onSimulate: (bloc) => bloc.add(const MarketEvent.simulate()),
      // Dispatch confirmAndSign, then either advance the host's morphing flow
      // to the pipeline step ([onConfirmed]) or pop `true` so a separate-route
      // host can open the pipeline sheet itself.
      onConfirm: (context, bloc) {
        bloc.add(const MarketEvent.confirmAndSign());
        final advance = onConfirmed;
        if (advance != null) {
          advance();
        } else {
          Navigator.of(context).pop(true);
        }
      },
      simulationFor: (state) {
        final prep = state is TxFlowReady<MarketPrepData, MarketSuccessData>
            ? state.data
            : null;
        // While the tx is still being built (sheet opened immediately on tap,
        // pre-`TxFlowReady`) keep the confirm button disabled and the banner
        // silent — same treatment as an in-flight simulation.
        final isPreparing =
            state is TxFlowPreparing<MarketPrepData, MarketSuccessData>;
        return SimulationBannerState(
          isSimulating: isPreparing || (prep?.isSimulating ?? false),
          result: prep?.simulationResult,
        );
      },
      balanceCheckFor: (state) => BalanceCheckSpec(
        paymentMint: totalCost.effectiveCurrencyMint,
        requiredRawAmount: marketRequiredRawAmount(
          actionType: actionType,
          totalCost: totalCost,
          escrowedOfferAmount: escrowedOfferAmount,
        ),
        additionalSolLamports: marketAdditionalSolLamports(
          actionType: actionType,
          prepMallowFeeLamports:
              state is TxFlowReady<MarketPrepData, MarketSuccessData>
              ? state.data.mallowFeeLamports
              : null,
          editionMintFeeLamports: editionMintFeeLamports,
        ),
      ),
      bodyBuilder: (context, state) {
        // Net SOL change for the payer once the tx executes — populated by
        // the bloc for actions that reclaim rent (burn). Already includes
        // the deducted tx fee.
        final prep = state is TxFlowReady<MarketPrepData, MarketSuccessData>
            ? state.data
            : null;
        final payerNetLamports = prep?.simulatedPayerLamportsDelta;
        final isSimulating = prep?.isSimulating ?? false;
        // Tx not built yet (sheet opened immediately on tap): shimmer the
        // headline + fee instead of rendering placeholder zeros.
        final isPreparing =
            state is TxFlowPreparing<MarketPrepData, MarketSuccessData>;
        return [
          if (showArtworkHeader) ...[
            ArtworkPreviewHeader(
              title: artworkTitle,
              imageUrl: artworkImageUrl,
              username: artistUsername,
              artistName: artistName,
              creatorAddress: creatorAddress,
              nsfw: nsfw,
            ),
            const SizedBox(height: MallowTheme.spacingLg),
          ],
          // Accept-offer "Direct all proceeds to creators" toggle (webapp
          // parity). Sits above the "You'll receive" breakdown. Toggling
          // dispatches [MarketEvent.setAcceptOfferSplit], which re-prepares the
          // accept from the bloc's stored args and re-simulates the rebuilt tx,
          // so the breakdown below shimmers and resolves in place. The toggle
          // caches its own gate/value so it stays visible (disabled) through the
          // re-prepare window (state → Preparing, prep → null) — the control the
          // user just tapped never vanishes, and it can't sign the old tx.
          if (actionType == 'accept-offer')
            _AcceptOfferSplitToggle(
              prep: prep,
              isSimulating: isSimulating,
              isPreparing: isPreparing,
            ),
          if (actionType == 'burn') ...[
            _buildBurnBreakdown(
              context,
              estimatedFeeLamports: estimatedFeeLamports,
              payerNetLamports: payerNetLamports,
              isSimulating: isSimulating,
              isPreparing: isPreparing,
            ),
            // Webapp parity (BurnModal): burning a collection only
            // burns the Collection NFT — minted member NFTs survive.
            if (isCollection) ...[
              const SizedBox(height: MallowTheme.spacingMd),
              Text(
                'Burning a collection does not burn the NFTs minted '
                'within it, just the collection NFT. This cannot be '
                'undone.',
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ],
          ] else if (prep?.settleProceeds case final proceeds?)
            // Seller-side payouts (auction settle, accept-offer) split the
            // escrowed amount into mallow fee + creator royalties + the
            // seller's take. The headline shows the net "You'll receive" and a
            // "Fee details" disclosure itemises the deductions; the amounts come
            // from the tx simulation, so they shimmer until it lands.
            _buildSettleBreakdown(
              context,
              proceeds,
              estimatedFeeLamports,
              grossLabel: actionType == 'accept-offer'
                  ? 'Offer amount'
                  : 'Winning bid',
            )
          else if (isPreparing &&
              totalCost.rawAmount > 0 &&
              (actionType == 'settle-auction' || actionType == 'accept-offer'))
            // Same seller payout, but the tx is still being built (sheet opened
            // immediately on tap), so the proceeds aren't resolved yet. Render
            // the *same* settle layout with the gross we already know and the
            // earnings + fee shimmering, so it fills in place once the
            // simulation lands — no display swap.
            _buildSettleBreakdown(
              context,
              SettleProceeds(
                grossBidRaw: totalCost.rawAmount.round(),
                currencyMint: totalCost.currencyMint,
              ),
              estimatedFeeLamports,
              grossLabel: actionType == 'accept-offer'
                  ? 'Offer amount'
                  : 'Winning bid',
              isPreparing: true,
            )
          else if (actionType == 'settle-auction')
            // Winner-claim (same ix) and no-bid reclaim carry no proceeds data
            // and fall back to the gas-only "Network Fee" row — settling
            // collects no payment from them, the escrowed bid is already
            // on-chain, so only gas is left to pay.
            TxCostSummary(
              lines: [
                if (isPreparing)
                  TxCostLine.shimmer(label: 'Network Fee')
                else
                  TxCostLine.lamports(
                    label: 'Network Fee',
                    lamports: estimatedFeeLamports,
                    sign: '-',
                  ),
              ],
            )
          else if (actionType == 'cancel-auction' ||
              actionType == 'reclaim-auction')
            // Cancelling an auction (or reclaiming the NFT after a no-bid
            // expiry) collects no payment — it just returns the NFT to the
            // seller — so the reserve price is irrelevant. Only gas is left to
            // pay: show a single "Network fee" row (red, outgoing), no
            // reserve-price headline and no "Fee details" split.
            TxCostSummary(
              lines: [
                if (isPreparing)
                  TxCostLine.shimmer(label: 'Network fee')
                else
                  TxCostLine.lamports(
                    label: 'Network fee',
                    lamports: estimatedFeeLamports,
                    sign: '-',
                    valueColor: context.mallowColors.negative,
                  ),
              ],
            )
          else if (prep?.mallowFeeLamports != null)
            // Edition buys carry a flat "mallow fee" (the on-chain print fee)
            // on top of the listing price; the rest of the SOL cost (rent +
            // protocol + tx fee) is estimated from the payer-balance delta.
            _buildEditionBreakdown(
              context,
              totalCost,
              estimatedFeeLamports,
              prep!,
            )
          else
            _buildPriceBreakdown(
              context,
              totalCost,
              estimatedFeeLamports,
              copy,
              actionType,
              isPreparing: isPreparing,
            ),
        ];
      },
    );
  }
}

/// The accept-offer "Direct all proceeds to creators" checkbox, split into its
/// own stateful widget so it can cache the last resolved gate + value. During a
/// toggle's re-prepare the bloc state is [TxFlowPreparing] (prep == null), so
/// without a cache the checkbox — the very control the user tapped — would
/// unmount for the whole round-trip. Caching keeps it visible (disabled) until
/// the rebuilt [TxFlowReady] lands.
class _AcceptOfferSplitToggle extends StatefulWidget {
  const _AcceptOfferSplitToggle({
    required this.prep,
    required this.isSimulating,
    required this.isPreparing,
  });

  /// The current ready prep, or null while a (re-)prepare is in flight.
  final MarketPrepData? prep;
  final bool isSimulating;
  final bool isPreparing;

  @override
  State<_AcceptOfferSplitToggle> createState() =>
      _AcceptOfferSplitToggleState();
}

class _AcceptOfferSplitToggleState extends State<_AcceptOfferSplitToggle> {
  bool _visible = false;
  bool _disablePrimarySplit = true;

  @override
  Widget build(BuildContext context) {
    final prep = widget.prep;
    // Refresh the cache from every resolved prep; keep the last values while
    // preparing (prep == null) so the control survives the re-prepare window.
    if (prep != null) {
      _visible = prep.showDirectProceedsOption;
      _disablePrimarySplit = prep.disablePrimarySplit;
    }
    if (!_visible) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacingMd),
      child: MallowCheckbox(
        value: !_disablePrimarySplit,
        label: 'Direct all proceeds to creators',
        // Disabled while the tx is (re)building or simulating — a toggle is
        // only actionable from a resolved ready state.
        enabled: !widget.isSimulating && !widget.isPreparing,
        onChanged: (directToCreators) => context.read<MarketBloc>().add(
          MarketEvent.setAcceptOfferSplit(
            disablePrimarySplit: !directToCreators,
          ),
        ),
      ),
    );
  }
}

/// Per-action copy: title, the in-card amount label, the confirm CTA, and
/// the always-visible aggregate label above the fee disclosure.
class _ActionCopy {
  const _ActionCopy({
    required this.title,
    required this.amountLabel,
    required this.confirmLabel,
    this.totalLabel = 'Total cost',
    this.sumsFeeIntoTotal = true,
  });

  final String title;
  final String amountLabel;
  final String confirmLabel;
  final String totalLabel;

  /// True when the user pays the amount, so the SOL network fee folds into
  /// the headline total. False for seller-side actions (accept-offer) where
  /// the amount is received and the fee is only gas — folding it in would
  /// overstate the proceeds.
  final bool sumsFeeIntoTotal;

  static const _byType = <String, _ActionCopy>{
    'buy': _ActionCopy(
      title: 'Confirm Purchase',
      amountLabel: 'Price',
      confirmLabel: 'Buy Now',
    ),
    // The confirm step of the Make Offer flow.
    'offer': _ActionCopy(
      title: 'Make Offer',
      amountLabel: 'Offer Amount',
      confirmLabel: 'Place Offer',
      totalLabel: 'Total Offer',
    ),
    'bid': _ActionCopy(
      title: 'Confirm Bid',
      amountLabel: 'Bid Amount',
      confirmLabel: 'Place Bid',
    ),
    // Mirrors the make-offer confirm step from the seller's side.
    'accept-offer': _ActionCopy(
      title: 'Accept Offer',
      amountLabel: 'Offer Amount',
      confirmLabel: 'Accept Offer',
      totalLabel: "You'll receive",
      sumsFeeIntoTotal: false,
    ),
    'cancel-offer': _ActionCopy(
      title: 'Cancel Offer',
      amountLabel: 'Offer Amount',
      confirmLabel: 'Cancel Offer',
      totalLabel: 'Total returned',
    ),
    'cancel-listing': _ActionCopy(
      title: 'Cancel Listing',
      amountLabel: 'Listing Price',
      confirmLabel: 'Cancel Listing',
    ),
    'update-listing': _ActionCopy(
      title: 'Update Listing',
      amountLabel: 'New Price',
      confirmLabel: 'Update Listing',
    ),
    'cancel-auction': _ActionCopy(
      title: 'Cancel Auction',
      amountLabel: 'Reserve Price',
      confirmLabel: 'Cancel Auction',
    ),
    // Same on-chain ix as cancel-auction; separate copy for the seller
    // reclaiming their NFT after a no-bid auction expires. Gas-only, so
    // amountLabel is unused (the sheet renders the Network fee row directly).
    'reclaim-auction': _ActionCopy(
      title: 'Reclaim NFT',
      amountLabel: 'Network fee',
      confirmLabel: 'Reclaim NFT',
    ),
    'settle-auction': _ActionCopy(
      title: 'Settle Auction',
      amountLabel: 'Winning Bid',
      confirmLabel: 'Settle',
    ),
    'burn': _ActionCopy(
      title: 'Burn Artwork',
      amountLabel: 'Network Fee',
      confirmLabel: 'Burn Artwork',
    ),
  };

  /// Falls back to the offer copy for unknown types — matches the original
  /// behavior when only `buy` was branched.
  static _ActionCopy of(String actionType) =>
      _byType[actionType] ?? _byType['offer']!;
}

/// Burn-specific breakdown: a fee row plus, when simulation has produced
/// a payer-balance delta, a "you'll receive" line summarising the SOL
/// reclaimed from the closed metadata / token / edition accounts.
///
/// [payerNetLamports] is the *signed* net change (post − pre) the bloc
/// derives from the simulation; the fee is already deducted from that
/// number. We add the fee back when displaying the gross "Rent reclaimed"
/// figure so the breakdown reads:
///
///     Network fee:        ~0.000005 SOL
///     Rent reclaimed:     ~0.0021 SOL
///     ───────────────
///     You'll receive:     ~0.002095 SOL
///
/// When the simulation hasn't produced a delta yet (`null`), fall back
/// to a single fee row + spinner. When the net is non-positive (rare:
/// only happens if the asset has no rent left to reclaim), fall back
/// to the same fee-only layout to avoid showing a misleading negative
/// "you'll receive" figure.
TxCostSummary _buildBurnBreakdown(
  BuildContext context, {
  required int estimatedFeeLamports,
  required int? payerNetLamports,
  required bool isSimulating,
  // True when the tx is still being built (sheet opened immediately on tap,
  // pre-`TxFlowReady`): the fee isn't known yet, so shimmer it instead of
  // rendering a placeholder "0" — matches every other action's preparing state.
  bool isPreparing = false,
}) {
  final feeLine = isPreparing
      ? TxCostLine.shimmer(label: 'Network fee')
      : TxCostLine.lamports(
          label: 'Network fee',
          lamports: estimatedFeeLamports,
          sign: '-',
        );
  if (payerNetLamports == null || payerNetLamports <= 0) {
    return TxCostSummary(
      lines: [
        feeLine,
        if (isSimulating)
          TxCostLine.text(label: 'Estimating SOL refund…', value: ''),
      ],
    );
  }

  // payerNetLamports is signed and already includes the fee. Adding the
  // fee back gives the gross rent figure the user actually reclaims.
  final grossReclaimLamports = payerNetLamports + estimatedFeeLamports;
  return TxCostSummary(
    lines: [
      feeLine,
      TxCostLine.lamports(
        label: 'Rent reclaimed',
        lamports: grossReclaimLamports,
      ),
    ],
    total: TxCostLine.lamports(
      label: "You'll receive",
      lamports: payerNetLamports,
      sign: '+',
      valueColor: context.mallowColors.positive,
    ),
  );
}

/// Renders the cost section per the QA redesign: the
/// aggregate "Total cost" stays visible while the per-line Price /
/// Network Fee breakdown collapses into a "Fee details" disclosure.
///
/// SOL listings sum price + fee into the total. Non-SOL listings show
/// the price as the total because "X USDC + Y SOL fee" can't be summed
/// into one number — the SOL fee still appears inside the disclosure,
/// mirroring the webapp's split breakdown.
Widget _buildPriceBreakdown(
  BuildContext context,
  MarketPrice totalCost,
  int estimatedFeeLamports,
  _ActionCopy copy,
  String actionType, {
  // True when the tx is still being prepared (the sheet was opened immediately
  // on tap, before `TxFlowReady`): the headline + network-fee values aren't
  // known yet, so render them as loading skeletons.
  bool isPreparing = false,
}) {
  final listingCurrency = totalCost.effectiveCurrencyMint;
  final isSolListing = listingCurrency == solMint;
  // Cancelling an offer is the one inflow case here: the closed Offer PDA
  // returns the escrowed offer amount plus its prepaid rent to the buyer,
  // so the headline reads as money received (green, "+"). A SOL offer
  // escrows the amount in lamports alongside the rent, so both sum into one
  // SOL headline; a token offer escrows the amount in a token account — a
  // different currency from the SOL rent — so the headline shows just the
  // refunded token amount and the rent stays in its own "+" disclosure line.
  final isCancelOffer = actionType == 'cancel-offer';

  final double headlineAmount;
  if (isCancelOffer) {
    headlineAmount = isSolListing
        ? totalCost.rawAmount + _kOfferRentLamports
        : totalCost.rawAmount;
  } else if (isSolListing && copy.sumsFeeIntoTotal) {
    headlineAmount = totalCost.rawAmount + estimatedFeeLamports.toDouble();
  } else {
    headlineAmount = totalCost.rawAmount;
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TxCostSummary(
        lines: [
          if (isPreparing)
            TxCostLine.shimmer(label: copy.totalLabel)
          else
            TxCostLine.tokenAmount(
              label: copy.totalLabel,
              rawAmount: headlineAmount,
              currencyMint: listingCurrency,
              sign: isCancelOffer ? '+' : '',
              valueColor: isCancelOffer
                  ? context.mallowColors.positive
                  : context.mallowColors.accent,
            ),
        ],
      ),
      const SizedBox(height: MallowTheme.spacingMd),
      FeeDetailsDisclosure(
        child: TxCostSummary(
          card: false,
          lineStyle: MallowTheme.uiCaption,
          lines: [
            TxCostLine.tokenAmount(
              label: copy.amountLabel,
              rawAmount: totalCost.rawAmount,
              currencyMint: listingCurrency,
            ),
            if (isPreparing)
              TxCostLine.shimmer(label: 'Network Fee')
            else
              TxCostLine.lamports(
                label: 'Network Fee',
                lamports: estimatedFeeLamports,
                sign: '-',
              ),
            // Making an offer opens an on-chain Offer PDA the buyer funds
            // upfront; it's returned when the offer is accepted or
            // cancelled, hence "reclaimable".
            if (actionType == 'offer')
              TxCostLine.lamports(
                label: 'Solana rent (reclaimable)',
                lamports: _kOfferRentLamports,
                sign: '-',
              )
            // Cancelling closes that same Offer PDA, returning its rent to
            // the buyer — shown as an incoming "+" line.
            else if (actionType == 'cancel-offer')
              TxCostLine.lamports(
                label: 'Solana rent (returned)',
                lamports: _kOfferRentLamports,
                sign: '+',
                valueColor: context.mallowColors.positive,
              ),
          ],
        ),
      ),
    ],
  );
}

/// Edition-buy cost breakdown. Unlike a 1/1 buy, an edition mint charges a
/// flat on-chain "mallow fee" (`feeConfig.printFee`) on top of the listing
/// price, plus account rent the buyer prepays for the freshly-minted print.
/// To stay consistent with the webapp's `EditionFeesBox`, the print fee gets
/// its own "mallow fee" line; everything else (rent + protocol + tx fee)
/// collapses into "Network fee", estimated from the simulated payer-balance
/// delta and falling back to the static base fee until the simulation lands.
///
/// The delta is the net SOL the payer spends (always negative here). For SOL
/// listings it includes the listing price, so we subtract the price and the
/// mallow fee to isolate the network cost; for token listings (USDC, etc.)
/// the price is paid in the token, so only the mallow fee is subtracted.
Widget _buildEditionBreakdown(
  BuildContext context,
  MarketPrice totalCost,
  int estimatedFeeLamports,
  MarketPrepData prep,
) {
  final mallowFeeLamports = prep.mallowFeeLamports!;
  final listingCurrency = totalCost.effectiveCurrencyMint;
  final isSolListing = listingCurrency == solMint;
  final delta = prep.simulatedPayerLamportsDelta;
  // While the simulation is in flight (no delta yet) show shimmers; once it
  // lands — or if it never produces a delta — use the derived/fallback value.
  final showLoader = prep.isSimulating && delta == null;

  final priceSolLamports = isSolListing ? totalCost.rawAmount.round() : 0;
  final int networkLamports;
  if (delta != null) {
    final derived = -delta - priceSolLamports - mallowFeeLamports;
    networkLamports = derived < 0 ? 0 : derived;
  } else {
    networkLamports = estimatedFeeLamports;
  }

  // SOL listings fold every cost into one headline; token listings can't sum
  // "X USDC + Y SOL", so the headline stays the token price and the SOL fees
  // live in the disclosure (mirrors [_buildPriceBreakdown]).
  final headlineAmount = isSolListing
      ? totalCost.rawAmount + mallowFeeLamports + networkLamports
      : totalCost.rawAmount;
  final headlineCurrency = isSolListing ? solMint : listingCurrency;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TxCostSummary(
        lines: [
          if (showLoader)
            TxCostLine.shimmer(label: 'Total cost')
          else
            TxCostLine.tokenAmount(
              label: 'Total cost',
              rawAmount: headlineAmount,
              currencyMint: headlineCurrency,
              valueColor: context.mallowColors.accent,
            ),
        ],
      ),
      const SizedBox(height: MallowTheme.spacingMd),
      FeeDetailsDisclosure(
        child: TxCostSummary(
          card: false,
          lineStyle: MallowTheme.uiCaption,
          lines: [
            TxCostLine.tokenAmount(
              label: 'Price',
              rawAmount: totalCost.rawAmount,
              currencyMint: listingCurrency,
            ),
            TxCostLine.lamports(
              label: 'mallow fee',
              lamports: mallowFeeLamports,
              sign: '-',
            ),
            if (showLoader)
              TxCostLine.shimmer(label: 'Network fee')
            else
              TxCostLine.lamports(
                label: 'Network fee',
                lamports: networkLamports,
                sign: '-',
              ),
          ],
        ),
      ),
    ],
  );
}

/// Seller-side payout breakdown (auction settle, accept-offer) — the buyer's
/// [_buildEditionBreakdown] inverted. The escrowed amount ([grossLabel]:
/// "Winning bid" for a settle, "Offer amount" for an accept) is split on-chain
/// into the mallow fee, creator royalties, and the seller's proceeds; the
/// headline shows what the seller nets and the disclosure itemises the
/// deductions. The amounts are resolved from the tx simulation (fee bps can't
/// be re-derived reliably client-side), so they shimmer until
/// [SettleProceeds.isResolved]. The network fee is the seller's gas, shown as a
/// separate SOL deduction (it isn't folded into the payout-currency total,
/// which may not be SOL). Royalties are listed only when some go to *other*
/// creators — the seller's own cut is already in the headline.
Widget _buildSettleBreakdown(
  BuildContext context,
  SettleProceeds proceeds,
  int estimatedFeeLamports, {
  String grossLabel = 'Winning bid',
  // True when the tx is still being prepared: the network fee isn't known yet
  // either, so render it as a skeleton too (the earnings + mallow fee already
  // shimmer off the unresolved proceeds).
  bool isPreparing = false,
}) {
  final mint = proceeds.currencyMint;
  final resolved = proceeds.isResolved;
  final royaltiesToOthers = proceeds.royaltiesToOthersRaw ?? 0;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TxCostSummary(
        lines: [
          if (resolved)
            TxCostLine.tokenAmountPrecise(
              label: "You'll receive",
              rawAmount: proceeds.sellerEarningsRaw!.toDouble(),
              currencyMint: mint,
              sign: '+',
              valueColor: context.mallowColors.positive,
            )
          else
            TxCostLine.shimmer(label: "You'll receive"),
        ],
      ),
      const SizedBox(height: MallowTheme.spacingMd),
      FeeDetailsDisclosure(
        child: TxCostSummary(
          card: false,
          lineStyle: MallowTheme.uiCaption,
          lines: [
            TxCostLine.tokenAmountPrecise(
              label: grossLabel,
              rawAmount: proceeds.grossBidRaw.toDouble(),
              currencyMint: mint,
            ),
            if (resolved)
              TxCostLine.tokenAmountPrecise(
                label: 'mallow fee',
                rawAmount: proceeds.marketFeeRaw!.toDouble(),
                currencyMint: mint,
                sign: '-',
              )
            else
              TxCostLine.shimmer(label: 'mallow fee'),
            if (resolved && royaltiesToOthers > 0)
              TxCostLine.tokenAmountPrecise(
                label: 'Creator royalties',
                rawAmount: royaltiesToOthers.toDouble(),
                currencyMint: mint,
                sign: '-',
              ),
            if (isPreparing)
              TxCostLine.shimmer(label: 'Network fee')
            else
              TxCostLine.lamports(
                label: 'Network fee',
                lamports: estimatedFeeLamports,
                sign: '-',
              ),
          ],
        ),
      ),
    ],
  );
}
