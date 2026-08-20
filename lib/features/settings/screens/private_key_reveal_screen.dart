import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../widgets/secret_copy_button.dart';
import '../widgets/settings_page_scaffold.dart';

/// Displays a single imported wallet's raw private key.
///
/// Receives the key via constructor as a `String` (shown as stored — raw hex
/// for Ethereum/Tezos, base58 for Solana). Security: the key is only held in
/// widget state while this screen is mounted.
class PrivateKeyRevealScreen extends StatelessWidget {
  const PrivateKeyRevealScreen({required this.privateKey, super.key});

  final String privateKey;

  void _copyToClipboard(BuildContext context) {
    // Plain copy (no auto-clear) — matches the product decision for keys.
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: privateKey));
    AppSnackBar.show(context, 'Private key copied to clipboard.');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return SettingsPageScaffold(
      title: 'Your private key',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
                ),
                child: SelectableText(
                  privateKey,
                  style: MallowTheme.uiBody.copyWith(
                    fontFamily: 'monospace',
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: SecretCopyButton(
              label: 'Copy private key',
              onTap: () => _copyToClipboard(context),
            ),
          ),
        ],
      ),
    );
  }
}
