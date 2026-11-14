import 'package:collection/collection.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:ledger_solana/ledger_solana.dart';

import '../../shared/utils/chain.dart';

part 'account.freezed.dart';

/// Canonical default account name: `Account NN`, two-digit zero-padded (and
/// natural width past 99). Single source of truth shared by the wallet
/// repository (the persisted name on import) and the import pickers (the live
/// preview), so what the picker previews matches what is saved.
String formatAccountName(int number) =>
    'Account ${number.toString().padLeft(2, '0')}';

/// Longest account name the user can enter — in Edit Account and when naming
/// an account in the import pickers.
const int kMaxAccountNameLength = 32;

/// Maximum wallets a single profile may link — the cap [ProfileGroup.isFull]
/// enforces in the wallet drawer and the Create/Edit Profile wizard enforces
/// client-side (linking is applied one wallet at a time, so an over-cap
/// selection would half-commit before the backend rejected it).
const int kMaxProfileWallets = 5;

/// Shape of an [Account] — how its wallets were sourced.
enum AccountKind {
  /// Derivation-index grouping of HD wallets from a seed phrase (multi-chain).
  seed,

  /// A single imported private-key wallet.
  privateKey,

  /// A single view-only (watch) wallet.
  viewOnly,

  /// A social-auth identity's wallets (Solana + Ethereum + Tezos), grouped
  /// into one account.
  social,

  /// All imported Ledger hardware wallets, grouped into one account.
  hardware,

  /// Seed Vault wallets at one derivation index, grouped into one account.
  ///
  /// Deliberately *not* [hardware], even though a Seed Vault wallet is a
  /// hardware wallet in every other sense. Hardware accounts are resolved by
  /// derivation index alone, so a Ledger and a Seed Vault imported at the same
  /// index would collapse into a single account card holding two unrelated
  /// devices' addresses.
  seedVault,

  /// Keystone wallets at one (master fingerprint, derivation index), grouped
  /// into one account.
  ///
  /// Its own kind for the same reason as [seedVault], and keyed one level
  /// tighter: two Keystone devices both export index 0, so resolving by index
  /// alone would merge two unrelated devices into one account card. The
  /// device's master fingerprint lives on the account row to tell them apart.
  keystone;

  String toDbString() => switch (this) {
    AccountKind.seed => 'seed',
    AccountKind.privateKey => 'privateKey',
    AccountKind.viewOnly => 'viewOnly',
    AccountKind.social => 'social',
    AccountKind.hardware => 'hardware',
    AccountKind.seedVault => 'seedVault',
    AccountKind.keystone => 'keystone',
  };

  static AccountKind fromDbString(String value) => switch (value) {
    'seed' => AccountKind.seed,
    'privateKey' => AccountKind.privateKey,
    'viewOnly' => AccountKind.viewOnly,
    'social' => AccountKind.social,
    'hardware' => AccountKind.hardware,
    'seedVault' => AccountKind.seedVault,
    'keystone' => AccountKind.keystone,
    // 🛑 Fails soft to `seed`, which is a worse downgrade than
    // [WalletType.fromDbString]'s `hd`: an older build shows a Keystone
    // account as a seed account. It still cannot sign — the rows inside load
    // as HD wallets with no seed phrase behind them — so the failure is at
    // signing, not at load.
    _ => AccountKind.seed,
  };
}

/// Type of wallet within an account.
///
/// 🛑 [fromDbString] fails soft: an unrecognized DB string becomes [hd]. So a
/// row written by a newer build and read by an older one loads as an HD wallet
/// with no key behind it, which fails at signing rather than at load. Only
/// reachable by downgrading, or by running a build compiled from a tree that
/// predates the value — but it is silent either way, so a new value here is a
/// one-way door: never rename or remove an existing DB string.
enum WalletType {
  /// HD-derived from a seed phrase
  hd,

  /// Imported via raw private key
  importedKey,

  /// View-only (no signing capability)
  viewOnly,

