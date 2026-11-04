import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/account.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/picker_card_chrome.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/picker_account.dart';

/// One account card: a derivation index with its multi-chain wallet rows.
///
/// Shared by the seed-phrase and Ledger import pickers. Selection is driven by
/// the caller via [selectedKeys]; row toggles call [onToggleWallet] with the
/// wallet's [PickerWallet.key] and the header "select all" calls
/// [onToggleAccount] with the account's index.
///
/// When [onRename] is set, a not-yet-imported card shows an edit icon beside
/// its name that turns the name into an in-place text field.
class AccountPickerCard extends StatelessWidget {
  const AccountPickerCard({
    required this.account,
    required this.displayName,
    required this.selectedKeys,
    required this.onToggleWallet,
    required this.onToggleAccount,
    this.onRename,
    super.key,
  });

  final PickerAccount account;

  /// Resolved header name (without the derivation prefix), from
  /// [previewAccountNames]: a stored name, the live `Account NN` preview, or a
  /// bare `Account` for unselected rows.
  final String displayName;
  final Set<String> selectedKeys;
  final ValueChanged<String> onToggleWallet;
  final ValueChanged<int> onToggleAccount;

  /// Called with the edited name (untrimmed, possibly blank) when the user
  /// finishes editing. Null hides the edit icon. Never offered for an account
  /// that already exists — the import does not rename it.
  final ValueChanged<String>? onRename;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    // Accounts with some already-imported wallets still render in full: their
    // imported rows show disabled, the rest stay toggleable so the user can
    // import additional chains/addresses from the same account.
    final selectable = account.wallets
        .where((w) => !w.alreadyImported && !w.addressPending)
        .toList();
    final allSelected =
        selectable.isNotEmpty &&
        selectable.every((w) => selectedKeys.contains(w.key));
    // When every wallet in the account is already imported there is nothing
    // left to select, so the header "select all" checkbox is dropped entirely.
    final allImported = account.wallets.every((w) => w.alreadyImported);

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Account header — fixed height so the connector line below
              // anchors to the avatar's centre regardless of trailing content.
              SizedBox(
                height: kPickerHeaderHeight,
                child: Row(
                  children: [
                    AccountAvatar(seed: account.avatarSeed, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _AccountName(
                        // Leading derivation-index prefix (1-based), then the
                        // resolved name. The prefix is positional; the name's
                        // number (when present) comes from the global counter.
                        prefix: '${account.index + 1}. ',
                        name: displayName,
                        onRename: account.importedName == null
                            ? onRename
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _AccountActivity(account: account),
                    if (!allImported) ...[
                      const SizedBox(width: 8),
                      MallowCheckbox(
                        value: allSelected,
                        enabled: selectable.isNotEmpty,
                        onChanged: (_) => onToggleAccount(account.index),
                      ),
                    ],
                  ],
                ),
              ),
              // Wallet rows, indented so their bottom dividers start at the
              // connector line (x = 8).
              Padding(
                padding: const EdgeInsets.only(left: kPickerRailX),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final w in account.wallets)
                      _WalletRow(
                        wallet: w,
                        selected: selectedKeys.contains(w.key),
                        onToggle: () => onToggleWallet(w.key),
                      ),
                  ],
                ),
              ),
            ],
          ),
          // Vertical connector descending from the avatar through the rows.
          Positioned(
            left: kPickerRailX,
            top: kPickerAvatarBottom,
            bottom: 0,
            child: Container(width: 1, color: colors.dividerLight),
          ),
        ],
      ),
    );
  }
}

/// The card header's name. Read-only text, plus an edit icon when [onRename]
/// is set; tapping it swaps the name for a text field in the same place, which
/// commits on Done or when it loses focus.
class _AccountName extends StatefulWidget {
  const _AccountName({
    required this.prefix,
    required this.name,
    required this.onRename,
  });

  final String prefix;
  final String name;
  final ValueChanged<String>? onRename;

  @override
  State<_AccountName> createState() => _AccountNameState();
}

