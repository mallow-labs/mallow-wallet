import 'package:flutter/material.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_sheet_frame.dart';
import 'highest_offer_panel.dart';

/// Persistent bottom sheet shown when the connected wallet owns the artwork
/// and it isn't currently listed. Mirrors the webapp's `OwnerUnlistedBox`.
///
/// When the artwork has a live highest offer, the sheet
/// surfaces it — buyer, amount, age — with an Accept Offer CTA (live tx).
class ArtworkOwnerSheet extends StatelessWidget {
  const ArtworkOwnerSheet({
    required this.artwork,
    required this.onList,
    required this.onSend,
    required this.onAcceptOffer,
    super.key,
    this.canList = true,
    this.canSend = true,
    this.highestOffer,
    this.isLoading = false,
  });

  final ArtworkDetails artwork;
  final VoidCallback onList;

  /// Whether the artwork may be listed. Resolved by
  /// [ArtworkOwnerUnlistedAction] — `permissions.canList` plus the
  /// artwork-level listing policy (flagged, sold-out master).
  final bool canList;

  /// Whether the artwork may be transferred — `permissions.canTransfer`, the
  /// same predicate the context menu's Transfer row uses. Independent of
  /// [canList]: a flagged artwork can still be sent, and a listing-blocked one
  /// must not lose its only way out of the app.
  final bool canSend;

  /// Sends (transfers) the artwork to another wallet — secondary action that
  /// sits directly above the primary "List artwork" CTA.
  final VoidCallback onSend;

  /// Highest active offer on the artwork, loaded via `OfferRepository`.
  /// Null while loading or when none exist — the offer panel only renders
  /// when set.
  final OfferRender? highestOffer;

  /// Dispatches the accept-offer transaction for the given offer.
  final ValueChanged<OfferRender> onAcceptOffer;

  /// True while a market action is in flight — disables the offer CTAs.
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final offer = highestOffer;

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offer != null) ...[
            HighestOfferPanel(offer: offer),
            const SizedBox(height: MallowTheme.spacingMd),
            MallowButton(
              label: 'Accept Offer',
              variant: MallowButtonVariant.secondary,
              onPressed: isLoading ? null : () => onAcceptOffer(offer),
              isFullWidth: true,
            ),
            const SizedBox(height: MallowTheme.spacingSm),
          ],
          if (canSend)
            MallowButton(
              label: 'Send artwork',
              variant: MallowButtonVariant.secondary,
              onPressed: onSend,
              isFullWidth: true,
            ),
          if (canList) ...[
            if (canSend) const SizedBox(height: MallowTheme.spacingSm),
            MallowButton(
              label: 'List artwork',
              onPressed: onList,
              isFullWidth: true,
            ),
          ],
        ],
      ),
    );
  }
}
