import 'package:flutter/widgets.dart';

import '../../../di.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../profile/data/user_profile_repository.dart';
import 'active_wallet_verification.dart';
import 'artwork_hidden_signal.dart';

/// Hides or unhides [mintAccount] from the requesting owner's profile.
///
/// Mirrors the webapp's hide/unhide: it flips the item's visibility via the
/// `/v0/hide` · `/v0/unhide` endpoints (already keyed by `mintAccount`). The
/// backend gates the write on the ACTIVE login wallet — not just any session
/// wallet — so [ensureActiveWalletVerified] runs first; see it for why.
///
/// Optimism is broadcast, not local: on success [notifyArtworkHidden] fires so
/// every mounted owned-art grid + the detail screen flips the item's `isHidden`
/// (corner badge + menu row) without a refetch. [currentlyHidden] is the state
/// the caller is toggling away from.
///
/// Returns the new hidden state on success, or null when verification failed or
/// the write threw (the caller's optimistic state, if any, should not advance).
Future<bool?> toggleArtworkHidden(
  BuildContext context, {
  required String mintAccount,
  required bool currentlyHidden,
}) async {
  final verifyError = await ensureActiveWalletVerified();
  if (verifyError != null) {
    // Fail loud — a silent abort here reads as "nothing happened".
    if (context.mounted) AppSnackBar.show(context, verifyError);
    return null;
  }
  final next = !currentlyHidden;
  try {
    final repo = sl<UserProfileRepository>();
    if (next) {
      await repo.hideMint(mintAccount);
    } else {
      await repo.unhideMint(mintAccount);
    }
    notifyArtworkHidden(mintAccount, isHidden: next);
    if (context.mounted) {
      AppSnackBar.show(context, next ? 'Hidden from profile' : 'Unhidden');
    }
    return next;
  } catch (_) {
    // The backend now 403s an unauthorized hide instead of silently 200ing, so
    // a throw here means the write did NOT take effect. Surface it and leave the
    // optimistic state untouched — [notifyArtworkHidden] above never fired, so
    // no grid/badge flips.
    if (context.mounted) {
      AppSnackBar.show(
        context,
        next ? 'Failed to hide artwork' : 'Failed to unhide artwork',
        type: AppSnackBarType.error,
      );
    }
    return null;
  }
}
