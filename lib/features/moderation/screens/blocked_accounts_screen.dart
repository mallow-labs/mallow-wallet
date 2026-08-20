import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/services/avatar_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../settings/widgets/settings_page_scaffold.dart';
import '../models/moderation_models.dart';
import '../services/block_store.dart';
import '../services/moderation_actions.dart';
import '../widgets/unblock_pill.dart';

/// Settings → Security & Privacy → Blocked accounts.
///
/// Lists `GET /v2/blocks` with a per-row Unblock. Two jobs: it is the only
/// place a block can be undone, and it makes the feature legible to an App
/// Review tester who needs to see that blocking is real and reversible.
class BlockedAccountsScreen extends StatefulWidget {
  const BlockedAccountsScreen({super.key});

  @override
  State<BlockedAccountsScreen> createState() => _BlockedAccountsScreenState();
}

class _BlockedAccountsScreenState extends State<BlockedAccountsScreen> {
  List<api.BlockedAccount>? _accounts;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await sl<BlockStore>().refresh();
      if (!mounted) return;
      setState(() {
        _accounts = rows;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      // A failed pull-to-refresh must not throw away rows that are already on
      // screen — the last-known list is still the truth the viewer acted on.
      if (_accounts != null) {
        AppSnackBar.show(
          context,
          'Couldn’t refresh your blocked accounts.',
          type: AppSnackBarType.error,
        );
        return;
      }
      setState(() => _error = 'Couldn’t load your blocked accounts.');
    }
  }

  Future<void> _unblock(api.BlockedAccount account) async {
    final ok = await runUnblockUserFlow(
      context,
      address: account.address,
      label: account.label,
    );
    if (!ok || !mounted) return;
    // Drop the row locally rather than refetching — the write is idempotent
    // and already reflected in [BlockStore.blocked].
    setState(() {
      _accounts = _accounts
          ?.where((a) => a.address != account.address)
          .toList(growable: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Blocked accounts',
      child: MallowRefreshIndicator(onRefresh: _load, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final colors = context.mallowColors;
    final accounts = _accounts;

    if (_error != null) {
      return _centered(
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
        ),
      );
    }
    if (accounts == null) {
      return _centered(MallowLoader(size: 24, color: colors.textSecondary));
    }
    if (accounts.isEmpty) {
      return _centered(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'You haven’t blocked anyone',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              'Blocking hides an account’s artworks, curations, offers, and '
              'notifications from your view. It is one-directional and does '
              'not stop them bidding on your artwork on-chain.',
              textAlign: TextAlign.center,
              style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: MallowTheme.spacing20,
        vertical: MallowTheme.spacingLg,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: accounts.length,
      separatorBuilder: (_, _) => Divider(
        height: MallowTheme.spacingLg * 2,
        color: colors.dividerLight,
      ),
      itemBuilder: (_, index) => _BlockedAccountRow(
        account: accounts[index],
        onUnblock: () => _unblock(accounts[index]),
      ),
    );
  }

  /// Keeps the empty / loading / error states inside a scrollable so
  /// pull-to-refresh still works when there are no rows.
  Widget _centered(Widget child) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(
      MallowTheme.spacingXl,
      80,
      MallowTheme.spacingXl,
      MallowTheme.spacingXl,
    ),
    children: [Center(child: child)],
  );
}

class _BlockedAccountRow extends StatelessWidget {
  const _BlockedAccountRow({required this.account, required this.onUnblock});

  final api.BlockedAccount account;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    const avatarSize = 36.0;
    final imageUrl = account.imageUrl;

    return Row(
      children: [
        SizedBox(
          width: avatarSize,
          height: avatarSize,
          child: imageUrl != null && imageUrl.isNotEmpty
              ? MallowNetworkImage(
                  imageUrl: imageUrl,
                  logicalSize: avatarSize,
                  width: avatarSize,
                  height: avatarSize,
                  borderRadius: BorderRadius.circular(avatarSize / 2),
                  errorBuilder: (_) => _generatedAvatar(),
                )
              : _generatedAvatar(),
        ),
        const SizedBox(width: MallowTheme.spacingMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                account.label,
                overflow: TextOverflow.ellipsis,
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              ),
              if ((account.username?.isNotEmpty ?? false) &&
                  account.label != '@${account.username}')
                Text(
                  '@${account.username}',
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiMeta.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: MallowTheme.spacingMd),
        UnblockPill(onTap: onUnblock),
      ],
    );
  }

  Widget _generatedAvatar() => AccountAvatar(
    seed: avatarSeedOf(address: account.address, username: account.username),
    size: 36,
  );
}
