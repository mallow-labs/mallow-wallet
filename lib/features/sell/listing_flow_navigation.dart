import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';

/// Navigation shared by the fixed-price and auction listing flows. Both run a
/// pipeline sheet pushed over a form (and, when launched from the artwork
/// detail screen, a sell-type chooser above that). On success the sheet offers
/// a "View listing/auction" primary and a "Done" secondary, which unwind that
/// stack identically for either flow.

/// Pops the pipeline sheet and the listing form, then surfaces the just-listed
/// artwork so the user can see it live. When the flow was entered from the
/// artwork detail screen that artwork is already in the stack, so we pop back
/// to it instead of pushing a duplicate.
void viewListedArtwork(
  BuildContext context, {
  required bool entryFromArtworkDetail,
  required String? mint,
}) {
  Navigator.of(context).pop(); // pipeline sheet
  context.pop(); // form
  if (entryFromArtworkDetail) {
    context.pop(); // sell-type chooser → lands on the artwork detail
    return;
  }
  if (mint != null && mint.isNotEmpty) {
    context.goToArtwork(mint);
  }
}

/// Pops the pipeline sheet and the listing form back to wherever the flow was
/// entered (the portfolio, or the artwork detail when entered from there).
void dismissListingFlowToOrigin(
  BuildContext context, {
  required bool entryFromArtworkDetail,
}) {
  Navigator.of(context).pop(); // pipeline sheet
  context.pop(); // form
  if (entryFromArtworkDetail) {
    context.pop(); // sell-type chooser
  }
}
