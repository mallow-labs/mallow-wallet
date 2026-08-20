import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../features/portfolio/services/token_balance_bloc.dart';
import '../utils/balance_check.dart';
import 'generic_confirmation_sheet.dart';
import 'mallow_button.dart';

/// Payment requirement for the gas/balance check. Pass [requiredRawAmount]
/// as `null` when the amount isn't known yet (e.g. swap before quote);
/// pass `0` for gas-only flows.
class BalanceCheckSpec {
  const BalanceCheckSpec({
    required this.paymentMint,
    required this.requiredRawAmount,
    this.includeGasReserve = true,
    this.additionalSolLamports = 0,
  });

  final String? paymentMint;
  final int? requiredRawAmount;
  final bool includeGasReserve;

  /// SOL the tx spends beyond the payment and the gas reserve — owed whatever
  /// [paymentMint] is. See `checkBalance`'s `additionalSolLamports`.
  final int additionalSolLamports;
}

/// Shared lifecycle for transaction-confirmation sheets (send/swap/market).
///
/// Owns the bits every sheet was reimplementing by hand:
/// * post-frame `simulate` kickoff in `initState`
/// * `BlocBuilder`/`BlocConsumer` wrapping that exposes the BLoC state to the
///   body builder
/// * the `TokenBalanceBloc` balance check on confirm
/// * the confirm button with simulation/processing gating
/// * the standard `GenericConfirmationSheet` chrome
///
/// Each sheet is responsible for the parts that genuinely differ — its body
/// widgets, the per-state extractors for the simulation banner and balance
/// requirement, and what happens on confirm (pop, dispatch an event, both).
class TransactionConfirmationSheetBase<
  TBloc extends StateStreamableSource<TState>,
  TState
>
    extends StatefulWidget {
  const TransactionConfirmationSheetBase({
    required this.title,
    required this.confirmLabel,
    required this.onSimulate,
    required this.onConfirm,
    required this.bodyBuilder,
    required this.simulationFor,
    super.key,
    this.confirmLabelFor,
    this.confirmVariant = MallowButtonVariant.primary,
    this.balanceCheckFor,
    this.isProcessingFor,
    this.listener,
    this.tokenBalanceBloc,
    this.onCancel,
    this.cancelLabel = 'Cancel',
  });

  final String title;

  /// Default confirm label. May be overridden per-state via [confirmLabelFor]
  /// (e.g. "Swapping…" while signing).
  final String confirmLabel;
  final String Function(TState state)? confirmLabelFor;
  final MallowButtonVariant confirmVariant;

  /// Fired via `WidgetsBinding.addPostFrameCallback` after first mount.
  /// Typically dispatches the BLoC's `simulate` event.
  final void Function(TBloc bloc) onSimulate;

  /// Called when the user taps confirm AND the balance check passes AND the
  /// BLoC is not currently simulating/processing. Caller decides whether to
  /// `Navigator.pop(true)`, dispatch a BLoC event, or both.
  final void Function(BuildContext context, TBloc bloc) onConfirm;

  /// Renders the body region between the title and the simulation banner.
  /// Receives the latest BLoC state so per-state details (price deltas,
  /// route plans, simulated fee fallbacks) can be plumbed in.
  final List<Widget> Function(BuildContext context, TState state) bodyBuilder;

  /// Extracts the simulation banner inputs from the BLoC state.
  final SimulationBannerState Function(TState state) simulationFor;

  /// Returns the payment + amount the wallet must cover, or `null` to skip
  /// the balance check entirely. When non-null, the confirm button wraps in
  /// a [BlocBuilder]<[TokenBalanceBloc]> and runs [ensureSufficientBalance].
  final BalanceCheckSpec? Function(TState state)? balanceCheckFor;

  /// Returns `true` while the BLoC is mid-execute (signing/broadcasting).
  /// Disables the button and surfaces the spinner.
  final bool Function(TState state)? isProcessingFor;

  /// Optional state listener — used by sheets that stay mounted across the
  /// pipeline (swap) to pop on success/error.
  final void Function(BuildContext context, TState state)? listener;

  /// Override the ambient [TokenBalanceBloc] (e.g. when the sheet is opened
  /// via a modal route that doesn't inherit the screen-scoped provider).
  final TokenBalanceBloc? tokenBalanceBloc;

  /// Defaults to `Navigator.of(context).pop()`. Override to surface a
  /// specific result (`pop(false)`) or run extra cleanup.
  final VoidCallback? onCancel;

  final String cancelLabel;

  @override
  State<TransactionConfirmationSheetBase<TBloc, TState>> createState() =>
      _TransactionConfirmationSheetBaseState<TBloc, TState>();
}

