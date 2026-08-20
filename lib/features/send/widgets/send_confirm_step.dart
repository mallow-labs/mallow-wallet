import 'package:flutter/material.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/generic_confirmation_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/recipient_advisory.dart';
import 'send_sheet_widgets.dart';

/// Final send step: review summary + Send CTA.
///
/// Also used (via [SendConfirmStep.sizing]) as the invisible sizing child that
/// gives every step of the sheet a common floor height — each row there renders
/// unconditionally at a single line height, so the floor holds regardless of
/// data. The live step is free to grow past it when its own content is taller.
class SendConfirmStep extends StatelessWidget {
  const SendConfirmStep({
    required this.amountText,
    required this.amountFiatText,
    required this.tokenName,
    required this.recipientName,
    required this.recipientImageUrl,
    required this.recipientAddress,
    required this.feeText,
    required this.feeFiatText,
    required this.simulation,
    required this.isSending,
    required this.onBack,
    required this.onCancel,
    required this.onSend,
    this.networkName = 'Solana',
    this.feeSymbol = 'SOL',
    this.feeMint = solMint,
    this.feeDetailText,
    this.onEditFee,
    this.speedName,
    this.speedEta,
    this.recipientAvatarSeed,
    this.sourceAddress,
    this.onSwitch,
    this.recipientAdvisory,
    this.previousSendCount,
    bool intrinsicHeight = false,
    super.key,
  }) : _intrinsicHeight = intrinsicHeight;

  /// Layout probe with representative single-line content. Wrapped in an
  /// invisible non-scrollable viewport by the sheet host, so it reports the
  /// confirm step's natural height without ever painting or handling taps.
  ///
  /// [showSpeed] adds the Ethereum-only Speed section so the probe reports the
  /// taller ETH confirm height — the sheet then grows to fit it (up to the sheet
  /// max) instead of scrolling the section out of view.
  const SendConfirmStep.sizing({bool showSpeed = false, super.key})
    : amountText = '0 SOL',
      amountFiatText = '--',
      tokenName = 'Solana',
      recipientName = 'recipient',
      recipientImageUrl = null,
      recipientAddress = 'address',
      feeText = '0',
      feeFiatText = '--',
      networkName = 'Solana',
      feeSymbol = 'SOL',
      feeMint = solMint,
      feeDetailText = null,
      onEditFee = null,
      speedName = showSpeed ? 'Market' : null,
      speedEta = showSpeed ? '~12 sec' : null,
      recipientAvatarSeed = null,
      simulation = null,
      isSending = false,
      onBack = null,
      onCancel = null,
      onSend = null,
      // Representative source line so the height probe reserves room for the
      // "Your wallet" row the live steps render above the buttons.
      sourceAddress = 'address',
      onSwitch = null,
      // The advisory is deliberately absent from the floor: it fires on a
      // minority of sends, so reserving room for it would pad every other one.
      // The host's live probe grows the sheet when it does appear.
      recipientAdvisory = null,
      // Occupies the recipient label's row, so it never changes the height.
      previousSendCount = null,
      _intrinsicHeight = true;

  final String amountText;
  final String amountFiatText;
  final String tokenName;
  final String recipientName;
  final String? recipientImageUrl;
  final String recipientAddress;
  final String feeText;
  final String feeFiatText;

  /// Network the send routes over, shown in the "Network" pill (e.g. 'Solana',
  /// 'Tezos').
  final String networkName;

  /// Symbol + mint of the token the fee is denominated in — 'SOL'/[solMint] on
  /// Solana, 'XTZ'/[TokenBalance.tezosNativeSentinel] on Tezos — drives the fee
  /// row glyph.
  final String feeSymbol;
  final String feeMint;

  /// Optional secondary fee line (e.g. Tezos 'Gas 1400 · Storage 0 · incl.
  /// reveal'). Null hides the row (the Solana path shows no breakdown).
  final String? feeDetailText;

  /// When set, an "Edit" affordance appears on the Network fee row that opens
  /// the Edit Gas Fee sheet (Ethereum only). Null hides it.
  final VoidCallback? onEditFee;

  /// Optional Speed section (Ethereum): the chosen tier name ([speedName], e.g.
  /// 'Market') on the left and its ETA ([speedEta], e.g. '~12 sec') on the
  /// right. Both null hides the whole section.
  final String? speedName;
  final String? speedEta;

  /// Identicon seed for the recipient avatar. Set to a **local account's**
  /// persisted `avatarSeed` when the recipient is another account on this
  /// device, so the pill draws the same identicon the accounts list does.
  ///
  /// Null falls back to [recipientAddress], which is the right seed for anyone
  /// else: a stranger has no account row, and seeding off their address at
  /// least keeps one address looking like itself between screens.
  final String? recipientAvatarSeed;

  /// Non-blocking heads-up about the kind of account the recipient is (PDA,
  /// token account, contract, never-funded). Rendered under the address, where
  /// the design puts it — it describes the recipient, not the transaction.
  ///
  /// It **never** gates [onSend]: every class it flags is a legitimate
  /// destination in some context, so a block here would be wrong.
  final RecipientAdvisory? recipientAdvisory;