class _AccountNameState extends State<_AccountName> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startEditing() {
    _controller.value = TextEditingValue(
      text: widget.name,
      selection: TextSelection(baseOffset: 0, extentOffset: widget.name.length),
    );
    setState(() => _editing = true);
    _focusNode.requestFocus();
  }

  void _commit() {
    if (!_editing) return;
    setState(() => _editing = false);
    // Confirming the name as shown is not a rename: storing it would pin a
    // previewed `Account NN` that should keep tracking the selection.
    if (_controller.text.trim() == widget.name) return;
    widget.onRename?.call(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final style = MallowTheme.uiBody.copyWith(
      fontWeight: FontWeight.w500,
      color: colors.textPrimary,
    );
    return Row(
      children: [
        Text(widget.prefix, style: style),
        if (_editing)
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              style: style,
              cursorColor: colors.textPrimary,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [
                LengthLimitingTextInputFormatter(kMaxAccountNameLength),
              ],
              decoration: InputDecoration.collapsed(
                hintText: 'Account name',
                hintStyle: style.copyWith(color: colors.textTertiary),
              ),
              onSubmitted: (_) => _focusNode.unfocus(),
              onTapOutside: (_) => _focusNode.unfocus(),
            ),
          )
        else ...[
          Flexible(
            child: Text(
              widget.name,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.onRename != null) ...[
            const SizedBox(width: 6),
            TapTargetExpander(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _startEditing,
                child: MallowSvgIcon(
                  'assets/icons/edit.svg',
                  width: 14,
                  height: 14,
                  color: colors.textSecondary,
                  semanticLabel: 'Edit account name',
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// Account-level activity chips (aggregated across the account's Solana
/// wallets): artworks + USD when there is activity, "No activity" when enriched
/// and empty, shimmer while loading.
class _AccountActivity extends StatelessWidget {
  const _AccountActivity({required this.account});

  final PickerAccount account;

  @override
  Widget build(BuildContext context) {
    if (!account.isEnriched) {
      return const ShimmerBox(width: 72, height: 18);
    }
    if (!account.hasActivity) {
      return const PickerChip(label: 'No activity', outlined: true);
    }
    final artworks = account.artworkCount ?? 0;
    final usd = account.balanceUsd ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (artworks > 0) ...[
          PickerChip(label: '$artworks artworks', filled: true),
          const SizedBox(width: 6),
        ],
        PickerChip(label: '\$${usd.toStringAsFixed(2)}', filled: true),
      ],
    );
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({
    required this.wallet,
    required this.selected,
    required this.onToggle,
  });

  final PickerWallet wallet;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final pending = wallet.addressPending;
    // Pending and already-imported rows are both non-interactive. Already-
    // imported rows show the toggle ON (locked) to signal they're in the
    // wallet; pending rows hold OFF until their address derives.
    final inert = wallet.alreadyImported || pending;

    final toggle = MallowToggle(
      value: wallet.alreadyImported || (!pending && selected),
      onChanged: inert ? (_) {} : (_) => onToggle(),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: inert ? null : onToggle,
      child: Container(
        height: kPickerWalletRowHeight,
        padding: const EdgeInsets.only(left: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.surfaceMuted)),
        ),
        child: Row(
          children: [
            if (inert)
              Opacity(opacity: 0.4, child: IgnorePointer(child: toggle))
            else
              toggle,
            const SizedBox(width: 12),
            MallowSvgIcon(wallet.chain.paddedIconAsset, width: 16, height: 16),
            const SizedBox(width: 8),
            Expanded(
              child: pending
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: ShimmerBox(width: 96, height: 12),
                    )
                  : Text(
                      truncateAddress(wallet.address),
                      style: MallowTheme.uiMeta.copyWith(
                        color: wallet.alreadyImported
                            ? colors.textSecondary
                            : colors.textPrimary,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            if (!pending) _WalletActivity(wallet: wallet),
          ],
        ),
      ),
    );
  }
}

/// Per-wallet trailing activity text. Solana shows "N artworks • $Z" once
/// enriched (shimmer while loading); Ethereum/Tezos show nothing (mallow only
/// indexes Solana). Already-imported rows show an "Imported" label.
class _WalletActivity extends StatelessWidget {
  const _WalletActivity({required this.wallet});

  final PickerWallet wallet;

  @override
  Widget build(BuildContext context) {
    if (wallet.alreadyImported) {
      return const PickerChip(label: 'Imported', outlined: true);
    }
    if (!wallet.enrichable) return const SizedBox.shrink();
    if (wallet.artworkCount == null || wallet.balanceUsd == null) {
      return const ShimmerBox(width: 96, height: 14);
    }
    final artworks = wallet.artworkCount ?? 0;
    final usd = wallet.balanceUsd ?? 0;
    return Text(
      '$artworks artworks • \$${usd.toStringAsFixed(2)}',
      style: MallowTheme.uiCaption.copyWith(
        color: context.mallowColors.textSecondary,
      ),
    );
  }
}

/// Tappable "+ Show more" row that derives the next batch of accounts.
class ShowMoreRow extends StatelessWidget {
  const ShowMoreRow({required this.enabled, required this.onTap, super.key});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              '+ Show more',
              style: MallowTheme.uiCaption.copyWith(
                color: enabled
                    ? context.mallowColors.textSecondary
                    : context.mallowColors.textSecondary.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading placeholder mirroring [AccountPickerCard]: an avatar/name header, the
/// avatar connector line, and three wallet rows with shimmer where the
/// addresses will render once derived.
class SkeletonAccountCard extends StatelessWidget {
  const SkeletonAccountCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                height: kPickerHeaderHeight,
                child: Row(
                  children: [
                    ShimmerBox(
                      width: 16,
                      height: 16,
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                    SizedBox(width: 8),
                    ShimmerBox(width: 72, height: 15),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: kPickerRailX),
                child: Column(
                  children: [
                    for (var i = 0; i < 3; i++)
                      Container(
                        height: kPickerWalletRowHeight,
                        padding: const EdgeInsets.only(left: 16),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: colors.surfaceMuted),
                          ),
                        ),
                        child: const Align(
                          alignment: Alignment.centerLeft,
                          child: ShimmerBox(width: 140, height: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            left: kPickerRailX,
            top: kPickerAvatarBottom,
            bottom: 0,
            child: Container(width: 1, color: colors.dividerLight),
          ),
        ],
      ),
    );
  }
}
