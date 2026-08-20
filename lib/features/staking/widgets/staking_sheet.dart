import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/config/remote_config_service.dart';
import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/chain_support_guard.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../portfolio/data/token_repository.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../services/staking_bloc.dart';
import '../staking_constants.dart';
import 'staking_form_tab.dart';
import 'staking_leaderboard_tab.dart';
import 'staking_pipeline_sheet_view.dart';
import 'staking_season_banner.dart';

/// Open the stake sheet. Reuses the caller's [TokenBalanceBloc] for balances
/// and spins up a fresh [StakingBloc].
///
/// Deliberately **not** a kill-switch gate: this one entry hosts four distinct
/// builders (`stake-native`, `unstake-native`, `withdraw-stake`,
/// `stake-liquid`), so gating here would collapse all four into a single
/// switch — and would strand deactivated stake behind a kill of the stake
/// path. The gates live per-action in [StakingFormTab]; all this does is
/// refresh the config on the way in so those gates read a fresh value.
///
/// The **chain** gate does belong here, though: that objection turns on the
/// four cells being independently killable, and all four are `{Chain.solana}`,
/// so one check covers the sheet. Gating here rather than at the callers is
/// what stops the staking banner — which renders off aggregated session
/// balances, including a *view-only* Solana wallet's — from opening a stake
/// form that has no signer and cannot fund.
Future<void> showStakeSheet(BuildContext context) {
  if (guardUnsupportedChain(context, AppFlow.stakeNative, action: 'Staking')) {
    return Future<void>.value();
  }
  unawaited(sl<RemoteConfigService>().refreshIfStale());
  final tokenBalanceBloc = context.read<TokenBalanceBloc>();
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider.value(value: tokenBalanceBloc),
        BlocProvider(
          create: (_) => sl<StakingBloc>()..add(const StakingEvent.loadData()),
        ),
      ],
      child: const StakingSheet(),
    ),
  );
}

class StakingSheet extends StatefulWidget {
  const StakingSheet({super.key});

  @override
  State<StakingSheet> createState() => _StakingSheetState();
}

class _StakingSheetState extends State<StakingSheet> {
  /// Season number whose banner the user has closed. Seeded from — and written
  /// back to — [PreferencesService] so the dismissal survives closing the sheet
  /// and restarting the app. Scoped to the season rather than a flat bool so a
  /// new season's banner still shows.
  int? _dismissedSeason;

  /// True while the in-flight [StakingPipelineSheetView] is on screen — stops
  /// the flow listener from stacking a second pipeline sheet on each
  /// signing/broadcasting transition.
  bool _pipelineShown = false;

