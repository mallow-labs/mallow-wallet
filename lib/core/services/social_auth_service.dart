import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../shared/utils/chain.dart' show Chain;
import '../crypto/exceptions.dart';
import '../crypto/mnemonic_generator.dart';
import '../models/account.dart';
import '../observability/app_logger.dart';
import '../social_vault/passkey_prf.dart';
import '../social_vault/platform_backup_guard.dart';
import '../social_vault/social_identity.dart';
import '../social_vault/social_vault_api.dart';
import '../social_vault/social_vault_crypto.dart';
import '../social_vault/social_vault_service.dart';
import '../social_vault/social_wallet_keys.dart';
import 'wallet_repository.dart';

/// Result of a social sign-in.
///
/// Carries no key material: the keys reach secure storage by direct call into
/// [WalletRepository.addSocialAccount] and never travel on the broadcast
/// stream, whose events are observable app-wide.
class SocialAuthResult {
  SocialAuthResult({
    required this.wallet,
    required this.provider,
    required this.existed,
  });

  /// The account's **Solana** row — the one the app selects and signs with.
  final WalletInfo wallet;

  /// The social provider used: 'google' or 'apple'.
  final String provider;

  /// Whether this identity already had a social account on this device, i.e.
  /// this login completed/refreshed it rather than creating it.
  final bool existed;
}

/// What the user answered when a sign-in found no wallet for the account.
enum SocialVaultCreateChoice {
  /// Create a new wallet for this account.
  create,

  /// This is the wrong account: sign in again and choose another.
  useAnotherAccount,

  /// Stop. Nothing is created.
  cancel,
}

/// How this device knows a vault is gone, which decides what an unlink does
/// with the vault's platform entries. See
/// [SocialAuthService.unlinkDeletedVault].
enum SocialVaultUnlink {
  /// The backend accepted a delete this device signed.
  signedDelete,

  /// The backend answered "not found".
  notFound,
}

/// The questions the social vault asks the user mid-flow, and the notices it
/// shows. Implemented by the app shell with sheets on the root navigator;
/// null in tests and before the shell has booted. Without it nothing is
/// offered and nothing that needs a yes happens: no wallet is created, and
/// no key is added.
abstract interface class SocialVaultPrompts {
  /// Offer a passkey right after a social wallet is created or first opened
  /// here, so the wallet also opens on the web and on devices of the other
  /// platform. True adds one — after [reauthenticate].
  Future<bool> offerPasskey(String provider);

  /// The app's own re-authentication (biometrics, else the PIN), asked before
  /// a sign-in key is added outside the Sign-in keys screen — the same gate
  /// that screen uses. A new key is a new way into the wallet, and whoever
  /// holds the unlocked phone must not be able to add one. True when cleared.
  Future<bool> reauthenticate();

  /// The sign-in found no wallet for the account ([emailHint], when the
  /// provider shared one). Nothing is created unless this answers
  /// [SocialVaultCreateChoice.create].
  ///
  /// [hasWalletHere]: this device already holds a wallet with sign-in keys
  /// for [provider], which belongs to [walletAccountEmail] (when known) — so
  /// the likelier story is a sign-in with the wrong account, and the question
  /// warns instead of inviting.
  Future<SocialVaultCreateChoice> confirmCreate({
    required String provider,
    String? emailHint,
    bool hasWalletHere = false,
    String? walletAccountEmail,
  });

  /// A wallet on this device had to be reopened, and the sign-in that
  /// answered is not the account it belongs to ([expectedEmail], when
  /// known). True signs in again with an account chooser.
  Future<bool> wrongAccount({
    required String provider,
    String? expectedEmail,
    String? signedInEmail,
  });

  /// The wallet was added, but a step that keeps it recoverable (this
  /// device's copy of the vault, its platform key or passkey) failed. The
  /// wallet works; the user can retry from Sign-in keys or by signing in
  /// again.
  Future<void> backupIncomplete({required String provider});

  /// Show what the latest record of [vaultId] calls for: the blocking
  /// warning when its deletion is pending and unanswered, then the notice
  /// for sign-in keys this device has not seen. Returns when the user has
  /// dealt with them; shows nothing when there is nothing to show.
  Future<void> reviewVault(String vaultId);

  /// A [provider] wallet on this device was unlinked from its vault because
  /// the backend no longer has it. Say so, once: the wallet stays on this
  /// phone and its recovery phrase is now its only backup, with a way to the
  /// phrase (behind the app's re-authentication). True once the user has
  /// seen it, false when it could not be shown.
  Future<bool> backupNoLongerStored({required String provider});

  /// This phone's backup was without end-to-end encryption for a while, with
  /// sign-in keys in it. Say so, and offer to replace them. True when the
  /// user chose to (and was taken to Sign-in keys, where it is done), false
  /// when they dismissed it, null when it could not be shown.
  ///
  /// The words must not promise more than a replacement does: it stops a
  /// key read from that backup from opening the wallet backup from then on,
  /// and does nothing about a read that was already used (the recovery
  /// phrase stays the same). See `backupWasUnprotectedMessage`.
  Future<bool?> offerKeyReplacement();
}

/// One more notice of the social vault's, kept apart from
/// [SocialVaultPrompts] so that a shell which does not show it yet still
/// builds. A shell that does implements both; one that does not is simply
/// never asked, and the notice stays due.
abstract interface class SocialVaultKeyReplacedPrompt {
  /// A status check found that this device's own sign-in key for a
  /// [provider] wallet no longer opens the wallet backup: the keys were
  /// replaced on another device. Say so, once — otherwise the user only
  /// finds Sign-in keys asking them to sign in again, with no reason given,
  /// and the checks that would warn them of a pending deletion or a new key
  /// have stopped without a word. Signing in again puts it right
  /// (`signInKeyReplacedMessage`).
  ///
  /// True once the user has seen it, false when it could not be shown.
  Future<bool> signInKeyReplaced({required String provider});
}

