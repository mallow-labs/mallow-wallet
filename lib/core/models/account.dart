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
  hardware;

  String toDbString() => switch (this) {
    AccountKind.seed => 'seed',
    AccountKind.privateKey => 'privateKey',
    AccountKind.viewOnly => 'viewOnly',
    AccountKind.social => 'social',
    AccountKind.hardware => 'hardware',
  };

  static AccountKind fromDbString(String value) => switch (value) {
    'seed' => AccountKind.seed,
    'privateKey' => AccountKind.privateKey,
    'viewOnly' => AccountKind.viewOnly,
    'social' => AccountKind.social,
    'hardware' => AccountKind.hardware,
    _ => AccountKind.seed,
  };
}

/// Type of wallet within an account.
enum WalletType {
  /// HD-derived from a seed phrase
  hd,

  /// Imported via raw private key
  importedKey,

  /// View-only (no signing capability)
  viewOnly,

  /// Derived from a social-auth (Web3Auth) login; the key is held locally,
  /// like [importedKey]
  social,

  /// Connected via Ledger hardware wallet (BLE)
  ledger;

  // Future: keystone — QR-based air-gapped signing

  /// Database string representation.
  String toDbString() => switch (this) {
    WalletType.hd => 'hd',
    WalletType.importedKey => 'imported_key',
    WalletType.viewOnly => 'view_only',
    WalletType.social => 'social',
    WalletType.ledger => 'ledger',
  };

  /// Parse from database string.
  static WalletType fromDbString(String value) => switch (value) {
    'hd' => WalletType.hd,
    'imported_key' => WalletType.importedKey,
    'view_only' => WalletType.viewOnly,
    'social' => WalletType.social,
    'ledger' => WalletType.ledger,
    'hardware' => WalletType.ledger, // backward compat
    _ => WalletType.hd,
  };

  /// Whether this is a hardware wallet type (Ledger, Keystone, etc.)
  bool get isHardware => this == WalletType.ledger;

  /// Whether signing requires an external device.
  bool get needsDeviceForSigning => isHardware;
}

/// The provenance badge shown beside a wallet/account name. Each value maps to
/// a single icon (see `WalletTypeBadge`). Plain HD/imported wallets carry no
/// badge.
enum WalletBadge { watchOnly, hardware, google, apple }

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

    /// Ledger derivation scheme (null for non-Ledger wallets).
    SolanaDerivationScheme? derivationScheme,

    /// Social-auth provider ('google' or 'apple') — set only for social
    /// wallets, drives the brand badge beside the name. Null otherwise.
    String? socialProvider,

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
  /// One caveat this gate cannot express: a social row created before the
  /// Web3Auth migration has no stored key. Signing it triggers a one-shot
  /// interactive recovery (`SocialAuthService.recoverKeysForAccount`), which
  /// throws `LegacySocialWalletException` because the re-login derives a
  /// different address. That is a sign-time failure, not a capability one.
  bool get canSign => walletType != WalletType.viewOnly;

  /// Whether this wallet can locally sign a *send transfer* on its own chain.
  ///
  /// Each arm mirrors what its `WalletManager.sign*` entry point actually
  /// supports, because a wallet that passes this gate but throws at signing
  /// dead-ends the user **after** the biometric prompt:
  ///
  /// - Ethereum — HD / imported-key / social (local secp256k1) or Ledger
  ///   (on-device).
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
    Chain.ethereum =>
      walletType == WalletType.hd ||
          walletType == WalletType.importedKey ||
          walletType == WalletType.social ||
          walletType == WalletType.ledger,
    Chain.tezos =>
      walletType == WalletType.hd ||
          walletType == WalletType.importedKey ||
          walletType == WalletType.social,
    Chain.solana => canSign,
  };

  /// Whether signing on this wallet's chain reads the **globally selected**
  /// wallet rather than an explicit wallet id.
  ///
  /// Solana only: `WalletManager._getKeypair()` resolves the signer from
  /// `loadSelectedWalletId()`, so a Solana flow must re-point the global
  /// selection (and with it the `/v0/login` identity) before it can sign with a
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
  WalletBadge? get badge => switch (walletType) {
    WalletType.viewOnly => WalletBadge.watchOnly,
    WalletType.ledger => WalletBadge.hardware,
    WalletType.social =>
      socialProvider == 'apple' ? WalletBadge.apple : WalletBadge.google,
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

  /// The address that identifies this profile to the backend (`/v0/login`).
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
