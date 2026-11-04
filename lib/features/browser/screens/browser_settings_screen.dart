import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/sort_options_sheet.dart';
import '../../settings/widgets/settings_page_scaffold.dart';
import '../models/browser_models.dart';
import '../services/browser_data_clearer.dart';
import '../services/browser_services.dart';
import '../services/browser_transaction_tracker.dart';
import '../services/dapp_permission_service.dart';
import '../widgets/browser_settings_rows.dart';
import '../widgets/clear_browsing_data_sheet.dart';
import '../../walletconnect/services/walletconnect_service.dart';
import '../../walletconnect/widgets/walletconnect_settings_screen.dart';
import 'browser_connected_sites_screen.dart';
import 'browser_transactions_screen.dart';

/// Browser settings: one icon-and-label row per setting, in the app settings'
/// layout. Connected sites, WalletConnect and Recent transactions each open
/// their own screen.
class BrowserSettingsScreen extends StatefulWidget {
  const BrowserSettingsScreen({
    super.key,
    this.dataClearer,
    this.permissions,
    this.accounts,
  });

  final BrowserDataClearer? dataClearer;
  final DappPermissionService? permissions;

  /// Passed to [BrowserConnectedSitesScreen].
  final Future<List<Account>> Function()? accounts;

  @override
  State<BrowserSettingsScreen> createState() => _BrowserSettingsScreenState();
}

class _BrowserSettingsScreenState extends State<BrowserSettingsScreen> {
  late final BrowserDataClearer _dataClearer =
      widget.dataClearer ?? BrowserDataClearer.platform();
  late final _permissions = widget.permissions ?? browserPermissions;
  late Future<List<DappGrant>> _grants = _permissions.list();
  bool _clearing = false;
  String? _error;

  Future<void> _chooseSearchEngine() async {
    final engine = await showSortOptionsSheet<BrowserSearchEngine>(
      context,
      title: 'Search engine',
      options: BrowserSearchEngine.values,
      currentSort: browserSearchEngine.value,
      labelFor: (engine) => engine.label,
    );
    if (engine != null) await browserSearchEngine.choose(engine);
  }

  Future<void> _open(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _openConnectedSites() async {
    await _open(
      BrowserConnectedSitesScreen(
        permissions: _permissions,
        accounts: widget.accounts,
      ),
    );
    // The count follows any disconnect made there.
    if (!mounted) return;
    setState(() {
      _grants = _permissions.list();
    });
  }

  Future<void> _clear() async {
    final keepBookmarks = await showClearBrowsingDataSheet(context);
    if (keepBookmarks == null || !mounted) return;
    setState(() => _clearing = true);
    try {
      final failures = await _dataClearer.clearBrowsingData(
        keepBookmarks: keepBookmarks,
      );
      if (!mounted) return;
      if (failures.isEmpty) {
        setState(() {
          _grants = _permissions.list();
          _error = null;
        });
      } else {
        setState(
          () => _error =
              'Some browsing data could not be cleared. Please try again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Some browsing data could not be cleared. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    const gap = SizedBox(height: MallowTheme.spacingSm);
    return SettingsPageScaffold(
      title: 'Browser settings',
      onBack: () => Navigator.of(context).maybePop(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          ValueListenableBuilder<BrowserSearchEngine>(
            valueListenable: browserSearchEngine,
            builder: (context, engine, _) => BrowserSettingsRow(
              iconAsset: 'assets/icons/search.svg',
              label: 'Search engine',
              value: engine.label,
              onTap: _chooseSearchEngine,
            ),
          ),
          gap,
          FutureBuilder<List<DappGrant>>(
            future: _grants,
            builder: (context, snapshot) => BrowserSettingsRow(
              iconAsset: 'assets/icons/link.svg',
              label: 'Connected sites',
              // One site can see several wallets; count the sites.
              badge: _count(
                {
                  for (final grant in snapshot.data ?? const <DappGrant>[])
                    grant.origin,
                }.length,
              ),
              onTap: _openConnectedSites,
            ),
          ),
          if (WalletConnectService.instance case final walletConnect?) ...[
            gap,
            ValueListenableBuilder<List<WalletConnectSessionView>>(
              valueListenable: walletConnect.sessions,
              builder: (context, sessions, _) => BrowserSettingsRow(
                iconAsset: 'assets/icons/connect.svg',
                label: 'WalletConnect',
                badge: _count(sessions.length),
                onTap: () =>
                    _open(WalletConnectSettingsScreen(service: walletConnect)),
              ),
            ),
          ],
          gap,
          ListenableBuilder(
            listenable: BrowserTransactionTracker.instance,
            builder: (context, _) => BrowserSettingsRow(
              iconAsset: 'assets/icons/receipt.svg',
              label: 'Recent transactions',
              badge: _count(BrowserTransactionTracker.instance.records.length),
              onTap: () => _open(const BrowserTransactionsScreen()),
            ),
          ),
          gap,
          BrowserSettingsRow(
            iconAsset: 'assets/icons/trash.svg',
            label: 'Clear browsing data',
            destructive: true,
            onTap: _clearing ? null : _clear,
            trailing: _clearing ? const MallowLoader(size: 20) : null,
          ),
          if (_error case final error?) ...[
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              error,
              style: MallowTheme.uiMeta.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }
}

String? _count(int count) => count == 0 ? null : '$count';
