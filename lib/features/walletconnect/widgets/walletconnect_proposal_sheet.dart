import 'package:flutter/material.dart';
import 'package:reown_core/reown_core.dart' show Validation;

import '../../../core/models/account.dart' show WalletInfo;
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/review_wallet_identity.dart';
import '../../../shared/widgets/signing_review_layout.dart';
import '../../../shared/widgets/sort_options_sheet.dart';
import '../../../shared/widgets/switch_pill.dart';
import '../../browser/widgets/browser_site_tile.dart';
import '../services/walletconnect_namespaces.dart';
import '../services/walletconnect_service.dart';

/// Opens a wallet picker for [chain] over the sheet, with [current] marked,
/// and returns the wallet picked, or null when the user backs out.
typedef WalletConnectWalletPicker =
    Future<WalletInfo?> Function(
      BuildContext context,
      Chain chain,
      WalletInfo current,
    );

/// Asks whether to connect a WalletConnect website, and with which wallet
/// for each network it asked for. Pops the chosen wallets, or null to reject.
///
/// The name, address and icon are the website's own report. The Verify line
/// under them is the only part WalletConnect checked: a website it could not
/// match to the address it reports is shown as such, and connecting to it
/// takes a deliberate "Connect anyway".
///
/// [pickWallet] backs each wallet row's Switch, as in the browser's connect
/// sheet. Without it, Switch lists the proposal's own candidates.
Future<Map<String, WalletInfo>?> showWalletConnectProposalSheet(
  BuildContext context,
  WalletConnectProposal proposal, {
  WalletConnectWalletPicker? pickWallet,
}) => Navigator.of(context).push(
  mallowSheetRoute<Map<String, WalletInfo>>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        WalletConnectProposalSheet(proposal: proposal, pickWallet: pickWallet),
  ),
);

class WalletConnectProposalSheet extends StatefulWidget {
  const WalletConnectProposalSheet({
    required this.proposal,
    this.pickWallet,
    super.key,
  });
  final WalletConnectProposal proposal;
  final WalletConnectWalletPicker? pickWallet;

  @override
  State<WalletConnectProposalSheet> createState() =>
      _WalletConnectProposalSheetState();
}

