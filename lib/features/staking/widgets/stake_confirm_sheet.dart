import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/services/fee_config.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../send/widgets/send_sheet_widgets.dart';
import '../services/staking_bloc.dart';
import '../staking_constants.dart';
import '../staking_format.dart';

/// Open the Stake / Unstake confirmation, returning `true` only when the user
/// confirms. Cancel resolves `false`; a drag- or barrier-dismiss resolves
/// `null` — the caller treats everything but `true` as "do not submit".
///
/// 🛑 **Pop before dispatching.** [StakingSheet._onFlowChanged] pushes the
/// pipeline sheet the moment `flow` leaves idle, so a caller that dispatched
/// `StakingEvent.submit()` while this sheet was still mounted would stack the
/// pipeline on top of it and leave a dead confirm route underneath. Awaiting
/// this future puts the dispatch after the pop.
///
/// The sheet reads the live [StakingBloc], not a snapshot of it: the liquid
/// path's 30 s quote poll keeps running while this is open, and its result has
/// to land here — the "You'll receive" row is a shimmer until it does.
Future<bool?> showStakeConfirmSheet(BuildContext context) {
  final bloc = context.read<StakingBloc>();
  final colors = context.mallowColors;
  return showMallowSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider<StakingBloc>.value(
      value: bloc,
      child: Container(
        decoration: BoxDecoration(
          color: colors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.popupRadius),
          ),
        ),
        child: const StakeConfirmSheet(),
      ),
    ),
  );
}

