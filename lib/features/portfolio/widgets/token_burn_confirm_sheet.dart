import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/services/transaction_flow_state.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/generic_confirmation_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/transaction_confirmation_sheet_base.dart';
import '../../../shared/widgets/tx_cost_summary.dart';
import '../../send/widgets/send_sheet_widgets.dart';
import '../../send/widgets/send_wallet_select_sheet.dart';
import '../data/session_portfolio_aggregator.dart';
import '../models/token_balance.dart';
import '../services/token_balance_bloc.dart';
import '../services/token_burn_bloc.dart';

import '../../../shared/utils/chain.dart';

/// Confirmation sheet for burning a fungible token's entire balance and
/// closing its token account. Mirrors the NFT burn sheet: danger styling, a
/// simulation banner, and a fee / reclaimed-rent breakdown.
///
/// A burn only ever destroys the **active** wallet's holding of the mint, so
/// when more than one session wallet holds it the sheet offers the shared
/// "Your wallet · Switch" source line above the CTA.
class TokenBurnConfirmSheet extends StatefulWidget {
  const TokenBurnConfirmSheet({
    required this.token,
    required this.tokenBalanceBloc,
    super.key,
    this.onConfirmed,
  });

  /// When provided, the confirm tap dispatches the burn and then calls this
  /// instead of popping the route — used by the single-route flow host that
  /// morphs the confirm step into the pipeline step in place. When null, the
  /// sheet pops `true` so a separate-route host can take over.
  final VoidCallback? onConfirmed;

  final TokenBalance token;

  /// Passed explicitly (rather than read from context) so opening the sheet via
  /// a modal route surfaces the dependency at compile time. Burn collects no
  /// payment so the balance check is skipped, but the base still requires it.
  final TokenBalanceBloc tokenBalanceBloc;

  @override
  State<TokenBurnConfirmSheet> createState() => _TokenBurnConfirmSheetState();
}

class _TokenBurnConfirmSheetState extends State<TokenBurnConfirmSheet> {
  /// Session wallets that actually hold this mint — the candidates for the
  /// source line. A wallet without a token account for the mint can't be burned
  /// from at all (the tx build fails outright), so it is never offered.
  /// "Switch" only appears with two or more.
  List<SendSourceCandidate> _sources = const [];

  /// The wallet the burn is currently built for, from the same
  /// [WalletManager.getAddress] DB read the tx builder and the payer-delta
  /// simulation use — so the address shown is the address that signs.
  String? _payer;

  /// True while the picker is open / the switch is committing. Disables the
  /// Burn CTA: the picker can be drag-dismissed before its `/v0/login` settles,
  /// which would otherwise leave this sheet tappable mid-switch.
  bool _switching = false;

