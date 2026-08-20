import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../core/services/avatar_service.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/recent_recipient.dart';
import '../models/recipient_suggestion.dart';
import 'recipient_search_dropdown.dart';
import 'send_sheet_widgets.dart';

import '../../../shared/utils/chain.dart';

/// Second send step: recipient address entry with
/// paste/QR helpers and the locally-saved recent recipients list.
class SendRecipientStep extends StatelessWidget {
  const SendRecipientStep({
    required this.controller,
    required this.focusNode,
    required this.chain,
    required this.errorText,
    required this.isResolving,
    required this.resolvedAddress,
    required this.recents,
    required this.onChanged,
    required this.onPaste,
    required this.onScan,
    required this.onRecentTap,
    required this.searchController,
    required this.onSuggestionPicked,
    required this.onBack,
    required this.onCancel,
    required this.onNext,
    this.sourceAddress,
    this.onSwitch,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Chain of the send in progress — drives the address-field placeholder so it
  /// reads "Tezos address" / "Ethereum address" instead of the Solana default.
  final Chain chain;
  final String? errorText;
  final bool isResolving;
  final String? resolvedAddress;
  final List<RecentRecipient> recents;
  final ValueChanged<String> onChanged;
  final VoidCallback onPaste;
  final VoidCallback onScan;
  final ValueChanged<RecentRecipient> onRecentTap;

  /// Drives the username-search dropdown anchored under the address field.
  final RecipientSearchController searchController;
  final ValueChanged<RecipientSuggestion> onSuggestionPicked;

  final VoidCallback onBack;
  final VoidCallback onCancel;
  final VoidCallback onNext;
  final String? sourceAddress;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SendStepHeader(title: 'Send', onBack: onBack),
          const SizedBox(height: MallowTheme.spacingLg),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Recipient Address',
                  style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
                ),
              ),
              TapTargetExpander(
                child: GestureDetector(
                  onTap: onPaste,
                  behavior: HitTestBehavior.opaque,
                  child: Text(
                    'Paste',
                    style: MallowTheme.uiMeta.copyWith(color: colors.accent),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: MallowTheme.spacing12),
          RecipientSearchDropdown(
            controller: searchController,
            focusNode: focusNode,
            onSelected: onSuggestionPicked,
            child: MallowPillField(
              controller: controller,
              focusNode: focusNode,
              hintText: '${chain.label} address or username',
              errorText: errorText,
              onChanged: onChanged,
              autocorrect: false,
              enableSuggestions: false,
              suffix: TapTargetExpander(
                child: GestureDetector(
                  onTap: onScan,
                  behavior: HitTestBehavior.opaque,
                  child: MallowSvgIcon(
                    'assets/icons/qr.svg',
                    width: 20,
                    height: 20,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          if (isResolving) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            Row(
              children: [
                MallowLoader(size: 12, color: colors.textSecondary),
                const SizedBox(width: MallowTheme.spacingSm),
                Text(
                  'Resolving...',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ] else if (resolvedAddress != null) ...[
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              resolvedAddress!,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: MallowTheme.spacingLg),
          Expanded(child: _recentList(context)),
          const SizedBox(height: MallowTheme.spacingMd),
          SendStepButtons(
            primaryLabel: 'Next',
            onCancel: onCancel,
            onPrimary: onNext,
            sourceAddress: sourceAddress,
            onSwitch: onSwitch,
          ),
        ],
      ),
    );
  }

  Widget _recentList(BuildContext context) {
    if (recents.isEmpty) return const SizedBox.shrink();
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Recent',
          style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: MallowTheme.spacing12),
        Expanded(
          child: ListView.separated(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.zero,
            itemCount: recents.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: MallowTheme.spacingSm),
            itemBuilder: (context, index) =>
                _RecentRow(recent: recents[index], onTap: onRecentTap),
          ),
        ),
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.recent, required this.onTap});

  final RecentRecipient recent;
  final ValueChanged<RecentRecipient> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final truncated = truncateAddress(recent.address);
    // Same order as [RecentRecipient.displayName], so the picture and the name
    // always come from one identity: the mallow profile (its pfp, or a
    // username-seeded identicon when it has none), else the local account's
    // own identicon, else one seeded off the address.
    final username = recent.username;
    final seed = username != null
        ? avatarSeedOf(username: username, address: recent.address)
        : (recent.accountAvatarSeed ?? recent.address);
    return TapTargetExpander(
      child: GestureDetector(
        onTap: () => onTap(recent),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 24,
          child: Row(
            children: [
              RecipientAvatar(size: 24, imageUrl: recent.imageUrl, seed: seed),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: Text(
                  recent.displayName ?? truncated,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Text(
                truncated,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
