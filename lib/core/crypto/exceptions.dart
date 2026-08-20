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

/// Thrown when a Tezos operation is signed with a wallet type that has no
/// local Ed25519 seed: Ledger and view-only wallets.
///
/// The Tezos send flow signs locally, from a seed phrase, an imported `edsk`
/// key, or a social wallet's stored seed (social rows go through the
/// imported-key arm). Only on-device (Ledger) Tezos signing is unwired, so that
/// path fails loud rather than silently producing no signature.
class TezosOperationSigningNotSupportedException implements Exception {
  TezosOperationSigningNotSupportedException([
    this.message =
        'Signing Tezos transactions is only supported for seed-phrase and '
        'imported-key wallets.',
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

/// Thrown when a social wallet predates the Web3Auth migration.
///
/// Such a row's key never left Reown's hosted wallet, so there is nothing to
/// recover on-device: signing in again with the same identity derives a
/// *different* address, which would sign for a wallet the row does not
/// represent. The row is therefore permanently view-only and every sign path
/// must fail loud rather than substitute the new key.
class LegacySocialWalletException implements Exception {
  LegacySocialWalletException([
    this.message =
        'This wallet was created with the old sign-in system and can no longer '
        'sign. Its key cannot be recovered — signing in again creates a '
        'different wallet.',
  ]);

  final String message;

  @override
  String toString() => 'LegacySocialWalletException: $message';
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
