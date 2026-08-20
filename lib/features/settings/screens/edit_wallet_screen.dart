import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../accounts/services/account_wallet_bloc.dart';
import '../../home/widgets/drawer_signal.dart';
import '../widgets/settings_page_scaffold.dart';

/// Screen for editing (renaming) or removing a wallet.
class EditWalletScreen extends StatefulWidget {
  const EditWalletScreen({required this.walletId, super.key});

  final String walletId;

  @override
  State<EditWalletScreen> createState() => _EditWalletScreenState();
}

class _EditWalletScreenState extends State<EditWalletScreen> {
  final _controller = TextEditingController();
  String _originalName = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadWallet();
  }

  Future<void> _loadWallet() async {
    final wallet = await sl<WalletRepository>().getWalletById(widget.walletId);
    if (!mounted) return;
    if (wallet == null) {
      context.pop();
      return;
    }
    setState(() {
      _originalName = wallet.name;
      _controller.text = wallet.name;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canContinue {
    final text = _controller.text.trim();
    return text.isNotEmpty && text != _originalName;
  }

  Future<void> _onContinue() async {
    final newName = _controller.text.trim();
    if (newName.isEmpty || newName == _originalName) return;

    await sl<WalletRepository>().renameWallet(widget.walletId, newName);
    if (!mounted) return;
    sl<AccountWalletBloc>().add(const AccountWalletEvent.load());
    DrawerSignal.reloadDrawerOnReturn = true;
    context.pop();
  }

  Future<void> _onRemoveWallet() async {
    final confirmed = await showConfirmSheet(
      context,
      title: 'Remove wallet?',
      message:
          'This wallet will be removed from your device. '
          'Make sure you have backed up your recovery phrase '
          'before proceeding.',
      confirmLabel: 'Remove',
      destructive: true,
    );

    if (confirmed != true || !mounted) return;

    final replacementId = await sl<WalletManager>().removeWallet(
      widget.walletId,
    );

    if (!mounted) return;

    if (replacementId == null) {
      // No wallets remain — clear selection and let router redirect to welcome
      await sl<WalletManager>().clearWalletSelection();
      await sl<AuthStateNotifier>().onLogout();
    } else {
      // Switch to replacement wallet (fires onWalletChanged → re-auth)
      await sl<WalletManager>().switchWalletById(replacementId);
      if (!mounted) return;
      sl<AccountWalletBloc>().add(const AccountWalletEvent.load());
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Edit wallet',
      showDivider: false,
      child: _loading
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MallowSectionLabel(label: 'Update your wallet name'),
                  const SizedBox(height: MallowTheme.spacingMd),
                  MallowPillField(
                    controller: _controller,
                    onChanged: (_) => setState(() {}),
                    suffix: _controller.text.isNotEmpty
                        ? TapTargetExpander(
                            child: GestureDetector(
                              onTap: () {
                                _controller.clear();
                                setState(() {});
                              },
                              behavior: HitTestBehavior.opaque,
                              child: MallowSvgIcon(
                                'assets/icons/x.svg',
                                width: 18,
                                height: 18,
                                color: context.mallowColors.textSecondary,
                              ),
                            ),
                          )
                        : null,
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _onRemoveWallet,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.mallowColors.error,
                        foregroundColor: context.mallowColors.textOnAccent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: MallowTheme.spacingLg,
                          vertical: MallowTheme.spacingMd,
                        ),
                        minimumSize: const Size(88, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            MallowTheme.radiusFull,
                          ),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        'Remove wallet',
                        style: MallowTheme.uiBody.copyWith(
                          color: context.mallowColors.textOnAccent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  MallowButton(
                    label: 'Continue',
                    isFullWidth: true,
                    enabled: _canContinue,
                    onPressed: _onContinue,
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }
}
