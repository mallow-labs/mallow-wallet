import 'package:flutter/widgets.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../di.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../artwork/services/artwork_removal_signal.dart';
import '../../profile/widgets/profile_required_sheet.dart';
import '../models/moderation_models.dart';
import '../widgets/report_sheet.dart';
import 'block_store.dart';
import 'moderation_hide_store.dart';

/// Shown after every accepted report. The 24-hour promise is backed by an
/// alert the backend fires on insert — a human triages it.
const String _reportConfirmation =
    'Thanks — we’ll review this within 24 hours.';

/// Reports an artwork, then hides it from the reporter's own view.
///
/// The hide is **viewer-side only**. It fires the app-wide
/// [ArtworkRemovalSignal] — every mounted artwork grid (profile, collection,
/// curation, portfolio group) already drops the mint on that signal — and
/// records it in [ModerationHideStore] so surfaces can filter it out. It does
/// **not** call `/v0/hide`: that route is owner-scoped, gated on a `wallet-sig`
/// cookie proving you own the item, and 403s on someone else's artwork.
///
/// Returns true when the report was accepted (including a rate-limited 429,
/// which is a soft success — the hide and the confirmation still happen so a
/// spammer is never told how the limit works).
Future<bool> runReportArtworkFlow(
  BuildContext context, {
  required String mintAccount,
  required String screen,
}) async {
  final outcome = await _report(
    context,
    targetType: api.ReportTargetType.artwork,
    targetId: mintAccount,
    screen: screen,
  );
  if (outcome == null) return false;

  sl<ModerationHideStore>().hide(api.ReportTargetType.artwork, mintAccount);
  notifyArtworkRemoved(mintAccount);
  if (context.mounted) AppSnackBar.show(context, _reportConfirmation);
  return true;
}

/// Reports a curation, then suppresses it locally. The caller is responsible
/// for leaving the curation screen if the report was filed from inside it —
/// there is no app-wide curation-removal signal to piggyback on.
///
/// [curationSlug] — **the exhibition slug, not the curation id.** The
/// moderation alert links the reported curation as `mallow.art/e/<slug>`, and
/// an id there produces a dead link in the triage card.
Future<bool> runReportCurationFlow(
  BuildContext context, {
  required String curationSlug,
  required String screen,
}) async {
  final outcome = await _report(
    context,
    targetType: api.ReportTargetType.curation,
    targetId: curationSlug,
    screen: screen,
  );
  if (outcome == null) return false;

  sl<ModerationHideStore>().hide(api.ReportTargetType.curation, curationSlug);
  if (context.mounted) AppSnackBar.show(context, _reportConfirmation);
  return true;
}

/// Reports a user, then offers to block them.
///
/// Blocking is the follow-up rather than an automatic consequence: a report is
/// "someone should look at this", a block is "I don't want to see this person",
/// and silently doing the second on the strength of the first leaves the user
/// with a filter they never asked for and can't find. The block sheet spells
/// out what blocking does and does not do.
Future<bool> runReportUserFlow(
  BuildContext context, {
  required String address,
  required String label,
  required String screen,
}) async {
  final outcome = await _report(
    context,
    targetType: api.ReportTargetType.user,
    targetId: address,
    screen: screen,
  );
  if (outcome == null) return false;

  sl<ModerationHideStore>().hide(api.ReportTargetType.user, address);
  if (!context.mounted) return true;
  AppSnackBar.show(context, _reportConfirmation);
  await runBlockUserFlow(context, address: address, label: label);
  return true;
}

/// Opens the report sheet and normalises its result. Returns null when the
/// user backed out, wasn't logged in, or the submit failed.
Future<ReportOutcome?> _report(
  BuildContext context, {
  required api.ReportTargetType targetType,
  required String targetId,
  required String screen,
}) async {
  // Every report is attributable (`LoginAddress` is required server-side), so
  // an Account-mode viewer has to pick or create a profile first.
  if (!await requireProfile(context)) return null;
  if (!context.mounted) return null;
  return showReportSheet(
    context,
    targetType: targetType,
    targetId: targetId,
    screen: screen,
  );
}

/// Confirms and applies a block. Returns true when the block landed.
///
/// The confirmation copy is deliberately unflattering about what a block is:
/// it is a **one-directional personal view filter**. It cannot stop the blocked
/// account from bidding on or buying the viewer's artwork — that is on-chain
/// and permissionless — and promising otherwise turns into a support ticket the
/// first time it happens.
Future<bool> runBlockUserFlow(
  BuildContext context, {
  required String address,
  required String label,
}) async {
  if (!await requireProfile(context)) return false;
  if (!context.mounted) return false;

  final confirmed = await showConfirmSheet(
    context,
    title: 'Block $label?',
    message:
        'You won’t see their artworks, curations, or offers, and they won’t '
        'be able to reach you with notifications.\n\n'
        'This only changes what you see. It is not mutual, they are not told, '
        'and it cannot stop them bidding on or buying your artwork — that '
        'happens on-chain and is open to anyone.\n\n'
        'You can unblock any time in Settings → Security & Privacy → Blocked '
        'accounts.',
    confirmLabel: 'Block',
    destructive: true,
  );
  if (confirmed != true || !context.mounted) return false;

  final ok = await sl<BlockStore>().block(address);
  if (!context.mounted) return ok;
  AppSnackBar.show(
    context,
    ok ? 'Blocked $label' : 'Couldn’t block that account. Please try again.',
    type: ok ? AppSnackBarType.info : AppSnackBarType.error,
  );
  return ok;
}

/// Removes a block. No confirmation — unblocking is the reversible direction.
Future<bool> runUnblockUserFlow(
  BuildContext context, {
  required String address,
  required String label,
}) async {
  final ok = await sl<BlockStore>().unblock(address);
  if (!context.mounted) return ok;
  AppSnackBar.show(
    context,
    ok
        ? 'Unblocked $label'
        : 'Couldn’t unblock that account. Please try again.',
    type: ok ? AppSnackBarType.info : AppSnackBarType.error,
  );
  return ok;
}
