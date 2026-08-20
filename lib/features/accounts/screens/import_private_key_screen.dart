import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/security/redacted.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_textarea_field.dart';
import '../../home/widgets/drawer_signal.dart';
import '../services/import_private_key_bloc.dart';

/// Two-step private key import:
/// 1. Enter/paste the key → validate
/// 2. Show wallet summary → confirm import
class ImportPrivateKeyScreen extends StatelessWidget {
  const ImportPrivateKeyScreen({required this.accountId, super.key});

  final String accountId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<ImportPrivateKeyBloc>(),
      child: _ImportPrivateKeyBody(accountId: accountId),
    );
  }
}

class _ImportPrivateKeyBody extends StatefulWidget {
  const _ImportPrivateKeyBody({required this.accountId});

  final String accountId;

  @override
  State<_ImportPrivateKeyBody> createState() => _ImportPrivateKeyBodyState();
}

class _ImportPrivateKeyBodyState extends State<_ImportPrivateKeyBody> {
  final _controller = TextEditingController();
  // Retained across `importing`/`imported` so the summary stays mounted while
  // the import finishes — otherwise the textarea (still holding the key)
  // briefly re-renders.
  ImportPrivateKeyValidated? _summarySnapshot;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: BlocConsumer<ImportPrivateKeyBloc, ImportPrivateKeyState>(
            listener: (context, state) {
              if (state is ImportPrivateKeyValidated) {
                _summarySnapshot = state;
              } else {
                state.maybeWhen(
                  importing: () {},
                  imported: (_) {
                    final authNotifier = sl<AuthStateNotifier>();
                    if (!authNotifier.hasCompletedOnboarding) {
                      authNotifier.onWalletCreated();
                      context.go(AppRoutes.biometricSetup);
                    } else {
                      AppSnackBar.show(context, 'Wallet imported');
                      DrawerSignal.showAccountsOnNextOpen = true;
                      context.go(AppRoutes.home);
                    }
                  },
                  orElse: () => _summarySnapshot = null,
                );
              }
            },
            builder: (context, state) {
              final isImporting = state.maybeWhen(
                importing: () => true,
                imported: (_) => true,
                orElse: () => false,
              );
              final summary = state is ImportPrivateKeyValidated
                  ? state
                  : (isImporting ? _summarySnapshot : null);
              final showSummary = summary != null;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  MallowHeader(
                    title: 'Import private key',
                    onBack: isImporting
                        ? null
                        : () {
                            if (showSummary) {
                              context.read<ImportPrivateKeyBloc>().add(
                                const ImportPrivateKeyEvent.validateKey(
                                  Redacted(''),
                                ),
                              );
                            } else {
                              context.pop();
                            }
                          },
                    actions: [
                      if (!showSummary)
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
                  const SizedBox(height: 16),
                  if (showSummary)
                    _buildSummary(context, summary)
                  else
                    _buildInput(context, state),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildInput(BuildContext context, ImportPrivateKeyState state) {
    final errorMessage = state.maybeWhen(
      error: (msg) => msg,
      orElse: () => null,
    );
    final isValidating = state.maybeWhen(
      validating: () => true,
      orElse: () => false,
    );

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MallowSectionLabel(label: 'Enter your private key.'),
          const SizedBox(height: MallowTheme.spacingMd),
          MallowTextareaField(
            controller: _controller,
            hintText: 'Paste your private key here...',
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: MallowTheme.spacingXs),
            Text(
              errorMessage,
              style: MallowTheme.uiCaption.copyWith(
                color: context.mallowColors.error,
              ),
            ),
          ],
          const SizedBox(height: MallowTheme.spacingSm),
          Text(
            'You can add any Solana, Ethereum or Tezos wallet by entering '
            'the private key associated with that wallet.',
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
          const Spacer(),
          MallowButton(
            label: isValidating ? 'Validating...' : 'Next',
            onPressed: _controller.text.trim().isNotEmpty && !isValidating
                ? () {
                    context.read<ImportPrivateKeyBloc>().add(
                      ImportPrivateKeyEvent.validateKey(
                        Redacted(_controller.text),
                      ),
                    );
                  }
                : null,
            isFullWidth: true,
            enabled: _controller.text.trim().isNotEmpty && !isValidating,
            isLoading: isValidating,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSummary(BuildContext context, ImportPrivateKeyValidated state) {
    final isImporting = context.read<ImportPrivateKeyBloc>().state.maybeWhen(
      importing: () => true,
      imported: (_) => true,
      orElse: () => false,
    );

    return Expanded(
      child: Column(
        children: [
          const SizedBox(height: 20),
          // Chain icon
          MallowSvgIcon(state.chain.paddedIconAsset, width: 58, height: 58),
          const SizedBox(height: 40),
          // Full address
          Text(
            state.address,
            textAlign: TextAlign.center,
            style: MallowTheme.uiBody.copyWith(
              fontWeight: FontWeight.w600,
              color: context.mallowColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          if (state.artworkCount != null)
            Text(
              'This wallet has ${state.artworkCount} artworks',
              style: MallowTheme.uiMeta.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
          const Spacer(),
          MallowButton(
            label: isImporting ? 'Adding...' : 'Add wallet',
            onPressed: !isImporting
                ? () {
                    context.read<ImportPrivateKeyBloc>().add(
                      const ImportPrivateKeyEvent.importWallet(),
                    );
                  }
                : null,
            isFullWidth: true,
            enabled: !isImporting,
            isLoading: isImporting,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    setState(() {});
  }
}