  /// Completed transfers this device has made to [recipientAddress]. Null hides
  /// the label entirely (the sizing probe); 0 renders "No previous sends",
  /// which is the whole point of counting — a first-time recipient is the one
  /// worth a second look.
  final int? previousSendCount;

  final SimulationBannerState? simulation;
  final bool isSending;
  final VoidCallback? onBack;
  final VoidCallback? onCancel;
  final VoidCallback? onSend;
  final String? sourceAddress;
  final VoidCallback? onSwitch;

  /// Lay out at the step's natural height (a shrink-wrapped column) instead of
  /// filling the height the host hands down. Set by [SendConfirmStep.sizing]
  /// and by the host's live height probe — see the sheet's sizing stack.
  final bool _intrinsicHeight;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SendStepHeader(title: 'Confirm Send', onBack: onBack),
        const SizedBox(height: MallowTheme.spacingLg),
        _summaryRow(context),
        const SizedBox(height: MallowTheme.spacingLg),
        Row(
          children: [
            const Expanded(child: SendSectionLabel(label: 'Recipient')),
            if (_previousSendsLabel != null)
              // Expanded, not bare: it pins the label to the right edge, and at
              // a large system text scale "Recipient" + "No previous sends" is
              // wider than a narrow screen — this row is the only one here that
              // would overflow rather than ellipsize.
              Expanded(
                child: Text(
                  _previousSendsLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: MallowTheme.uiCaption.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: MallowTheme.spacing12),
        SendConfirmPill(
          child: Row(
            children: [
              RecipientAvatar(
                size: 24,
                imageUrl: recipientImageUrl,
                seed: recipientAvatarSeed ?? recipientAddress,
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: Text(
                  recipientName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiLabel.copyWith(
                    color: context.mallowColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: MallowTheme.spacing12),
        Text(
          recipientAddress,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: MallowTheme.uiCaption.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        if (recipientAdvisory != null) ...[
          const SizedBox(height: MallowTheme.spacing12),
          SendWarningNotice(message: recipientAdvisory!.message),
        ],
        const SizedBox(height: MallowTheme.spacingLg),
        const SendSectionLabel(label: 'Network'),
        const SizedBox(height: MallowTheme.spacing12),
        SendConfirmPill(
          child: Text(
            networkName,
            style: MallowTheme.uiLabel.copyWith(
              color: context.mallowColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        Row(
          children: [
            const Expanded(child: SendSectionLabel(label: 'Network fee')),
            if (onEditFee != null)
              TapTargetExpander(
                child: GestureDetector(
                  onTap: onEditFee,
                  behavior: HitTestBehavior.opaque,
                  child: Text(
                    'Edit',
                    style: MallowTheme.uiMeta.copyWith(
                      color: context.mallowColors.accent,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: MallowTheme.spacing12),
        SendConfirmPill(
          child: Row(
            children: [
              tokenImageWidget(
                mint: feeMint,
                size: 16,
                symbol: feeSymbol,
                enlargeChainGlyph: true,
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: Text(
                  feeText,
                  style: MallowTheme.uiBody.copyWith(
                    color: context.mallowColors.textPrimary,
                  ),
                ),
              ),
              Text(
                feeFiatText,
                style: MallowTheme.uiCaption.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        if (feeDetailText != null) ...[
          const SizedBox(height: MallowTheme.spacingXs),
          Text(
            feeDetailText!,
            style: MallowTheme.uiCaption.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
        ],
        if (speedName != null) ...[
          const SizedBox(height: MallowTheme.spacingLg),
          const SendSectionLabel(label: 'Speed'),
          const SizedBox(height: MallowTheme.spacing12),
          SendConfirmPill(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    speedName!,
                    style: MallowTheme.uiBody.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  speedEta ?? '',
                  style: MallowTheme.uiBody.copyWith(
                    color: context.mallowColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (simulation != null) ...[
          const SizedBox(height: MallowTheme.spacing12),
          ConfirmationSimulationBanner(state: simulation!),
        ],
      ],
    );

    final buttons = SendStepButtons(
      primaryLabel: 'Send',
      isLoading: isSending,
      onCancel: onCancel ?? () {},
      onPrimary: onSend,
      sourceAddress: sourceAddress,
      onSwitch: onSwitch,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        mainAxisSize: _intrinsicHeight ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The host sizes the sheet to this step's natural height, so growing
          // content (the simulation warning) grows the sheet. The filling
          // render only scrolls once that growth has hit the sheet cap.
          if (_intrinsicHeight)
            body
          else
            Expanded(child: SingleChildScrollView(child: body)),
          const SizedBox(height: MallowTheme.spacingMd),
          buttons,
        ],
      ),
    );
  }

  Widget _summaryRow(BuildContext context) {
    final colors = context.mallowColors;
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
              'assets/icons/send.svg',
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
                      amountText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MallowTheme.uiDisplay.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    amountFiatText,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: MallowTheme.spacingXs),
              Text(
                tokenName,
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

  /// Right-hand caption on the Recipient row, or null when there is no count
  /// to show.
  String? get _previousSendsLabel {
    final count = previousSendCount;
    if (count == null) return null;
    if (count == 0) return 'No previous sends';
    return count == 1 ? '1 previous send' : '$count previous sends';
  }
}