  /// A Google or Apple sign-in wallet. Its keys are held locally like
  /// [importedKey]. They come from a social vault, except for a wallet made by
  /// the older sign-in (`WalletInfo.isLegacySocialWallet`), whose keys came
  /// from Web3Auth and which this app can no longer re-create
  social,

  /// Connected via Ledger hardware wallet (BLE)
  ledger,

  /// Held in the device's Seed Vault (Solana Mobile, Android). Like [ledger],
  /// the key never leaves the secure environment and every signature needs an
  /// explicit user approval outside our process — but the transport is
  /// same-device IPC rather than BLE, and Seed Vault defines exactly one
  /// purpose, so these rows are always Solana.
  seedVault,

  /// Held on a Keystone air-gapped hardware wallet. Every signature is a QR
  /// round trip: the app shows the request as an animated QR, the device
  /// shows its signature back as a QR, and nothing crosses any other channel.
  /// The row carries the device's master fingerprint, which every sign
  /// request must name. Solana today; the device has no Tezos support at all.
  keystone;

  /// Database string representation.
  String toDbString() => switch (this) {
    WalletType.hd => 'hd',
    WalletType.importedKey => 'imported_key',
    WalletType.viewOnly => 'view_only',
    WalletType.social => 'social',
    WalletType.ledger => 'ledger',
    WalletType.seedVault => 'seed_vault',
    WalletType.keystone => 'keystone',
  };

  /// Parse from database string.
  static WalletType fromDbString(String value) => switch (value) {
    'hd' => WalletType.hd,
    'imported_key' => WalletType.importedKey,
    'view_only' => WalletType.viewOnly,
    'social' => WalletType.social,
    'ledger' => WalletType.ledger,
    'hardware' => WalletType.ledger, // backward compat
    'seed_vault' => WalletType.seedVault,
    'keystone' => WalletType.keystone,
    _ => WalletType.hd,
  };

  /// Whether this is a hardware wallet type (Ledger, Seed Vault, Keystone).
  bool get isHardware => switch (this) {
    WalletType.ledger || WalletType.seedVault || WalletType.keystone => true,
    WalletType.hd ||
    WalletType.importedKey ||
    WalletType.viewOnly ||
    WalletType.social => false,
  };

  /// Whether signing requires an external device.
  bool get needsDeviceForSigning => isHardware;

  /// Whether this app holds the signing key in its own vault: a seed phrase,
  /// an imported private key or a social login key. Removing such a wallet
  /// can delete that key from the device, so removal re-authenticates first.
  bool get storesKeyOnDevice => switch (this) {
    WalletType.hd || WalletType.importedKey || WalletType.social => true,
    WalletType.viewOnly ||
    WalletType.ledger ||
    WalletType.seedVault ||
    WalletType.keystone => false,
  };
}

/// The provenance badge shown beside a wallet/account name. Each value maps to
/// a single icon (see `WalletTypeBadge`). Plain HD/imported wallets carry no
/// badge.
///
/// `googleLegacy` and `appleLegacy` are the provider marks of a wallet from the
/// older sign-in ([WalletInfo.isLegacySocialWallet]): the same icon with the
/// small mark of that sign-in at its bottom right.
enum WalletBadge {
  watchOnly,
  ledger,
  seedVault,
  keystone,
  google,
  apple,
  googleLegacy,
  appleLegacy,
}

