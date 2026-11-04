import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tappable.dart';
import '../../browser/widgets/browser_settings_rows.dart';
import '../../browser/widgets/browser_site_tile.dart';
import '../../send/widgets/send_qr_scanner_view.dart';
import '../../settings/widgets/settings_page_scaffold.dart';
import '../services/walletconnect_service.dart';
import '../walletconnect_module.dart';

/// Opens the camera for a website's WalletConnect QR code and connects to
/// it. Anything that is not a WalletConnect code is ignored.
Future<void> scanWalletConnectCode(BuildContext context) async {
  final code = await Navigator.of(context, rootNavigator: true).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (routeContext) => SendQrScannerView(
        onDetect: (capture) {
          final code = capture.barcodes.firstOrNull?.rawValue?.trim();
          if (code == null || !code.startsWith('wc:')) return;
          // Detection fires repeatedly; only the first hit may pop.
          final route = ModalRoute.of(routeContext);
          if (route == null || !route.isCurrent) return;
          Navigator.of(routeContext).pop(code);
        },
        onClose: () => Navigator.of(routeContext).pop(),
      ),
    ),
  );
  if (code != null) handleWalletConnectText(code);
}

/// Browser settings' WalletConnect screen: connect a website by QR code or
/// pasted link, and the websites connected that way.
class WalletConnectSettingsScreen extends StatelessWidget {
  const WalletConnectSettingsScreen({required this.service, super.key});
  final WalletConnectService service;

  Future<void> _paste(BuildContext context) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!context.mounted) return;
    if (text == null || !handleWalletConnectText(text)) {
      AppSnackBar.show(
        context,
        'Copy a WalletConnect link from the website first',
        type: AppSnackBarType.error,
      );
    }
  }

  Future<void> _disconnect(
    BuildContext context,
    WalletConnectSessionView session,
  ) async {
    final confirmed = await showConfirmSheet(
      context,
      title: 'Disconnect ${session.name}?',
      message:
          'The website will no longer see your wallets and must ask to '
          'connect again.',
      confirmLabel: 'Disconnect',
      destructive: true,
    );
    if (confirmed != true) return;
    try {
      await service.disconnect(session.topic);
    } catch (_) {
      // The session is dropped on this device regardless.
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'WalletConnect',
      onBack: () => Navigator.of(context).maybePop(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          const BrowserSettingsCaption(
            'Connect to websites open in another browser or on another '
            'device. Every signature still requires approval.',
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          BrowserSettingsRow(
            iconAsset: 'assets/icons/qr.svg',
            label: 'Scan a QR code',
            onTap: () => scanWalletConnectCode(context),
          ),
          const SizedBox(height: MallowTheme.spacingSm),
          BrowserSettingsRow(
            iconAsset: 'assets/icons/paste.svg',
            label: 'Paste a link',
            onTap: () => _paste(context),
          ),
          const SizedBox(height: MallowTheme.spacingLg),
          const BrowserSettingsSection(title: 'Connected websites'),
          const SizedBox(height: MallowTheme.spacingSm),
          ValueListenableBuilder<List<WalletConnectSessionView>>(
            valueListenable: service.sessions,
            builder: (context, sessions, _) => sessions.isEmpty
                ? const BrowserSettingsPlaceholder('No connected websites')
                : Column(
                    children: [
                      for (final session in sessions)
                        _SessionRow(
                          session: session,
                          onDisconnect: () => _disconnect(context, session),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onDisconnect});
  final WalletConnectSessionView session;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final wallets = [
      for (final address in session.addresses.values.toSet())
        truncateAddress(address, lead: 4, trail: 4),
    ].join(' · ');
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          BrowserSiteTile(
            host: session.origin.host,
            iconUrl: session.iconUrl,
            size: 36,
          ),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${session.origin.host} · $wallets',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MallowTheme.uiMeta.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Tappable(
            onTap: onDisconnect,
            semanticLabel: 'Disconnect ${session.name}',
            child: SizedBox.square(
              dimension: 44,
              child: Center(
                child: MallowSvgIcon(
                  'assets/icons/close.svg',
                  width: 20,
                  height: 20,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
