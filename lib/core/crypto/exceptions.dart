/// Exceptions related to wallet and cryptographic operations.
library;

/// Exception thrown when no wallet has been created or imported.
class NoWalletException implements Exception {
  NoWalletException([
    this.message = 'No wallet found. Please create or import a wallet.',
  ]);

  final String message;

  @override
  String toString() => 'NoWalletException: $message';
}

/// Exception thrown when a mnemonic phrase is invalid.
class InvalidMnemonicException implements Exception {
  InvalidMnemonicException([this.message = 'Invalid mnemonic phrase']);

  final String message;

  @override
  String toString() => 'InvalidMnemonicException: $message';
}

/// Exception thrown when transaction signing fails.
class SigningException implements Exception {
  SigningException([this.message = 'Failed to sign transaction']);

  final String message;

  @override
  String toString() => 'SigningException: $message';
}

/// Exception thrown when key derivation fails.
class DerivationException implements Exception {
  DerivationException([this.message = 'Failed to derive keys']);

  final String message;

  @override
  String toString() => 'DerivationException: $message';
}

/// Exception thrown when trying to sign with a view-only wallet.
class ViewOnlyWalletException implements Exception {
  ViewOnlyWalletException([
    this.message = 'This wallet is view-only and cannot sign transactions.',
  ]);

  final String message;

  @override
  String toString() => 'ViewOnlyWalletException: $message';
}

/// Exception thrown when a private key is invalid or unrecognizable.
class InvalidPrivateKeyException implements Exception {
  InvalidPrivateKeyException([this.message = 'Invalid private key format.']);

  final String message;

  @override
  String toString() => 'InvalidPrivateKeyException: $message';
}

/// Thrown when the user cancels or fails the biometric / device-passcode
/// prompt that gates every local signing path. Treated as a clean abort so
/// the UI can surface "Cancelled" without scaring the user — no signature
/// was produced and no chain state changed.
class TransactionAuthCancelledException implements Exception {
  TransactionAuthCancelledException([
    this.message = 'Authentication was cancelled. Transaction aborted.',
  ]);

  final String message;

  @override
  String toString() => 'TransactionAuthCancelledException: $message';
}

/// Thrown when the Tezos wallet has neither a local key nor a supported
/// hardware signing path (view-only, Seed Vault and Keystone).
class TezosOperationSigningNotSupportedException implements Exception {
  TezosOperationSigningNotSupportedException([
    this.message = 'This wallet type does not support Tezos signing.',
  ]);
  final String message;
  @override
  String toString() => 'TezosOperationSigningNotSupportedException: $message';
}

/// Thrown when an Ethereum transaction sign is requested for a wallet type that
/// has no local secp256k1 key — Ledger and view-only Ethereum wallets. Social
/// wallets hold one and sign through the imported-key arm. On-device (Ledger)
/// Ethereum transaction signing is not wired, so that path fails loud rather
/// than silently producing no signature.
class EthereumTransactionSigningNotSupportedException implements Exception {
  EthereumTransactionSigningNotSupportedException([
    this.message =
        'Signing Ethereum transactions is only supported for seed-phrase and '
        'imported-key wallets.',
  ]);

  final String message;

  @override
  String toString() =>
      'EthereumTransactionSigningNotSupportedException: $message';
}

/// Thrown when a Google or Apple wallet's key is missing from this device and
/// nothing here can produce it again, or when a recovery produced a different
/// wallet than the one the row holds.
///
/// Storing or signing with any other key would produce valid signatures from
/// an address the row does not represent, which fails silently — so every
/// sign path fails loud with this instead. [message] is shown to the user.
class LegacySocialWalletException implements Exception {
  LegacySocialWalletException([
    this.message =
        'This wallet cannot sign on this device: its key is not here and '
        'signing in again would open a different wallet.',
  ]);

  final String message;

  @override
  String toString() => 'LegacySocialWalletException: $message';
}

/// Thrown when a wallet from the older Google or Apple sign-in (the one run
/// by Web3Auth, `WalletInfo.isLegacySocialWallet`) has no stored key on this
/// device.
///
/// This app has no older sign-in, so it cannot fetch that key again — a
/// keystore wipe, or a database restored onto a fresh install, leaves the row
/// unable to sign here. The key itself is not lost: the older sign-in on the
/// mallow website still reproduces it, and [message] says how to bring it
/// back. A subtype of [LegacySocialWalletException], so every surface that
/// already renders that message renders this one.
class LegacySocialKeyUnavailableException extends LegacySocialWalletException {
  LegacySocialKeyUnavailableException({String provider = 'google'})
    : super(recoveryMessage(provider));