/// A single wallet (HD, imported key, view-only, social, or hardware).
@freezed
abstract class WalletInfo with _$WalletInfo {
  const factory WalletInfo({
    required String id,
    required String address,
    required String name,
    required WalletType walletType,
    required String chain,

    /// The account this wallet belongs to (Accounts-model FK).
    String? accountId,

    /// Set for HD wallets — links to the SeedPhrase this wallet was derived from.
    String? seedPhraseId,
    int? derivationIndex,

    /// Solana derivation scheme — set for HD Solana rows and every hardware
    /// row; null where the chain has a single fixed path.
    SolanaDerivationScheme? derivationScheme,

    /// The Keystone device's BIP32 master fingerprint (uint32) — set for
    /// Keystone rows only. Every sign request must carry it, and the device
    /// refuses a request whose fingerprint is not its own.
    int? masterFingerprint,

    /// Social-auth provider ('google' or 'apple') — set only for social
    /// wallets, drives the brand badge beside the name. Null otherwise.
    String? socialProvider,

    /// The social vault this social wallet's keys come from. Null for
    /// non-social wallets, for a wallet from the older sign-in
    /// ([legacySocial]) and for a vault wallet whose backup was deleted.
    String? socialVaultId,

    /// The sign-in identity [socialVaultId]'s vault belongs to, as the
    /// backend names it (an opaque id, not an email). Null without a vault,
    /// and for a vault wallet not opened since the id was first recorded.
    String? socialIdentityId,

    /// The stored mark of a wallet from the older Google or Apple sign-in.
    /// Read it through [isLegacySocialWallet].
    @Default(false) bool legacySocial,

    /// Explicit display order — sourced from DB, not persisted back.
    int? sortIndex,

    /// Ephemeral — not persisted in DB, set at runtime.
    double? balanceUsd,
  }) = _WalletInfo;
  const WalletInfo._();

  /// Whether this wallet can sign transactions.
  ///
  /// Only view-only is excluded. Social wallets hold a per-chain private key
  /// in secure storage (`WalletRepository.addSocialAccount`) and sign locally
  /// through the imported-key paths, so nothing about them is remote.
  ///
  /// One caveat this gate cannot express: a social row whose stored key is
  /// missing. Signing it triggers a one-shot recovery
  /// (`SocialAuthService.recoverKeysForAccount`), which reopens a vault
  /// wallet's social vault and, for a wallet from the older sign-in, throws
  /// `LegacySocialKeyUnavailableException` — this app cannot re-create that
  /// key. That is a sign-time failure, not a capability one.
  bool get canSign => walletType != WalletType.viewOnly;

  /// Whether this is a wallet from the older Google or Apple sign-in — the
  /// one run by Web3Auth, where the Google or Apple account alone reproduces
  /// the keys. THE predicate for that: every surface that marks, explains or
  /// refuses such a wallet reads this and nothing else.
  ///
  /// False for a social vault wallet, including one whose backup was deleted
  /// (it has no [socialVaultId] either, which is why the answer is a stored
  /// mark and not `socialVaultId == null`). The mark is set by the database
  /// migration that introduced it, for the social wallets that were already
  /// on the device, and by nothing afterwards: this app has no older sign-in.
  bool get isLegacySocialWallet =>
      walletType == WalletType.social && legacySocial;

  /// Whether this wallet can locally sign a *send transfer* on its own chain.
  ///
  /// Each arm mirrors what its `WalletManager.sign*` entry point actually
  /// supports, because a wallet that passes this gate but throws at signing
  /// dead-ends the user **after** the biometric prompt:
  ///
  /// - Ethereum — HD / imported-key / social (local secp256k1), Ledger
  ///   (on-device) or Keystone (on-device, over QR).
  /// - Tezos — HD / imported-key / social (local ed25519 seed).
  ///   [WalletManager.signTezosOperation] still throws
  ///   `TezosOperationSigningNotSupportedException` for ledger and view-only,
  ///   and Tezos Ledger wallets *are* creatable, so the broader [canSign] gate
  ///   offered them as sources and failed at the forge/sign step.
  /// - Solana — the executor signs with the active wallet (see
  ///   [bindsGlobalSigner]), which [canSign] already describes.
  ///
  /// Social wallets sign on all three chains because a social login stores a
  /// per-chain private key on-device (`WalletRepository.addSocialAccount`) and
  /// signs through the same local paths as an imported key — nothing is remote.
  bool get canSignSendTransfer => switch (chainEnum) {
    // Exhaustive on purpose: an `==` chain compiles clean when a wallet type
    // is added and silently answers false for it.
    Chain.ethereum => switch (walletType) {
      WalletType.hd ||
      WalletType.importedKey ||
      WalletType.social ||
      WalletType.ledger ||
      WalletType.keystone => true,
      WalletType.viewOnly || WalletType.seedVault => false,
    },
    Chain.tezos => switch (walletType) {
      WalletType.hd || WalletType.importedKey || WalletType.social => true,
      WalletType.ledger ||
      WalletType.viewOnly ||
      WalletType.seedVault ||
      WalletType.keystone => false,
    },
    Chain.solana => canSign,
  };

