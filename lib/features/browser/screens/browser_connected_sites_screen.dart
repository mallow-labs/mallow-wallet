import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../settings/widgets/settings_page_scaffold.dart';
import '../services/browser_services.dart';
import '../services/dapp_permission_service.dart';
import '../widgets/browser_settings_rows.dart';

/// The sites the in-app browser has connected, each with the wallet it can
/// see and a disconnect control.
class BrowserConnectedSitesScreen extends StatefulWidget {
  const BrowserConnectedSitesScreen({
    super.key,
    this.permissions,
    this.accounts,
  });

  final DappPermissionService? permissions;

  /// Accounts used to name the address behind each connection. Defaults to
  /// every Account on the device. A wallet's own stored name is an internal
  /// label and is never shown.
  final Future<List<Account>> Function()? accounts;

  @override
  State<BrowserConnectedSitesScreen> createState() =>
      _BrowserConnectedSitesScreenState();
}

class _BrowserConnectedSitesScreenState
    extends State<BrowserConnectedSitesScreen> {
  late final _permissions = widget.permissions ?? browserPermissions;
  late Future<List<DappGrant>> _grants = _permissions.list();

  /// Account name by wallet address.
  Map<String, String> _accountNames = const {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAccountNames();
  }

  Future<void> _loadAccountNames() async {
    try {
      final resolve = widget.accounts;
      final accounts = resolve != null
          ? await resolve()
          : sl.isRegistered<WalletRepository>()
          ? await sl<WalletRepository>().getAccountViews()
          : const <Account>[];
      if (!mounted) return;
      setState(
        () => _accountNames = {
          for (final account in accounts)
            for (final wallet in account.wallets) wallet.address: account.name,
        },
      );
    } catch (_) {
      // Names are a convenience; rows fall back to the short address.
    }
  }

  Future<void> _disconnect(DappGrant grant) async {
    final host = Uri.parse(grant.origin).host;
    final confirmed = await showConfirmSheet(
      context,
      title: 'Disconnect $host?',
      message:
          'The site will no longer see this wallet and must ask to connect '
          'again.',
      confirmLabel: 'Disconnect',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await _permissions.revoke(grant.origin, grant.address);
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = 'The site could not be disconnected. Please try again.',
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _grants = _permissions.list();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Connected sites',
      onBack: () => Navigator.of(context).maybePop(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          const BrowserSettingsCaption(
            'Connections reveal your address. Every signature still requires '
            'approval.',
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          FutureBuilder<List<DappGrant>>(
            future: _grants,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const BrowserSettingsPlaceholder(
                  'Connections could not be loaded',
                );
              }
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: MallowLoader(size: 24)),
                );
              }
              if (snapshot.data!.isEmpty) {
                return const BrowserSettingsPlaceholder('No connected sites');
              }
              return Column(
                children: [
                  for (final grant in snapshot.data!)
                    ConnectedSiteRow(
                      grant: grant,
                      accountName: _accountNames[grant.address],
                      onDisconnect: () => _disconnect(grant),
                    ),
                ],
              );
            },
          ),
          if (_error case final error?) ...[
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              error,
              style: MallowTheme.uiMeta.copyWith(
                color: context.mallowColors.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