/// Google and Apple sign-in, backed by the social vault.
///
/// A sign-in identifies the person (an ID token the backend verifies) and
/// fetches their vault — ciphertext the backend cannot open. A slot only the
/// user's devices hold opens it here: the platform slot silently, else a
/// passkey. The wallet inside is a recovery phrase; its per-chain keys are
/// then stored exactly as the imported-key signing paths read them, so signing
/// never touches the vault.
///
/// An identity with no vault gets one, holding a fresh phrase: its first slot
/// is made on this device, and the backend stores it. Only after the user
/// confirmed it: "no wallet for this account" is as often the wrong account
/// as a new user.
///
/// Every vault link records the sign-in identity it belongs to (the opaque id
/// `open` returns), on the wallet's rows and in the recovery graph. A vault
/// reopened for a wallet already on the device is opened only by that
/// identity, and no answer from any other account is acted on.
///
/// Nothing here knows the older sign-in (run by Web3Auth) that made Google and
/// Apple wallets before the vault. Such a wallet
/// (`WalletInfo.isLegacySocialWallet`) keeps signing from the keys already
/// stored on its device, is never placed in a vault, and cannot be re-created
/// by this app: see [LegacySocialKeyUnavailableException].
@lazySingleton
class SocialAuthService {
  SocialAuthService(this._identity, this._vaults);

  static const _tag = 'SocialAuthService';

  final SocialIdentityProvider _identity;
  final SocialVaultService _vaults;

  /// Set by the app shell once its navigator exists.
  SocialVaultPrompts? prompts;

  final StreamController<SocialAuthResult> _signInController =
      StreamController<SocialAuthResult>.broadcast();

  /// Fires once per successful social sign-in with the account's Solana row.
  /// Durable and lifecycle-independent: the provider sheet can background
  /// the app, and the screen that started the sign-in can be torn down before
  /// it returns. Key recovery deliberately does not publish.
  Stream<SocialAuthResult> get onSignInComplete => _signInController.stream;

  // ---------------------------------------------------------------------------
  // Pure policy (pinned by tests)
  // ---------------------------------------------------------------------------

  /// What a key recovery for one account must reproduce, or
  /// [LegacySocialWalletException] when the account cannot be recovered.
  ///
  /// Unrecoverable means: no social row, no usable `socialProvider` (we would
  /// not know whom to sign in as), or no social Solana row (the address a
  /// recovery is verified against).
  ///
  /// `legacy` is `WalletInfo.isLegacySocialWallet` for the account: a wallet
  /// from the older sign-in, which has no vault to reopen.
  @visibleForTesting
  static ({
    String provider,
    String solanaAddress,
    String? ethereumAddress,
    String? tezosAddress,
    String? vaultId,
    String? identityId,
    bool legacy,
  })
  recoveryTargetFor(List<WalletInfo> wallets) {
    final social = wallets
        .where((w) => w.walletType == WalletType.social)
        .toList();
    if (social.isEmpty) {
      throw LegacySocialWalletException(
        'This account has no social wallet to sign in for.',
      );
    }
    final provider = social
        .map((w) => w.socialProvider)
        .firstWhere((p) => p == 'google' || p == 'apple', orElse: () => null);
    if (provider == null) throw LegacySocialWalletException();
    WalletInfo? on(Chain chain) => social.cast<WalletInfo?>().firstWhere(
      (w) => w!.chain == chain.toDbString(),
      orElse: () => null,
    );
    final solana = on(Chain.solana);
    if (solana == null) throw LegacySocialWalletException();
    return (
      provider: provider,
      solanaAddress: solana.address,
      ethereumAddress: on(Chain.ethereum)?.address,
      tezosAddress: on(Chain.tezos)?.address,
      vaultId: social
          .map((w) => w.socialVaultId)
          .firstWhere((id) => id != null, orElse: () => null),
      identityId: social
          .map((w) => w.socialIdentityId)
          .firstWhere((id) => id != null, orElse: () => null),
      legacy: social.any((w) => w.isLegacySocialWallet),
    );
  }

  /// Gate a recovery on it reproducing the address the account holds.
  ///
  /// Storing a different key against the row would produce valid signatures
  /// from an address the row does not represent, which fails silently — so
  /// this throws instead.
  @visibleForTesting
  static void requireDerivedAddressMatches({
    required String expected,
    required String derived,
  }) {
    if (expected == derived) return;
    throw LegacySocialWalletException(_differentWalletMessage);
  }

  static const _differentWalletMessage =
      'This sign-in opened a different wallet than the one on this device, '
      'so nothing was changed.';

  // ---------------------------------------------------------------------------
  // Sign-in
  // ---------------------------------------------------------------------------

  /// Sign in with Google. Returns null when the user cancels.
  Future<SocialAuthResult?> signInWithGoogle() => _signIn('google');

  /// Sign in with Apple. Returns null when the user cancels.
  Future<SocialAuthResult?> signInWithApple() => _signIn('apple');

  /// Returns null only for a cancellation. Every other failure is logged and
  /// rethrown so the sheet can say why.
  Future<SocialAuthResult?> _signIn(String provider) async {
    try {
      final signedIn = await _openOrCreate(provider);
      if (signedIn == null) return null;
      final opened = signedIn.opened;
      final unlocked = signedIn.unlocked;
      final vaultId = unlocked.vault.vaultId;

      final keys = await SocialWalletKeys.fromPayload(unlocked.payload);
      final repository = GetIt.instance<WalletRepository>();
      final outcome = await _storeSocialAccount(
        repository,
        provider,
        keys,
        vaultId,
        opened.identityId,
      );
      final result = SocialAuthResult(
        wallet: _solanaRowOf(outcome.wallets),
        provider: provider,
        existed: outcome.existed,
      );
      AppLogger.info(
        _tag,
        '$provider sign-in complete for ${result.wallet.address} '
        '(existed=${result.existed})',
      );
      // The account exists from here on, whatever happens next: it is
      // published even if keeping this device's copy of the vault or adding
      // its keys fails, and that failure is reported on its own.
      var backupComplete = true;
      try {
        await _vaults.persist(
          unlocked,
          provider: provider,
          emailHint: opened.emailHint,
        );
        await _afterOpen(provider, unlocked, opened.emailHint);
      } catch (e) {
        backupComplete = false;
        AppLogger.error(_tag, '$provider wallet stored; backup step failed', e);
      }
      _signInController.add(result);
      if (!backupComplete) {
        await prompts?.backupIncomplete(provider: provider);
      }
      // A deletion request pending on the vault just opened, or a sign-in key
      // this device has not seen, is said now rather than at the next unlock.
      await _reviewVault(vaultId);
      return result;
    } on TransactionAuthCancelledException {
      AppLogger.info(_tag, '$provider sign-in cancelled');
      return null;
    } on PasskeyPrfException catch (e) {
      if (e.error == PasskeyPrfError.cancelled) {
        AppLogger.info(_tag, '$provider sign-in cancelled at the passkey');
        return null;
      }
      AppLogger.error(_tag, '$provider sign-in failed', e);
      rethrow;
    } catch (e) {
      // Only the error type and its own message are logged — never a token,
      // a payload or a key, none of which any exception here carries.
      AppLogger.error(_tag, '$provider sign-in failed', e);
      rethrow;
    }
  }

