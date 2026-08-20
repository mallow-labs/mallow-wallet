import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/data/mallow_tokens.dart';
import '../../../../core/models/account.dart';
import '../../../../core/network/auth_service.dart';
import '../../../../di.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../portfolio/data/session_portfolio_aggregator.dart';
import '../../../portfolio/services/token_balance_bloc.dart';
import '../../../send/widgets/send_sheet_widgets.dart';
import '../../../send/widgets/send_wallet_select_sheet.dart';

import '../../../../shared/utils/chain.dart';

/// "Your wallet: `<addr>` · Switch" source line above an artwork **funding**
/// CTA — buy, make offer, place bid, buy raffle tickets. Part of the
/// wallet-switching contract.
///
/// Same shape as the send and staking pickers: candidates come from
/// [SessionPortfolioAggregator.sendSourcesForMint] keyed on the flow's own
/// funding mint, the switch itself is committed by [showSendWalletSelectSheet],
/// and the line is **never rendered with fewer than two candidates** — with one
/// signable wallet there is nothing to switch to.
///
/// This is the one funding flow on the `AuthService.currentAddress` side of
/// the fault line: its dispatches reach `MarketplaceActionFlow.prepare`, which
/// reads the address of the last `/v0/login` rather than the DB selection. That
/// is only safe because `SessionManager.selectSourceWallet` awaits the login —
/// mid-switch the address is null. Hence [builder] is handed
/// a `switching` flag so the CTA disables itself for the duration; tapping Buy
/// during the gap would build the tx with no authority at all.
class ArtworkFundingSource extends StatefulWidget {
  const ArtworkFundingSource({
    required this.currencyMint,
    required this.builder,
    super.key,
  });

  /// The mint this flow is funded in — the listing / offer / bid / ticket
  /// currency. Null means SOL.
  final String? currencyMint;

  /// The CTA(s) the line sits above. `switching` is true while a switch is in
  /// flight.
  final Widget Function(BuildContext context, bool switching) builder;

  @override
  State<ArtworkFundingSource> createState() => _ArtworkFundingSourceState();
}

class _ArtworkFundingSourceState extends State<ArtworkFundingSource> {
  /// Signable Solana wallets in the session paired with their balance of the
  /// funding mint. Empty until the scan resolves, so the affordance appears
  /// rather than flickering away.
  List<SendSourceCandidate> _sources = const [];

  bool _switching = false;

  String get _mint => widget.currencyMint ?? solMint;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSources());
  }

  @override
  void didUpdateWidget(ArtworkFundingSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The listing currency can change under the sheet (an auction resolving to
    // a buy-now, a refetch landing) — rescan against the new mint.
    if (oldWidget.currencyMint != widget.currencyMint) {
      unawaited(_loadSources());
    }
  }

  Future<void> _loadSources() async {
    List<SendSourceCandidate> candidates;
    try {
      candidates = await sl<SessionPortfolioAggregator>().sendSourcesForMint(
        chain: Chain.solana,
        mint: _mint,
      );
    } catch (_) {
      // A failed candidate scan degrades to "no switch affordance" — the flow
      // still funds from the active wallet, which is what it did before this
      // line existed.
      candidates = const [];
    }
    if (mounted) setState(() => _sources = candidates);
  }

  /// "Switch" tapped — hand off to the shared picker, which commits the signer
  /// switch (and awaits its `/v0/login`) itself, surfaces its own error and
  /// stays open on failure, and returns null when cancelled or failed.
  Future<void> _onSwitch() async {
    if (_switching) return;
    final me = sl<AuthService>().currentAddress;
    String? activeWalletId;
    for (final candidate in _sources) {
      if (candidate.wallet.address == me) {
        activeWalletId = candidate.wallet.id;
        break;
      }
    }
    setState(() => _switching = true);
    WalletInfo? chosen;
    try {
      chosen = await showSendWalletSelectSheet(
        context,
        chain: Chain.solana,
        tokenSymbol: tokenByMint(_mint)?.symbol ?? 'SOL',
        candidates: _sources,
        activeWalletId: activeWalletId,
      );
    } catch (_) {
      if (mounted) setState(() => _switching = false);
      rethrow;
    }
    // Cancelled, or the switch failed — the picker already reported it and the
    // previous wallet is still the signer, so nothing downstream is stale.
    if (chosen == null || !mounted) {
      if (mounted) setState(() => _switching = false);
      return;
    }
    // Every figure below this line was computed for the old wallet. The sheet
    // balance — and with it the affordability gate on the CTA — comes from
    // TokenBalanceBloc, so re-derive it, then rescan the candidates so their
    // per-wallet balances (and the active row) reflect the new selection.
    //
    // The CTA stays disabled until BOTH have landed. Clearing `_switching` as
    // soon as the picker closed would re-enable it while `checkBalanceOrSkip`
    // still reads the previous wallet's TokenBalanceBloc state, giving a wrong
    // affordability verdict on the first tap after a switch — a spurious
    // "insufficient funds", or a pass that then fails at simulate.
    context.read<TokenBalanceBloc>().add(const TokenBalanceEvent.refresh());
    await _loadSources();
    if (mounted) setState(() => _switching = false);
  }

  @override
  Widget build(BuildContext context) {
    final cta = widget.builder(context, _switching);
    final me = sl<AuthService>().currentAddress;
    // Fewer than two candidates → no affordance at all.
    if (_sources.length < 2 || me == null || me.isEmpty) return cta;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SendSourceLine(address: me, onSwitch: _switching ? null : _onSwitch),
        const SizedBox(height: MallowTheme.spacing12),
        cta,
      ],
    );
  }
}