  @override
  void initState() {
    super.initState();
    _dismissedSeason = sl<PreferencesService>().dismissedStakingSeason;
    // Seed balances for the active signer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshActiveBalances();
    });
  }

  /// Push the **active signer's own** SOL + mallowSOL balances into the bloc —
  /// not the session aggregate, so an aggregating Profile session shows the
  /// balance of the wallet actually shown in the "Your wallet" line. Reads the
  /// per-wallet cache; [refresh] fans out to the network.
  Future<void> _refreshActiveBalances({bool refresh = false}) async {
    final address = context.read<StakingBloc>().state.myAddress;
    if (address == null || address.isEmpty) return;
    final repo = sl<TokenRepository>();
    List<TokenBalance> tokens;
    try {
      tokens = refresh
          ? await repo.getTokenBalances(address)
          : await repo.getCachedBalances(address);
    } catch (_) {
      return; // keep whatever the bloc already had
    }
    // Bail if unmounted or the active wallet changed while we were fetching.
    if (!mounted || context.read<StakingBloc>().state.myAddress != address) {
      return;
    }
    var sol = 0;
    var mallowSol = 0;
    for (final token in tokens) {
      if (token.isNative && token.mint == TokenBalance.solMint) {
        sol = token.rawBalance;
      } else if (token.mint == StakingConstants.mallowSolMint) {
        mallowSol = token.rawBalance;
      }
    }
    context.read<StakingBloc>().add(
      StakingEvent.balancesUpdated(
        solLamports: sol,
        mallowSolLamports: mallowSol,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return MultiBlocListener(
      listeners: [
        // A portfolio refresh updated the per-wallet caches — re-pull the
        // active wallet's balance from its own cache.
        BlocListener<TokenBalanceBloc, TokenBalanceState>(
          listener: (context, _) => _refreshActiveBalances(),
        ),
        // The active signer changed (first load or a "Switch") — fetch that
        // wallet's balance, network-fresh.
        BlocListener<StakingBloc, StakingState>(
          listenWhen: (a, b) => a.myAddress != b.myAddress,
          listener: (context, _) => _refreshActiveBalances(refresh: true),
        ),
        BlocListener<StakingBloc, StakingState>(
          listenWhen: (a, b) => a.flow.runtimeType != b.flow.runtimeType,
          listener: _onFlowChanged,
        ),
      ],
      child: Container(
        height: MediaQuery.of(context).size.height * 0.9,
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        // Tap anywhere on empty space to dismiss the keyboard while typing the
        // amount. Interactive children (tabs, buttons, the field) win their own
        // hit areas, so only bare taps reach this handler.
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.opaque,
          // Reserve the keyboard's height inside the fixed-height sheet so the
          // scrollable region shrinks and the submit button rides just above the
          // keyboard when the amount field is focused. Kept inside the container
          // (not around it) so the 0.9-height sheet + keyboard never overflow the
          // screen. The button's own spacer stays on `includeKeyboard: false`.
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              children: [
                const SheetDragHandle(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      MallowTheme.spacing20,
                      MallowTheme.spacing12,
                      MallowTheme.spacing20,
                      0,
                    ),
                    child: BlocBuilder<StakingBloc, StakingState>(
                      builder: (context, state) => _body(context, state),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The flow left idle (submit/claim started) — present the in-flight
  /// pipeline sheet once. It owns every later transition (signing →
  /// broadcasting → success/error) and its own dismissal + form reset; this
  /// host just launches it and clears the guard when it closes.
  void _onFlowChanged(BuildContext context, StakingState state) {
    final active = state.flow is! TxFlowIdle<StakePrep, StakeSuccessData>;
    if (!active || _pipelineShown) return;
    _pipelineShown = true;
    final stakingBloc = context.read<StakingBloc>();
    final tokenBalanceBloc = context.read<TokenBalanceBloc>();
    showTransactionPipelineSheet(
      context: context,
      builder: (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: stakingBloc),
          BlocProvider.value(value: tokenBalanceBloc),
        ],
        child: const StakingPipelineSheetView(),
      ),
    ).whenComplete(() {
      if (!mounted) return;
      _pipelineShown = false;
      final flow = stakingBloc.state.flow;
      // A kill caught by the signing backstop closed the pipeline sheet without
      // an error body — explain it here, over this (still open) stake form, so
      // the operator's message reads the same mid-flow as at the per-action
      // gates in [StakingFormTab]. The cell isn't
      // known here (this sheet fronts four of them and the failure carries only
      // the message), so the event lands with its `surface` dimension only.
      // `this.context`, not the listener's: the `mounted` check above is the
      // guard for this State's own context after the sheet's async gap.
      if (flow is TxFlowFailure<StakePrep, StakeSuccessData>) {
        handleFlowDisabled(this.context, flow.failure);
      }
      // If the sheet was dragged away mid-error (rather than dismissed via its
      // Back/Retry actions, which reset), the flow is still non-idle and the
      // form stays locked — reset it back to an editable idle state.
      if (flow is! TxFlowIdle<StakePrep, StakeSuccessData>) {
        stakingBloc.add(const StakingEvent.reset());
      }
    });
  }

  void _dismissBanner(int season) {
    setState(() => _dismissedSeason = season);
    unawaited(sl<PreferencesService>().setDismissedStakingSeason(season));
  }

  Widget _body(BuildContext context, StakingState state) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.data != null &&
            state.data!.currentSeason.season != _dismissedSeason) ...[
          StakingSeasonBanner(
            season: state.data!.currentSeason,
            onDismiss: () => _dismissBanner(state.data!.currentSeason.season),
          ),
          const SizedBox(height: MallowTheme.spacingLg),
        ],
        _TabSwitcher(
          active: state.tab,
          onSelect: (tab) =>
              context.read<StakingBloc>().add(StakingEvent.setTab(tab)),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        Expanded(child: _tabContent(context, state, colors)),
      ],
    );
  }

  Widget _tabContent(
    BuildContext context,
    StakingState state,
    MallowColors colors,
  ) {
    if (state.isLoading && state.data == null) {
      return Center(child: MallowLoader(color: colors.accent));
    }
    if (state.data == null && state.loadError != null) {
      return Center(
        child: Text(
          state.loadError!.message,
          style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
        ),
      );
    }
    final data = state.data;
    if (data == null) return const SizedBox.shrink();

    switch (state.tab) {
      case StakeTab.stake:
      case StakeTab.unstake:
        return const StakingFormTab();
      case StakeTab.leaderboard:
        return StakingLeaderboardTab(data: data, myAddress: state.myAddress);
    }
  }
}

class _TabSwitcher extends StatelessWidget {
  const _TabSwitcher({required this.active, required this.onSelect});

  final StakeTab active;
  final ValueChanged<StakeTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _tab(context, 'Stake', StakeTab.stake),
        _tab(context, 'Unstake', StakeTab.unstake),
        _tab(context, 'Leaderboard', StakeTab.leaderboard),
        Expanded(
          child: Container(
            height: 33,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.mallowColors.dividerLight),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tab(BuildContext context, String label, StakeTab tab) {
    final colors = context.mallowColors;
    final selected = active == tab;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: () => onSelect(tab),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: MallowTheme.spacingSm,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.textPrimary : colors.dividerLight,
                width: selected ? 2 : 1,
              ),
            ),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ),
    );
  }
}
