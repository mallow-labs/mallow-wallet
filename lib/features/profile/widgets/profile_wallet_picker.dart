import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/picker_card_chrome.dart';
import '../../../shared/widgets/wallet_type_badge.dart';
import '../../receive/sheets/chain_visuals.dart';
import '../services/wallet_link_selection.dart';

/// One account card in the Create/Edit Profile "Select wallets" step: the
/// account header with a select-all checkbox over a rail of per-wallet toggles.
///
/// Visually the same card as the seed-phrase import picker
/// ([AccountPickerCard]), but driven by real device accounts rather than
/// derivation previews — so there is no `1. ` index prefix and no
/// imported/pending row states. Selection is fully controlled by the caller.
class ProfileWalletPickerCard extends StatelessWidget {
  const ProfileWalletPickerCard({
    required this.account,
    required this.selectedWalletIds,
    required this.lockedWalletIds,
    required this.atCapacity,
    required this.onToggleWallet,
    required this.onToggleAccount,
    super.key,
  });

  final LinkableAccount account;

  final Set<String> selectedWalletIds;

  /// Wallets pinned ON and non-interactive — the profile's signing wallet,
  /// which cannot be unlinked without invalidating the session.
  final Set<String> lockedWalletIds;

  /// True once the profile has hit [kMaxProfileWallets]; unselected rows go
  /// inert so the user can't queue a link that would fail server-side.
  final bool atCapacity;

  final ValueChanged<String> onToggleWallet;
  final ValueChanged<LinkableAccount> onToggleAccount;

  bool _isSelected(LinkableWallet w) =>
      lockedWalletIds.contains(w.id) || selectedWalletIds.contains(w.id);

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final selectable = account.wallets
        .where((w) => !lockedWalletIds.contains(w.id))
        .toList();
    final allSelected = selectable.isNotEmpty && selectable.every(_isSelected);

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Fixed height so the rail below anchors to the avatar's centre
              // regardless of trailing chip content.
              SizedBox(
                height: kPickerHeaderHeight,
                child: Row(
                  children: [
                    AccountAvatar(seed: account.avatarSeed, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        account.name,
                        style: MallowTheme.uiBody.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _AccountActivity(account: account),
                    // Nothing left to choose when every wallet is locked on.
                    if (selectable.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      MallowCheckbox(
                        value: allSelected,
                        enabled: allSelected || !atCapacity,
                        onChanged: (_) => onToggleAccount(account),
                      ),
                    ],
                  ],
                ),
              ),
              // Wallet rows, indented so their bottom dividers start at the rail.
              Padding(
                padding: const EdgeInsets.only(left: kPickerRailX),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final w in account.wallets)
                      _WalletRow(
                        wallet: w,
                        selected: _isSelected(w),
                        locked: lockedWalletIds.contains(w.id),
                        atCapacity: atCapacity,
                        onToggle: () => onToggleWallet(w.id),
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

/// Account-level activity chips aggregated across the account's Solana wallets:
/// artworks + USD when there is activity, "No activity" once enriched and empty,
/// shimmer while loading.
class _AccountActivity extends StatelessWidget {
  const _AccountActivity({required this.account});

  final LinkableAccount account;

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
    required this.locked,
    required this.atCapacity,
    required this.onToggle,
  });

  final LinkableWallet wallet;
  final bool selected;

  /// Pinned ON — the profile's signing wallet.
  final bool locked;
  final bool atCapacity;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    // Locked rows can't be turned off; at the wallet cap, rows that aren't
    // already selected can't be turned on.
    final inert = locked || (atCapacity && !selected);

    final toggle = MallowToggle(
      value: selected,
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
            const SizedBox(width: 8),
            ChainGlyph(chain: wallet.wallet.chainEnum, size: 12),
            const SizedBox(width: 4),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      truncateAddress(wallet.address),
                      style: MallowTheme.uiCaption.copyWith(
                        color: selected
                            ? colors.textPrimary
                            : colors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Where this wallet's key lives — hardware / Google / Apple.
                  // Per-wallet, not per-account: the row is what gets linked.
                  WalletTypeBadge(wallet.badge, size: 12),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _WalletActivity(wallet: wallet),
          ],
        ),
      ),
    );
  }
}

/// Per-wallet trailing activity: "N artworks • $Z" once enriched, shimmer while
/// loading. Resolved for every chain.
class _WalletActivity extends StatelessWidget {
  const _WalletActivity({required this.wallet});

  final LinkableWallet wallet;

  @override
  Widget build(BuildContext context) {
    if (!wallet.isEnriched) return const ShimmerBox(width: 96, height: 14);
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

/// Loading placeholder mirroring [ProfileWalletPickerCard]'s geometry.
class ProfileWalletPickerSkeleton extends StatelessWidget {
  const ProfileWalletPickerSkeleton({super.key});

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
                    for (var i = 0; i < 2; i++)
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
