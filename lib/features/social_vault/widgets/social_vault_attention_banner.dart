import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/social_vault/social_vault_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/social_wallet_copy.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../services/social_vault_attention.dart';

/// A banner for a social vault wallet that is not as recoverable as it should
/// be. It is not dismissible. In order:
///
/// - the phone's backup is paused (Android, no screen lock): it goes away
///   when a screen lock is set and the app next comes forward;
/// - backed up without a passkey: it goes away when the wallet gets a
///   passkey, or, where no passkey can be added on this device, when the user
///   acknowledges the limit on the Sign-in keys screen.
///
/// Never shown for a wallet from the older sign-in, which has no vault: its
/// one-time notice is the whole message, and a banner would only repeat the
/// mark and the sentence its own screens already carry.
class SocialVaultAttentionBanner extends StatefulWidget {
  const SocialVaultAttentionBanner({super.key});

  @override
  State<SocialVaultAttentionBanner> createState() =>
      _SocialVaultAttentionBannerState();
}

class _SocialVaultAttentionBannerState
    extends State<SocialVaultAttentionBanner> {
  List<SocialVaultAttention> _items = const [];

  /// What the list is read again for. The one it starts with is not a vault
  /// record: it is the acknowledgement made on the Sign-in keys screen,
  /// which may have been reached from Settings rather than from this banner.
  final _sources = <Listenable>[socialVaultAttentionChanges];

  /// Counts the reads, so an older one that ends late does not replace what
  /// a newer one found.
  int _reads = 0;

  @override
  void initState() {
    super.initState();
    if (sl.isRegistered<SocialVaultService>()) {
      final vaults = sl<SocialVaultService>();
      // The vault records, and what the last check of the phone's backup
      // found.
      _sources.addAll([vaults.changes, vaults.platformBackup]);
    }
    for (final source in _sources) {
      source.addListener(_load);
    }
    _load();
  }

  @override
  void dispose() {
    for (final source in _sources) {
      source.removeListener(_load);
    }
    super.dispose();
  }

  Future<void> _load() async {
    final read = ++_reads;
    try {
      final items = await loadSocialVaultAttention();
      if (mounted && read == _reads) setState(() => _items = items);
    } catch (_) {
      // A banner is advice; a failed lookup shows none rather than an error.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final item = _items.first;
    final colors = context.mallowColors;
    final (title, body) = switch (item.kind) {
      SocialVaultAttentionKind.backupPaused => (
        backupPausedTitle,
        backupPausedMessage,
      ),
      SocialVaultAttentionKind.noPasskey => (
        'Add a passkey to your ${item.providerName} wallet',
        '${item.accountName} opens only where this phone’s backup reaches, '
            'and not on the web. A passkey opens it anywhere.',
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Material(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
          onTap: () async {
            // No pre-authenticated flag: Home is not behind the re-auth
            // gate, so the Sign-in keys screen asks before it opens.
            await context.push(AppRoutes.signInKeys);
            if (mounted) await _load();
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MallowSvgIcon(
                  'assets/icons/shield_alert.svg',
                  width: 24,
                  height: 24,
                  color: colors.warning,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: MallowTheme.uiBody),
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: MallowTheme.uiMeta.copyWith(
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
      ),
    );
  }
}