class _TransactionConfirmationSheetBaseState<
  TBloc extends StateStreamableSource<TState>,
  TState
>
    extends State<TransactionConfirmationSheetBase<TBloc, TState>> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onSimulate(context.read<TBloc>());
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<TBloc, TState>(
      listener: (context, state) => widget.listener?.call(context, state),
      builder: (context, state) {
        final simulation = widget.simulationFor(state);
        final isProcessing = widget.isProcessingFor?.call(state) ?? false;
        final label =
            widget.confirmLabelFor?.call(state) ?? widget.confirmLabel;
        final disabled = isProcessing || simulation.isSimulating;
        final balanceSpec = widget.balanceCheckFor?.call(state);

        return GenericConfirmationSheet(
          title: widget.title,
          confirmLabel: label,
          confirmVariant: widget.confirmVariant,
          confirmLoading: isProcessing,
          cancelLabel: widget.cancelLabel,
          onCancel: widget.onCancel,
          // [onConfirm] on GenericConfirmationSheet is ignored when
          // [confirmSlot] is provided, but the param is non-nullable so
          // pass a stable no-op.
          onConfirm: () {},
          simulation: simulation,
          body: widget.bodyBuilder(context, state),
          confirmSlot: _ConfirmButton<TBloc, TState>(
            label: label,
            variant: widget.confirmVariant,
            isLoading: isProcessing,
            disabled: disabled,
            balanceSpec: balanceSpec,
            tokenBalanceBloc: widget.tokenBalanceBloc,
            onPressed: () => widget.onConfirm(context, context.read<TBloc>()),
          ),
        );
      },
    );
  }
}

class _ConfirmButton<TBloc extends StateStreamableSource<TState>, TState>
    extends StatelessWidget {
  const _ConfirmButton({
    required this.label,
    required this.variant,
    required this.isLoading,
    required this.disabled,
    required this.balanceSpec,
    required this.tokenBalanceBloc,
    required this.onPressed,
  });

  final String label;
  final MallowButtonVariant variant;
  final bool isLoading;
  final bool disabled;
  final BalanceCheckSpec? balanceSpec;
  final TokenBalanceBloc? tokenBalanceBloc;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (balanceSpec == null) {
      return MallowButton(
        label: label,
        variant: variant,
        isLoading: isLoading,
        onPressed: disabled ? null : onPressed,
      );
    }
    return BlocBuilder<TokenBalanceBloc, TokenBalanceState>(
      bloc: tokenBalanceBloc,
      builder: (context, balanceState) {
        final result = checkBalanceOrSkip(
          paymentMint: balanceSpec!.paymentMint,
          requiredRawAmount: balanceSpec!.requiredRawAmount,
          balanceState: balanceState,
          includeGasReserve: balanceSpec!.includeGasReserve,
          additionalSolLamports: balanceSpec!.additionalSolLamports,
        );
        return MallowButton(
          label: label,
          variant: variant,
          isLoading: isLoading,
          onPressed: disabled
              ? null
              : () {
                  if (!ensureSufficientBalance(context, result)) return;
                  onPressed();
                },
        );
      },
    );
  }
}
