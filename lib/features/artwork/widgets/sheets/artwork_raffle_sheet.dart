import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/config/store_build.dart';
import '../../../../core/data/mallow_tokens.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/artwork_web_link.dart';
import '../../../../shared/utils/balance_check.dart';
import '../../../../shared/utils/price_format.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../../../shared/widgets/user_handle_text.dart';
import '../../../portfolio/services/token_balance_bloc.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_funding_source.dart';
import 'artwork_sheet_frame.dart';

/// Coarse role of the connected wallet relative to a raffle.
///
/// [RaffleRole.owner] is the raffle's **creator**, not the indexed NFT owner:
/// while a raffle is live the prize sits in the raffle escrow, so the creator
/// is frequently not the owner of record. The webapp derives it the same way
/// (`raffleStateDerivation` —
/// `creator = raffleMetadata.creator`, `isUserOwner = userAddresses.includes(creator)`).
enum RaffleRole { buyer, owner, winner, observer }

/// Sub-state of the raffle lifecycle.
///
/// Port of the webapp's `deriveRaffleState`
/// (`raffleStateDerivation`; the hook
/// `useRaffleState` at `useRaffleState` is a thin wrapper over it).
/// Every terminal phase has its own value — collapsing them is how a finished
/// raffle ended up rendering a live "Buy tickets" CTA and how the
/// expired-unsold case rendered an empty sheet, stranding the creator's NFT in
/// raffle escrow with no way to reclaim it on mobile.
enum RaffleSubState {
  /// Sale window open (`nowMs < endsAt` — webapp `deriveIsActive`,
  /// `raffleStateDerivation`). Tickets may still be sold out; see
  /// [RaffleGate.isSoldOut].
  selling,

  /// Window closed, tickets were sold, the draw hasn't run yet — webapp
  /// `isAwaitingDraw` (`raffleStateDerivation`).
  awaitingDraw,

  /// Winner drawn, prize not yet transferred — webapp `isNftClaimable`'s
  /// winner arm (`raffleStateDerivation`).
  drawnUnclaimed,

  /// Winner drawn **and** the prize already claimed. Terminal for the winner;
  /// the creator may still have proceeds to collect, which is why the webapp's
  /// `isProceedsClaimable` (`raffleStateDerivation`) does not consult
  /// `isPrizeClaimed`. This used to fall through to [selling] — a finished
  /// raffle showing "Buy tickets".
  drawnClaimed,

  /// Window closed with zero tickets sold. The webapp calls this "expired"
  /// (`endTimestamp < now && numberSold === 0`) and routes the prize back to
  /// the creator (`claimPrize`). Rendering nothing here
  /// is what made creator reclaim unreachable on mobile.
  endedCancelled,
}

/// Buy-side gates for a raffle, derived once by
/// `resolveArtworkActionState` so the sheet renders and the CTA agrees.
///
/// Ports the webapp's `deriveRaffleState`
/// (`raffleStateDerivation`) and
/// `raffleWalletLimit` (`nft`).
@immutable
class RaffleGate {
  const RaffleGate({
    this.canBuyTickets = false,
    this.isSoldOut = false,
    this.walletLimit = 0,
    this.userTickets = 0,
    this.ticketsRemaining,
  });

  /// Webapp `canBuyTicket` (`raffleStateDerivation`):
  /// `supply != null && userTickets < walletLimit && !isUserOwner &&
  /// isActive && !isSoldOut`.
  final bool canBuyTickets;

  /// `sold >= supply` (`raffleStateDerivation`).
  final bool isSoldOut;

  /// Per-wallet ticket ceiling — the program's 40%-of-supply cap, narrowed by
  /// a configured `ticketLimit`.
  final int walletLimit;

  /// Tickets already held by the session's wallets, from `countByEntrant`.
  final int userTickets;

  /// `supply - sold`. Null when the raffle reports no supply.
  final int? ticketsRemaining;
}

/// Bottom sheet for raffle listings.
///
/// Ticket purchase itself is **not** an in-app transaction: the primary CTA
/// links out to mallow.art (see [kShowRaffleEntry]). Everything else — the
/// lifecycle copy, the numbers, the cancel / claim / reclaim CTAs — is
/// resolved here from `raffleMetadata` + [gate].
///
/// Triggered by `raffle` (any role) — see `docs/artwork_state.md`.
class ArtworkRaffleSheet extends StatelessWidget {
  const ArtworkRaffleSheet({
    required this.artwork,
    required this.role,
    required this.subState,
    required this.onBuyTickets,
    required this.onCancelRaffle,
    required this.onClaimNft,
    required this.onClaimProceeds,
    this.raffle,
    this.gate = const RaffleGate(),
    this.winnerUsername,
    this.isLoading = false,
    super.key,
  });

  final ArtworkDetails artwork;
  final RaffleRole role;
  final RaffleSubState subState;