  /// Sign in and open the account's vault, or — when it has none and the
  /// user says so — create one. Null when the user backs out, at the provider
  /// or at the question; nothing is created or stored then.
  Future<({api.SocialVaultOpenResponse opened, UnlockedSocialVault unlocked})?>
  _openOrCreate(String provider) async {
    var opened = await _openIdentity(provider);
    while (true) {
      if (opened == null) return null;
      final vault = opened.vault;
      if (vault != null) {
        return (
          opened: opened,
          unlocked: await _cancellable(_vaults.unlock(vault)),
        );
      }
      switch (await _confirmCreate(provider, opened)) {
        case SocialVaultCreateChoice.create:
          return (
            opened: opened,
            unlocked: await _createVault(provider, opened),
          );
        case SocialVaultCreateChoice.cancel:
          AppLogger.info(_tag, '$provider sign-in: no wallet, none created');
          return null;
        case SocialVaultCreateChoice.useAnotherAccount:
          opened = await _openIdentity(provider, chooseAccount: true);
      }
    }
  }

  /// Get an ID token and hand it to the vault's `open`. Null when the user
  /// cancels the provider's sheet.
  ///
  /// A token from a [silent] sign-in can be one the provider's SDK had
  /// cached, which the backend refuses as already used or too old
  /// (`invalid_id_token`). That is no reason to fail: the sign-in is asked
  /// again, with its sheet, once.
  Future<api.SocialVaultOpenResponse?> _openIdentity(
    String provider, {
    bool silent = false,
    bool chooseAccount = false,
  }) async {
    final token = await _cancellable(
      _identity.idToken(provider, silent: silent, chooseAccount: chooseAccount),
    );
    if (token == null) return null;
    try {
      return await _vaults.vaultApi.open(token);
    } on SocialVaultApiException catch (e) {
      if (!silent || chooseAccount || !e.idTokenRefused) rethrow;
      AppLogger.info(_tag, 'silent sign-in token refused; asking again');
      final fresh = await _cancellable(_identity.idToken(provider));
      if (fresh == null) return null;
      return _vaults.vaultApi.open(fresh);
    }
  }

  /// Ask before a wallet is created for an account that has none. Warns
  /// instead when this device already holds a wallet with sign-in keys for
  /// the provider: then the account that just signed in is more likely the
  /// wrong one than a new one.
  Future<SocialVaultCreateChoice> _confirmCreate(
    String provider,
    api.SocialVaultOpenResponse opened,
  ) async {
    final prompts = this.prompts;
    // Nobody to ask is not a yes.
    if (prompts == null) {
      throw StateError('a new wallet needs a confirmation; no prompts are set');
    }
    WalletInfo? here;
    for (final w in await GetIt.instance<WalletRepository>().getAllWallets()) {
      if (w.walletType == WalletType.social &&
          w.socialProvider == provider &&
          w.socialVaultId != null) {
        here = w;
        break;
      }
    }
    return prompts.confirmCreate(
      provider: provider,
      emailHint: opened.emailHint,
      hasWalletHere: here != null,
      walletAccountEmail: here == null
          ? null
          : (await _vaults.cached(here.socialVaultId!))?.emailHint,
    );
  }

  /// First sign-in for an identity: a new wallet — a fresh recovery phrase —
  /// in a new vault. Always: nothing is looked up about the identity
  /// elsewhere, and an older-sign-in wallet it may have is not brought in.
  Future<UnlockedSocialVault> _createVault(
    String provider,
    api.SocialVaultOpenResponse opened,
  ) async {
    try {
      return await _cancellable(
        _vaults.create(
          identityToken: opened.identityToken,
          payload: SocialVaultPayload(MnemonicGenerator.generate12Words()),
          userName: _userName(provider, opened.emailHint),
        ),
      );
    } on SocialVaultApiException catch (e) {
      if (e.error != SocialVaultApiError.vaultExists) rethrow;
      // Another device created this identity's vault first. Open that one.
      AppLogger.info(_tag, 'vault created elsewhere first; opening it');
      final again = await _openIdentity(provider, silent: true);
      if (again == null) throw TransactionAuthCancelledException();
      // The second sign-in shows no sheet where it can, so it may not be the
      // account the first one was. Another account's vault is not this one's.
      if (again.identityId != opened.identityId) {
        throw SocialAccountMismatchException(
          provider: provider,
          expectedEmail: opened.emailHint,
        );
      }
      final vault = again.vault;
      if (vault == null) rethrow;
      return _cancellable(_vaults.unlock(vault));
    }
  }

  /// After a vault opens on this device: give the device its own platform
  /// slot (so a reinstall reopens silently), then offer a passkey when the
  /// vault has none. Both best effort — the wallet is already usable.
  ///
  /// The platform slot is added without asking: it is this device's own key,
  /// kept where only this user's devices read it. The passkey is not: it is
  /// a key that can live anywhere, so it is added only after the offer was
  /// accepted AND the app's re-authentication cleared.
  Future<void> _afterOpen(
    String provider,
    UnlockedSocialVault unlocked,
    String? emailHint,
  ) async {
    var vault = unlocked.vault;
    // Against the slot list as it is now, read by the sweep itself: the
    // record in hand was fetched before the user was asked for a passkey,
    // however long ago that was.
    try {
      await _vaults.sweepPlatformEntries(vault.vaultId, unlocked.dataKey);
    } catch (e) {
      AppLogger.warn(_tag, 'platform entries not swept: ${e.runtimeType}');
    }
    try {
      vault = await _vaults.ensurePlatformSlot(vault, unlocked.dataKey);
    } catch (e) {
      AppLogger.warn(_tag, 'platform slot not added: ${e.runtimeType}');
    }
    final hasPasskey = vault.slots.any(
      (s) => s.kind == api.SocialVaultSlotKind.passkeyPrf,
    );
    final prompts = this.prompts;
    if (hasPasskey || prompts == null) return;
    if (!await _vaults.passkeysAvailable()) return;
    if (!await prompts.offerPasskey(provider)) return;
    if (!await prompts.reauthenticate()) {
      AppLogger.info(_tag, 'passkey not added: re-authentication not cleared');
      return;
    }
    try {
      await _vaults.addPasskeySlot(
        vault,
        unlocked.dataKey,
        userName: _userName(provider, emailHint),
      );
    } catch (e) {
      // The offer is optional; the Sign-in keys screen can add one later.
      AppLogger.warn(_tag, 'passkey not added: $e');
    }
  }

