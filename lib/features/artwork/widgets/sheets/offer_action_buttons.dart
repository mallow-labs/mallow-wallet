import 'package:flutter/material.dart';

import '../../../../core/config/store_build.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/mallow_button.dart';

/// Offer CTA block shared by the buy and unlisted-viewer sheets: "Make
/// offer" normally, "Update offer / Cancel offer" when the connected
/// wallet already has a live offer — post-offer the sheet shows both
/// management actions. Updating re-opens the offer input; the backend
/// builder issues an `updateOffer` re-bid when an offer already exists.
class OfferActionButtons extends StatelessWidget {
  const OfferActionButtons({
    required this.onMakeOffer,
    required this.onCancelOffer,
    this.userOwnOffer = false,
    this.isLoading = false,
    this.isPrimary = false,
    super.key,
  });

  final VoidCallback onMakeOffer;
  final VoidCallback onCancelOffer;
  final bool userOwnOffer;
  final bool isLoading;

  /// True where make/update-offer is the sheet's main CTA (the unlisted
  /// viewer sheet): renders it in the primary variant with the in-flight
  /// spinner. False keeps it secondary under another primary button (the
  /// buy sheet, where the Buy button carries the spinner).
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    if (!showNftCommerce) {
      // Store build: making or updating an offer is a purchase CTA and is
      // not rendered; cancelling a live offer is the escape hatch that
      // reclaims the escrowed bid, so it stays.
      if (!userOwnOffer) return const SizedBox.shrink();
      return MallowButton(
        label: 'Cancel offer',
        variant: MallowButtonVariant.secondary,
        onPressed: isLoading ? null : onCancelOffer,
        // Sole CTA in this branch, so it carries the in-flight spinner
        // itself — the sibling buttons that hold it when commerce is shown
        // (Buy, make/update offer) are not rendered here.
        isLoading: isLoading,
        isFullWidth: true,
      );
    }
    final makeOfferVariant = isPrimary
        ? MallowButtonVariant.primary
        : MallowButtonVariant.secondary;
    if (!userOwnOffer) {
      return MallowButton(
        label: 'Make offer',
        variant: makeOfferVariant,
        onPressed: isLoading ? null : onMakeOffer,
        isLoading: isPrimary && isLoading,
        isFullWidth: true,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MallowButton(
          label: 'Update offer',
          variant: makeOfferVariant,
          onPressed: isLoading ? null : onMakeOffer,
          isLoading: isPrimary && isLoading,
          isFullWidth: true,
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        MallowButton(
          label: 'Cancel offer',
          variant: MallowButtonVariant.secondary,
          onPressed: isLoading ? null : onCancelOffer,
          isFullWidth: true,
        ),
      ],
    );
  }
}
