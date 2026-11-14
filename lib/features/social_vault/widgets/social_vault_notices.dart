import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/observability/app_logger.dart';
import '../../../core/router/app_router.dart';
import '../../../core/social_vault/social_vault_api.dart';
import '../../../core/social_vault/social_vault_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/social_wallet_copy.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../services/sign_in_key_label.dart';
import 'social_vault_notice_sheet.dart';

/// What a sign-in key is called in a list: its label, else its kind.
///
/// The label is made one line of plain text first (see
/// [signInKeyLabelOnOneLine]); the row that draws it cuts it to its width.
String signInKeyTitle(api.SocialVaultSlot slot) {
  final label = signInKeyLabelOnOneLine(slot.label ?? '');
  if (label.isNotEmpty) return label;
  return slot.kind == api.SocialVaultSlotKind.passkeyPrf
      ? 'Passkey'
      : 'Device backup';
}

/// The longest a key's name runs inside a sentence or a title.
const _inlineTitleLength = 40;

/// [signInKeyTitle] for a sentence or a title, where no row cuts the name to
/// its width: a long one ends in an ellipsis, so the words after it stay on
/// screen.
String signInKeyInlineTitle(api.SocialVaultSlot slot) =>
    ellipsizeSignInKeyLabel(signInKeyTitle(slot), _inlineTitleLength);

/// A backend timestamp (ISO-8601) as a date the user reads, in this device's
/// time zone. A value that does not parse is shown as it came.
String socialVaultDate(String iso) {
  final parsed = DateTime.tryParse(iso);
  return parsed == null ? iso : DateFormat.yMMMMd().format(parsed.toLocal());
}

/// The new-key notice for [slots], one line each.
List<String> newSignInKeysLines(List<api.SocialVaultSlot> slots) => [
  for (final slot in slots)
    signInKeyAddedMessage(
      socialVaultDate(slot.createdAt),
      signInKeyInlineTitle(slot),
    ),
];

/// Show what this device's latest record of [vaultId] calls for, in order:
///
/// 1. the blocking, full-screen warning when a deletion of the wallet backup
///    is pending and the user has not said "it was me" to that request;
/// 2. the notice for sign-in keys this device has not seen before — once
///    the user has answered it. "Dismiss", a tap outside the sheet and the
///    back gesture are answers, and so is "Review sign-in keys": the list is
///    where a key is removed. A sheet the app removed (the page under it was
///    replaced) is not one: its reader may never have seen it, so the keys
///    stay unseen and the notice is shown at the next check.
///
/// Shows nothing when neither applies. Reads only what the status check or
/// the sign-in already stored; it makes no request of its own.
Future<void> showSocialVaultNotices(
  BuildContext context,
  String vaultId,
) async {
  final vaults = sl<SocialVaultService>();
  final pending = await vaults.unacknowledgedDeletion(vaultId);
  if (!context.mounted) return;
  if (pending != null) {
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            PendingDeletionWarningScreen(vaultId: vaultId, pending: pending),
      ),
    );
    if (!context.mounted) return;
  }
  final unseen = await vaults.unseenSlots(vaultId);
  if (unseen.isEmpty || !context.mounted) return;
  final review = await showSocialVaultNoticeSheet(
    context,
    title: unseen.length == 1 ? 'New sign-in key' : 'New sign-in keys',
    lines: newSignInKeysLines(unseen),
    // A key's name is not the app's text: it gets two lines at most.
    maxLinesPerLine: 2,
    confirmLabel: 'Review sign-in keys',
    cancelLabel: 'Dismiss',
  );
  // Removed by the app, not answered: still to be told.
  if (review == null) return;
  await vaults.acknowledgeSlots(vaultId, [for (final s in unseen) s.slotId]);
  if (!review || !context.mounted) return;
  // Not awaited: the push completes only when the screen is left again. No
  // pre-authenticated flag, so the screen asks for the PIN or biometrics.
  unawaited(GoRouter.of(context).push(AppRoutes.signInKeys));
}

/// The warning shown, over everything, while a deletion of a wallet backup
/// is pending: a request the vault key did not sign, filed on the user's
/// behalf, which is applied a week after it was made unless a device that
/// holds the vault key refuses it.
///
/// It cannot be backed out of. "Keep my backup" cancels the request with a
/// write this device signs; "It was me, continue" lets it stand and is
/// remembered for this request only, so a later request warns again.
class PendingDeletionWarningScreen extends StatefulWidget {
  const PendingDeletionWarningScreen({
    required this.vaultId,
    required this.pending,
    super.key,
  });

  final String vaultId;
  final api.SocialVaultPendingDeletion pending;

  @override
  State<PendingDeletionWarningScreen> createState() =>
      _PendingDeletionWarningScreenState();
}

class _PendingDeletionWarningScreenState
    extends State<PendingDeletionWarningScreen> {
  bool _busy = false;

  SocialVaultService get _vaults => sl<SocialVaultService>();

  Future<void> _keep() async {
    if (_busy) return;
    setState(() => _busy = true);
    String? error;
    try {
      await _vaults.cancelDeletion(widget.vaultId);
    } on SocialVaultStaleKeyException {
      error =
          'This device can no longer sign for this wallet’s backup. Sign in '
          'to the wallet again here, then keep it.';
    } on SocialVaultApiException catch (e) {
      error = e.error == SocialVaultApiError.staleTimestamp
          ? socialVaultClockMessage
          : 'Could not keep your backup. Check your connection and try '
                'again.';
    } catch (e) {
      AppLogger.warn('SocialVault', 'cancel deletion: ${e.runtimeType}');
      error =
          'Could not keep your backup. Check your connection and try again.';
    }
    if (!mounted) return;
    if (error != null) {
      setState(() => _busy = false);
      AppSnackBar.show(context, error, type: AppSnackBarType.error);
      return;
    }
    AppSnackBar.show(context, 'Your wallet backup is kept.');
    Navigator.of(context).pop();
  }

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _vaults.acknowledgeDeletion(
        widget.vaultId,
        widget.pending.requestedAt,
      );
    } catch (e) {
      // The answer is kept in this device's secure store, which can fail to
      // read or write. This screen cannot be backed out of, so it must not
      // be left with both buttons dead: say so and let the user answer again.
      AppLogger.warn('SocialVault', 'acknowledge deletion: ${e.runtimeType}');
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackBar.show(
        context,
        'Could not save your answer. Try again.',
        type: AppSnackBarType.error,
      );
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: colors.bgPrimary,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 40, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      Center(
                        child: MallowSvgIcon(
                          'assets/icons/shield_alert.svg',
                          width: 72,
                          height: 72,
                          color: colors.error,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Your wallet backup is about to be deleted',
                        style: MallowTheme.editorialSection.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        pendingDeletionMessage(
                          socialVaultDate(widget.pending.appliesAt),
                        ),
                        style: MallowTheme.uiBody.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'The backup is what lets you sign in to this wallet '
                        'on a new device. Without it, the wallet is only on '
                        'the devices that already hold it and in its '
                        'recovery phrase.',
                        style: MallowTheme.uiMeta.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                MallowButton(
                  label: 'Keep my backup',
                  isFullWidth: true,
                  isLoading: _busy,
                  onPressed: _keep,
                ),
                const SizedBox(height: 12),
                MallowButton(
                  label: 'It was me, continue',
                  variant: MallowButtonVariant.secondary,
                  isFullWidth: true,
                  enabled: !_busy,
                  onPressed: _continue,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
