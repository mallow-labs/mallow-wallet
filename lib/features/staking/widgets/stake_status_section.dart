import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../services/staking_bloc.dart';
import 'stake_status_cards.dart';
import 'staking_sheet.dart';

/// [StakeStatusCards] for surfaces outside the stake sheet, with their own data
/// behind them — the tokens portfolio renders this above the sort row.
///
/// Self-loading because the portfolio has no staking data of its own: the
/// staking banner next to it is a static CTA, so this owns a [StakingBloc]
/// purely for the read. That bloc is **not** the sheet's — [showStakeSheet]
/// builds its own — which is why the refresh is wired to [TokenBalanceBloc]
/// below rather than shared directly.
///
/// Renders nothing at all when there is no native stake to report, including
/// its trailing gap, so the portfolio's 26 px rhythm closes up cleanly instead
/// of leaving a hole for the majority of users who have never staked.
class StakeStatusSection extends StatelessWidget {
  const StakeStatusSection({super.key});

  /// A finished balance load — not the `isRefreshing: true` half of one, so a
  /// single pull-to-refresh triggers a single staking re-read.
  static bool _settled(TokenBalanceState state) =>
      state.maybeMap(loaded: (s) => !s.isRefreshing, orElse: () => false);

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<StakingBloc>()..add(const StakingEvent.loadData()),
      child: BlocListener<TokenBalanceBloc, TokenBalanceState>(
        // Balances settling is this section's refresh signal: pull-to-refresh
        // dispatches it, and so does a successful stake/unstake/claim in the
        // sheet, which is the case that matters — the sheet's own bloc dies
        // with it, so without this the cells would still describe the
        // pre-stake world after the sheet closed.
        listenWhen: (a, b) => !_settled(a) && _settled(b),
        listener: (context, _) =>
            context.read<StakingBloc>().add(const StakingEvent.loadData()),
        child: BlocBuilder<StakingBloc, StakingState>(
          builder: (context, state) {
            final native = state.nativeStake;
            if (native == null || !StakeStatusCards.hasAny(native)) {
              return const SizedBox.shrink();
            }
            // The trailing 26 belongs to the cards, not to the portfolio: it
            // has to disappear with them, or a non-staker's list gains a hole.
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                0,
                MallowTheme.spacing20,
                MallowTheme.spacing26,
              ),
              child: StakeStatusCards(
                native: native,
                epoch: state.epochProgress,
                // Claiming needs the biometric gate, the withdraw-stake kill
                // switch and a progress sheet; all of that already lives in
                // the stake sheet, so send the user there rather than host a
                // second copy of the tx pipeline in the portfolio.
                onClaim: () => showStakeSheet(context),
              ),
            );
          },
        ),
      ),
    );
  }
}
