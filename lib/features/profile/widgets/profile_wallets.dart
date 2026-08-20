import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/explorer_utils.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/tap_target_expander.dart';

/// Wallets tab content: list of the user's linked wallet addresses
/// (truncated). Tap opens the address in the user's preferred Solana
/// explorer; long-press copies the full address to the clipboard.
class ProfileWallets extends StatelessWidget {
  const ProfileWallets({required this.addresses, super.key});

  final List<String> addresses;

  @override
  Widget build(BuildContext context) {
    if (addresses.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          MallowTheme.spacing20,
          MallowTheme.spacingMd,
          MallowTheme.spacing20,
          MallowTheme.spacingMd,
        ),
        child: Text(
          'No wallets linked',
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MallowTheme.spacing20,
        MallowTheme.spacingMd,
        MallowTheme.spacing20,
        MallowTheme.spacingMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final address in addresses) _WalletAddressRow(address: address),
        ],
      ),
    );
  }
}

class _WalletAddressRow extends StatelessWidget {
  const _WalletAddressRow({required this.address});

  final String address;

  Future<void> _open() async {
    await HapticFeedback.mediumImpact();
    final uri = Uri.parse(buildAccountExplorerUrlFromPrefs(address));
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: address));
    HapticFeedback.lightImpact();
    AppSnackBar.show(
      context,
      '${truncateAddress(address)} copied to clipboard',
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _open,
        onLongPress: () => _copy(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            truncateAddress(address),
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
