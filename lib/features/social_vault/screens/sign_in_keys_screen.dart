import 'dart:io' show Platform;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/models/account.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/router/app_router.dart';
import '../../../core/security/reauth_gate.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/social_auth_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/social_vault/passkey_prf.dart';
import '../../../core/social_vault/platform_backup_guard.dart';
import '../../../core/social_vault/social_vault_api.dart';
import '../../../core/social_vault/social_vault_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/choice_sheet.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/utils/social_wallet_copy.dart';
import '../../../shared/widgets/social_provider_icon.dart';
import '../../settings/widgets/settings_page_scaffold.dart';
import '../services/social_vault_attention.dart';
import '../widgets/rename_sign_in_key_sheet.dart';
import '../widgets/social_vault_notices.dart';

/// "Sign-in keys": the slots that open each Google or Apple wallet's social
/// vault — the platform backup of each device and any passkeys — with ways
/// to add a passkey, rename one and remove a key. The last key cannot be
/// removed: the vault would then open nowhere.
///
/// A wallet from the older sign-in (`Account.isLegacySocial`) has no vault
/// and so no keys here. It is still listed, with its marked icon and the
/// sentence that says what it is, so its owner is not left wondering why one
/// Google or Apple wallet has keys and the other has none.
///
/// Lists what this device last saw of each vault (the record is not secret);
/// every change is signed with the vault key this device holds, and the
/// answer refreshes the list.
///
/// On Android it also says where this phone's own key is right now — in
/// Google's end-to-end encrypted backup of the phone, or on the phone alone
/// because the phone has no screen lock and the backup is paused — and, after
/// a backup that held a key was seen without encryption, offers to replace
/// the wallet's keys.
///
/// The screen is behind the re-auth gate on every way in. [preAuthenticated]
/// is set only by the Security & Privacy row, whose own entry gate was just
/// cleared; any other entry — the Home banner, the new-key notice, a
/// programmatic push — leaves it false, and the screen asks for the PIN or
/// biometrics itself before it lists anything (`extra` is an in-process
/// object, so a link cannot forge the flag). Adding a key, removing one and
/// deleting the backup each pass the gate again: a new passkey is a new way
/// into the wallet, a removed one may be some other device's only way in,
/// and a deleted backup cannot be brought back. Renaming a passkey does not:
/// a label is display text and opens nothing.
class SignInKeysScreen extends StatefulWidget {
  const SignInKeysScreen({super.key, this.preAuthenticated = false});

  final bool preAuthenticated;

  @override
  State<SignInKeysScreen> createState() => _SignInKeysScreenState();
}

