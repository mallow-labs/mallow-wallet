import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../cast/widgets/now_casting_bar.dart';
import '../../receive/sheets/account_receive_sheet.dart';
import '../models/token_balance.dart';
import 'portfolio_action_buttons.dart';
import 'portfolio_value_section.dart';
import 'token_list_item.dart';
import 'token_sort_header.dart';

import '../../../shared/utils/chain.dart';

/// 0-balance placeholder row for a chain's native gas token.
TokenBalance nativePlaceholder(Chain chain) => switch (chain) {
  Chain.solana => TokenBalance.nativeSol(lamports: 0, pricePerToken: 0),
  Chain.ethereum => TokenBalance.nativeEth(),
  Chain.tezos => TokenBalance.nativeTezos(),
};

/// Empty state shown when the user has no tokens.
///
/// Signable wallets get a funding prompt card (its own \$0.00 + a
/// `Transfer crypto` CTA), the action-button row, and 0-balance gas-token rows.
/// Watch-only wallets — which cannot sign or fund — keep the bare \$0.00 value
/// over the same gas-token rows.
class TokensEmptyState extends StatelessWidget {
  const TokensEmptyState({
    required this.totalUsd,
    required this.canSend,
    required this.chains,
    super.key,
  });

  final double totalUsd;

  /// Whether the session can send anything. False collapses the layout to the
  /// value section alone — no funding card, no action row.
  ///
  /// Not "the active wallet is view-only": the row's Send works off the
  /// session's wallet on the token's chain, so a watch-only Solana selection
  /// alongside a signable ETH wallet must still get the actionable layout.
  final bool canSend;

  /// Native chains the current session holds a wallet for, ordered SOL → ETH →
  /// XTZ. The first entry drives the top card's copy; one 0-balance gas-token
  /// row is shown per entry.
  final List<Chain> chains;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      // The empty state rarely fills the viewport — keep it pullable so the
      // enclosing RefreshIndicator can trigger.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverToBoxAdapter(
          child: SizedBox(height: MallowTheme.spacing26),
        ),
        // Signable wallets: a card prompting the user to transfer their
        // preferred native asset (it carries its own $0.00) followed by the
        // action-button row. Watch-only wallets cannot sign or fund, so they
        // keep the plain $0.00 value with no CTAs.
        if (!canSend)
          SliverToBoxAdapter(child: PortfolioValueSection(totalUsd: totalUsd))
        else ...[
          SliverToBoxAdapter(
            child: _TransferCard(totalUsd: totalUsd, chain: chains.first),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: MallowTheme.spacing26),
          ),
          const SliverToBoxAdapter(child: PortfolioActionButtonsRow()),
        ],
        const SliverToBoxAdapter(
          child: SizedBox(height: MallowTheme.spacing26),
        ),
        // Sort header
        SliverToBoxAdapter(
          child: TokenSortHeader(
            currentSort: TokenSortOption.topValue,
            onSortChanged: (_) {},
          ),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: MallowTheme.spacingXs),
        ),
        // One $0 native gas-token row per chain the session has a wallet for,
        // ordered SOL → ETH → XTZ.
        for (final chain in chains)
          SliverToBoxAdapter(
            child: TokenListItem(token: nativePlaceholder(chain)),
          ),
        // Bottom reserve for nav bar (grows when cast bar is active).
        const SliverToBoxAdapter(child: NavBarBottomReserve()),
      ],
    );
  }
}

/// Signable empty-state prompt: \$0.00 over a short instruction and a
/// `Transfer crypto` (receive) CTA. The chain named in the copy is the
/// session's preferred native chain, passed in by the caller (SOL → ETH → XTZ).
class _TransferCard extends StatelessWidget {
  const _TransferCard({required this.totalUsd, required this.chain});

  final double totalUsd;
  final Chain chain;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Container(
        padding: const EdgeInsets.all(MallowTheme.spacing12),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PortfolioValueSection(totalUsd: totalUsd, padding: EdgeInsets.zero),
            const SizedBox(height: MallowTheme.spacing12),
            Text(
              'To get started, transfer ${chain.label} to your wallet',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: MallowTheme.spacing12),
            MallowButton(
              label: 'Transfer crypto',
              variant: MallowButtonVariant.secondary,
              isFullWidth: true,
              onPressed: () => showSessionReceiveSheet(context),
            ),
          ],
        ),
      ),
    );
  }
}
