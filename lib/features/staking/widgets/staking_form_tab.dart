import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/config/remote_config.dart';
import '../../../core/config/remote_config_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../portfolio/data/session_portfolio_aggregator.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../../send/widgets/send_sheet_widgets.dart';
import '../../send/widgets/send_wallet_select_sheet.dart';
import '../services/staking_bloc.dart';
import '../staking_constants.dart';
import '../staking_format.dart';
import 'stake_confirm_sheet.dart';
import 'stake_status_cards.dart';
import 'staking_stat_card.dart';

import '../../../shared/utils/chain.dart';

/// The Stake and Unstake tabs (same chrome, different balances/labels).
/// Matches the Figma spec.
class StakingFormTab extends StatefulWidget {
  const StakingFormTab({super.key});

  @override
  State<StakingFormTab> createState() => _StakingFormTabState();
}

/// How often the liquid quote is re-fetched while the liquid path is selected.
/// Webapp parity: `StakingSection` (`refetchInterval: 30_000`). The
/// quote is what the disclosure below shows *and* what gets signed, so it must
/// not be allowed to age arbitrarily while the sheet sits open.
const _quoteRefreshInterval = Duration(seconds: 30);

class _StakingFormTabState extends State<StakingFormTab> {
  final _controller = TextEditingController();
  Timer? _quoteDebounce;
  Timer? _quoteRefresh;

  /// Signable Solana wallets in the current session — the candidates for the
  /// "Your wallet · Switch" source line. The Switch action only appears with
  /// two or more.
  List<SendSourceCandidate> _sources = const [];

  @override
  void initState() {
    super.initState();
    _loadSources();
    _syncQuoteRefresh(context.read<StakingBloc>().state);
  }