  /// Whether signing on this wallet's chain reads the **globally selected**
  /// wallet rather than an explicit wallet id.
  ///
  /// Solana only: `WalletManager._getKeypair()` resolves the signer from
  /// `loadSelectedWalletId()`, so a Solana flow must re-point the global
  /// selection (and with it the `/v2/session` identity) before it can sign with a
  /// wallet other than the active one. Tezos and Ethereum sign by explicit id
  /// ([WalletManager.signTezosOperation], [WalletManager.signEthereumTransaction]),
  /// so a flow sourcing from those chains must leave the selection alone —
  /// moving it re-points the backend login identity, which gates every
  /// `owner == req.loginAddress` write (hide/download, curation edit, profile
  /// edit), for no signing benefit.
  ///
  /// 🛑 Nothing enforces the Solana half of this. `SendBloc` reads the bare
  /// `WalletManager.getAddress()` in `_primeSolBalance`, both Max handlers,
  /// `_onSimulate` and `_applyOptimisticDeltas` — all behind Solana-only
  /// branches. If this ever returned false for Solana they would silently price
  /// and sign against the wrong wallet rather than failing.
  bool get bindsGlobalSigner => chainEnum == Chain.solana;

  /// The wallet's chain as a typed enum (parsed from the [chain] string).
  Chain get chainEnum => Chain.fromDbString(chain);

  /// The provenance badge for this wallet, or null for plain HD/imported keys.
  /// Social wallets without a recorded provider default to the Google mark.
  ///
  /// Ledger, Seed Vault and Keystone each carry their own mark. Both are hardware
  /// wallets, but the badge names *which* device holds the key, and that is
  /// the one thing a user cannot infer from the account name: the two demand
  /// different things to sign — a paired Ledger over BLE, an on-device
  /// Seed Vault prompt, or a QR exchange with a Keystone. Use [WalletType.isHardware] to ask the weaker
  /// "needs an external signer?" question.
  WalletBadge? get badge => switch (walletType) {
    WalletType.viewOnly => WalletBadge.watchOnly,
    WalletType.ledger => WalletBadge.ledger,
    WalletType.seedVault => WalletBadge.seedVault,
    WalletType.keystone => WalletBadge.keystone,
    WalletType.social => switch ((
      socialProvider == 'apple',
      isLegacySocialWallet,
    )) {
      (true, false) => WalletBadge.apple,
      (true, true) => WalletBadge.appleLegacy,
      (false, false) => WalletBadge.google,
      (false, true) => WalletBadge.googleLegacy,
    },
    WalletType.hd || WalletType.importedKey => null,
  };
}

/// A seed phrase (mnemonic source), decoupled from any profile grouping.
@freezed
abstract class SeedPhraseInfo with _$SeedPhraseInfo {
  const factory SeedPhraseInfo({
    required String id,
    required String name,

    /// Explicit display order — sourced from DB, not persisted back.
    int? sortIndex,
  }) = _SeedPhraseInfo;
}

/// A profile group — backend user with linked wallets (or anon group).
@freezed
abstract class ProfileGroup with _$ProfileGroup {
  const factory ProfileGroup({
    required List<WalletInfo> wallets,
    required bool isAnon,
    String? userId,
    String? username,
    String? displayName,
    String? imageUrl,
  }) = _ProfileGroup;
  const ProfileGroup._();

  bool get canAcceptLink => wallets.any((w) => w.canSign);
  bool get isFull => wallets.length >= kMaxProfileWallets;

