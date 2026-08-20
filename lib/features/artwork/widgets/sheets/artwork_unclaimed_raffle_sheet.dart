import 'package:flutter/material.dart';

import '../../../../core/data/mallow_tokens.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/price_format.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_sheet_frame.dart';

/// Which claim the connected wallet can complete on an unclaimed raffle.
///
/// Mirrors the three buttons of the webapp's `UnclaimedRaffleActionBox`
/// (`UnclaimedRaffleActionBox`):
/// winner "Claim NFT", creator "Reclaim NFT" (gated on `sold === 0`), creator
/// "Claim Proceeds" (gated on `sold > 0`). The dispatcher resolves exactly one
/// of them, so this sheet never renders a button the caller cannot sign.
enum UnclaimedRaffleClaim {
  /// Winner collects the prize (`isPrizeClaimed` is false).
  prize,

  /// Creator reclaims the prize after the raffle expired with no tickets sold.
  reclaim,

  /// Creator collects ticket revenue from a drawn raffle (`isClaimed` false).
  proceeds,
}

/// Shown when the connected wallet has an unclaimed raffle prize or
/// proceeds on **another** raffle of this same mint. Mirrors the webapp's
/// `UnclaimedRaffleActionBox` and takes precedence over the regular
/// per-listing sheet so the user can complete the claim.
///
/// The precedence only holds because the dispatcher now filters
/// `unclaimedRaffles` down to raffles this wallet can act on
/// (`/v1/artwork/byMint` returns **every** unclaimed raffle for the mint,
/// user-agnostic — `raffleMetadataHelper`).
/// See `docs/artwork_state.md`.
class ArtworkUnclaimedRaffleSheet extends StatelessWidget {
  const ArtworkUnclaimedRaffleSheet({
    required this.raffle,
    required this.claim,
    required this.onClaimNft,
    required this.onClaimProceeds,
    this.isLoading = false,
    super.key,
  });

  final RaffleMetadata raffle;
  final UnclaimedRaffleClaim claim;
  final VoidCallback onClaimNft;
  final VoidCallback onClaimProceeds;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title(),
            style: MallowTheme.uiBody.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _summary(),
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          MallowButton(
            label: _label(),
            enabled: !isLoading,
            isLoading: isLoading,
            onPressed: isLoading
                ? null
                : (claim == UnclaimedRaffleClaim.proceeds
                      ? onClaimProceeds
                      : onClaimNft),
            isFullWidth: true,
          ),
        ],
      ),
    );
  }

  String _title() => switch (claim) {
    UnclaimedRaffleClaim.prize => 'You won this raffle!',
    UnclaimedRaffleClaim.reclaim => 'Your raffle ended with no tickets sold',
    UnclaimedRaffleClaim.proceeds => 'Raffle proceeds available',
  };

  String _label() => switch (claim) {
    UnclaimedRaffleClaim.prize => 'Claim NFT',
    UnclaimedRaffleClaim.reclaim => 'Reclaim NFT',
    UnclaimedRaffleClaim.proceeds => 'Claim proceeds',
  };

  /// Webapp parity for the two figures the action box shows
  /// (`UnclaimedRaffleActionBox`): ticket price for a winner,
  /// `price × sold` total proceeds for the creator, plus tickets sold.
  ///
  /// `priceRaw` is base units, so it goes through the token decimals — the
  /// same division `formatPrice` applies
  /// (`tokens`).
  String _summary() {
    final sold = raffle.sold ?? 0;
    final supply = raffle.supply;
    final soldLabel = supply != null
        ? '${formatCount(sold)} / ${formatCount(supply)} sold'
        : '${formatCount(sold)} sold';
    final raw = raffle.priceRaw;
    final token = tokenByMint(raffle.currencyMint ?? solMint);
    if (raw == null || token == null) return soldLabel;
    if (claim == UnclaimedRaffleClaim.prize) {
      final price = displayDecimal(token.rawToDisplay(raw.round()));
      return 'Ticket price: $price ${token.symbol}   ·   $soldLabel';
    }
    final total = displayDecimal(token.rawToDisplay((raw * sold).round()));
    return 'Total proceeds: $total ${token.symbol}   ·   $soldLabel';
  }
}