  /// Raffle facts to render, already merged with the live PDA snapshot by the
  /// dispatcher. Falls back to the indexed `artwork.raffleMetadata`.
  final RaffleMetadata? raffle;
  final RaffleGate gate;

  /// Resolved mallow username for `raffleMetadata.winner`. Renders as
  /// `@handle` in the drawn sub-states.
  final String? winnerUsername;

  /// Opens the ticket-count input flow on the screen side, then dispatches
  /// `RaffleEvent.buyTickets`.
  ///
  /// Only invoked when [kShowRaffleEntry] is on — store builds render a
  /// "View on mallow.art" outlink in place of the buy CTA.
  final VoidCallback onBuyTickets;
  final VoidCallback onCancelRaffle;
  final VoidCallback onClaimNft;
  final VoidCallback onClaimProceeds;
  final bool isLoading;

  RaffleMetadata? get _raffle => raffle ?? artwork.raffleMetadata;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final raffle = _raffle;
    final showWinner =
        (subState == RaffleSubState.drawnUnclaimed ||
            subState == RaffleSubState.drawnClaimed) &&
        role != RaffleRole.winner &&
        raffle?.winner != null;

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _statusLine(),
            style: MallowTheme.uiBody.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _summaryLine(),
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          if (showWinner) ...[
            const SizedBox(height: 4),
            UserHandleText(
              prefix: 'Winner: ',
              username: winnerUsername,
              address: raffle!.winner,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: MallowTheme.spacingMd),
          ..._buildButtons(context),
        ],
      ),
    );
  }

  /// "Ticket price: 0.1 SOL · 12 / 50 sold · Wallet limit: 20".
  ///
  /// `raffleMetadata.price` is **raw base units** (`priceRaw`), so it goes
  /// through the token's decimals exactly like the webapp's `formatPrice`
  /// (`tokens`). Rendering it directly
  /// turned a 0.1 SOL ticket into "100000000 SOL".
  String _summaryLine() {
    final raffle = _raffle;
    final parts = <String>['Ticket price: ${_ticketPriceLabel()}'];
    final sold = formatCount(raffle?.sold ?? 0);
    final supply = raffle?.supply;
    parts.add(
      supply != null ? '$sold / ${formatCount(supply)} sold' : '$sold sold',
    );
    if (gate.walletLimit > 0) {
      parts.add('Wallet limit: ${formatCount(gate.walletLimit)}');
    }
    if (gate.userTickets > 0) {
      parts.add('Your tickets: ${formatCount(gate.userTickets)}');
    }
    return parts.join('   ·   ');
  }

  String _ticketPriceLabel() {
    final raffle = _raffle;
    final raw = raffle?.priceRaw;
    if (raw == null) return '--';
    final token = tokenByMint(raffle?.currencyMint ?? solMint);
    if (token == null) return '--';
    return '${displayDecimal(token.rawToDisplay(raw.round()))} ${token.symbol}';
  }

  String _statusLine() {
    switch (subState) {
      case RaffleSubState.selling:
        if (role == RaffleRole.owner) return 'Your raffle is live';
        if (gate.isSoldOut) return 'Sold out';
        // Without in-app entry the old copy ("Buy tickets for a chance to
        // win") is a call to action into a paid prize draw, which a store
        // build must not carry.
        return kShowRaffleEntry
            ? 'Buy tickets for a chance to win'
            : 'Raffle in progress';
      case RaffleSubState.awaitingDraw:
        return 'Awaiting draw';
      case RaffleSubState.drawnUnclaimed:
        if (role == RaffleRole.winner) return 'You won!';
        if (role == RaffleRole.owner) return 'Raffle drawn — proceeds pending';
        return 'Raffle drawn';
      case RaffleSubState.drawnClaimed:
        if (role == RaffleRole.winner) return 'You claimed your prize';
        if (role == RaffleRole.owner) return 'Raffle drawn — prize claimed';
        return 'Raffle drawn';
      case RaffleSubState.endedCancelled:
        return 'Raffle ended — no tickets sold';
    }
  }

  Future<void> _openOnWeb() => openArtworkOnWeb(artwork.mintAccount);

  Widget _viewOnWebButton() => MallowButton(
    label: 'View on mallow.art',
    variant: MallowButtonVariant.secondary,
    onPressed: _openOnWeb,
    isFullWidth: true,
  );

  List<Widget> _buildButtons(BuildContext context) {
    final raffle = _raffle;
    final hasTickets = (raffle?.sold ?? 0) > 0;
    final prizeClaimed = raffle?.isPrizeClaimed ?? false;
    final proceedsClaimed = raffle?.isClaimed ?? false;
    switch (subState) {
      case RaffleSubState.selling:
        if (role == RaffleRole.owner) {
          // Webapp `canCancel` (`raffleStateDerivation`):
          // `isUserOwner && isActive && sold === 0`.
          return [
            MallowButton(
              label: hasTickets
                  ? 'Cancel unavailable (tickets sold)'
                  : 'Cancel raffle',
              variant: MallowButtonVariant.secondary,
              enabled: !hasTickets && !isLoading,
              onPressed: hasTickets || isLoading ? null : onCancelRaffle,
              isFullWidth: true,
            ),
          ];
        }
        if (!gate.canBuyTickets) {
          // Sold out, wallet limit reached, or no supply reported. No live buy
          // affordance — the webapp hard-disables the same way
          // (`BuyTicketsModal` `isBuyDisabled`).
          return [
            MallowButton(
              label: gate.isSoldOut ? 'Sold out' : 'Tickets unavailable',
              enabled: false,
              onPressed: null,
              isFullWidth: true,
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            _viewOnWebButton(),
          ];
        }
        if (!kShowRaffleEntry) {
          // Store builds ship no in-app raffle entry: the buy CTA — and
          // the funding-source switch that only exists to pay for tickets —
          // are replaced by an outlink to the artwork on the web.
          return [_viewOnWebButton()];
        }
        return [
          // Tickets are funded in the raffle's own currency.
          ArtworkFundingSource(
            currencyMint: raffle?.currencyMint,
            builder: (context, switching) =>
                BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
                  builder: (context, balanceState) {
                    final mint = raffle?.currencyMint ?? solMint;
                    // `priceRaw` is already in base units — the old
                    // `displayToRaw(price)` scaled it a second time and
                    // demanded 1e17 lamports for a 0.1 SOL ticket.
                    final requiredRaw = raffle?.priceRaw?.round();
                    final result = checkBalanceOrSkip(
                      paymentMint: mint,
                      requiredRawAmount: requiredRaw,
                      balanceState: balanceState,
                    );
                    return MallowButton(
                      label: 'Buy tickets',
                      enabled: !switching,
                      onPressed: isLoading
                          ? null
                          : () {
                              if (!ensureSufficientBalance(context, result)) {
                                return;
                              }
                              onBuyTickets();
                            },
                      isLoading: isLoading,
                      isFullWidth: true,
                    );
                  },
                ),
          ),
        ];
      case RaffleSubState.awaitingDraw:
        return [
          // Not an action — a status line rendered in the button slot: the
          // raffle has sold out / expired and nobody can do anything until
          // the draw lands. The label carries the explanation, so there is
          // deliberately no handler and no `onDisabledTap`; `onPressed` is a
          // required parameter, hence the explicit null.
          const MallowButton(
            label: 'Draw pending…',
            enabled: false,
            onPressed: null,
            isFullWidth: true,
          ),
        ];
      case RaffleSubState.drawnUnclaimed:
        if (role == RaffleRole.winner) {
          return [
            MallowButton(
              label: 'Claim NFT',
              onPressed: isLoading ? null : onClaimNft,
              isLoading: isLoading,
              isFullWidth: true,
            ),
          ];
        }
        if (role == RaffleRole.owner) {
          // The prize belongs to the winner — the creator only collects
          // proceeds. Webapp `isNftClaimable`
          // (`raffleStateDerivation`) gives the creator the prize
          // arm ONLY when `sold === 0`, which is [endedCancelled] below; the
          // "Reclaim NFT" button this used to render here would have been
          // rejected by the backend ("Creator can only reclaim the prize
          // after a no-bid expiry").
          return [_claimProceedsButton(claimed: proceedsClaimed)];
        }
        return const [];
      case RaffleSubState.drawnClaimed:
        // Webapp `isProceedsClaimable` (`raffleStateDerivation`) is
        // `!isActive && isUserOwner && winner != null` — it does not consult
        // `isPrizeClaimed`, so the creator's payout survives the winner
        // collecting the NFT.
        if (role == RaffleRole.owner) {
          return [_claimProceedsButton(claimed: proceedsClaimed)];
        }
        return const [];
      case RaffleSubState.endedCancelled:
        // Expired unsold: the prize returns to the creator
        // (`claimPrize`, mirrored by the server's own reclaim arm). This arm
        // rendered nothing before, so a creator could not get their NFT out
        // of raffle escrow from the app at all.
        if (role == RaffleRole.owner) {
          return [
            MallowButton(
              label: prizeClaimed ? 'NFT reclaimed' : 'Reclaim NFT',
              enabled: !prizeClaimed && !isLoading,
              onPressed: prizeClaimed || isLoading ? null : onClaimNft,
              isLoading: isLoading,
              isFullWidth: true,
            ),
          ];
        }
        return const [];
    }
  }

  Widget _claimProceedsButton({required bool claimed}) => MallowButton(
    label: claimed ? 'Proceeds claimed' : 'Claim proceeds',
    variant: MallowButtonVariant.secondary,
    enabled: !claimed && !isLoading,
    onPressed: claimed || isLoading ? null : onClaimProceeds,
    isFullWidth: true,
  );
}
