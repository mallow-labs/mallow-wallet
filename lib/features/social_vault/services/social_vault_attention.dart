import 'package:flutter/foundation.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/models/account.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/social_vault/social_vault_service.dart';
import '../../../di.dart';

/// Why a social vault wallet is less recoverable than it should be. In
/// order of urgency: the first one a device has is the one its banner shows.
enum SocialVaultAttentionKind {
  /// Android only. The phone has no screen lock, so Google's backup of it is
  /// not end-to-end encrypted, and the wallet's device key was pulled out of
  /// that backup: it is on this phone alone until a screen lock is set.
  backupPaused,

  /// Its vault has no passkey: it opens only where the platform backup
  /// reaches (this phone after a reinstall; other devices only through
  /// iCloud Keychain or a new Android phone set up from this one's backup),
  /// and never on the web.
  noPasskey,
}

class SocialVaultAttention {
  const SocialVaultAttention({
    required this.accountId,
    required this.accountName,
    required this.provider,
    required this.kind,
  });

  final String accountId;
  final String accountName;
  final String provider;
  final SocialVaultAttentionKind kind;

  String get providerName => provider == 'apple' ? 'Apple' : 'Google';
}

/// Bumped when something [loadSocialVaultAttention] reads has changed and no
/// other notifier says so: today, the acknowledgement of a wallet that
/// cannot get a passkey on this device, which is a preference and touches no
/// vault record. Whatever shows the attention list listens to it.
final ValueNotifier<int> socialVaultAttentionChanges = ValueNotifier<int>(0);

/// The user has read that the wallet of [vaultId] opens only where this
/// device's backup reaches, on a device that cannot add a passkey. Recorded,
/// and said to whatever shows the attention list: the banner on Home goes
/// now, not at the next launch.
Future<void> acknowledgeSocialVaultPlatformOnly(String vaultId) async {
  await sl<PreferencesService>().acknowledgeSocialVaultPlatformOnly(vaultId);
  socialVaultAttentionChanges.value++;
}

/// Every social vault wallet on this device that needs something from its
/// owner, the most urgent first.
///
/// A wallet whose device key is out of the phone's backup is listed for as
/// long as the phone has no screen lock; nothing acknowledges that away. A
/// platform-only vault stays listed until it has a passkey, or — only where
/// no passkey can be added here — until the user acknowledges the limit.
///
/// A wallet without a vault is never listed: one from the older sign-in
/// (`Account.isLegacySocial`) has its own one-time notice and no banner, and
/// nothing here can give a vault wallet whose backup was deleted a new one.
Future<List<SocialVaultAttention>> loadSocialVaultAttention() async {
  final accounts = (await sl<WalletRepository>().getAccountViews()).where(
    (a) => a.kind == AccountKind.social,
  );
  final vaults = sl<SocialVaultService>();
  final acknowledged =
      sl<PreferencesService>().socialVaultPlatformOnlyAcknowledged;
  final paused = vaults.platformBackup.value.pausedVaultIds;
  final out = <SocialVaultAttention>[];
  for (final account in accounts) {
    final social = account.wallets
        .where((w) => w.walletType == WalletType.social)
        .toList();
    if (social.isEmpty) continue;
    final provider = social.first.socialProvider ?? 'google';
    final vaultId = social
        .map((w) => w.socialVaultId)
        .whereType<String>()
        .firstOrNull;
    if (vaultId == null) continue;
    if (paused.contains(vaultId)) {
      out.add(
        SocialVaultAttention(
          accountId: account.id,
          accountName: account.name,
          provider: provider,
          kind: SocialVaultAttentionKind.backupPaused,
        ),
      );
    }
    final vault = (await vaults.cached(vaultId))?.vault;
    // Without a record of the vault this device cannot say it has a passkey,
    // so it does not: the banner shows. Staying quiet would hide the advice
    // from exactly the wallet whose state is unknown, and the Sign-in keys
    // screen it leads to says what to do (sign in again to see the keys).
    final hasPasskey =
        vault?.slots.any((s) => s.kind == api.SocialVaultSlotKind.passkeyPrf) ??
        false;
    if (hasPasskey || acknowledged.contains(vaultId)) continue;
    out.add(
      SocialVaultAttention(
        accountId: account.id,
        accountName: account.name,
        provider: provider,
        kind: SocialVaultAttentionKind.noPasskey,
      ),
    );
  }
  // Stable, so wallets keep their order within a kind.
  return [
    for (final kind in SocialVaultAttentionKind.values)
      ...out.where((item) => item.kind == kind),
  ];
}