  static String _userName(String provider, String? emailHint) =>
      (emailHint != null && emailHint.isNotEmpty)
      ? emailHint
      : '${_providerLabel(provider)} wallet';

  // ---------------------------------------------------------------------------
  // Key recovery
  // ---------------------------------------------------------------------------

  /// Re-derive and re-store the keys for the social account [accountId].
  ///
  /// Called when a social row's stored key is missing — a wiped keystore, or
  /// a database restored onto a fresh install. A vault-linked account is
  /// reopened: from this device's own copy when it still holds the data key,
  /// else by signing in again (silently where the provider allows it) and
  /// opening the vault with the platform slot or a passkey.
  ///
  /// The sign-in must be the account the wallet belongs to. When it is not —
  /// the provider silently handed over another account — this asks the user
  /// to sign in again with an account chooser, and throws
  /// [SocialAccountMismatchException] when they decline. Whatever such a
  /// sign-in answers ("no vault", another vault), nothing on this device or
  /// in the platform's synced keychain is deleted because of it.
  ///
  /// An account with no vault has nothing to reopen. For a wallet from the
  /// older sign-in this throws [LegacySocialKeyUnavailableException], whose
  /// message says how to bring the wallet back (the older sign-in on the
  /// mallow website, an export there, an import here); for a vault wallet
  /// whose backup was deleted, a [LegacySocialWalletException] pointing at
  /// its recovery phrase. Neither signs in or prompts.
  ///
  /// Every chain address the account holds must come out the same, or this
  /// throws [LegacySocialWalletException] and stores nothing.
  ///
  /// Throws [TransactionAuthCancelledException] when the user backs out: the
  /// caller is mid-signature, so a cancel must unwind the whole flow.
  ///
  /// Concurrent calls for the same [accountId] share one attempt and one
  /// outcome — see [_recoveriesInFlight].
  Future<void> recoverKeysForAccount(String accountId) {
    final pending = _recoveriesInFlight[accountId];
    if (pending != null) return pending;
    final started = _runKeyRecovery(accountId);
    _recoveriesInFlight[accountId] = started;
    return started;
  }

  /// In-flight recoveries, keyed by account id. `WalletManager` wires
  /// recovery into every social key load, so a multi-chain sign can enter
  /// here twice at once; un-coalesced, each would show its own sign-in.
  final Map<String, Future<void>> _recoveriesInFlight =
      <String, Future<void>>{};

  Future<void> _runKeyRecovery(String accountId) async {
    try {
      await _recoverKeysForAccount(accountId);
    } finally {
      final _ = _recoveriesInFlight.remove(accountId);
    }
  }

  Future<void> _recoverKeysForAccount(String accountId) async {
    final repository = GetIt.instance<WalletRepository>();
    try {
      final target = recoveryTargetFor(
        await repository.getWalletsForAccount(accountId),
      );
      final vaultId = target.vaultId;
      if (vaultId == null) {
        throw target.legacy
            ? LegacySocialKeyUnavailableException(provider: target.provider)
            : LegacySocialWalletException(_backupDeletedMessage);
      }
      final reopened = await _reopen(
        target.provider,
        vaultId,
        target.identityId,
      );
      final unlocked = reopened.unlocked;
      final keys = await SocialWalletKeys.fromPayload(unlocked.payload);
      requireDerivedAddressMatches(
        expected: target.solanaAddress,
        derived: keys.solanaAddress,
      );
      if (!keys.matches(
        solana: target.solanaAddress,
        ethereum: target.ethereumAddress,
        tezos: target.tezosAddress,
      )) {
        throw LegacySocialWalletException(_differentWalletMessage);
      }
      // Idempotent: re-stores all three keys and backfills a missing row —
      // and records the identity on a row that predates it.
      await _storeSocialAccount(
        repository,
        target.provider,
        keys,
        vaultId,
        reopened.identityId,
      );
      await _vaults.persist(
        unlocked,
        provider: target.provider,
        emailHint: reopened.emailHint,
      );
      AppLogger.info(_tag, 'recovered keys for ${target.solanaAddress}');
    } on TransactionAuthCancelledException {
      AppLogger.info(_tag, 'key recovery cancelled');
      rethrow;
    } on PasskeyPrfException catch (e) {
      if (e.error == PasskeyPrfError.cancelled) {
        throw TransactionAuthCancelledException(
          'Sign-in was cancelled. Transaction aborted.',
        );
      }
      AppLogger.error(_tag, 'key recovery failed', e);
      rethrow;
    } catch (e) {
      AppLogger.error(_tag, 'key recovery failed', e);
      rethrow;
    }
  }

  static const _backupDeletedMessage =
      'This wallet’s backup was deleted. Restore it from its recovery phrase.';