/// Review step for a stake or unstake, following the Confirm Send layout:
/// an icon + amount summary, then one labelled pill per consequence, then
/// Cancel / confirm.
///
/// The middle section is the one that changes with the mechanism, because the
/// two mechanisms have entirely different consequences. **Native** is
/// epoch-bound, so it reports when the funds start (or stop) earning —
/// the thing a user cannot read off the form. **Liquid** is a Jupiter swap that
/// settles immediately, so an epoch countdown would describe a lock that does
/// not exist; it reports the swap output instead. Both keep the network fee.
///
/// There is no Recipient section: staking sends to the user's own stake account
/// or through a swap, so there is no counterparty to check.
class StakeConfirmSheet extends StatelessWidget {
  const StakeConfirmSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<StakingBloc, StakingState>(
      builder: (context, state) {
        final isStake = state.tab == StakeTab.stake;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetDragHandle(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: MallowTheme.spacing20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SendStepHeader(
                      title: isStake ? 'Confirm Stake' : 'Confirm Unstake',
                    ),
                    const SizedBox(height: MallowTheme.spacingLg),
                    _summaryRow(context, state),
                    const SizedBox(height: MallowTheme.spacingLg),
                    if (state.stakeType == StakeType.native)
                      _epochSection(context, state)
                    else
                      _receiveSection(context, state),
                    const SizedBox(height: MallowTheme.spacingLg),
                    _feeSection(context, state),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacing20,
                0,
              ),
              child: SendStepButtons(
                primaryLabel: isStake ? 'Stake' : 'Unstake',
                onCancel: () => Navigator.of(context).pop(false),
                onPrimary: () => Navigator.of(context).pop(true),
                // Shown, but with no Switch: the signer is chosen on the form,
                // and re-pointing it here would invalidate the balance the
                // amount on screen was validated against.
                sourceAddress: (state.myAddress?.isNotEmpty ?? false)
                    ? state.myAddress
                    : null,
              ),
            ),
            SizedBox(height: sheetBottomInset(context, includeKeyboard: false)),
          ],
        );
      },
    );
  }

  /// Stake glyph + the amount being committed, in the token being spent.
  ///
  /// The amount is the one **typed**, not [StakingState.submitLamports] — the
  /// latter floors a native stake at the rent-adjusted minimum, and that extra
  /// ~0.0023 SOL funds the new stake account rather than being delegated. The
  /// typed figure is what actually earns, and it is what the form's yield
  /// estimate quotes against.
  Widget _summaryRow(BuildContext context, StakingState state) {
    final colors = context.mallowColors;
    final usd = sl<TokenPriceService>().usdValueOfRaw(
      state.typedLamports,
      state.inputMint,
    );
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.surfaceMuted,
          ),
          child: Center(
            child: MallowSvgIcon(
              'assets/icons/diamond.svg',
              width: 24,
              height: 24,
              color: colors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: MallowTheme.spacing12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_amountText(state.amount)} ${_symbolOf(state.inputMint)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MallowTheme.uiDisplay.copyWith(
                        color: colors.textPrimary,
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
              const SizedBox(height: MallowTheme.spacingXs),
              Text(
                _mechanismOf(state.stakeType),
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Native only — when the stake starts, or stops, earning. Both transitions
  /// normally complete at the epoch boundary, so both read the same countdown;
  /// only the verb differs.
  ///
  /// The exception is unstaking stake that never finished activating: that
  /// deactivation short-circuits and the funds are claimable on the spot
  /// ([StakingState.deactivatesImmediately]). Showing the countdown there
  /// would report a two-day lock the user does not have — the countdown is
  /// this sheet's only claim about *when*, so it has to be the right one.
  Widget _epochSection(BuildContext context, StakingState state) {
    final colors = context.mallowColors;
    if (state.deactivatesImmediately) {
      return _section(
        // No "in": there is no interval to name.
        label: 'Deactivates',
        child: Text(
          'Immediately',
          style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
        ),
      );
    }
    final epoch = state.epochProgress;
    return _section(
      label: state.tab == StakeTab.stake ? 'Activates in' : 'Deactivates in',
      // The epoch read is best-effort and lands after the staking payload, so
      // it can still be in flight here.
      child: epoch == null
          ? const ShimmerBox(width: 64, height: 14)
          : Text(
              StakingFormat.countdown(epoch.timeRemaining),
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
    );
  }

  /// Liquid only — what the swap returns, in the token it returns.
  ///
  /// Reads [StakingState.displayQuote], so a quote priced for a different
  /// amount is never attached to this trade; the poll refreshes it in place
  /// while the sheet is open. The CTA stays live through the shimmer because
  /// the bloc fetches a quote at submit when it holds none — a pending quote is
  /// not a reason to strand the user on a dead button.
  Widget _receiveSection(BuildContext context, StakingState state) {
    final quote = state.displayQuote;
    final outMint = state.inputMint == StakingConstants.mallowSolMint
        ? StakingConstants.solMint
        : StakingConstants.mallowSolMint;
    return _section(
      label: "You'll receive",
      child: quote == null
          ? const ShimmerBox(width: 96, height: 14)
          : Row(
              children: [
                tokenImageWidget(
                  mint: outMint,
                  size: 16,
                  symbol: _symbolOf(outMint),
                  enlargeChainGlyph: true,
                ),
                const SizedBox(width: MallowTheme.spacingSm),
                Expanded(
                  child: Text(
                    '${StakingFormat.receiveAmount(quote.outAmount)} '
                    '${_symbolOf(outMint)}',
                    style: MallowTheme.uiBody.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  /// Base validator fee plus the user's **own** priority-fee ceiling, so a
  /// wallet that raised its ceiling in Settings is quoted the fee it will
  /// actually bid rather than the app default.
  ///
  /// An estimate, hence the `~`: the ceiling is an upper bound that
  /// `SolanaRpcService.computeBudgetIxs` clamps the network's live
  /// recommendation into, and the tx itself is not built until submit.
  Widget _feeSection(BuildContext context, StakingState state) {
    final colors = context.mallowColors;
    final feeLamports =
        kBaseSolanaTxFeeLamports + sl<PriorityFeeService>().ceilingLamports;
    final usd = sl<TokenPriceService>().usdValueOfRaw(
      feeLamports,
      StakingConstants.solMint,
    );
    return _section(
      label: 'Network fee',
      child: Row(
        children: [
          tokenImageWidget(
            mint: StakingConstants.solMint,
            size: 16,
            symbol: 'SOL',
            enlargeChainGlyph: true,
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: Text(
              '~${PriceFormatter.formatFeeLamports(feeLamports)}',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
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

  /// A labelled consequence: the heading, then the fact, in the same chrome
  /// Confirm Send states its recipient and fee in.
  Widget _section({required String label, required Widget child}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SendSectionLabel(label: label),
      const SizedBox(height: MallowTheme.spacing12),
      SendConfirmPill(child: child),
    ],
  );

  static String _symbolOf(String mint) =>
      mint == StakingConstants.mallowSolMint ? 'mallowSOL' : 'SOL';

  /// The mechanism this transaction will use. It sits under the amount instead
  /// of the token name because the token is already spelled out beside the
  /// figure above it, whereas the mechanism — which decides whether this is an
  /// epoch-bound delegation or an instant swap — is otherwise only inferable
  /// from which of the sections below happens to be rendered.
  static String _mechanismOf(StakeType type) =>
      type == StakeType.native ? 'Native stake' : 'Liquid stake';

  /// The typed amount as entered, minus a trailing decimal point — the form
  /// keeps `"1."` typeable, and it must not reach a confirmation screen.
  static String _amountText(String amount) {
    final trimmed = amount.endsWith('.')
        ? amount.substring(0, amount.length - 1)
        : amount;
    return trimmed.isEmpty ? '0' : trimmed;
  }
}
