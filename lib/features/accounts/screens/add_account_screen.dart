import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/account.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/services/social_auth_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/menu_row.dart';
import '../../onboarding/widgets/create_wallet_menu.dart';

/// Full-screen menu for adding a new account.
///
/// Options:
/// - Create new account (new seed or social sign-in)
/// - Connect hardware wallet (the live Ledger BLE scan, not a placeholder)
/// - Add from recovery phrase (only when existing phrases exist)
/// - Import recovery phrase
/// - Import private key
/// - Watch address
class AddAccountScreen extends StatefulWidget {
  const AddAccountScreen({super.key});

  @override
  State<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends State<AddAccountScreen> {
  List<Account> _phraseAccounts = [];

  @override
  void initState() {
    super.initState();
    _loadPhraseAccounts();
  }

  Future<void> _loadPhraseAccounts() async {
    final all = await sl<WalletRepository>().getAccountViews();
    final withPhrase = all.where((a) => a.hasSeedPhrase).toList();
    if (!mounted) return;
    setState(() => _phraseAccounts = withPhrase);
  }

  void _onAddFromPhraseTap() {
    context.push(AppRoutes.selectPhraseForImport);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const MallowHeader(title: 'Add account'),
              const SizedBox(height: 32),
              // Menu rows
              MenuRow(
                icon: 'assets/icons/plus_padded.svg',
                label: 'Create new account',
                onTap: () => _showCreateAccountMenu(context),
              ),
              if (_phraseAccounts.isNotEmpty) ...[
                const SizedBox(height: 8),
                MenuRow(
                  icon: 'assets/icons/notes.svg',
                  label: 'Import wallets from recovery phrase',
                  onTap: _onAddFromPhraseTap,
                ),
              ],
              const SizedBox(height: 8),
              MenuRow(
                icon: 'assets/icons/notes.svg',
                label: 'Import recovery phrase',
                onTap: () {
                  context.push(AppRoutes.importAccountSeed);
                },
              ),
              const SizedBox(height: 8),
              MenuRow(
                icon: 'assets/icons/key.svg',
                label: 'Import private key',
                onTap: () {
                  context.push(AppRoutes.importPrivateKeyPath('new'));
                },
              ),
              const SizedBox(height: 8),
              MenuRow(
                icon: 'assets/icons/hardware_wallet.svg',
                label: 'Connect hardware wallet',
                onTap: () {
                  context.push(AppRoutes.ledgerScan);
                },
              ),
              const SizedBox(height: 8),
              MenuRow(
                icon: 'assets/icons/watch.svg',
                label: 'Watch address',
                onTap: () {
                  context.push(AppRoutes.watchAddressPath('new'));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateAccountMenu(BuildContext context) async {
    // The sheet shows a spinner while the social sign-in is in flight. The
    // result itself is handled by the top-level listener in `app.dart`, which
    // persists the wallet and navigates — so account creation survives the
    // OAuth round-trip even when this sheet/screen is torn down on resume.
    await CreateWalletMenu.show(
      context,
      onGoogleSignIn: () => sl<SocialAuthService>().signInWithGoogle(),
      onAppleSignIn: () => sl<SocialAuthService>().signInWithApple(),
      onRecoveryPhraseTap: () {
        Navigator.pop(context); // close bottom sheet
        context.push(AppRoutes.createAccountSeed);
      },
    );
  }
}