  /// Open the vault [vaultId] again: from this device's data key and cached
  /// record when both are here (no prompt, no network), else through a
  /// sign-in and a slot. The caller checks the addresses either way.
  ///
  /// [identityId] is the sign-in identity recorded with the wallet's vault
  /// link, or null for a row that predates it. `identityId` in the result is
  /// the one the sign-in proved, or null when no sign-in was needed.
  Future<
    ({UnlockedSocialVault unlocked, String? emailHint, String? identityId})
  >
  _reopen(String provider, String vaultId, String? identityId) async {
    final dataKey = await _vaults.loadDataKey(vaultId);
    final cached = await _vaults.cached(vaultId);
    if (dataKey != null && cached != null) {
      try {
        final payload = await SocialVaultCrypto.openPayload(
          vaultId: vaultId,
          dataKey: dataKey,
          sealed: SocialVaultSealed.fromWire(
            nonce: cached.vault.payloadNonce,
            ciphertext: cached.vault.payloadCiphertext,
          ),
        );
        return (
          unlocked: UnlockedSocialVault(
            vault: cached.vault,
            dataKey: dataKey,
            payload: payload,
            openedWithSlotId: '',
          ),
          emailHint: cached.emailHint,
          identityId: null,
        );
      } on SocialVaultCryptoException catch (e) {
        AppLogger.warn(_tag, 'local vault copy unusable: ${e.message}');
      }
    }
    var opened = await _openIdentity(provider, silent: true);
    while (true) {
      if (opened == null) {
        throw TransactionAuthCancelledException(
          'Sign-in was cancelled. Transaction aborted.',
        );
      }
      final refusal = recoveryRefusalFor(
        provider: provider,
        vaultId: vaultId,
        identityId: identityId,
        opened: opened,
        expectedEmail: cached?.emailHint,
      );
      if (refusal == null) break;
      // Whatever the reason, nothing is deleted: not this device's copy, and
      // above all not the platform entries, which may be the only thing that
      // opens a vault that still exists for another account.
      if (refusal is! SocialAccountMismatchException) throw refusal;
      final again =
          await prompts?.wrongAccount(
            provider: provider,
            expectedEmail: cached?.emailHint,
            signedInEmail: opened.emailHint,
          ) ??
          false;
      if (!again) throw refusal;
      opened = await _openIdentity(provider, chooseAccount: true);
    }
    var unlocked = await _cancellable(_vaults.unlock(opened.vault!));
    // As in [_afterOpen]: the sweep reads the slot list itself, now.
    try {
      await _vaults.sweepPlatformEntries(
        unlocked.vault.vaultId,
        unlocked.dataKey,
      );
    } catch (_) {}
    // Awaited, so the record persisted afterwards is the one after this
    // write rather than racing it.
    try {
      unlocked = unlocked.withVault(
        await _vaults.ensurePlatformSlot(unlocked.vault, unlocked.dataKey),
      );
    } catch (e) {
      AppLogger.warn(_tag, 'platform slot not added: ${e.runtimeType}');
    }
    return (
      unlocked: unlocked,
      emailHint: opened.emailHint,
      identityId: opened.identityId,
    );
  }

  /// Why the sign-in answer [opened] cannot reopen the vault [vaultId] of a
  /// wallet on this device, or null when it can.
  ///
  /// - Another identity than the one recorded with the link
  ///   ([SocialAccountMismatchException]): the wrong account. Its answer says
  ///   nothing about this wallet's vault.
  /// - No identity recorded (a row older than the record) and the answer is
  ///   not this vault: it cannot be told apart from a wrong account, so it is
  ///   treated as one.
  /// - The wallet's own account, and it has no vault or another one: the
  ///   backup was deleted. A [LegacySocialWalletException] pointing at the
  ///   recovery phrase.
  ///
  /// None of these deletes anything.
  @visibleForTesting
  static LegacySocialWalletException? recoveryRefusalFor({
    required String provider,
    required String vaultId,
    required String? identityId,
    required api.SocialVaultOpenResponse opened,
    String? expectedEmail,
  }) {
    final sameVault = opened.vault?.vaultId == vaultId;
    if (identityId == null) {
      return sameVault
          ? null
          : SocialAccountMismatchException(
              provider: provider,
              expectedEmail: expectedEmail,
            );
    }
    if (opened.identityId != identityId) {
      return SocialAccountMismatchException(
        provider: provider,
        expectedEmail: expectedEmail,
      );
    }
    return sameVault
        ? null
        : LegacySocialWalletException(_backupDeletedMessage);
  }

  // ---------------------------------------------------------------------------
  // The vault's own life: status, deletion
  // ---------------------------------------------------------------------------

  /// Read the status of every vault a wallet here is linked to and this
  /// device holds the data key for, and act on the answers:
  ///
  /// - an unlink that was begun and cut short — the rows were unlinked, and
  ///   the recovery graph or this device's copy of the vault was not — is
  ///   finished first ([_finishUnlinks]);
  /// - a vault the backend has said "not found" for twice, at least a day
  ///   apart, is unlinked from its wallet ([unlinkDeletedVault] with
  ///   [SocialVaultUnlink.notFound]): its platform entries are kept, and the
  ///   user is told once. A single "not found" changes nothing and shows
  ///   nothing — and only the backend's own coded answer, from the backend
  ///   the vault is known to live on, counts as one at all
  ///   (`SocialVaultService.checkStatus`). This is also how a Delete wallet
  ///   backup that was cut short between the backend and this device
  ///   finishes;
  /// - a vault under another vault key drops this device's stale data key,
  ///   and the user is told once ([SocialVaultKeyReplacedPrompt]);
  /// - a vault a wallet was unlinked from that way is asked about again
  ///   ([_reviewRetiredVaults]): if it is there after all the wallet is
  ///   linked back, and only after 30 days of "not found" are its platform
  ///   entries deleted;
  /// - a pending deletion, or a sign-in key this device has not seen, is
  ///   shown ([SocialVaultPrompts.reviewVault]);
  /// - the platform entry of a vault creation that never happened is cleaned
  ///   up.
  ///
  /// Before any of that, and every time (it asks only this device): the
  /// phone backup that carries the platform entries is checked for
  /// end-to-end encryption, and the entries are pulled out of it or put back
  /// (`SocialVaultService.checkPlatformBackup`). When that found keys in a
  /// backup that had lost its encryption, the user is offered — once, when
  /// the encryption is back — to replace them
  /// ([SocialVaultPrompts.offerKeyReplacement]).
  ///
  /// Called when the app is unlocked or comes to the foreground; each vault's
  /// status is read at most once per `SocialVaultService.statusInterval`.
  /// Never awaited by the UI and never throws: being offline is normal.
  /// Concurrent calls share one run.
  Future<void> checkVaults() =>
      _vaultCheck ??= _runVaultCheck().whenComplete(() => _vaultCheck = null);

  Future<void>? _vaultCheck;

