import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/menu_row.dart';

import '../../../core/models/account.dart';

/// Full-screen menu for adding a wallet to an existing account.
class AddWalletScreen extends StatelessWidget {
  const AddWalletScreen({required this.accountId, super.key});

  final String accountId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: FutureBuilder(
            future: sl<WalletRepository>().getAccountViews(),
            builder: (context, AsyncSnapshot<List<Account>> snapshot) {
              Account? account;
              if (snapshot.hasData) {
                for (final a in snapshot.data!) {
                  if (a.id == accountId) {
                    account = a;
                    break;
                  }
                }
              }
              final hasSeed = account?.hasSeedPhrase ?? false;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  const MallowHeader(title: 'Import wallet'),
                  const SizedBox(height: 32),
                  // Conditional: Import from phrase or Import recovery phrase
                  if (hasSeed)
                    MenuRow(
                      icon: 'assets/icons/settings.svg',
                      label: 'Import wallets from phrase',
                      onTap: () {
                        context.push(
                          AppRoutes.importFromPhrasePath(
                            account!.seedPhraseId!,
                          ),
                        );
                      },
                    )
                  else
                    MenuRow(
                      icon: 'assets/icons/settings.svg',
                      label: 'Import recovery phrase',
                      onTap: () {
                        context.push(
                          AppRoutes.importRecoveryPhrasePath(accountId),
                        );
                      },
                    ),
                  const SizedBox(height: 8),
                  MenuRow(
                    icon: 'assets/icons/settings.svg',
                    label: 'Connect hardware wallet',
                    onTap: () {
                      context.push(AppRoutes.ledgerScan);
                    },
                  ),
                  const SizedBox(height: 8),
                  MenuRow(
                    icon: 'assets/icons/settings.svg',
                    label: 'Import private key',
                    onTap: () {
                      context.push(AppRoutes.importPrivateKeyPath(accountId));
                    },
                  ),
                  const SizedBox(height: 8),
                  MenuRow(
                    icon: 'assets/icons/settings.svg',
                    label: 'Watch address',
                    onTap: () {
                      context.push(AppRoutes.watchAddressPath(accountId));
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