  /// The burned holding. Re-pointed at the chosen wallet's balance on a switch
  /// so the header amount — and the auth gate's USD threshold, which is derived
  /// from it — describe the wallet that will actually sign.
  late TokenBalance _token = widget.token;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    try {
      final payer = await sl<WalletManager>().getAddress();
      final candidates = await sl<SessionPortfolioAggregator>()
          .sendSourcesForMint(chain: Chain.solana, mint: widget.token.mint);
      if (!mounted) return;
      setState(() {
        _payer = payer;
        _sources = [
          for (final c in candidates)
            if (c.rawBalance > 0) c,
        ];
      });
    } catch (_) {
      // No resolvable active wallet / balance cache — leave the source line
      // hidden rather than blocking the burn the user already opened.
    }
  }

  /// "Switch" tapped — open the shared picker (which commits the signer switch
  /// and awaits its re-login), then rebuild the burn: the prepared tx, the fee
  /// and the simulated rent reclaim were all derived for the previous payer.
  Future<void> _onSwitchSource() async {
    if (_switching) return;
    final bloc = context.read<TokenBurnBloc>();
    String? activeWalletId;
    for (final c in _sources) {
      if (c.wallet.address == _payer) {
        activeWalletId = c.wallet.id;
        break;
      }
    }

    setState(() => _switching = true);
    try {
      final chosen = await showSendWalletSelectSheet(
        context,
        chain: Chain.solana,
        tokenSymbol: widget.token.symbol,
        candidates: _sources,
        activeWalletId: activeWalletId,
      );
      if (!mounted) return;
      // Cancelled, or the switch failed (the picker surfaced the error and kept
      // the previous wallet selected) — leave the prepared tx alone.
      if (chosen == null) return;

      SendSourceCandidate? picked;
      for (final c in _sources) {
        if (c.wallet.id == chosen.id) {
          picked = c;
          break;
        }
      }
      _token = picked == null ? _token : picked.narrow(_token);
      // Re-prepare (which re-simulates) for the newly-active wallet.
      bloc.add(TokenBurnPrepareRequested(_token));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
    await _loadSources();
  }

  @override
  Widget build(BuildContext context) {
    final token = _token;
    return TransactionConfirmationSheetBase<TokenBurnBloc, TokenBurnState>(
      title: 'Burn Token',
      confirmLabel: 'Burn Token',
      confirmVariant: MallowButtonVariant.danger,
      tokenBalanceBloc: widget.tokenBalanceBloc,
      // Keeps the CTA disabled (and spinning) for the whole switch, including
      // the window after a mid-switch drag-dismiss of the picker.
      isProcessingFor: (_) => _switching,
      // The bloc auto-simulates after preparing; nothing to kick off here.
      onSimulate: (_) {},
      // Dispatch the burn, then either advance the host's morphing flow to the
      // pipeline step ([onConfirmed]) or pop `true` so a separate-route host can
      // open the pipeline sheet itself.
      onConfirm: (context, bloc) {
        bloc.add(const TokenBurnConfirmRequested());
        final advance = widget.onConfirmed;
        if (advance != null) {
          advance();
        } else {
          Navigator.of(context).pop(true);
        }
      },
      // Prep failed while the sheet was up (it mounts during preparing) — pop
      // so the host can surface the reason. Post-confirm failures land in the
      // pipeline sheet instead, by which point this sheet is already gone.
      listener: (context, state) {
        if (state is TxFlowFailure<TokenBurnPrep, TokenBurnSuccess>) {
          Navigator.of(context).pop(false);
        }
      },
      simulationFor: (state) {
        final prep = state is TxFlowReady<TokenBurnPrep, TokenBurnSuccess>
            ? state.data
            : null;
        // Treat "not ready yet" (preparing) as simulating so the confirm
        // button stays disabled until the tx is built and simulated.
        return SimulationBannerState(
          isSimulating: prep == null || prep.isSimulating,
          result: prep?.simulationResult,
        );
      },
      bodyBuilder: (context, state) {
        final prep = state is TxFlowReady<TokenBurnPrep, TokenBurnSuccess>
            ? state.data
            : null;
        final payer = _payer;
        return [
          _TokenBurnHeader(token: token),
          const SizedBox(height: MallowTheme.spacingLg),
          _buildBurnBreakdown(
            context,
            estimatedFeeLamports: prep?.estimatedFeeLamports,
            payerNetLamports: prep?.simulatedPayerLamportsDelta,
            isSimulating: prep?.isSimulating ?? false,
            isPreparing: prep == null,
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          Text(
            'This burns all of your ${token.symbol} and closes its token '
            'account. This cannot be undone.',
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
          if (payer != null) ...[
            const SizedBox(height: MallowTheme.spacingLg),
            SendSourceLine(
              address: payer,
              onSwitch: _sources.length >= 2 && !_switching
                  ? _onSwitchSource
                  : null,
            ),
          ],
        ];
      },
    );
  }
}

/// Token logo + name + a "Burn all {amount} {symbol}" subtitle.
class _TokenBurnHeader extends StatelessWidget {
  const _TokenBurnHeader({required this.token});

  final TokenBalance token;

  static final _amountFormat = NumberFormat('#,##0.#####');

  @override
  Widget build(BuildContext context) {
    final assetPath = localTokenImagePath(token.mint);
    final logo = Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: context.mallowColors.divider,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      clipBehavior: Clip.antiAlias,
      child: assetPath != null
          ? Image.asset(assetPath, width: 48, height: 48, fit: BoxFit.cover)
          : token.logoUrl != null
          ? MallowNetworkImage(
              imageUrl: token.logoUrl!,
              logicalSize: 48,
              width: 48,
              height: 48,
            )
          : Center(
              child: Text(
                token.symbol.isNotEmpty ? token.symbol[0].toUpperCase() : '?',
                style: MallowTheme.uiBody.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ),
    );

    return Row(
      children: [
        logo,
        const SizedBox(width: MallowTheme.spacing12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                token.name,
                style: MallowTheme.editorialQuote.copyWith(
                  color: context.mallowColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                'Burn all ${_amountFormat.format(token.uiBalance)} '
                '${token.symbol}',
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Fee + reclaimed-rent breakdown. Identical in shape to the NFT burn sheet:
/// a network-fee row plus, once simulation produces a payer-balance delta, a
/// "Rent reclaimed" row and a green "You'll receive" total.
///
/// While the tx is still building ([isPreparing]) both rows shimmer. Once the
/// fee is known but the simulation is still in flight, the fee shows and only
/// the reclaimed-rent row shimmers.
TxCostSummary _buildBurnBreakdown(
  BuildContext context, {
  required int? estimatedFeeLamports,
  required int? payerNetLamports,
  required bool isSimulating,
  required bool isPreparing,
}) {
  if (isPreparing || estimatedFeeLamports == null) {
    return TxCostSummary(
      lines: [
        TxCostLine.shimmer(label: 'Network fee'),
        TxCostLine.shimmer(label: 'Rent reclaimed'),
      ],
    );
  }

  final feeLine = TxCostLine.lamports(
    label: 'Network fee',
    lamports: estimatedFeeLamports,
    sign: '-',
  );
  if (payerNetLamports == null || payerNetLamports <= 0) {
    return TxCostSummary(
      lines: [
        feeLine,
        if (isSimulating) TxCostLine.shimmer(label: 'Rent reclaimed'),
      ],
    );
  }

  // payerNetLamports is signed and already includes the fee. Adding the fee
  // back gives the gross rent figure the user actually reclaims.
  final grossReclaimLamports = payerNetLamports + estimatedFeeLamports;
  return TxCostSummary(
    lines: [
      feeLine,
      TxCostLine.lamports(
        label: 'Rent reclaimed',
        lamports: grossReclaimLamports,
      ),
    ],
    total: TxCostLine.lamports(
      label: "You'll receive",
      lamports: payerNetLamports,
      sign: '+',
      valueColor: context.mallowColors.positive,
    ),
  );
}