  Future<void> _runVaultCheck() async {
    // First, and on its own: it needs no network, and what it guards (a slot
    // secret in a backup Google can read) does not wait for the rest.
    PlatformBackupStatus? backup;
    try {
      backup = await _vaults.checkPlatformBackup();
    } catch (e) {
      AppLogger.info(_tag, 'backup check failed: ${e.runtimeType}');
    }
    try {
      final repository = GetIt.instance<WalletRepository>();
      await _finishUnlinks(repository);
      final linked = <String, String>{};
      final providers = <String, String>{};
      for (final w in await repository.getAllWallets()) {
        final vaultId = w.socialVaultId;
        final accountId = w.accountId;
        if (w.walletType != WalletType.social ||
            vaultId == null ||
            accountId == null) {
          continue;
        }
        linked[vaultId] = accountId;
        providers[vaultId] = w.socialProvider == 'apple' ? 'apple' : 'google';
      }
      final toReview = <String>[];
      for (final MapEntry(key: vaultId, value: accountId) in linked.entries) {
        switch (await _vaults.checkStatus(vaultId)) {
          case SocialVaultStatus.gone:
            AppLogger.warn(
              _tag,
              'a linked vault was not found twice; unlinking its wallet',
            );
            await unlinkDeletedVault(
              accountId,
              vaultId,
              SocialVaultUnlink.notFound,
            );
          case SocialVaultStatus.unconfirmedGone:
            // One "not found" proves nothing: see
            // `SocialVaultService.checkStatus`.
            break;
          case SocialVaultStatus.current:
            toReview.add(vaultId);
          case SocialVaultStatus.skipped:
            // Read recently (or no data key: then nothing is cached either).
            // What the last read found may still be waiting for an answer.
            toReview.add(vaultId);
          case SocialVaultStatus.staleKey:
            // Said below, with any that an earlier check found and could
            // not show.
            break;
          case SocialVaultStatus.failed:
            break;
        }
      }
      await _vaults.sweepAbandonedCreates(
        referencedVaultIds: linked.keys.toSet(),
      );
      await _reviewRetiredVaults(repository);
      for (final vaultId in toReview) {
        await _reviewVault(vaultId);
      }
      for (final MapEntry(key: vaultId, value: provider) in providers.entries) {
        if (await _vaults.staleKeyNoticeDue(vaultId)) {
          await _announceKeyReplaced(vaultId, provider);
        }
      }
      if (backup != null && backup.replacementOfferDue(linked.keys)) {
        await _offerKeyReplacement();
      }
    } catch (e) {
      AppLogger.info(_tag, 'vault check failed: ${e.runtimeType}');
    }
  }

  /// Offer, once, to replace sign-in keys a phone backup held while it was
  /// not end-to-end encrypted. Dismissing it is an answer: the advice is
  /// dropped. An offer that could not be shown is made at the next check.
  Future<void> _offerKeyReplacement() {
    final prompts = this.prompts;
    if (prompts == null) return Future<void>.value();
    return _reviews = _reviews.then((_) async {
      try {
        final replace = await prompts.offerKeyReplacement();
        if (replace == null) return;
        await _vaults.markKeyReplacementOffered();
        if (!replace) await _vaults.dismissBackupExposure();
      } catch (e) {
        AppLogger.warn(_tag, 'key replacement not offered: ${e.runtimeType}');
      }
    });
  }

  /// Say, once, that this device's sign-in key for [vaultId] was replaced
  /// elsewhere. A notice that could not be shown — no shell yet, or one
  /// that does not show this notice — stays due and is tried at the next
  /// check. One notice at a time, like [_reviewVault].
  Future<void> _announceKeyReplaced(String vaultId, String provider) {
    final Object? prompts = this.prompts;
    if (prompts is! SocialVaultKeyReplacedPrompt) return Future<void>.value();
    return _reviews = _reviews.then((_) async {
      try {
        if (await prompts.signInKeyReplaced(provider: provider)) {
          await _vaults.markStaleKeyAnnounced(vaultId);
        }
      } catch (e) {
        AppLogger.warn(_tag, 'replaced-key notice not shown: ${e.runtimeType}');
      }
    });
  }

  /// One review at a time: a sign-in and a status check can both want to
  /// show the same vault's warning, and the second finds it answered.
  Future<void> _reviewVault(String vaultId) {
    final prompts = this.prompts;
    if (prompts == null) return Future<void>.value();
    return _reviews = _reviews.then((_) async {
      try {
        await prompts.reviewVault(vaultId);
      } catch (e) {
        AppLogger.warn(_tag, 'vault notices not shown: ${e.runtimeType}');
      }
    });
  }

  Future<void> _reviews = Future<void>.value();

  /// Go through the vaults wallets here were unlinked from on a "not found"
  /// answer (`SocialVaultService.retire`):
  ///
  /// - the user is told, once, that the wallet's backup is no longer stored
  ///   ([SocialVaultPrompts.backupNoLongerStored]);
  /// - the backend is asked about the vault again, at most once a day, with
  ///   the data key set aside for it. If the vault is there after all, the
  ///   wallet is linked back to it ([_relink]) — nothing of it was ever
  ///   deleted. Its platform entries are deleted only by
  ///   `SocialVaultService.checkRetired`, after 30 days of "not found" and on
  ///   a fresh one;
  /// - a vault whose wallet has left this device, or is linked again (a
  ///   sign-in does that), is no longer kept track of. Its entries stay.
  Future<void> _reviewRetiredVaults(WalletRepository repository) async {
    for (final retired in await _vaults.retiredVaults()) {
      try {
        final rows = (await repository.getWalletsForAccount(
          retired.accountId,
        )).where((w) => w.walletType == WalletType.social).toList();
        if (rows.isEmpty || rows.any((w) => w.socialVaultId != null)) {
          await _vaults.forgetRetired(retired.vaultId);
          continue;
        }
        if (!retired.announced) await _announceBackupGone(retired);
        final unlocked = (await _vaults.checkRetired(retired.vaultId)).unlocked;
        if (unlocked != null) {
          await _relink(repository, retired, rows, unlocked);
        }
      } catch (e) {
        AppLogger.info(_tag, 'retired vault not reviewed: ${e.runtimeType}');
      }
    }
  }

  /// One notice at a time, like [_reviewVault]. A notice that could not be
  /// shown is shown at the next check.
  Future<void> _announceBackupGone(RetiredSocialVault retired) {
    final prompts = this.prompts;
    if (prompts == null) return Future<void>.value();
    return _reviews = _reviews.then((_) async {
      try {
        if (await prompts.backupNoLongerStored(provider: retired.provider)) {
          await _vaults.markRetiredAnnounced(retired.vaultId);
        }
      } catch (e) {
        AppLogger.warn(_tag, 'backup notice not shown: ${e.runtimeType}');
      }
    });
  }

