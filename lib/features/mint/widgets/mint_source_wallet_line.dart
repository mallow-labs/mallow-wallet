import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../portfolio/data/session_portfolio_aggregator.dart';
import '../../portfolio/models/token_balance.dart';
import '../../send/widgets/send_sheet_widgets.dart';
import '../../send/widgets/send_wallet_select_sheet.dart';
import '../services/mint_bloc.dart';

import '../../../shared/utils/chain.dart';

/// "Your wallet · Switch" source line for the mint review step, reusing the
/// send flow's [SendSourceLine] and picker sheet.
///
/// Two things make this different from the send/staking source line:
///
///  * The chosen wallet is **not just the payer** — it is written on-chain as
///    the artwork's creator and update authority, and that is permanent. The
///    caption spells that out so nobody mints under the wrong identity by
///    tapping through.
///  * Nothing renders at all below two funded candidates, so a single-wallet
///    session never sees a wallet decision it can't act on.
///
/// Candidates are the session's signable Solana wallets that can actually fund
/// the mint — `qualifies(isNative: true)` applies the SOL fee buffer, which is
/// the right gate for a tx paying fees *and* account rent.
class MintSourceWalletLine extends StatefulWidget {
  const MintSourceWalletLine({
    required this.address,
    required this.onSwitchingChanged,
    super.key,
  });

  /// The wallet the form is currently building for — `MintState.userPubkey`.
  final String address;

  /// Raised with `true` while a switch is in flight so the host can disable the
  /// mint CTA: the picker commits a durable, app-wide signer change, and the
  /// creator/fee re-derivation lands after it.
  final ValueChanged<bool> onSwitchingChanged;

  @override
  State<MintSourceWalletLine> createState() => _MintSourceWalletLineState();
}

class _MintSourceWalletLineState extends State<MintSourceWalletLine> {
  List<SendSourceCandidate> _sources = const [];
  bool _switching = false;

  /// Address the bloc is expected to re-derive to after a committed switch.
  /// Non-null while the CTA must stay blocked (see [_onSwitch]).
  String? _pendingAddress;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSources());
  }

  Future<void> _loadSources() async {
    final candidates = await sl<SessionPortfolioAggregator>()
        .sendSourcesForMint(chain: Chain.solana, mint: TokenBalance.solMint);
    if (!mounted) return;
    setState(() {
      _sources = [
        for (final c in candidates)
          if (c.qualifies(isNative: true)) c,
      ];
    });
  }

  Future<void> _onSwitch() async {
    String? activeWalletId;
    for (final c in _sources) {
      if (c.wallet.address == widget.address) {
        activeWalletId = c.wallet.id;
        break;
      }
    }
    _setSwitching(true);
    try {
      // The sheet commits the switch (including the awaited re-login) and
      // reports null on cancel *or* failure, having surfaced the error itself —
      // so a failed switch simply leaves the form on the previous wallet.
      final chosen = await showSendWalletSelectSheet(
        context,
        chain: Chain.solana,
        tokenSymbol: 'SOL',
        candidates: _sources,
        activeWalletId: activeWalletId,
      );
      if (!mounted || chosen == null || chosen.address == widget.address) {
        _setSwitching(false);
        return;
      }
      // Re-derive the creator/authority, the parent collection and the fee
      // estimate for the newly-active wallet.
      //
      // Deliberately do NOT clear the switching flag here. The handler is async
      // (it awaits `getAddress()`) before it emits the new `userPubkey`,
      // rewrites the self-creator row and clears the fee estimate. Re-enabling
      // the Mint CTA in that window would let a confirm land while the previous
      // wallet is still the on-chain creator and royalty recipient — permanent
      // and unfixable after mint. `didUpdateWidget` clears it once the bloc has
      // actually re-derived the address.
      _pendingAddress = chosen.address;
      context.read<MintBloc>().add(const MintEvent.sourceWalletChanged());
      unawaited(_loadSources());
    } catch (_) {
      _setSwitching(false);
      rethrow;
    }
  }

  @override
  void didUpdateWidget(MintSourceWalletLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The bloc has re-derived the creator — safe to re-enable the CTA. If the
    // re-derive fails (unresolvable address), the flag stays set and the CTA
    // stays blocked: the safe direction, since the alternative is minting a
    // permanent creator the user did not choose.
    if (_pendingAddress != null && widget.address == _pendingAddress) {
      _pendingAddress = null;
      _setSwitching(false);
    }
  }

  void _setSwitching(bool value) {
    if (!mounted) return;
    setState(() => _switching = value);
    widget.onSwitchingChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    if (_sources.length < 2) return const SizedBox.shrink();
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SendSourceLine(
          address: widget.address,
          onSwitch: _switching ? null : _onSwitch,
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        Text(
          'This wallet is minted as the on-chain creator and update authority '
          "— it can't be changed after minting.",
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}
