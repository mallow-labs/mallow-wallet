import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/crypto/exceptions.dart';
import '../../../core/crypto/mnemonic_generator.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/seed_phrase_grid.dart';

/// Screen for importing an existing wallet via seed phrase.
///
/// Supports two input modes:
/// - Paste full phrase
/// - Word-by-word input with suggestions
class ImportWalletScreen extends StatefulWidget {
  const ImportWalletScreen({
    this.isAddingAccount = false,
    this.accountId,
    super.key,
  });

  /// When true, creates a new seed phrase via WalletRepository and navigates
  /// to the HD picker (skips PIN/biometric setup).
  final bool isAddingAccount;

  /// If provided, imports seed into this existing account.
  final String? accountId;

  @override
  State<ImportWalletScreen> createState() => _ImportWalletScreenState();
}

class _ImportWalletScreenState extends State<ImportWalletScreen> {
  bool _isImporting = false;
  bool _is24Words = false;
  String? _errorMessage;
  late List<String> _words;

  @override
  void initState() {
    super.initState();
    _words = List.filled(12, '');
  }

  /// Fire the `Wallet Imported` analytics event for a recovery-phrase import.
  void _trackImported() {
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImported,
        properties: {
          AnalyticsProp.chain: AnalyticsChain.solana.wire,
          AnalyticsProp.method: 'seed_phrase',
        },
      ),
    );
  }

  /// Fire `Wallet Import Failed`. Recovery-phrase failures here are local
  /// (invalid phrase, secure-storage write) with no matching [FailureReason]
  /// bucket, so they report [FailureReason.unknown].
  void _trackImportFailed() {
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImportFailed,
        properties: {
          AnalyticsProp.method: 'seed_phrase',
          AnalyticsProp.reason: FailureReason.unknown.wire,
        },
      ),
    );
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
                    onPressed: _pasteFromClipboard,
                    icon: const MallowSvgIcon(
                      'assets/icons/paste.svg',
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
              const SizedBox(height: 12),
              // Subtitle
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Enter your recovery phrase',
                  style: MallowTheme.uiMeta.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Seed phrase grid (editable) with toggle below
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
                          editable: true,
                          onWordChanged: (index, word) {
                            setState(() => _words[index] = word);
                          },
                          onPhrasePasted: _handlePhrasePasted,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Toggle for 12/24 words - below grid, left-aligned
                      Row(
                        children: [
                          MallowToggle(
                            value: _is24Words,
                            onChanged: (val) {
                              setState(() {
                                _is24Words = val;
                                _words = List.filled(val ? 24 : 12, '');
                              });
                            },
                            label: 'Use a 24-word recovery phrase instead',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // Error message
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: MallowTheme.uiLabel.copyWith(
                    color: context.mallowColors.error,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              // Import button
              if (_isImporting)
                const Center(
                  child: MallowLoadingIndicator(message: 'Importing wallet...'),
                )
              else
                MallowButton(
                  label: 'Continue',
                  onPressed: _canImport ? _importWallet : null,
                  isFullWidth: true,
                  enabled: _canImport,
                ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  bool get _canImport {
    final filledWords = _words.where((w) => w.isNotEmpty).length;
    final expectedWords = _is24Words ? 24 : 12;
    return filledWords == expectedWords && !_isImporting;
  }

  void _handlePhrasePasted(List<String> words) {
    final targetCount = words.length >= 24 ? 24 : 12;
    setState(() {
      _words = List.generate(
        targetCount,
        (i) => i < words.length ? words[i].toLowerCase() : '',
      );
      _is24Words = targetCount == 24;
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      final words = data!.text!.trim().split(RegExp(r'\s+'));
      _handlePhrasePasted(words);
    }
  }

  Future<void> _importWallet() async {
    final mnemonic = _words.join(' ').trim().toLowerCase();

    // Validate before attempting import
    if (!MnemonicGenerator.validate(mnemonic)) {
      setState(() {
        _errorMessage = 'Invalid recovery phrase. Please check your words.';
      });
      _trackImportFailed();
      return;
    }

    setState(() {
      _isImporting = true;
      _errorMessage = null;
    });

    try {
      if (widget.accountId != null || widget.isAddingAccount) {
        // Navigate to HD picker — seed phrase is created only on import.
        // Pass a placeholder accountId in the path; mnemonic goes via extra.
        if (mounted) {
          context.go(AppRoutes.importFromPhrasePath('new'), extra: mnemonic);
        }
      } else {
        // Onboarding path: create seed phrase, continue to PIN/biometric setup
        final walletRepo = sl<WalletRepository>();
        await walletRepo.createSeedPhrase(mnemonic);
        _trackImported();
        final authNotifier = sl<AuthStateNotifier>();
        authNotifier.onWalletCreated();

        if (mounted) {
          context.go(AppRoutes.biometricSetup);
        }
      }
    } on InvalidMnemonicException catch (e) {
      _trackImportFailed();
      if (mounted) {
        setState(() {
          _errorMessage = e.message;
        });
      }
    } on PlatformException catch (e) {
      // Secure-storage failures surface as PlatformExceptions from the native
      // vault channel. Log the code (never the value) so the real cause is
      // diagnosable instead of being hidden behind the generic message.
      AppLogger.error(
        'ImportWallet',
        'Secure storage write failed (code: ${e.code})',
        e.message,
      );
      _trackImportFailed();
      if (mounted) {
        setState(() {
          _errorMessage =
              'Could not securely store your wallet. Make sure your device '
              'is unlocked, then try again.';
        });
      }
    } catch (e) {
      AppLogger.error('ImportWallet', 'Unexpected import failure', e);
      _trackImportFailed();
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to import wallet. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }
}