  /// The vault a wallet was unlinked from is there after all, and the data
  /// key this device set aside opened it. Link the wallet's rows back to it —
  /// provided the phrase inside is this wallet: every chain address the
  /// account holds must come out the same, or nothing is touched.
  Future<void> _relink(
    WalletRepository repository,
    RetiredSocialVault retired,
    List<WalletInfo> rows,
    UnlockedSocialVault unlocked,
  ) async {
    final target = recoveryTargetFor(rows);
    final keys = await SocialWalletKeys.fromPayload(unlocked.payload);
    if (!keys.matches(
      solana: target.solanaAddress,
      ethereum: target.ethereumAddress,
      tezos: target.tezosAddress,
    )) {
      AppLogger.warn(_tag, 'a retired vault holds another wallet; not linked');
      await _vaults.forgetRetired(retired.vaultId);
      return;
    }
    await _storeSocialAccount(
      repository,
      target.provider,
      keys,
      retired.vaultId,
      retired.identityId,
    );
    // Also drops the vault from the retired ones.
    await _vaults.persist(
      unlocked,
      provider: target.provider,
      emailHint: retired.emailHint,
    );
    AppLogger.info(_tag, 'a vault reported missing is back; wallet relinked');
  }

  /// Delete the wallet backup of the social account [accountId]: its social
  /// vault on the backend, with a delete this device signs. The wallet stays
  /// on this device, as a Google or Apple wallet with no vault whose recovery
  /// phrase — kept under the account from here on — is its only backup.
  ///
  /// Throws, having deleted nothing:
  /// [SocialVaultPhraseUnavailableException] when this device does not hold
  /// the recovery phrase (deleting the backup would then leave none at all),
  /// [SocialVaultStaleKeyException] when it holds no data key that signs for
  /// the vault, and whatever the signed delete throws (a
  /// `SocialVaultApiError.staleTimestamp` for a wrong clock included).
  ///
  /// When the backend accepts the delete, the vault's platform entries are
  /// deleted with it. When it answers that there is no such vault, the
  /// wallet is unlinked all the same — that is what the user asked for — but
  /// as after any "not found": the entries are kept, to be deleted only once
  /// the vault has stayed gone ([SocialVaultUnlink.notFound], with no notice,
  /// since the user just did this).
  ///
  /// "No such vault" here is the backend's own coded answer, from the
  /// backend the vault is known to live on. Any other 404 — a proxy's, a
  /// backend without these routes — is a failed request like any other: it
  /// is thrown, and nothing is unlinked or deleted. The same goes for a
  /// vault this build's backend has never shown to exist
  /// (`SocialVaultService.deleteVault`).
  ///
  /// Ordered so that a crash cannot leave the wallet looking backed up: the
  /// backend delete comes first, and until [unlinkDeletedVault] has unlinked
  /// the rows this device keeps the data key — so a later [checkVaults]
  /// finds the vault gone and unlinks. Every step can be repeated: called
  /// again after it failed partway through the unlink (the rows unlinked,
  /// the recovery graph or this device's copy of the vault not), it
  /// finishes that unlink, and throws again if it still cannot.
  Future<void> deleteWalletBackup(String accountId) async {
    final repository = GetIt.instance<WalletRepository>();
    final vaultId = (await repository.getWalletsForAccount(accountId))
        .where((w) => w.walletType == WalletType.social)
        .map((w) => w.socialVaultId)
        .firstWhere((id) => id != null, orElse: () => null);
    // Already unlinked. Done — once whatever an earlier run left unfinished
    // is finished.
    if (vaultId == null) {
      await _finishUnlinks(
        repository,
        accountId: accountId,
        rethrowFailure: true,
      );
      return;
    }
    if (!await _vaults.hasMnemonic(vaultId)) {
      throw const SocialVaultPhraseUnavailableException();
    }
    switch (await _vaults.deleteVaultWithLocalKey(vaultId)) {
      case SocialVaultDeletion.noKey:
        throw SocialVaultStaleKeyException(vaultId);
      case SocialVaultDeletion.deleted:
        await unlinkDeletedVault(
          accountId,
          vaultId,
          SocialVaultUnlink.signedDelete,
        );
      case SocialVaultDeletion.notFound:
        await unlinkDeletedVault(
          accountId,
          vaultId,
          SocialVaultUnlink.notFound,
          announce: false,
        );
    }
  }

  /// Unlink the wallet of [accountId] from the vault [vaultId], which the
  /// backend no longer has. [why] says how this device knows, and decides
  /// what happens to the vault's platform entries — slot secrets whose
  /// deletion reaches every device the platform syncs them to:
  ///
  /// - [SocialVaultUnlink.signedDelete]: the backend accepted a delete this
  ///   device signed. The entries are deleted at once (by the delete itself,
  ///   and again here, so a repeat finishes the job).
  /// - [SocialVaultUnlink.notFound]: the backend answered "not found". That
  ///   cannot be authenticated, so the entries are kept and the data key is
  ///   set aside (`SocialVaultService.retire`), and the user is told once
  ///   unless [announce] is false.
  ///
  /// Either way:
  ///
  /// 1. the recovery phrase is kept under the account, so Show secrets still
  ///    exports it;
  /// 2. the rows are unlinked (and the recovery graph with them) — from here
  ///    the wallet shows as one whose backup was deleted, never as an
  ///    older-sign-in wallet, and offers no vault actions;
  /// 3. this device's copy of the vault (data key, phrase, record) is
  ///    dropped.
  ///
  /// The data key goes last, after the unlink, because it is what lets a
  /// later launch notice a half-finished run. Every step can be repeated.
  ///
  /// Step 2 writes two stores, the rows and then the recovery graph, and
  /// the second can fail with the first already done. From then on the rows
  /// name no vault, so nothing would lead back to the data key and the
  /// second copy of the phrase still kept under the vault id, or to the
  /// graph that still names the deleted vault. So the unlink is written
  /// down before step 2 (`SocialVaultService.beginUnlink`) and crossed out
  /// by step 3; [_finishUnlinks] sees an unfinished one through, at the
  /// next [checkVaults] or when the user asks for the delete again.
  Future<void> unlinkDeletedVault(
    String accountId,
    String vaultId,
    SocialVaultUnlink why, {
    bool announce = true,
  }) async {
    final repository = GetIt.instance<WalletRepository>();
    switch (why) {
      case SocialVaultUnlink.signedDelete:
        await _vaults.forgetPlatformEntries(vaultId);
      case SocialVaultUnlink.notFound:
        final rows = (await repository.getWalletsForAccount(
          accountId,
        )).where((w) => w.walletType == WalletType.social).toList();
        await _vaults.retire(
          vaultId,
          accountId: accountId,
          provider: rows
              .map((w) => w.socialProvider)
              .firstWhere((p) => p == 'apple', orElse: () => 'google')!,
          identityId: rows
              .map((w) => w.socialIdentityId)
              .firstWhere((id) => id != null, orElse: () => null),
          announced: !announce,
        );
    }
    // Written down first, and not begun if that fails: an unlink nothing
    // remembers is one a failure below could leave half done for good.
    await _vaults.beginUnlink(vaultId, accountId);
    await _vaults.keepMnemonicForAccount(vaultId, accountId);
    await repository.setSocialVaultId(accountId, null);
    await _vaults.forgetLocal(vaultId);
  }

