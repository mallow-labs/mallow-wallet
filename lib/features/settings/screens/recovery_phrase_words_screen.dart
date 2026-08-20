import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/seed_phrase_grid.dart';
import '../widgets/secret_copy_button.dart';
import '../widgets/settings_page_scaffold.dart';

/// Displays the recovery phrase word grid.
///
/// Receives the mnemonic words via constructor as `List<String>`.
/// Security: words are only held in widget state while this screen is mounted.
class RecoveryPhraseWordsScreen extends StatelessWidget {
  const RecoveryPhraseWordsScreen({required this.words, super.key});

  final List<String> words;

  void _copyToClipboard(BuildContext context) {
    // Plain copy (no auto-clear) — matches the product decision for keys.
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: words.join(' ')));
    AppSnackBar.show(context, 'Recovery phrase copied to clipboard.');
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Your recovery phrase',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: SeedPhraseGrid(
                words: words,
                is24Words: words.length == 24,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: SecretCopyButton(
              label: 'Copy recovery phrase',
              onTap: () => _copyToClipboard(context),
            ),
          ),
        ],
      ),
    );
  }
}
