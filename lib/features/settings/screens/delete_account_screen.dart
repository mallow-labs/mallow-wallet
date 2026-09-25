import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../services/account_deletion.dart';
import '../widgets/settings_page_scaffold.dart';

/// Settings → Security & Privacy → Delete profile.
///
/// Sits beside "Reset app" and must never be confused with it, so the copy
/// itemises what goes and what stays — the wallet / recovery-phrase line is the
/// load-bearing one. A single destructive button, no typed confirmation: the
/// whole area is already behind the reauth gate, so a second challenge here
/// would be friction for its own sake.
///
/// The row that leads here is always shown, so the screen also owns the case
/// where the signed-in address never set a username. That address still has a
/// server record — every `/v0/login` upserts one — so the delete is offered and
/// runs for real; only the heading changes. The one case with nothing to call
/// is a signed-out session: the route would 401, so the screen asks for a
/// sign-in rather than claiming there is nothing there. Reset app is never the
/// answer to either — it wipes the wallets and never touches the server.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  /// Captured once on entry: [deleteMallowAccount] logs out, which nulls the
  /// authenticated user the getter reads, and the screen is still mounted while
  /// that happens.
  final ({bool signedIn, String? username}) _profile = deletableProfile();
  bool _deleting = false;

  Future<void> _delete() async {
    if (_deleting) return;
    setState(() => _deleting = true);

    final outcome = await deleteMallowAccount();
    if (!mounted) return;

    if (outcome == AccountDeletionOutcome.failed) {
      setState(() => _deleting = false);
      AppSnackBar.show(
        context,
        'Couldn’t delete your profile. Try again.',
        type: AppSnackBarType.error,
      );
      return;
    }

    AppSnackBar.show(context, 'Your mallow profile was deleted');
    // Back to Settings, past the Security & Privacy screen that offered the
    // row. The session drop fired `onWalletChanged`, so Settings reloads its
    // identity as the active Account on the way out.
    if (context.canPop()) context.pop();
    if (context.mounted && context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final username = _profile.username;
    // The only branch: without a session there is no `login-token` to
    // authenticate the delete with, so the call would 401 and the profile would
    // survive. Everything else — username or not — deletes for real.
    final canDelete = _profile.signedIn;
    return SettingsPageScaffold(
      title: 'Delete profile',
      showDivider: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 20),
                children: [
                  Center(
                    child: MallowSvgIcon(
                      'assets/icons/shield_alert.svg',
                      width: 72,
                      height: 72,
                      color: canDelete ? colors.error : colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    !canDelete
                        ? 'Sign in to delete your profile'
                        : username == null
                        ? 'Delete your mallow profile'
                        : 'Delete @$username',
                    style: MallowTheme.editorialSection,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    canDelete
                        ? 'This deletes your mallow profile. It cannot be '
                              'undone.'
                        : 'You’re signed out, so we can’t tell which profile '
                              'to delete. Sign in on this device, then open '
                              'this screen again.',
                    style: MallowTheme.uiBody.copyWith(
                      color: canDelete ? colors.error : colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Divider(color: colors.dividerLight),
                  const SizedBox(height: 16),
                  if (canDelete) ...[
                    const _Section(
                      title: 'What gets removed',
                      items: [
                        'Your username',
                        'Your display name',
                        'Your bio',
                        'Your profile picture',
                        'Your banner image',
                        'Your website link',
                        'Your Twitter link',
                        'Any roles on your profile',
                        'Your profile record — the wallet addresses linked to '
                            'it, your sign-in history, and the push '
                            'notifications registered to them',
                      ],
                    ),
                    const SizedBox(height: 20),
                    const _Section(
                      title: 'What stays',
                      items: [
                        'Your wallets and recovery phrase — they never leave '
                            'this device and are not touched',
                        'Your artworks',
                        'Your on-chain history',
                        'Your listings and offers',
                      ],
                    ),
                    const SizedBox(height: 20),
                    Divider(color: colors.dividerLight),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    'To remove the wallets from this device instead, use '
                    'Reset app.',
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (canDelete)
              MallowButton(
                label: 'Delete profile',
                variant: MallowButtonVariant.danger,
                isFullWidth: true,
                isLoading: _deleting,
                onPressed: _delete,
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

/// Titled bullet list — one for what the delete removes, one for what survives.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.items});

  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 8),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '•  ',
                  style: MallowTheme.uiBody.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                Expanded(
                  child: Text(
                    item,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
