import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../services/account_deletion.dart';
import '../widgets/settings_page_scaffold.dart';

/// Settings → Security & Privacy → Delete account.
///
/// Sits beside "Reset app" and must never be confused with it, so the copy
/// itemises what goes and what stays — the wallet / recovery-phrase line is the
/// load-bearing one. A single destructive button, no typed confirmation: the
/// whole area is already behind the reauth gate, so a second challenge here
/// would be friction for its own sake.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  /// Captured once on entry: [deleteMallowAccount] logs out, which nulls the
  /// authenticated user the getter reads, and the screen is still mounted while
  /// that happens.
  final String? _username = deletableUsername();
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
        'Couldn’t delete your account. Try again.',
        type: AppSnackBarType.error,
      );
      return;
    }

    AppSnackBar.show(context, 'Your mallow account was deleted');
    // Back to Settings, past the Security & Privacy screen that offered the
    // row. The session drop fired `onWalletChanged`, so Settings reloads its
    // identity as the active Account on the way out.
    if (context.canPop()) context.pop();
    if (context.mounted && context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SettingsPageScaffold(
      title: 'Delete account',
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
                      color: colors.error,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _username == null
                        ? 'Delete your mallow account'
                        : 'Delete @$_username',
                    style: MallowTheme.editorialSection,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This deletes your mallow profile. It cannot be undone.',
                    style: MallowTheme.uiBody.copyWith(color: colors.error),
                  ),
                  const SizedBox(height: 20),
                  Divider(color: colors.dividerLight),
                  const SizedBox(height: 16),
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
                      'Any roles on your account',
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
            MallowButton(
              label: 'Delete account',
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