  /// How to get such a wallet back, for [provider] (`google` or `apple`).
  /// Names no host: the website is whichever one this deployment serves. The
  /// row is removed first because an import at an address a wallet already
  /// holds is refused as a duplicate.
  static String recoveryMessage(String provider) =>
      'This wallet was made with mallow’s older '
      '${provider == 'apple' ? 'Apple' : 'Google'} sign-in, and its keys are '
      'not on this device. To use it again, sign in on the mallow website '
      'with the older sign-in and export the wallet’s keys there. Then remove '
      'this wallet here and add the keys with Import wallet.';

  @override
  String toString() => 'LegacySocialKeyUnavailableException: $message';
}

/// Thrown when a Google or Apple wallet's vault has to be reopened and the
/// sign-in that answered is not the account the wallet belongs to — or cannot
/// be shown to be (the wallet's row predates the stored identity, and the
/// account that answered has no vault, or another one).
///
/// Nothing is concluded from such an answer and nothing is deleted: "this
/// account has no vault" says the wallet's backup is gone only when the
/// wallet's own account says it. [message] names the account the wallet
/// needs when this device knows it. A subtype of
/// [LegacySocialWalletException], so every surface that already renders that
/// message renders this one.
class SocialAccountMismatchException extends LegacySocialWalletException {
  SocialAccountMismatchException({required this.provider, this.expectedEmail})
    : super(describe(provider: provider, expectedEmail: expectedEmail));

  /// `google` or `apple`.
  final String provider;

  /// The email last seen for the wallet's own account, when known. Display
  /// only: the comparison is by the identity id, never by email.
  final String? expectedEmail;

  static String describe({required String provider, String? expectedEmail}) {
    final name = provider == 'apple' ? 'Apple' : 'Google';
    final account = (expectedEmail != null && expectedEmail.isNotEmpty)
        ? expectedEmail
        : 'the $name account it was created with';
    return 'This wallet belongs to $account. Sign in with that account to '
        'use it. Nothing was changed.';
  }

  @override
  String toString() => 'SocialAccountMismatchException: $message';
}

/// Thrown when a Solana signing path resolves a wallet row that is not a Solana
/// row, so there is no Solana keypair to load — its key is a raw hex secret on
/// another curve (Ethereum secp256k1) or an Ed25519 *seed* (Tezos), not the
/// base58 64-byte keypair the Solana loader decodes.
///
/// Reachable because Solana signing reads the **globally selected** wallet
/// ([WalletInfo.bindsGlobalSigner]) rather than an explicit id: nothing stops
/// the selection landing on an Ethereum/Tezos row (e.g. after the last Solana
/// row is removed). Typed rather than a bare `StateError` so `AppFailure.from`
/// classifies it as a signing failure with actionable copy instead of letting
/// it surface as a crashy unknown error.
class NonSolanaSigningWalletException implements Exception {
  NonSolanaSigningWalletException([
    this.message =
        'This wallet cannot sign Solana transactions. Switch to a Solana '
        'wallet and try again.',
  ]);

  final String message;

  @override
  String toString() => 'NonSolanaSigningWalletException: $message';
}

/// Thrown by the legacy [WalletManager.signTransactionWithAdditionalSigners]
/// path, which social wallets are not wired through.
///
/// The live transaction path — [WalletManager.signCompiledTx], used by every
/// in-app flow (send, mint, swap, market, auction) — signs social wallets
/// locally from their stored key, like any imported key. This exception remains
/// only for the unused legacy entry point; if that path is ever revived, wire
/// it the same way as `signCompiledTx`.
class SocialTransactionSigningNotSupportedException implements Exception {
  SocialTransactionSigningNotSupportedException([
    this.message =
        'Signing this transaction with a social wallet is not yet supported. '
        'Please use an HD, imported, or Ledger wallet, or mint on mallow.art.',
  ]);

  final String message;

  @override
  String toString() =>
      'SocialTransactionSigningNotSupportedException: $message';
}

/// Thrown instead of signing a login challenge that is not a sign-in for this
/// app and this wallet; see `checkSolanaLoginChallenge`.
///
/// A [SigningException], so it surfaces as a signing failure. [reason] names
/// the rule the challenge broke and never carries key material.
class LoginChallengeRejectedException extends SigningException {
  LoginChallengeRejectedException(this.reason)
    : super(
        'The sign-in request from the server was refused because $reason. '
        'Nothing was signed.',
      );

  final String reason;

  @override
  String toString() => 'LoginChallengeRejectedException: $message';
}
