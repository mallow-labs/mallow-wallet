import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/crypto/mnemonic_generator.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/security/security_utils.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/seed_phrase_grid.dart';

/// Screen displaying the generated seed phrase.
///
/// Shows the mnemonic words in a grid with copy functionality.
/// User must acknowledge they've saved the phrase before continuing.
class SeedPhraseDisplayScreen extends StatefulWidget {
  const SeedPhraseDisplayScreen({
    required this.mnemonic,
    this.isAddingAccount = false,
    super.key,
  });

  final String mnemonic;

  /// When true, creates a new seed phrase via WalletRepository and navigates
  /// to the HD picker instead of continuing to PIN/biometric setup.
  final bool isAddingAccount;

  @override
  State<SeedPhraseDisplayScreen> createState() =>
      _SeedPhraseDisplayScreenState();
}

class _SeedPhraseDisplayScreenState extends State<SeedPhraseDisplayScreen> {
  bool _hasConfirmed = false;
  bool _is24Words = false;
  bool _isSubmitting = false;
  late String _mnemonic;

  List<String> get _words => _mnemonic.split(' ');

  @override
  void initState() {
    super.initState();
    // Generate mnemonic if not passed or empty
    if (widget.mnemonic.isEmpty) {
      _mnemonic = MnemonicGenerator.generate12Words();
    } else {
      _mnemonic = widget.mnemonic;
    }
  }

  void _toggleWordCount(bool is24Words) {
    setState(() {
      _is24Words = is24Words;
      // Regenerate mnemonic with new word count
      _mnemonic = is24Words
          ? MnemonicGenerator.generate24Words()
          : MnemonicGenerator.generate12Words();
      // Reset confirmation when changing word count
      _hasConfirmed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 8),
              MallowHeader(
                title: 'Your recovery phrase',
                actions: [
                  IconButton(
                    onPressed: _copyToClipboard,
                    icon: const MallowSvgIcon(
                      'assets/icons/copy.svg',
                      width: 24,
                      height: 24,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Seed phrase grid
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      AnimatedSize(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                        alignment: Alignment.topCenter,
                        child: SeedPhraseGrid(
                          words: _words,
                          is24Words: _is24Words,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Toggle for 12/24 words - below grid, left-aligned
                      Row(
                        children: [
                          MallowToggle(
                            value: _is24Words,
                            onChanged: _toggleWordCount,
                            label: 'Use a 24-word recovery phrase',
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      // Info card
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: context.mallowColors.bgSurface,
                          borderRadius: BorderRadius.circular(
                            MallowTheme.radiusPrimary,
                          ),
                        ),
                        child: Row(
                          children: [
                            const MallowSvgIcon(
                              'assets/icons/pencil.svg',
                              width: 24,
                              height: 24,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Write this phrase down and store it somewhere safe. '
                                'Do not share the phrase with anyone.',
                                style: MallowTheme.uiCaption.copyWith(
                                  color: context.mallowColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Checkbox for confirmation
              MallowCheckbox(
                value: _hasConfirmed,
                onChanged: (val) => setState(() => _hasConfirmed = val),
                label: "I've saved my recovery phrase in a secure location",
              ),
              const SizedBox(height: 20),
              // Continue button (disabled until confirmed)
              MallowButton(
                label: 'Continue',
                onPressed: _hasConfirmed ? _continue : null,
                isFullWidth: true,
                enabled: _hasConfirmed,
                isLoading: _isSubmitting,
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  void _copyToClipboard() {
    // Copy and auto-clear after 60 seconds
    HapticFeedback.lightImpact();
    SecurityUtils.copyToClipboardWithClear(_mnemonic);

    AppSnackBar.show(
      context,
      'Copied! Clipboard will be cleared in 60 seconds.',
      duration: const Duration(seconds: 3),
    );
  }

  Future<void> _continue() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      if (widget.isAddingAccount) {
        // Multi-account path: go to HD picker — seed phrase created on import
        if (mounted) {
          context.go(AppRoutes.importFromPhrasePath('new'), extra: _mnemonic);
        }
      } else {
        // Onboarding path: create seed phrase, continue to PIN/biometric setup
        final walletRepo = sl<WalletRepository>();
        await walletRepo.createSeedPhrase(_mnemonic);
        // Wallet is persisted and the user has confirmed they saved the phrase
        // (the checkbox gating this button), so both the creation and the
        // backup are complete at this single terminal point.
        unawaited(
          sl<AnalyticsService>().track(
            AnalyticsEvent.walletCreated,
            properties: {AnalyticsProp.chain: AnalyticsChain.solana.wire},
          ),
        );
        final authNotifier = sl<AuthStateNotifier>();
        authNotifier.onWalletCreated();

        if (mounted) {
          context.go(AppRoutes.biometricSetup);
        }
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, 'Failed to create wallet: $e');
        setState(() => _isSubmitting = false);
      }
    }
  }
}