  /// The address that identifies this profile to the backend (`/v2/session`).
  ///
  /// The exact answer, independent of the global active-wallet selection.
  /// `WalletManager.getAddress()` reads that selection, which
  /// [SessionManager.switchToProfile] moves onto a *held* wallet of this
  /// profile — so for a profile whose linked Solana address was never imported
  /// it lands on a held sibling rather than the address the backend keys the
  /// profile by. Resolve it from this profile's own wallets instead: a held
  /// signable Solana wallet (matching the signer pick), else any of its Solana
  /// addresses (e.g. a view-only placeholder), else its first wallet.
  String? get loginAddress {
    final solanaSigner = wallets.firstWhereOrNull(
      (w) => w.canSign && w.chainEnum == Chain.solana,
    );
    final solana = wallets.firstWhereOrNull((w) => w.chainEnum == Chain.solana);
    return (solanaSigner ?? solana ?? wallets.firstOrNull)?.address;
  }
}

/// An Account — a derivation-index grouping of wallets across chains, backed by
/// the `Accounts` table. See [AccountKind] for the three shapes.
@freezed
abstract class Account with _$Account {
  const factory Account({
    required String id,
    required String name,

    /// Stable seed driving the generated avatar (Accounts only) — a random
    /// UUID, except for `social` accounts, which seed from their Solana
    /// address so the same identity looks the same on every device.
    @Default('') String avatarSeed,
    @Default(AccountKind.seed) AccountKind kind,

    /// Set for `seed` accounts — the seed phrase + derivation index this
    /// account groups.
    String? seedPhraseId,
    int? derivationIndex,
    @Default([]) List<WalletInfo> wallets,

    /// Explicit display order — sourced from DB, not persisted back.
    int? sortIndex,

    /// Ephemeral — fetched from backend for the primary wallet's profile.
    String? profileImageUrl,
    String? profileName,
  }) = _Account;
  const Account._();

  /// The first wallet (primary).
  WalletInfo? get primaryWallet => wallets.isEmpty ? null : wallets.first;

  /// Whether this is a watch-only account — it has wallets and none can sign.
  /// Drives the watch icon shown beside the account name across the app.
  bool get isWatchOnly =>
      wallets.isNotEmpty && wallets.every((w) => !w.canSign);

  /// The provenance badge shown beside this account's name, or null for a plain
  /// HD/imported account. A watch-only account (no signer) always wins; an
  /// account's wallets otherwise share a type, so the primary wallet decides.
  WalletBadge? get typeBadge =>
      isWatchOnly ? WalletBadge.watchOnly : primaryWallet?.badge;

  /// Whether this is an account from the older Google or Apple sign-in: any
  /// of its wallets answers [WalletInfo.isLegacySocialWallet] (they share the
  /// mark, like they share a provider).
  bool get isLegacySocial => wallets.any((w) => w.isLegacySocialWallet);

  /// The provider name of this account's social wallets as shown to the
  /// user: "Apple" or "Google" (the default when none is recorded).
  String get socialProviderName =>
      wallets.any(
        (w) => w.walletType == WalletType.social && w.socialProvider == 'apple',
      )
      ? 'Apple'
      : 'Google';

  /// Whether this group has a seed phrase (at least one HD wallet).
  bool get hasSeedPhrase => wallets.any((w) => w.walletType == WalletType.hd);

  /// Whether this group has a hardware wallet.
  bool get hasHardwareWallet => wallets.any((w) => w.walletType.isHardware);

  /// The Solana wallets in this account (≥2 when legacy paths are imported).
  List<WalletInfo> get solanaWallets =>
      wallets.where((w) => w.chainEnum == Chain.solana).toList();

  /// The single wallet on [chain], or null. For Solana with multiple wallets,
  /// callers should disambiguate via the active-wallet picker (see session spec).
  WalletInfo? walletForChain(Chain chain) {
    final matches = wallets.where((w) => w.chainEnum == chain).toList();
    return matches.isEmpty ? null : matches.first;
  }
}