class _WalletConnectProposalSheetState
    extends State<WalletConnectProposalSheet> {
  late final Map<String, WalletInfo> _chosen = {
    for (final entry in widget.proposal.candidates.entries)
      entry.key: entry.value.first,
  };

  Future<void> _switch(String namespace) async {
    final pickWallet = widget.pickWallet;
    final chain = namespaceChain(namespace);
    if (pickWallet != null && chain != null) {
      final picked = await pickWallet(context, chain, _chosen[namespace]!);
      if (picked != null && picked.chainEnum == chain && mounted) {
        setState(() => _chosen[namespace] = picked);
      }
      return;
    }
    final options = widget.proposal.candidates[namespace]!;
    final picked = await showSortOptionsSheet<WalletInfo>(
      context,
      title: 'Connect with',
      options: options,
      currentSort: _chosen[namespace]!,
      labelFor: (wallet) {
        final identity = ReviewWalletIdentity.resolve(wallet.address);
        return wallet.canSign
            ? '${identity.label} · ${identity.shortAddress}'
            : '${identity.label} · ${identity.shortAddress} · view only';
      },
    );
    if (picked != null && mounted) setState(() => _chosen[namespace] = picked);
  }

  void _pop(Map<String, WalletInfo>? result) {
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final proposal = widget.proposal;
    final host = proposal.origin.host;
    final invalid = proposal.validation.invalid;
    final (
      verifyGlyph,
      verifyText,
      verifyColor,
    ) = switch (proposal.validation) {
      Validation.VALID => (
        ReviewGlyph.check,
        'Verified as $host',
        colors.textSecondary,
      ),
      Validation.INVALID => (
        ReviewGlyph.warning,
        "This request didn't come from $host",
        colors.error,
      ),
      _ => (
        ReviewGlyph.info,
        "WalletConnect couldn't verify this website",
        colors.textSecondary,
      ),
    };
    return SigningReviewLayout(
      footerDivider: false,
      footer: ReviewDecisionBar(
        rejectKey: const Key('walletconnect-reject'),
        approveKey: const Key('walletconnect-approve'),
        rejectLabel: 'Not now',
        approveLabel: invalid ? 'Connect anyway' : 'Connect',
        holdToApprove: invalid,
        onReject: () => _pop(null),
        onApprove: () => _pop(Map.unmodifiable(_chosen)),
      ),
      children: [
        const SizedBox(height: 14),
        Center(
          child: BrowserSiteTile(
            host: host,
            iconUrl: proposal.iconUrl,
            size: 64,
          ),
        ),
        const SizedBox(height: 22),
        ReviewTitle('Connect to ${proposal.name}?'),
        const SizedBox(height: 6),
        Text(
          proposal.origin.origin,
          textAlign: TextAlign.center,
          style: MallowTheme.uiMeta.copyWith(
            letterSpacing: 0,
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          key: const Key('walletconnect-verify'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ReviewIcon(verifyGlyph, size: 12, color: verifyColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                verifyText,
                textAlign: TextAlign.center,
                style: MallowTheme.uiMeta.copyWith(
                  letterSpacing: 0,
                  color: verifyColor,
                ),
              ),
            ),
          ],
        ),
        if (invalid) ...[
          const SizedBox(height: 10),
          Text(
            'Another website may be pretending to be $host. Connect only if '
            'you opened this connection yourself, on $host.',
            textAlign: TextAlign.center,
            style: MallowTheme.uiMeta.copyWith(
              letterSpacing: 0,
              color: colors.error,
            ),
          ),
        ],
        const ReviewSectionLabel('Connect with'),
        for (final (i, namespace) in proposal.namespaces.indexed) ...[
          if (i > 0) const SizedBox(height: MallowTheme.spacingSm),
          _WalletRow(
            network: _network(namespace.namespace),
            wallet: _chosen[namespace.namespace]!,
            onSwitch:
                widget.pickWallet != null ||
                    proposal.candidates[namespace.namespace]!.length > 1
                ? () => _switch(namespace.namespace)
                : null,
          ),
        ],
        const ReviewSectionLabel('This website will be able to'),
        const _Line(ReviewGlyph.eye, 'See the addresses above'),
        const SizedBox(height: 14),
        const _Line(
          ReviewGlyph.pencil,
          'Request transactions and signatures',
          detail: 'You approve each one here',
        ),
        const SizedBox(height: 14),
        const _Line(
          ReviewGlyph.cross,
          'It can never move funds without asking',
          muted: true,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  static String _network(String namespace) => switch (namespace) {
    'eip155' => 'Ethereum',
    'tezos' => 'Tezos',
    _ => 'Solana',
  };
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({
    required this.network,
    required this.wallet,
    required this.onSwitch,
  });
  final String network;
  final WalletInfo wallet;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final identity = ReviewWalletIdentity.resolve(wallet.address);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.dividerLight),
      ),
      child: Row(
        children: [
          Expanded(
            child: MergeSemantics(
              child: Row(
                children: [
                  ReviewWalletAvatar(identity: identity, size: 36),
                  const SizedBox(width: MallowTheme.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          identity.label,
                          style: MallowTheme.uiBody.copyWith(
                            fontWeight: FontWeight.w500,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            identity.shortAddress,
                            network,
                            if (!wallet.canSign) 'view only',
                          ].join(' · '),
                          style: MallowTheme.uiMeta.copyWith(
                            letterSpacing: 0,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (onSwitch != null) ...[
            const SizedBox(width: MallowTheme.spacingSm),
            SwitchPill(
              onTap: onSwitch!,
              semanticLabel: 'Switch $network wallet',
            ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.glyph, this.text, {this.detail, this.muted = false});
  final ReviewGlyph glyph;
  final String text;
  final String? detail;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final ink = muted ? colors.textSecondary : colors.textPrimary;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: ReviewIcon(glyph, size: 16, color: ink),
          ),
          const SizedBox(width: MallowTheme.spacingMd),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: MallowTheme.uiBody.copyWith(
                      height: 1.35,
                      color: ink,
                    ),
                  ),
                  if (detail case final detail?)
                    Text(
                      detail,
                      style: MallowTheme.uiMeta.copyWith(
                        letterSpacing: 0,
                        height: 1.35,
                        color: colors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