  /// See through the unlinks that were begun and cut short (all of them, or
  /// only [accountId]'s): write the recovery graph again, then drop this
  /// device's copy of the vault — the two steps that follow the unlinking
  /// of the rows in [unlinkDeletedVault].
  ///
  /// Only when the rows are already unlinked. An unlink that never reached
  /// them is crossed out and nothing else: the wallet is still linked, and
  /// what happens to it is again up to what the backend answers.
  ///
  /// The phrase is copied under the account once more before the vault's
  /// own copy goes, as in the unlink itself. A failure leaves the record in
  /// place for the next try, and is thrown only with [rethrowFailure].
  Future<void> _finishUnlinks(
    WalletRepository repository, {
    String? accountId,
    bool rethrowFailure = false,
  }) async {
    for (final pending in await _vaults.pendingUnlinks()) {
      if (accountId != null && pending.accountId != accountId) continue;
      try {
        final rows = (await repository.getWalletsForAccount(
          pending.accountId,
        )).where((w) => w.walletType == WalletType.social).toList();
        if (rows.any((w) => w.socialVaultId == pending.vaultId)) {
          await _vaults.dropPendingUnlink(pending.vaultId);
          continue;
        }
        // No rows at all: the wallet has left this device since, and only
        // the vault's leftovers remain to be dropped.
        if (rows.isNotEmpty) {
          await _vaults.keepMnemonicForAccount(
            pending.vaultId,
            pending.accountId,
          );
          if (rows.every((w) => w.socialVaultId == null)) {
            await repository.setSocialVaultId(pending.accountId, null);
          }
        }
        await _vaults.forgetLocal(pending.vaultId);
        AppLogger.info(_tag, 'an unlink that was cut short is finished');
      } catch (e) {
        AppLogger.warn(_tag, 'unlink not finished: ${e.runtimeType}');
        if (rethrowFailure) rethrow;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------

  /// Map one vault wallet's keys onto the three chain rows, linked to the
  /// vault and to the sign-in identity it belongs to ([identityId]; null when
  /// the vault was reopened without a sign-in, which keeps what is recorded).
  Future<({List<WalletInfo> wallets, bool existed})> _storeSocialAccount(
    WalletRepository repository,
    String provider,
    SocialWalletKeys keys,
    String vaultId,
    String? identityId,
  ) => repository.addSocialAccount(
    provider: provider,
    name: '${_providerLabel(provider)} Wallet',
    solana: SocialChainCredential(
      address: keys.solanaAddress,
      storedKey: keys.solanaStoredKey,
    ),
    ethereum: SocialChainCredential(
      address: keys.ethereumAddress,
      storedKey: keys.ethereumKeyHex,
    ),
    tezos: SocialChainCredential(
      address: keys.tezosAddress,
      storedKey: keys.tezosSeedHex,
    ),
    socialVaultId: vaultId,
    socialIdentityId: identityId,
  );

  static String _providerLabel(String provider) =>
      provider == 'apple' ? 'Apple' : 'Google';

  static WalletInfo _solanaRowOf(List<WalletInfo> wallets) =>
      wallets.firstWhere(
        (w) => w.chain == Chain.solana.toDbString(),
        orElse: () => throw StateError(
          'Social account was created without a Solana wallet',
        ),
      );

  // ---------------------------------------------------------------------------
  // Cancellation
  // ---------------------------------------------------------------------------

  /// Race [operation] against a signal [cancelPendingRequest] can complete,
  /// publishing on [requestPending] that something cancellable is in flight.
  ///
  /// Wraps every step that waits on the user outside the app (a provider
  /// sheet, a browser tab, a passkey prompt). Unraced, an abandoned one would
  /// strand the caller — the transaction sheet's approval step — forever.
  Future<T> _cancellable<T>(Future<T> operation) async {
    final cancelSignal = Completer<Never>();
    _cancelSignals.add(cancelSignal);
    _requestPending.value = true;
    try {
      return await Future.any<T>([operation, cancelSignal.future]);
    } finally {
      _cancelSignals.remove(cancelSignal);
      if (_cancelSignals.isEmpty) _requestPending.value = false;
    }
  }

  /// Whether an interactive sign-in is in flight and can still be cancelled.
  /// Drives the Cancel affordance on `TransactionPipelineSheet`.
  ValueListenable<bool> get requestPending => _requestPending;
  final ValueNotifier<bool> _requestPending = ValueNotifier<bool>(false);

  /// One per in-flight [_cancellable]; a set because a recovery can overlap
  /// a sign-in or another account's recovery, and one Cancel must unwind all.
  final Set<Completer<Never>> _cancelSignals = <Completer<Never>>{};

  /// Stop waiting on whatever sign-in step is in flight. The provider's UI
  /// may stay up; all this does is stop *us* waiting on it.
  void cancelPendingRequest() {
    for (final signal in _cancelSignals.toList()) {
      if (signal.isCompleted) continue;
      signal.completeError(
        TransactionAuthCancelledException(
          'Sign-in was cancelled. Transaction aborted.',
        ),
      );
    }
  }
}