  @override
  void dispose() {
    _quoteDebounce?.cancel();
    _quoteRefresh?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Run the [_quoteRefreshInterval] poll only while the liquid path is
  /// selected — the native path has no quote to keep fresh.
  void _syncQuoteRefresh(StakingState state) {
    final wanted = state.stakeType == StakeType.liquid;
    if (wanted == (_quoteRefresh != null)) return;
    if (!wanted) {
      _quoteRefresh?.cancel();
      _quoteRefresh = null;
      return;
    }
    _quoteRefresh = Timer.periodic(_quoteRefreshInterval, (_) {
      if (mounted) {
        context.read<StakingBloc>().add(
          const StakingEvent.refreshLiquidQuote(),
        );
      }
    });
  }

  Future<void> _loadSources() async {
    final candidates = await sl<SessionPortfolioAggregator>()
        .sendSourcesForMint(
          chain: Chain.solana,
          mint: StakingConstants.solMint,
        );
    if (mounted) setState(() => _sources = candidates);
  }

  /// "Switch" tapped on the source line — open the shared wallet picker (which
  /// commits the signer switch itself), then reload staking data + balances for
  /// the newly-active wallet.
  Future<void> _onSwitchSource() async {
    final myAddress = context.read<StakingBloc>().state.myAddress;
    String? activeWalletId;
    for (final c in _sources) {
      if (c.wallet.address == myAddress) {
        activeWalletId = c.wallet.id;
        break;
      }
    }
    final chosen = await showSendWalletSelectSheet(
      context,
      chain: Chain.solana,
      tokenSymbol: 'SOL',
      candidates: _sources,
      activeWalletId: activeWalletId,
    );
    if (!mounted || chosen == null) return;
    // The picker already re-pointed the signer; reload for the new wallet.
    context.read<StakingBloc>().add(const StakingEvent.loadData());
    context.read<TokenBalanceBloc>().add(const TokenBalanceEvent.refresh());
    unawaited(_loadSources());
  }

  void _onAmountChanged(String value) {
    context.read<StakingBloc>().add(StakingEvent.setAmount(value));
    _scheduleQuote();
  }

  void _scheduleQuote() {
    _quoteDebounce?.cancel();
    _quoteDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        context.read<StakingBloc>().add(
          const StakingEvent.refreshLiquidQuote(),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return BlocConsumer<StakingBloc, StakingState>(
      listenWhen: (a, b) => a.amount != b.amount || a.stakeType != b.stakeType,
      listener: (context, state) {
        _syncQuoteRefresh(state);
        // Keep the field in sync when amount is set programmatically
        // (Half / Max / reset), or when the typed value was clamped to the
        // reserve-adjusted maximum.
        if (_controller.text != state.amount) {
          _controller.text = state.amount;
          _controller.selection = TextSelection.collapsed(
            offset: state.amount.length,
          );
        }
      },
      builder: (context, state) {
        final data = state.data;
        final isStake = state.tab == StakeTab.stake;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _amountHeader(context, state),
                    const SizedBox(height: MallowTheme.spacing12),
                    _amountInput(context, state),
                    if (state.belowNativeMinimum) ...[
                      const SizedBox(height: MallowTheme.spacingSm),
                      _minimumWarning(context),
                    ],
                    const SizedBox(height: MallowTheme.spacing12),
                    _halfMax(context),
                    const SizedBox(height: MallowTheme.spacingLg),
                    _stakeTypeSection(context, state),
                    const SizedBox(height: MallowTheme.spacingLg),
                    if (isStake) _yieldEstimate(context, state),
                    if (state.stakeType == StakeType.liquid) ...[
                      if (isStake)
                        const SizedBox(height: MallowTheme.spacingSm),
                      _receiveRow(context, state),
                    ],
                    if (isStake || state.stakeType == StakeType.liquid)
                      const SizedBox(height: MallowTheme.spacingLg),
                    if (state.stakeType == StakeType.native) ...[
                      Text(
                        'Note: Native stake is locked until the end of each '
                        'epoch (~2 days). Unstaked funds are claimable at the '
                        'next epoch end.',
                        style: MallowTheme.uiCaption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      if (!isStake) ...[
                        const SizedBox(height: MallowTheme.spacing12),
                        _unstakeStateCards(context, state),
                      ],
                      const SizedBox(height: MallowTheme.spacingLg),
                    ],
                    if (data != null && isStake) _statCards(context, state),
                    // The unstake tab surfaces deactivating/claimable funds via
                    // the cards above; keep this copy on the stake tab only.
                    if (isStake) _stakeStatusCards(context, state),
                  ],
                ),
              ),
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            if (state.myAddress?.isNotEmpty ?? false) ...[
              SendSourceLine(
                address: state.myAddress!,
                onSwitch: _sources.length >= 2 ? _onSwitchSource : null,
              ),
              const SizedBox(height: MallowTheme.spacing12),
            ],
            _submitSection(context, state),
            // Keep the button clear of the home indicator / bottom safe area.
            SizedBox(height: sheetBottomInset(context, includeKeyboard: false)),
          ],
        );
      },
    );
  }

  Widget _amountHeader(BuildContext context, StakingState state) {
    final colors = context.mallowColors;
    final symbol = state.inputMint == StakingConstants.mallowSolMint
        ? 'mallowSOL'
        : 'SOL';
    return Row(
      children: [
        Expanded(
          child: Text(
            state.tab == StakeTab.stake ? 'Stake amount' : 'Unstake amount',
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'Balance: ',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              TextSpan(
                text:
                    '${StakingFormat.lamportsSol(state.availableLamports)} '
                    '$symbol',
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _amountInput(BuildContext context, StakingState state) {
    final colors = context.mallowColors;
    final raw = state.typedLamports;
    final usd = sl<TokenPriceService>().usdValueOfRaw(raw, state.inputMint);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
      ),
      child: Row(
        children: [
          // Tracks the mint being spent — a liquid unstake spends mallowSOL,
          // so the field must not claim SOL. `size: 18` keeps the full-bleed
          // SOL glyph at its established 14px (see [tokenImageWidget]).
          tokenImageWidget(
            mint: state.inputMint,
            size: 18,
            symbol: state.inputMint == StakingConstants.mallowSolMint
                ? 'mallowSOL'
                : 'SOL',
            enlargeChainGlyph: true,
          ),
          const SizedBox(width: MallowTheme.spacing12),
          Expanded(
            child: TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
              ],
              onChanged: _onAmountChanged,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '0',
                hintStyle: MallowTheme.uiBody.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
          if (usd != null)
            Text(
              StakingFormat.usd(usd),
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }

  /// Shown while a native stake amount is below the 1 SOL minimum.
  Widget _minimumWarning(BuildContext context) {
    final colors = context.mallowColors;
    return Text(
      'Minimum native stake is 1 SOL.',
      style: MallowTheme.uiCaption.copyWith(color: colors.warning),
    );
  }

  Widget _halfMax(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _smallButton(context, 'Half', () {
          context.read<StakingBloc>().add(const StakingEvent.setHalf());
          _scheduleQuote();
        }),
        const SizedBox(width: MallowTheme.spacingSm),
        _smallButton(context, 'Max', () {
          context.read<StakingBloc>().add(const StakingEvent.setMax());
          _scheduleQuote();
        }),
      ],
    );
  }

  Widget _smallButton(BuildContext context, String label, VoidCallback onTap) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacingSm,
            vertical: MallowTheme.spacingXs,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: colors.divider),
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          ),
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ),
    );
  }

  Widget _stakeTypeSection(BuildContext context, StakingState state) {
    final colors = context.mallowColors;
    final data = state.data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stake type',
          style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacing12),
        // Liquid first: it is the unlocked path (no epoch wait, no 1 SOL
        // minimum), so it leads the pair.
        _typeRow(
          context,
          state,
          type: StakeType.liquid,
          label: 'Liquid',
          apy: data?.liquidApy,
          trailing: null,
        ),
        const SizedBox(height: MallowTheme.spacing12),
        _typeRow(
          context,
          state,
          type: StakeType.native,
          label: 'Native',
          apy: data?.nativeApy,
          // active **+ activating**, not active alone: on the unstake tab this
          // is the balance Half/Max fill from and the amount the builder can
          // actually deactivate ([StakingState.availableLamports]), so an
          // active-only figure read as a cap the form then exceeded.
          trailing: state.nativeStake == null
              ? null
              : 'Bal: ${StakingFormat.lamportsSol(state.availableNativeLamports)} SOL',
        ),
      ],
    );
  }

  Widget _typeRow(
    BuildContext context,
    StakingState state, {
    required StakeType type,
    required String label,
    required double? apy,
    required String? trailing,
  }) {
    final colors = context.mallowColors;
    final selected = state.stakeType == type;
    return TapTargetExpander(
      child: GestureDetector(
        onTap: () {
          context.read<StakingBloc>().add(StakingEvent.setStakeType(type));
          // The toggle keeps the typed amount, so selecting Liquid arrives with
          // an amount and no quote — fetch one, same as Half / Max do. Only on
          // an actual change: re-tapping the selected row is a bloc no-op, and
          // scheduling here anyway would throw away the good quote it kept.
          if (state.stakeType != type) _scheduleQuote();
        },
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            _radio(context, selected),
            const SizedBox(width: MallowTheme.spacingSm),
            Text(
              label,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            _apyBadge(context, apy),
            const Spacer(),
            if (trailing != null)
              Text(
                trailing,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _radio(BuildContext context, bool selected) {
    final colors = context.mallowColors;
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? colors.accent : colors.textSecondary,
          width: 1.5,
        ),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.accent,
                ),
              ),
            )
          : null,
    );
  }

  Widget _apyBadge(BuildContext context, double? apy) {
    final colors = context.mallowColors;
    return Container(
      width: 72,
      padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacingXs),
      decoration: BoxDecoration(
        color: colors.dividerLight,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Text(
        apy == null ? 'APY —' : 'APY ${StakingFormat.apy(apy)}',
        textAlign: TextAlign.center,
        style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
      ),
    );
  }

  /// Liquid-path quote disclosure: what the swap returns.
  ///
  /// A liquid stake/unstake *is* a Jupiter swap. Without this the quote was
  /// fetched, consumed to build the tx and never shown, so the user signed a
  /// trade with no preview of what they would get. Webapp parity: receive
  /// amount `StakingSection`.
  Widget _receiveRow(BuildContext context, StakingState state) {
    // Only a quote priced for the amount currently typed is shown — see
    // [StakingState.displayQuote].
    final quote = state.displayQuote;
    final outSymbol = state.inputMint == StakingConstants.mallowSolMint
        ? 'SOL'
        : 'mallowSOL';
    // Nothing usable yet: "Fetching…" while an amount is typed (the webapp
    // shows a skeleton here), an em dash when the field is empty.
    final placeholder = state.typedLamports > 0 ? 'Fetching…' : '—';
    return _quoteRow(
      context,
      'Receive',
      quote == null
          ? placeholder
          : '${StakingFormat.receiveAmount(quote.outAmount)} $outSymbol',
    );
  }

  /// Label left, value flush to the content's right edge — `Expanded` on the
  /// value (not the label) is what pins it there; a loose `Flexible` would
  /// shrink to the text's intrinsic width and leave it stranded mid-row.
  Widget _quoteRow(BuildContext context, String label, String value) {
    final colors = context.mallowColors;
    return Row(
      children: [
        Text(
          label,
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(width: MallowTheme.spacingSm),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ],
    );
  }

  /// Protocol-wide stat row, then the signed-in user's own position — the
  /// webapp's two `StatCard` grids (`MainContent`).
  Widget _statCards(BuildContext context, StakingState state) {
    final data = state.data!;
    final totalStaked = StakingFormat.withCommas(
      StakingFormat.lamportsToSol(
        int.tryParse(data.totalSolStakedLamports) ?? 0,
      ),
    );
    // The mallowSOL exchange rate. Without it the liquid path quotes a
    // receive amount with nothing to sanity-check it against, and a holder
    // has no way to see what their mallowSOL is currently worth in SOL.
    final rate = data.solPerMallowSol > 0
        ? '${StakingFormat.withCommas(data.solPerMallowSol, decimals: 5)} SOL'
        : '—';
    final hasAddress = state.myAddress?.isNotEmpty ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacing12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: StakingStatCard(
                  label: 'Total staked',
                  value: '$totalStaked SOL',
                ),
              ),
              const SizedBox(width: MallowTheme.spacing12),
              Expanded(
                child: StakingStatCard(label: '1 mallowSOL =', value: rate),
              ),
              const SizedBox(width: MallowTheme.spacing12),
              Expanded(
                child: StakingStatCard(
                  label: 'Total stakers',
                  value: StakingFormat.withCommas(data.totalStakers),
                ),
              ),
            ],
          ),
          if (hasAddress) ...[
            const SizedBox(height: MallowTheme.spacing12),
            Row(
              children: [
                Expanded(
                  child: StakingStatCard(
                    label: 'Your native stake',
                    value:
                        '${StakingFormat.withCommas(StakingFormat.lamportsToSol(state.nativeStake?.activeLamports ?? 0), decimals: 2)} SOL',
                  ),
                ),
                const SizedBox(width: MallowTheme.spacing12),
                Expanded(
                  // The mallowSOL wallet balance, exactly as the webapp reads
                  // it (`balanceByMint[MALLOW_SOL]`) — the indexed
                  // `userData.liquidStake` is its SOL-equivalent and is only
                  // used server-side to derive points.
                  child: StakingStatCard(
                    label: 'Your liquid stake',
                    value:
                        '${StakingFormat.withCommas(StakingFormat.lamportsToSol(state.mallowSolLamports), decimals: 2)} mallowSOL',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// `~X SOL / year` for the amount currently typed at the selected path's APY
  /// (webapp `StakingSection`). Staking is sold on yield; the
  /// APY badges alone never turn into a number for *this* stake.
  Widget _yieldEstimate(BuildContext context, StakingState state) {
    final apy = state.isNativeStake
        ? state.data?.nativeApy
        : state.data?.liquidApy;
    if (apy == null) return const SizedBox.shrink();
    // The amount as typed — not `submitLamports`, which floors a native stake
    // at the rent-adjusted minimum and would quote yield on an empty field.
    final sol = double.tryParse(state.amount) ?? 0;
    return _quoteRow(
      context,
      'Estimated yield',
      '~${StakingFormat.withCommas(sol * apy, decimals: 3)} SOL / year',
    );
  }

  /// Stake / Unstake tapped — review before signing.
  ///
  /// The CTA sits directly under the amount field on a tall sheet, one stray
  /// tap from committing real funds, so it opens [showStakeConfirmSheet] rather
  /// than submitting. Anything but an explicit confirm (Cancel, a drag-dismiss)
  /// leaves the form exactly as it was.
  ///
  /// 🛑 The dispatch is deliberately **after** the await: the confirm sheet has
  /// popped by then, so [StakingSheet._onFlowChanged] pushes the pipeline sheet
  /// over the stake form and not over a route that is on its way out.
  ///
  /// Claim is not gated the same way — it collects the user's own deactivated
  /// stake and carries no amount to get wrong.
  Future<void> _onSubmitTapped(BuildContext context) async {
    final bloc = context.read<StakingBloc>();
    final confirmed = await showStakeConfirmSheet(context);
    if (confirmed != true) return;
    bloc.add(const StakingEvent.submit());
  }

  /// Claim (withdraw) tapped, from either the unstake card or the stake-tab
  /// disclaimer.
  ///
  /// Its own `withdraw-stake` cell — an **escape hatch**: it is the only
  /// way deactivated stake gets back to the wallet, so a kill of `stake-native`
  /// must never reach it. Killing it deliberately is allowed, and explained on
  /// tap rather than greyed out silently: a Claim button that does nothing with
  /// funds sitting behind it is the worst version of this.
  Future<void> _onClaim(BuildContext context) async {
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.withdrawStake),
    )) {
      return;
    }
    if (!context.mounted) return;
    context.read<StakingBloc>().add(const StakingEvent.claim());
  }

  /// Claim season rewards tapped. Gated on the same `withdraw-stake` cell as
  /// [_onClaim] — see `StakingBloc._onClaimRewards` for why the two share one.
  Future<void> _onClaimRewards(BuildContext context) async {
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.withdrawStake),
    )) {
      return;
    }
    if (!context.mounted) return;
    context.read<StakingBloc>().add(const StakingEvent.claimRewards());
  }

  /// Unstake-tab native-stake status: any claimable funds (Claim button),
  /// funds still deactivating (claim countdown), and/or funds still activating.
  /// When none exists, falls back to the current epoch's progress.
  ///
  /// Ordered by hand rather than delegated to [StakeStatusCards]: claimable
  /// leads, because this is the tab you land on to collect, so the actionable
  /// card goes first.
  ///
  /// Activating stake belongs here, not just on the stake tab: this tab's
  /// balance and Max are `active + activating` ([StakingState.availableLamports],
  /// webapp `StakingSection`) and the unstake builder does deactivate
  /// activating accounts — so without this card the extra spendable SOL has no
  /// explanation. The webapp renders all three notices outside its tab switch
  /// for the same reason.
  Widget _unstakeStateCards(BuildContext context, StakingState state) {
    final native = state.nativeStake;
    if (native == null) return const SizedBox.shrink();
    final cards = <Widget>[
      if (state.smoresClaimableRaw > 0)
        StakeRewardsCard(
          smoresRaw: state.smoresClaimableRaw,
          onClaim: () => _onClaimRewards(context),
          isClaiming: state.isBusy,
        ),
      if (native.inactiveLamports > 0)
        StakeClaimableCard(
          lamports: native.inactiveLamports,
          onClaim: () => _onClaim(context),
          isClaiming: state.isBusy,
        ),
      if (native.deactivatingLamports > 0)
        StakeDeactivatingCard(
          lamports: native.deactivatingLamports,
          epoch: state.epochProgress,
        ),
      if (native.activatingLamports > 0)
        StakeActivatingCard(
          lamports: native.activatingLamports,
          epoch: state.epochProgress,
        ),
    ];
    if (cards.isEmpty) return _epochProgressCard(context, state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: MallowTheme.spacingSm,
      children: cards,
    );
  }

  /// No funds unstaking — show how far through the current epoch we are.
  Widget _epochProgressCard(BuildContext context, StakingState state) {
    final colors = context.mallowColors;
    final epoch = state.epochProgress;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MallowTheme.spacingSm),
      decoration: BoxDecoration(
        border: Border.all(color: colors.divider),
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            epoch == null ? 'Current epoch' : 'Epoch ${epoch.epoch}',
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingXs),
          Text(
            epoch == null
                ? 'Fetching epoch progress…'
                : '${StakingFormat.epochPercent(epoch.fraction)} complete  •  '
                      '(${StakingFormat.countdown(epoch.timeRemaining)} remaining)',
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }

  /// Stake-tab status: unclaimed season rewards and any funds activating,
  /// deactivating or claimable — the same cards the tokens portfolio renders.
  /// No epoch-progress fallback: on this tab an empty status collapses rather
  /// than filling the space.
  Widget _stakeStatusCards(BuildContext context, StakingState state) {
    final native = state.nativeStake;
    if (native == null) return const SizedBox.shrink();
    final hasRewards = state.smoresClaimableRaw > 0;
    final hasNative = StakeStatusCards.hasAny(native);
    if (!hasRewards && !hasNative) return const SizedBox.shrink();
    // Two conditional children rather than one flat list: `spacing` would put a
    // gap around a collapsed `StakeStatusCards`, so it must be absent, not
    // zero-height, when there is no native stake.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: MallowTheme.spacingSm,
      children: [
        if (hasRewards)
          StakeRewardsCard(
            smoresRaw: state.smoresClaimableRaw,
            onClaim: () => _onClaimRewards(context),
            isClaiming: state.isBusy,
          ),
        if (hasNative)
          StakeStatusCards(
            native: native,
            epoch: state.epochProgress,
            onClaim: () => _onClaim(context),
            isClaiming: state.isBusy,
          ),
      ],
    );
  }

  /// The submit CTA plus, when an operator has killed the cell this form would
  /// submit to, the server's explanation above it.
  ///
  /// A form is the one place the entry gate can't be a sheet on entry: the
  /// subject (native vs liquid, stake vs unstake) is only decided *inside* it.
  /// So the kill is surfaced inline and the CTA is dead — the user learns
  /// before typing an amount, not after. Which of the four staking cells this
  /// is comes from [stakingSubmitFlow], shared with the signing backstop.
  ///
  /// Rebuilds off [RemoteConfigService.config] so a refresh landing while the
  /// sheet is open takes effect without reopening it.
  Widget _submitSection(BuildContext context, StakingState state) {
    return ValueListenableBuilder<RemoteConfig>(
      valueListenable: sl<RemoteConfigService>().config,
      builder: (context, config, _) {
        final disabled = config.disabledMessage(
          Chain.solana,
          stakingSubmitFlow(stakeType: state.stakeType, tab: state.tab),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (disabled != null) ...[
              Text(
                disabled,
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.warning,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingSm),
            ],
            _submitButton(context, state, killed: disabled != null),
          ],
        );
      },
    );
  }

  Widget _submitButton(
    BuildContext context,
    StakingState state, {
    required bool killed,
  }) {
    final colors = context.mallowColors;
    // Same verb regardless of native/liquid — a liquid stake is still a
    // "Stake" to the user, not a "Swap".
    final label = state.tab == StakeTab.stake ? 'Stake' : 'Unstake';
    final enabled = state.canSubmit && !killed;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? () => _onSubmitTapped(context) : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.accent,
            borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
          ),
          child: state.isBusy
              ? MallowLoader(size: 20, color: colors.textOnAccent)
              : Text(
                  label,
                  style: MallowTheme.uiBody.copyWith(
                    color: colors.textOnAccent,
                  ),
                ),
        ),
      ),
    );
  }
}