class _SignInKeysScreenState extends State<SignInKeysScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _passkeysHere = false;
  List<_WalletKeys> _wallets = const [];

  SocialVaultService get _vaults => sl<SocialVaultService>();

  /// What the last check of the phone's backup found. Read at build time:
  /// the check runs whenever the app comes forward, this screen open or not.
  PlatformBackupStatus get _backup => _vaults.platformBackup.value;

  late final ValueNotifier<PlatformBackupStatus> _backupStatus;

  void _onBackupChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _backupStatus.removeListener(_onBackupChanged);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _backupStatus = _vaults.platformBackup..addListener(_onBackupChanged);
    if (widget.preAuthenticated) {
      _load();
    } else {
      // Reached without the Security & Privacy entry gate: challenge before
      // loading. `_loading` stays true (a blank scaffold) until it clears.
      WidgetsBinding.instance.addPostFrameCallback((_) => _gateThenLoad());
    }
  }

  Future<void> _gateThenLoad() async {
    final passed = await requireReauth(context);
    if (!mounted) return;
    if (!passed) {
      // Leave without having listed anything.
      await Navigator.of(context).maybePop();
      return;
    }
    await _load();
  }

  Future<void> _load() async {
    final accounts = (await sl<WalletRepository>().getAccountViews())
        .where((a) => a.kind == AccountKind.social)
        .toList();
    final passkeysHere = await _vaults.passkeysAvailable();
    final wallets = <_WalletKeys>[];
    for (final account in accounts) {
      final social = account.wallets
          .where((w) => w.walletType == WalletType.social)
          .toList();
      if (social.isEmpty) continue;
      final vaultId = social
          .map((w) => w.socialVaultId)
          .whereType<String>()
          .firstOrNull;
      CachedSocialVault? cached;
      var hasKey = false;
      var localSlotIds = const <String>{};
      if (vaultId != null) {
        cached = await _vaults.cached(vaultId);
        hasKey = await _vaults.hasUsableDataKey(vaultId);
        localSlotIds = await _vaults.localPlatformSlotIds(vaultId);
      }
      wallets.add(
        _WalletKeys(
          account: account,
          provider: social.first.socialProvider ?? 'google',
          vaultId: vaultId,
          cached: cached,
          hasDataKey: hasKey,
          localPlatformSlotIds: localSlotIds,
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _wallets = wallets;
      _passkeysHere = passkeysHere;
      _loading = false;
    });
  }

  /// One action at a time; the list is read again when it ends, however it
  /// ends. Each action says what went wrong in its own words. What reaches
  /// here is a failure none of them expected — a read of this device's
  /// secure store, say — and it is said too, so a tap never does nothing.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      AppLogger.warn('SignInKeys', 'action failed: ${e.runtimeType}');
      if (mounted) {
        AppSnackBar.show(
          context,
          'Something went wrong. Try again.',
          type: AppSnackBarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  Future<void> _addPasskey(_WalletKeys wallet) => _run(() async {
    if (!await requireReauth(context)) return;
    final vault = wallet.cached!.vault;
    final dataKey = await _vaults.loadDataKey(vault.vaultId);
    if (dataKey == null || !mounted) return;
    try {
      await _vaults.addPasskeySlot(
        vault,
        dataKey,
        userName: wallet.cached!.emailHint ?? '${wallet.providerName} wallet',
      );
      if (mounted) AppSnackBar.show(context, 'Passkey added.');
    } on SocialVaultStaleKeyException {
      if (mounted) {
        AppSnackBar.show(
          context,
          _staleKeyMessage(wallet),
          type: AppSnackBarType.error,
        );
      }
    } on SocialVaultApiException catch (e) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        e.error == SocialVaultApiError.staleTimestamp
            ? socialVaultClockMessage
            : 'Could not add a passkey. Check your connection and try again.',
        type: AppSnackBarType.error,
      );
    } on PasskeyPrfException catch (e) {
      if (e.error == PasskeyPrfError.cancelled || !mounted) return;
      AppSnackBar.show(
        context,
        e.error == PasskeyPrfError.prfUnsupported
            ? 'That passkey provider cannot unlock a wallet. Try saving the '
                  'passkey with ${Platform.isIOS ? 'iCloud Keychain' : 'Google Password Manager'}.'
            : 'Could not add a passkey. Try again.',
        type: AppSnackBarType.error,
      );
    } catch (e) {
      AppLogger.warn('SignInKeys', 'add passkey failed: ${e.runtimeType}');
      if (mounted) {
        AppSnackBar.show(
          context,
          'Could not add a passkey. Check your connection and try again.',
          type: AppSnackBarType.error,
        );
      }
    }
  });

  /// Rename the passkey [slot]: its label only, signed with the vault key.
  /// An empty name clears the label, and the key then reads as "Passkey".
  Future<void> _rename(_WalletKeys wallet, api.SocialVaultSlot slot) =>
      _run(() async {
        final label = slot.label;
        final name = await showRenameSignInKeySheet(
          context,
          current: label != null && label.isNotEmpty ? label : null,
        );
        if (name == null || name.trim() == (label ?? '') || !mounted) return;
        final vault = wallet.cached!.vault;
        final dataKey = await _vaults.loadDataKey(vault.vaultId);
        if (dataKey == null || !mounted) return;
        try {
          await _vaults.renameSlot(vault, dataKey, slot.slotId, name);
          if (mounted) AppSnackBar.show(context, 'Passkey renamed.');
        } on SocialVaultLabelException {
          // The name itself was refused, for its length. The rename sheet
          // lets through only what the service takes, so this is a rule the
          // two no longer share: say the true reason, not that the
          // connection failed.
          if (mounted) {
            AppSnackBar.show(
              context,
              signInKeyNameTooLongMessage,
              type: AppSnackBarType.error,
            );
          }
        } on SocialVaultStaleKeyException {
          if (mounted) {
            AppSnackBar.show(
              context,
              _staleKeyMessage(wallet),
              type: AppSnackBarType.error,
            );
          }
        } on SocialVaultConflictException {
          if (!mounted) return;
          AppSnackBar.show(
            context,
            'Another device changed these keys. Check the list and try again.',
            type: AppSnackBarType.error,
          );
        } on SocialVaultApiException catch (e) {
          if (!mounted) return;
          AppSnackBar.show(
            context,
            e.error == SocialVaultApiError.staleTimestamp
                ? socialVaultClockMessage
                : 'Could not rename the passkey. Check your connection and '
                      'try again.',
            type: AppSnackBarType.error,
          );
        } catch (e) {
          AppLogger.warn('SignInKeys', 'rename failed: ${e.runtimeType}');
          if (mounted) {
            AppSnackBar.show(
              context,
              'Could not rename the passkey. Check your connection and try '
              'again.',
              type: AppSnackBarType.error,
            );
          }
        }
      });

  /// Remove [slot] by rotating the vault: a new data key and vault key,
  /// re-wrapped only for what this device can re-create now. The user sees
  /// exactly what is kept and dropped before anything changes.
  Future<void> _remove(_WalletKeys wallet, api.SocialVaultSlot slot) =>
      _run(() => _rotateRemoving(wallet, slot));

  /// Replace the wallet's sign-in keys after this phone's backup held one
  /// without end-to-end encryption: the same rotation a removal runs, started
  /// from this phone's own device key. It makes a new device key (and so a
  /// new entry, in a backup that is encrypted again), keeps each passkey the
  /// user confirms, and leaves whatever the unprotected backup held opening
  /// nothing.
  ///
  /// Refused while the phone still has no screen lock: no new device key
  /// could be made, so the rotation would only take this phone's key away.
  Future<void> _replaceKeys(_WalletKeys wallet) => _run(() async {
    final vault = wallet.cached!.vault;
    // As it is now, not as this screen last drew it.
    final backup = await _vaults.checkPlatformBackup();
    if (!mounted) return;
    if (!backup.encrypted) {
      AppSnackBar.show(
        context,
        replaceNeedsScreenLockMessage,
        type: AppSnackBarType.error,
      );
      return;
    }
    final own = vault.slots.firstWhereOrNull(
      (s) =>
          s.kind == api.SocialVaultSlotKind.platform &&
          wallet.localPlatformSlotIds.contains(s.slotId),
    );
    if (own == null) {
      // No live key of this phone's is left in the vault, so what the backup
      // held opens nothing: there is nothing to replace.
      await _vaults.dismissBackupExposure(vault.vaultId);
      if (mounted) {
        AppSnackBar.show(
          context,
          'This phone has no sign-in key left to replace.',
        );
      }
      return;
    }
    await _rotateRemoving(wallet, own, replacing: true);
  });

  /// The rotation behind [_remove] and [_replaceKeys]. With [replacing], the
  /// words are about replacing the keys rather than removing [slot].
  Future<void> _rotateRemoving(
    _WalletKeys wallet,
    api.SocialVaultSlot slot, {
    bool replacing = false,
  }) async {
    final vault = wallet.cached!.vault;
    final plan = await _vaults.planRemoval(vault, slot.slotId);
    if (!mounted) return;
    final confirmed = await showConfirmSheet(
      context,
      title: replacing
          ? 'Replace sign-in keys?'
          : 'Remove “${signInKeyInlineTitle(slot)}”?',
      message: signInKeyRemovalMessage(plan, Platform.isIOS),
      confirmLabel: replacing ? 'Replace' : 'Remove',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    if (!await requireReauth(context)) return;
    final dataKey = await _vaults.loadDataKey(vault.vaultId);
    if (dataKey == null) return;
    // "…whether the key was removed" / "…whether the keys were replaced".
    final outcome = replacing
        ? 'the keys were replaced'
        : 'the key was removed';
    try {
      final rotation = await _vaults.rotateRemoving(
        vault: vault,
        dataKey: dataKey,
        plan: plan,
      );
      if (!mounted) return;
      final skipped = rotation.unconfirmedPasskeys.map(signInKeyInlineTitle);
      final done = replacing
          ? 'Sign-in keys replaced.'
          : 'Sign-in key removed.';
      AppSnackBar.show(
        context,
        skipped.isEmpty
            ? done
            : '$done Not confirmed, so also removed: ${skipped.join(', ')}.',
      );
    } on SocialVaultUnlockException catch (e) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        e.platformStoreFull
            ? 'This phone’s Google backup is full, and no passkey was '
                  'confirmed, so nothing was changed.'
            : 'Nothing could be kept, so nothing was changed: the wallet '
                  'would have no sign-in key left.',
        type: AppSnackBarType.error,
      );
    } on SocialVaultStaleKeyException {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        _staleKeyMessage(wallet),
        type: AppSnackBarType.error,
      );
    } on SocialVaultConflictException {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        'Another device changed these keys. Check the list and try again.',
        type: AppSnackBarType.error,
      );
    } on SocialVaultApiException catch (e) {
      if (!mounted) return;
      // A refused timestamp is this device's clock: nothing was changed and
      // nothing about this device's key changed.
      if (e.error == SocialVaultApiError.staleTimestamp) {
        AppSnackBar.show(
          context,
          socialVaultClockMessage,
          type: AppSnackBarType.error,
        );
        return;
      }
      // Without an answer (or with a server error) the rotation may or
      // may not have happened; only a definite refusal changed nothing.
      final unknown = e.status == null || e.status! >= 500;
      AppSnackBar.show(
        context,
        unknown
            ? 'We could not confirm whether $outcome. Sign in again with '
                  '${wallet.providerName} to see the wallet’s current '
                  'sign-in keys.'
            : replacing
            ? 'Could not replace the keys. Nothing was changed; try again.'
            : 'Could not remove the key. Nothing was changed; try again.',
        type: AppSnackBarType.error,
      );
    } catch (e) {
      AppLogger.warn('SignInKeys', 'rotation failed: ${e.runtimeType}');
      if (!mounted) return;
      AppSnackBar.show(
        context,
        'We could not confirm whether $outcome. Sign in again with '
        '${wallet.providerName} to see the wallet’s current sign-in keys.',
        type: AppSnackBarType.error,
      );
    }
  }

  /// Delete the wallet's backup: its social vault. Behind the re-auth gate,
  /// then a confirmation that says what is lost and offers the recovery
  /// phrase first — once the backup is gone the phrase is the only one.
  ///
  /// The wallet itself stays on this phone. Afterwards it is listed here as
  /// a wallet whose backup was deleted, with no keys and nothing to manage.
  Future<void> _deleteBackup(_WalletKeys wallet) => _run(() async {
    if (!await requireReauth(context) || !mounted) return;
    final choice = await showChoiceSheet<_DeleteBackupChoice>(
      context,
      title: 'Delete wallet backup?',
      message: deleteWalletBackupMessage,
      options: const [
        ChoiceSheetOption(
          label: 'View recovery phrase',
          value: _DeleteBackupChoice.viewPhrase,
        ),
        ChoiceSheetOption(
          label: 'Delete wallet backup',
          value: _DeleteBackupChoice.delete,
          variant: MallowButtonVariant.danger,
        ),
        ChoiceSheetOption(
          label: 'Cancel',
          value: _DeleteBackupChoice.cancel,
          variant: MallowButtonVariant.text,
        ),
      ],
    );
    if (!mounted) return;
    if (choice == _DeleteBackupChoice.viewPhrase) {
      // The gate above was just cleared, so Show secrets opens without a
      // second challenge. Nothing is deleted on this path: the user comes
      // back and asks again.
      await context.push(AppRoutes.recoveryPhrase, extra: true);
      return;
    }
    if (choice != _DeleteBackupChoice.delete) return;
    try {
      await sl<SocialAuthService>().deleteWalletBackup(wallet.account.id);
      if (mounted) {
        AppSnackBar.show(
          context,
          'Wallet backup deleted. The wallet stays on this phone.',
        );
      }
    } on SocialVaultPhraseUnavailableException {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        'This phone does not hold this wallet’s recovery phrase, so its '
        'backup was not deleted. Sign in again with ${wallet.providerName} '
        'first.',
        type: AppSnackBarType.error,
      );
    } on SocialVaultStaleKeyException {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        _staleKeyMessage(wallet),
        type: AppSnackBarType.error,
      );
    } on SocialVaultApiException catch (e) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        e.error == SocialVaultApiError.staleTimestamp
            ? socialVaultClockMessage
            : 'Could not delete the wallet backup. Check your connection '
                  'and try again.',
        type: AppSnackBarType.error,
      );
    } catch (e) {
      AppLogger.warn('SignInKeys', 'backup delete failed: ${e.runtimeType}');
      if (!mounted) return;
      AppSnackBar.show(
        context,
        'Could not finish deleting the wallet backup. Try again.',
        type: AppSnackBarType.error,
      );
    }
  });

  static String _staleKeyMessage(_WalletKeys wallet) =>
      'This device can no longer change this wallet’s sign-in keys — they were '
      'changed on another device. Sign in again with ${wallet.providerName} '
      'to manage them here.';

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Sign-in keys',
      child: _loading
          ? const SizedBox.shrink()
          : _wallets.isEmpty
          ? _note(context, 'No Google or Apple wallets on this device.')
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              children: [
                if (_wallets.any(
                  (w) => _backup.pausedVaultIds.contains(w.vaultId),
                )) ...[
                  _pausedNotice(context),
                  const SizedBox(height: 24),
                ],
                for (final wallet in _wallets) ...[
                  _walletSection(context, wallet),
                  const SizedBox(height: 32),
                ],
                // True of a wallet with sign-in keys only, so it is not shown
                // when every wallet listed is one from the older sign-in.
                if (_wallets.any((w) => w.vaultId != null))
                  Text(
                    'A wallet with sign-in keys opens with your Google or '
                    'Apple sign-in plus one of those keys. mallow stores only '
                    'an encrypted copy it cannot open. Without a passkey it '
                    'opens only where a device backup reaches, never on the '
                    'web. If you lose access to the Google or Apple account '
                    'itself, only its exported recovery phrase brings the '
                    'wallet back — see Show secrets.',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _walletSection(BuildContext context, _WalletKeys wallet) {
    final colors = context.mallowColors;
    final email = wallet.cached?.emailHint;
    final children = <Widget>[
      Row(
        children: [
          SocialProviderIcon(
            provider: wallet.provider,
            legacy: wallet.account.isLegacySocial,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              wallet.account.name,
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
      if (email != null) ...[
        const SizedBox(height: 4),
        Text(
          email,
          style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
        ),
      ],
      const SizedBox(height: 12),
    ];

    if (wallet.vaultId == null) {
      // No vault, so no sign-in keys: either a wallet from the older sign-in,
      // which never has one, or a vault wallet whose backup was deleted.
      children.add(
        _paragraph(
          context,
          wallet.account.isLegacySocial
              ? '${legacySocialSentence(wallet.providerName)} It has no '
                    'sign-in keys. $legacySocialRecoverySentence To keep your '
                    'own copy, save its keys from Show secrets.'
              : 'This wallet’s backup was deleted, so its keys are only on '
                    'this phone. Its recovery phrase is in Show secrets: '
                    'write it down.',
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    final vault = wallet.cached?.vault;
    if (vault == null) {
      children.add(
        _paragraph(
          context,
          'The keys of this wallet appear here after you next sign in with '
          '${wallet.providerName} on this device.',
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    final removable = wallet.hasDataKey && vault.slots.length > 1;
    for (final slot in vault.slots) {
      final isPasskey = slot.kind == api.SocialVaultSlotKind.passkeyPrf;
      final thisDevice = wallet.localPlatformSlotIds.contains(slot.slotId);
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              MallowSvgIcon(
                isPasskey ? 'assets/icons/key.svg' : 'assets/icons/shield.svg',
                width: 22,
                height: 22,
                color: colors.textPrimary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The name is its owner's text: one line, cut to the row.
                    Text(
                      signInKeyTitle(slot),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MallowTheme.uiBody,
                    ),
                    Text(
                      signInKeyKind(
                        slot,
                        onThisDevice: thisDevice,
                        cloudBacked:
                            Platform.isAndroid && thisDevice && !isPasskey
                            ? _backup.isCloudBacked(vault.vaultId, slot.slotId)
                            : null,
                      ),
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              // A passkey's label is the owner's to choose. A device backup's
              // is written by the app and says which device made it.
              if (isPasskey && wallet.hasDataKey)
                IconButton(
                  tooltip: 'Rename',
                  onPressed: _busy ? null : () => _rename(wallet, slot),
                  icon: MallowSvgIcon(
                    'assets/icons/pencil.svg',
                    width: 20,
                    height: 20,
                    color: colors.textSecondary,
                  ),
                ),
              if (removable)
                IconButton(
                  tooltip: 'Remove',
                  onPressed: _busy ? null : () => _remove(wallet, slot),
                  icon: MallowSvgIcon(
                    'assets/icons/trash.svg',
                    width: 20,
                    height: 20,
                    color: colors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final hasPasskey = vault.slots.any(
      (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
    );
    children.add(const SizedBox(height: 12));
    if (wallet.hasDataKey && _backup.exposedVaultIds.contains(vault.vaultId)) {
      // This phone's backup held a key of this wallet while it was not
      // end-to-end encrypted. Stays until the keys are replaced or the
      // advice is dismissed.
      children.addAll([
        _paragraph(context, backupWasUnprotectedMessage),
        const SizedBox(height: 12),
        MallowButton(
          label: replaceSignInKeysLabel,
          isFullWidth: true,
          isLoading: _busy,
          onPressed: () => _replaceKeys(wallet),
        ),
        MallowButton(
          label: 'Dismiss',
          variant: MallowButtonVariant.text,
          isFullWidth: true,
          enabled: !_busy,
          onPressed: () =>
              _run(() => _vaults.dismissBackupExposure(vault.vaultId)),
        ),
        const SizedBox(height: 12),
      ]);
    }
    if (!wallet.hasDataKey) {
      children.add(
        _paragraph(
          context,
          'Sign in again with ${wallet.providerName} on this device to manage '
          'these keys.',
        ),
      );
    } else if (_passkeysHere) {
      children.add(
        MallowButton(
          label: 'Add a passkey',
          variant: MallowButtonVariant.secondary,
          isFullWidth: true,
          isLoading: _busy,
          onPressed: () => _addPasskey(wallet),
        ),
      );
    } else if (!hasPasskey) {
      // iOS 16 and 17 can create passkeys but cannot evaluate the PRF
      // extension the vault needs, so no passkey can be added from here.
      children.add(
        _paragraph(
          context,
          Platform.isIOS
              ? 'Passkeys need iOS 18 or later. To open this wallet on the web, '
                    'add a passkey from an iPhone on iOS 18 or later, or from '
                    'an Android phone, signed in to this wallet.'
              : 'This device cannot use passkeys. To open this wallet on the '
                    'web, add a passkey from a device that can.',
        ),
      );
      if (!sl<PreferencesService>().socialVaultPlatformOnlyAcknowledged
          .contains(vault.vaultId)) {
        children.addAll([
          const SizedBox(height: 12),
          MallowButton(
            label: 'I understand',
            variant: MallowButtonVariant.text,
            isFullWidth: true,
            // Through the attention list's own helper, so the Home banner
            // that shows the same advice hears about it.
            onPressed: () =>
                _run(() => acknowledgeSocialVaultPlatformOnly(vault.vaultId)),
          ),
        ]);
      }
    }
    if (vault.slots.any((s) => s.kind == api.SocialVaultSlotKind.platform)) {
      children.addAll([
        const SizedBox(height: 12),
        _paragraph(
          context,
          platformBackupCaveat(
            ios: Platform.isIOS,
            paused: _backup.pausedVaultIds.contains(vault.vaultId),
          ),
        ),
      ]);
    }
    if (wallet.hasDataKey) {
      children.addAll([
        const SizedBox(height: 12),
        MallowButton(
          label: 'Delete wallet backup',
          variant: MallowButtonVariant.text,
          foregroundColor: colors.error,
          isFullWidth: true,
          enabled: !_busy,
          onPressed: () => _deleteBackup(wallet),
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// The same words as the Home banner, for the same state: the phone has no
  /// screen lock, so the device keys listed below are out of its backup.
  Widget _pausedNotice(BuildContext context) {
    final colors = context.mallowColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
      ),
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
                  const Text(backupPausedTitle, style: MallowTheme.uiBody),
                  const SizedBox(height: 4),
                  Text(
                    backupPausedMessage,
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
    );
  }

  Widget _paragraph(BuildContext context, String text) => Text(
    text,
    style: MallowTheme.uiMeta.copyWith(
      color: context.mallowColors.textSecondary,
    ),
  );

  Widget _note(BuildContext context, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: MallowTheme.uiMeta.copyWith(
          color: context.mallowColors.textSecondary,
        ),
      ),
    ),
  );
}

enum _DeleteBackupChoice { viewPhrase, delete, cancel }

class _WalletKeys {
  const _WalletKeys({
    required this.account,
    required this.provider,
    required this.vaultId,
    required this.cached,
    required this.hasDataKey,
    required this.localPlatformSlotIds,
  });

  final Account account;
  final String provider;
  final String? vaultId;
  final CachedSocialVault? cached;
  final bool hasDataKey;

  /// Platform slots whose secret this device can read (its own, or synced
  /// from another device on the same iCloud or Google account).
  final Set<String> localPlatformSlotIds;

  String get providerName => provider == 'apple' ? 'Apple' : 'Google';
}

/// The confirmation text for [plan]: what goes, what stays, and what a
/// removal does not do.
String signInKeyRemovalMessage(SocialVaultRemovalPlan plan, bool ios) {
  final dropped = plan.dropped.map(signInKeyInlineTitle).join(', ');
  final kept = <String>[
    if (plan.newPlatformSlot)
      'a new backup in ${ios ? 'this iPhone’s iCloud Keychain' : 'this phone’s Google backup'}',
    for (final p in plan.passkeysToConfirm)
      '${signInKeyInlineTitle(p)} (you confirm it next; skipping it removes it '
          'too)',
  ];
  return 'Removed: $dropped.\n'
      'Kept: ${kept.isEmpty ? 'nothing' : kept.join('; ')}.\n\n'
      'Removing a key stops it from being offered to unlock this wallet on '
      'new devices. A device that already unlocked this wallet keeps its '
      'keys — if a device was lost or stolen, move your funds to a new '
      'wallet.';
}

/// The line under a sign-in key's name: what kind of key it is and, for a
/// device key this device holds, where it is.
///
/// [cloudBacked] is given for an Android phone's own device key only: true
/// while its entry is in Google's end-to-end encrypted backup of the phone,
/// false while it is on the phone alone (the backup is paused, or was never
/// encrypted when the key was made), null when this device does not know.
/// Nothing here says "Google backup" unless the entry is in one.
String signInKeyKind(
  api.SocialVaultSlot slot, {
  required bool onThisDevice,
  bool? cloudBacked,
}) {
  if (slot.kind == api.SocialVaultSlotKind.passkeyPrf) return 'Passkey';
  if (!onThisDevice) return 'Device backup';
  return switch (cloudBacked) {
    true => 'Device backup · in this phone’s encrypted Google backup',
    false => 'On this phone only · not in a backup',
    null => 'Device backup · available on this device',
  };
}

/// What a platform backup key can and cannot do, said plainly: it is not a
/// general-purpose backup.
///
/// [paused] (Android): the phone has no screen lock, so its key is out of
/// the backup — and the caveat says that instead of describing a backup the
/// key is not in.
///
/// On iOS the entries live in iCloud Keychain, which every device signed in
/// to the Apple ID reads — so they are not one key per device, whatever
/// their labels say, and removing one here does not take a lost device's
/// access away. Removing the device from the Apple ID does.
String platformBackupCaveat({required bool ios, bool paused = false}) => ios
    ? 'A device backup key lives in iCloud Keychain. It reopens this wallet '
          'after a reinstall, and on your other Apple devices only while '
          'iCloud Keychain is turned on for this Apple ID. Every device '
          'signed in to the same Apple ID can read these keys, so removing '
          'one here does not lock out a lost device: remove that device from '
          'your Apple ID instead.'
    : paused
    ? backupPausedMessage
    : 'A device backup key lives in Google’s backup for this phone. Google '
          'restores it only while setting up a new Android phone from this '
          'one’s backup, not later, and the app can still reopen the wallet '
          'here after a reinstall.';
