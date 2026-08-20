import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:web3dart/web3dart.dart' show Transaction;

import '../database/database.dart' hide Wallet;
import '../database/database.dart' as db show Wallet;
import '../models/account.dart';
import '../network/ledger_connect_controller.dart';
import '../observability/app_logger.dart';
import '../security/secure_storage.dart';
import '../services/ledger_service.dart';
import '../services/social_auth_service.dart';
import '../services/wallet_repository.dart';
import 'derivation.dart';
import 'exceptions.dart';
import 'mnemonic_generator.dart';

import '../../shared/utils/chain.dart';

const _tag = 'WalletManager';

/// Result of signing the backend login challenge (`<message>\n\ntoken:<token>`)
/// for a wallet.
///
/// [signature]'s encoding is chain-specific: Solana → base58, Ethereum → `0x`
/// hex (EIP-191), Tezos → `edsig…`. [publicKey] and [timestamp] are populated
/// only for Tezos, which the `/authToken/verify` endpoint needs to rebuild and
/// verify the Micheline payload.
class LoginChallengeSignature {
  const LoginChallengeSignature({
    required this.chain,
    required this.signature,
    this.publicKey,
    this.timestamp,
  });

  final Chain chain;
  final String signature;
  final String? publicKey;
  final String? timestamp;
}

/// Inputs for [_signOnIsolate]. Must be a top-level type so [compute] can
/// ferry it across the isolate boundary.
class _IsolateSignTask {
  const _IsolateSignTask({
    required this.messageBytes,
    this.mnemonic,
    this.account = 0,
    this.privateKey,
  });

  final String? mnemonic;
  final int account;
  final List<int>? privateKey;
  final List<int> messageBytes;
}

class _IsolateSignResult {
  const _IsolateSignResult(this.signatureBytes, this.publicKeyBytes);
  final List<int> signatureBytes;
  final List<int> publicKeyBytes;
}

/// Run BIP-44 derivation (PBKDF2 — heavy) and ed25519 signing off the
/// platform main thread. Used by [WalletManager.signCompiledTx] for HD /
/// imported-key / legacy paths so signing doesn't stutter the UI.
Future<_IsolateSignResult> _signOnIsolate(_IsolateSignTask task) async {
  final Ed25519HDKeyPair keypair;
  if (task.mnemonic != null) {
    keypair = await Ed25519HDKeyPair.fromMnemonic(
      task.mnemonic!,
      account: task.account,
      change: 0,
    );
  } else if (task.privateKey != null) {
    keypair = await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: task.privateKey!,
    );
  } else {
    throw StateError('Need either a mnemonic or private key to sign');
  }
  final sig = await keypair.sign(task.messageBytes);
  return _IsolateSignResult(sig.bytes, keypair.publicKey.bytes);
}

/// Manages wallet creation, import, and signing operations.
///
/// Uses WalletRepository for wallet CRUD and seedPhraseId-based key derivation.
@lazySingleton
class WalletManager {
  WalletManager(this._storage, this._db, this._walletRepo, this._ledgerService);

  final SecureWalletStorage _storage;
  final MallowDatabase _db;
  final WalletRepository _walletRepo;
  final LedgerService _ledgerService;

  /// Stream controller for wallet change events.
  final _walletChangedController = StreamController<String>.broadcast();

  /// Stream that emits when the active wallet address changes.
  Stream<String> get onWalletChanged => _walletChangedController.stream;

  /// Create a new wallet with a randomly generated mnemonic.
  ///
  /// Returns the mnemonic for the user to back up.
  Future<String> createWallet({bool use24Words = false}) async {
    final mnemonic = use24Words
        ? MnemonicGenerator.generate24Words()
        : MnemonicGenerator.generate12Words();

    // Legacy path: also store in old key for backward compat
    await _storage.storeMnemonic(mnemonic);
    return mnemonic;
  }

  /// Import an existing wallet from a mnemonic phrase.
  ///
  /// Validates the mnemonic before storing.
  /// Returns the wallet address on success.
  Future<String> importWallet(String mnemonic) async {
    final normalizedMnemonic = mnemonic.trim().toLowerCase();

    if (!MnemonicGenerator.validate(normalizedMnemonic)) {
      throw InvalidMnemonicException();
    }

    if (!MnemonicGenerator.isValidWordCount(normalizedMnemonic)) {
      throw InvalidMnemonicException('Mnemonic must be 12 or 24 words');
    }

    await _storage.storeMnemonic(normalizedMnemonic);
    return getAddress();
  }

  /// Get the active signing/display address for [chain].
  ///
  /// **Solana** (default, the only transactional chain) resolves the active
  /// signing wallet via: selected wallet ID → selected address → mnemonic
  /// derivation — unchanged from the single-wallet model.
  ///
  /// **Ethereum / Tezos** are display-only this pass: they resolve the sibling
  /// wallet for [chain] within the *active account* (the account that owns the
  /// selected Solana wallet). Throws [NoWalletException] if the active account
  /// holds no wallet on that chain.
  Future<String> getAddress({Chain chain = Chain.solana}) async {
    if (chain != Chain.solana) {
      return _getAddressForChain(chain);
    }

    // Try multi-wallet: selected wallet ID → DB lookup
    final walletId = await _storage.loadSelectedWalletId();
    if (walletId != null) {
      final row = await _db.getWalletById(walletId);
      if (row != null) return row.address;
    }

    // Fallback: explicitly selected address
    final selected = await _storage.loadSelectedWallet();
    if (selected != null && selected.isNotEmpty) return selected;

    // Fallback: derive account 0 from legacy mnemonic
    final mnemonic = await _getMnemonic();
    return MultiChainDerivation.getSolanaAddress(mnemonic);
  }

  /// Resolve the active account's wallet address on a non-Solana [chain].
  ///
  /// The active account is the one holding the selected Solana wallet, so ETH
  /// and Tezos addresses track whichever account the user is signed in as.
  Future<String> _getAddressForChain(Chain chain) async {
    final selection = await _walletRepo.getActiveSelection();
    final wallet = selection?.$1.walletForChain(chain);
    if (wallet == null) throw NoWalletException();
    return wallet.address;
  }

  /// The active account's wallet on [chain] (carrying both `id` and `address`),
  /// or null when the active account has none. Lets chain-specific send/transfer
  /// flows resolve the signer wallet id + source address without duplicating the
  /// active-selection lookup.
  Future<WalletInfo?> activeWalletForChain(Chain chain) async {
    final selection = await _walletRepo.getActiveSelection();
    return selection?.$1.walletForChain(chain);
  }

  /// Get the wallet's public key.
  Future<Ed25519HDPublicKey> getPublicKey() async {
    final keypair = await _getKeypair();
    return keypair.publicKey;
  }

  /// Sign arbitrary data with the active wallet's key.
  ///
  /// Routes Ledger wallets through BLE signing.
  /// Throws [ViewOnlyWalletException] if the active wallet is view-only.
  Future<Signature> signMessage(List<int> message) async {
    // Check if active wallet is Ledger
    final walletId = await _storage.loadSelectedWalletId();
    if (walletId != null) {
      final row = await _db.getWalletById(walletId);
      if (row != null &&
          WalletType.fromDbString(row.walletType) == WalletType.ledger) {
        return _signMessageWithLedger(
          message,
          address: row.address,
          account: row.derivationIndex ?? 0,
          scheme: _schemeFromRow(row),
        );
      }
    }
    final keypair = await _getKeypair();
    return keypair.sign(message);
  }

  /// Sign arbitrary data with a specific wallet's key.
  ///
  /// Used in the wallet link flow where we need to sign with a wallet
  /// other than the currently active one.
  /// Routes Ledger wallets through BLE signing.
  /// Throws [ViewOnlyWalletException] if the wallet cannot sign.
  Future<Signature> signMessageForWallet(
    String walletId,
    List<int> message,
  ) async {
    final row = await _db.getWalletById(walletId);
    if (row != null &&
        WalletType.fromDbString(row.walletType) == WalletType.ledger) {
      return _signMessageWithLedger(
        message,
        address: row.address,
        account: row.derivationIndex ?? 0,
        scheme: _schemeFromRow(row),
      );
    }
    final keypair = await _getKeypairForWallet(walletId);
    return keypair.sign(message);
  }

  /// Sign a message using the connected Ledger device, returning [Signature].
  Future<Signature> _signMessageWithLedger(
    List<int> message, {
    required String address,
    required int account,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
  }) async {
    final sigBytes = await _withLedgerConnection(
      address,
      () => _ledgerService.signMessage(
        Uint8List.fromList(message),
        account: account,
        scheme: scheme,
      ),
    );
    return Signature(
      sigBytes.toList(),
      publicKey: Ed25519HDPublicKey.fromBase58(address),
    );
  }

  /// Sign a message with a specific wallet and return the signature as base58.
  ///
  /// Routes Ledger through BLE; HD, imported-key and social wallets through
  /// local keypair signing.
  /// Throws [ViewOnlyWalletException] for view-only wallets.
  Future<String> signMessageBase58ForWallet(
    String walletId,
    List<int> message,
  ) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();

    final walletType = WalletType.fromDbString(row.walletType);

    switch (walletType) {
      case WalletType.hd:
      case WalletType.importedKey:
      case WalletType.social:
        final keypair = await _getKeypairForWallet(walletId);
        final signature = await keypair.sign(message);
        return signature.toBase58();

      case WalletType.ledger:
        final sigBytes = await _withLedgerConnection(
          row.address,
          () => _ledgerService.signMessage(
            Uint8List.fromList(message),
            account: row.derivationIndex ?? 0,
            scheme: _schemeFromRow(row),
          ),
        );
        return base58encode(sigBytes.toList());

      case WalletType.viewOnly:
        throw ViewOnlyWalletException();
    }
  }

  /// Sign a message with the wallet matching [address] and return base58.
  ///
  /// Looks up the wallet by on-chain address rather than ID.
  /// Throws [ViewOnlyWalletException] for view-only/hardware.
  Future<String> signMessageBase58ForAddress(
    String address,
    List<int> message,
  ) async {
    final row = await _db.getWalletByAddress(address);
    if (row == null) throw NoWalletException();
    return signMessageBase58ForWallet(row.id, message);
  }

  /// Sign the backend login challenge for [walletId], producing a chain-specific
  /// [LoginChallengeSignature] for `/authToken/verify`.
  ///
  /// The signed payload is `<message>\n\ntoken:<token>` (e.g. `mallow Login`).
  /// Solana keeps the existing base58 ed25519 path (incl. social/Ledger).
  /// Ethereum and Tezos sign locally with the wallet's own key — the
  /// seed-derived one for HD rows, the stored raw key for imported/social rows
  /// (EIP-191 for ETH, Micheline/Blake2b/Ed25519 for Tezos) — to match how
  /// the reference web client signs and how the backend verifies. Ledger eth/tez is
  /// display-only and has no path here.
  Future<LoginChallengeSignature> signLoginChallenge(
    String walletId, {
    required String message,
    required String token,
  }) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    final chain = Chain.fromDbString(row.chain);
    final messageToSign = '$message\n\ntoken:$token';

    switch (chain) {
      case Chain.solana:
        final signature = await signMessageBase58ForWallet(
          walletId,
          utf8.encode(messageToSign),
        );
        return LoginChallengeSignature(chain: chain, signature: signature);

      case Chain.ethereum:
        final message = utf8.encode(messageToSign);
        final String signature;
        if (_usesStoredRawKey(row)) {
          final priv = await _withSocialKeyRecovery(
            row,
            () => _loadImportedRawKey(row),
          );
          signature =
              await MultiChainDerivation.signEthereumPersonalMessageWithKey(
                priv,
                message,
              );
        } else {
          // HD only — _loadHdMnemonic throws for view-only/Ledger.
          final mnemonic = await _loadHdMnemonic(row);
          signature = await MultiChainDerivation.signEthereumPersonalMessage(
            mnemonic,
            row.derivationIndex ?? 0,
            message,
          );
        }
        return LoginChallengeSignature(chain: chain, signature: signature);

      case Chain.tezos:
        // The wallet stamps the time it signs; the backend rebuilds the same
        // payload from this exact string, so any stable ISO-8601 form works.
        final timestamp = DateTime.now().toUtc().toIso8601String();
        final formatted = MultiChainDerivation.formatTezosSignedMessage(
          messageToSign,
          timestamp,
        );
        final ({String signature, String publicKey}) result;
        if (_usesStoredRawKey(row)) {
          final seed = await _withSocialKeyRecovery(
            row,
            () => _loadImportedRawKey(row),
          );
          result = await MultiChainDerivation.signTezosMichelineWithSeed(
            seed,
            formatted,
          );
        } else {
          // HD only — _loadHdMnemonic throws for view-only/Ledger.
          final mnemonic = await _loadHdMnemonic(row);
          result = await MultiChainDerivation.signTezosMicheline(
            mnemonic,
            row.derivationIndex ?? 0,
            formatted,
          );
        }
        return LoginChallengeSignature(
          chain: chain,
          signature: result.signature,
          publicKey: result.publicKey,
          timestamp: timestamp,
        );
    }
  }

  /// Sign the login challenge for the wallet matching [address].
  ///
  /// Looks up the wallet by on-chain address; see [signLoginChallenge].
  Future<LoginChallengeSignature> signLoginChallengeForAddress(
    String address, {
    required String message,
    required String token,
  }) async {
    final row = await _db.getWalletByAddress(address);
    if (row == null) throw NoWalletException();
    return signLoginChallenge(row.id, message: message, token: token);
  }

  /// Sign a locally-forged Tezos operation ([forgedHex] from
  /// `forgeOperationGroup`) with the Tezos wallet [walletId].
  ///
  /// v1 scope — HD, imported-key and social wallets only. Ledger and view-only
  /// Tezos wallets throw [TezosOperationSigningNotSupportedException]; there is
  /// no local Ed25519 key to sign with and hardware Tezos operation signing is
  /// not wired.
  ///
  /// Returns the `edsig…` signature and `signedOperationHex`
  /// (`forgedHex ++ raw-signature-hex`) for `/injection/operation`.
  Future<({String signature, String signedOperationHex})> signTezosOperation(
    String walletId,
    String forgedHex,
  ) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    if (Chain.fromDbString(row.chain) != Chain.tezos) {
      throw StateError('Wallet $walletId is not a Tezos wallet');
    }

    switch (WalletType.fromDbString(row.walletType)) {
      case WalletType.hd:
        final mnemonic = await _loadHdMnemonic(row);
        return MultiChainDerivation.signTezosOperation(
          mnemonic,
          row.derivationIndex ?? 0,
          forgedHex,
        );
      case WalletType.importedKey:
      case WalletType.social:
        final seed = await _withSocialKeyRecovery(
          row,
          () => _loadImportedRawKey(row),
        );
        return MultiChainDerivation.signTezosOperationWithSeed(seed, forgedHex);
      case WalletType.ledger:
      case WalletType.viewOnly:
        throw TezosOperationSigningNotSupportedException();
    }
  }

  /// Sign a fully-populated Ethereum [transaction] with the wallet [walletId],
  /// returning the raw signed bytes for `eth_sendRawTransaction`.
  ///
  /// The [transaction] must already carry its nonce, gas limit, and EIP-1559
  /// fees (the send flow fetches those from the node first). HD, imported-key
  /// and social wallets sign locally; Ledger wallets sign on-device (the Ethereum
  /// app hashes and signs the unsigned serialization, and we reassemble the
  /// signed envelope from the returned v/r/s). View-only Ethereum wallets throw
  /// [EthereumTransactionSigningNotSupportedException]; there is no wired path to
  /// sign for them.
  Future<Uint8List> signEthereumTransaction(
    String walletId,
    Transaction transaction, {
    required int chainId,
  }) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    if (Chain.fromDbString(row.chain) != Chain.ethereum) {
      throw StateError('Wallet $walletId is not an Ethereum wallet');
    }

    switch (WalletType.fromDbString(row.walletType)) {
      case WalletType.hd:
        final mnemonic = await _loadHdMnemonic(row);
        return MultiChainDerivation.signEthereumTransaction(
          mnemonic,
          row.derivationIndex ?? 0,
          transaction,
          chainId,
        );
      case WalletType.importedKey:
      case WalletType.social:
        final priv = await _withSocialKeyRecovery(
          row,
          () => _loadImportedRawKey(row),
        );
        return MultiChainDerivation.signEthereumTransactionWithKey(
          priv,
          transaction,
          chainId,
        );
      case WalletType.ledger:
        // The Ethereum app signs the exact bytes it will keccak256-hash: the
        // `0x02`-prefixed unsigned EIP-1559 serialization. It returns only the
        // raw (v, r, s); we reassemble the broadcast-ready signed envelope
        // locally (there is no seed to hand `signTransactionRaw`).
        if (!transaction.isEIP1559) {
          throw EthereumTransactionSigningNotSupportedException(
            'Ledger Ethereum signing supports EIP-1559 (type-2) transactions '
            'only.',
          );
        }
        final unsigned = MultiChainDerivation.unsignedEip1559Payload(
          transaction,
          chainId,
        );
        final sig = await _withLedgerConnection(
          row.address,
          () => _ledgerService.signEthereumTransaction(
            unsigned,
            account: row.derivationIndex ?? 0,
          ),
        );
        return MultiChainDerivation.encodeSignedEip1559Transaction(
          transaction,
          chainId,
          v: sig.v,
          r: sig.r,
          s: sig.s,
        );
      case WalletType.viewOnly:
        throw EthereumTransactionSigningNotSupportedException();
    }
  }

  /// The `edpk…` Ed25519 public key for the Tezos wallet [walletId], for
  /// building a `reveal` content on a never-revealed account.
  ///
  /// Same v1 scope as [signTezosOperation] — HD, imported-key and social only.
  Future<String> getTezosPublicKey(String walletId) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    if (Chain.fromDbString(row.chain) != Chain.tezos) {
      throw StateError('Wallet $walletId is not a Tezos wallet');
    }

    switch (WalletType.fromDbString(row.walletType)) {
      case WalletType.hd:
        final mnemonic = await _loadHdMnemonic(row);
        return MultiChainDerivation.getTezosPublicKeyAtIndex(
          mnemonic,
          row.derivationIndex ?? 0,
        );
      case WalletType.importedKey:
      case WalletType.social:
        final seed = await _withSocialKeyRecovery(
          row,
          () => _loadImportedRawKey(row),
        );
        return MultiChainDerivation.tezosPublicKeyFromSeed(seed);
      case WalletType.ledger:
      case WalletType.viewOnly:
        throw TezosOperationSigningNotSupportedException();
    }
  }

  /// Load the seed mnemonic backing an HD wallet [row].
  ///
  /// Throws [ViewOnlyWalletException] when [row] is not HD — Ethereum/Tezos
  /// signing needs a local seed, which imported/Ledger/view-only wallets on
  /// those chains do not have.
  Future<String> _loadHdMnemonic(db.Wallet row) async {
    if (WalletType.fromDbString(row.walletType) != WalletType.hd) {
      throw ViewOnlyWalletException();
    }
    final seedPhraseId = row.seedPhraseId;
    if (seedPhraseId == null) throw NoWalletException();
    final mnemonic = await _storage.loadMnemonicForSeedPhrase(seedPhraseId);
    if (mnemonic == null) throw NoWalletException();
    return mnemonic;
  }

  /// Load the raw 32-byte private key for an Ethereum (secp256k1) or Tezos
  /// (Ed25519 seed) wallet whose key lives in secure storage — imported and
  /// social rows both store it as hex (see `PrivateKeyParser` and
  /// `WalletRepository.addSocialAccount`). Solana keys take the
  /// base58-keypair path.
  Future<Uint8List> _loadImportedRawKey(db.Wallet row) async {
    final hex = await _storage.loadPrivateKey(row.id);
    if (hex == null) throw NoWalletException();
    return MultiChainDerivation.privateKeyBytesFromHex(hex);
  }

  /// Load + decode the 32-byte Ed25519 secret for a stored **Solana** keypair
  /// (imported or social — both stored as the base58 64-byte keypair).
  /// Ethereum/Tezos keys are stored as raw hex and load through
  /// [_loadImportedRawKey], not here, so reaching this with a non-Solana chain
  /// is an invariant violation — fail loud rather than mis-decode their hex as
  /// a base58 keypair. Loud but *classified*: the selection can legitimately
  /// hold a non-Solana row, so [NonSolanaSigningWalletException] carries this
  /// to the user as a signing failure rather than an unclassified crash.
  Future<List<int>> _loadImportedSolanaSecretKey(db.Wallet row) async {
    if (Chain.fromDbString(row.chain) != Chain.solana) {
      throw NonSolanaSigningWalletException();
    }
    final pkBase58 = await _storage.loadPrivateKey(row.id);
    if (pkBase58 == null) throw NoWalletException();
    return base58decode(pkBase58).sublist(0, 32);
  }

  /// Whether [row]'s key is the raw hex secret in secure storage rather than a
  /// seed phrase: imported Ethereum/Tezos keys and their social equivalents,
  /// which are stored in the same format.
  static bool _usesStoredRawKey(db.Wallet row) {
    final type = WalletType.fromDbString(row.walletType);
    return type == WalletType.importedKey || type == WalletType.social;
  }

  /// Run [load], recovering a social row's missing key once before retrying.
  ///
  /// A social row's stored key can be absent after a keystore wipe or a DB
  /// restore onto a fresh install. The keys are deterministic per identity, so
  /// one interactive re-login re-stores every row of the account and [load]
  /// succeeds on the retry. The re-login can prompt, so this must only ever be
  /// called from the platform thread.
  ///
  /// A social row with no account has nothing to re-login against, and a row
  /// whose identity derives a different address is a pre-migration wallet whose
  /// key never existed on device — both fail loud rather than sign with a key
  /// that is not the row's ([recoverKeysForAccount] raises
  /// [LegacySocialWalletException] for the mismatch). Non-social rows pass
  /// straight through.
  Future<T> _withSocialKeyRecovery<T>(
    db.Wallet row,
    Future<T> Function() load,
  ) async {
    if (WalletType.fromDbString(row.walletType) != WalletType.social) {
      return load();
    }
    try {
      return await load();
    } on NoWalletException {
      final accountId = row.accountId;
      if (accountId == null) throw LegacySocialWalletException();
      await GetIt.instance<SocialAuthService>().recoverKeysForAccount(
        accountId,
      );
      // A second miss means the recovery stored nothing for this row —
      // surface it instead of looping.
      return load();
    }
  }

  /// Sign a Solana transaction.
  ///
  /// For Ledger wallets, compiles the message and sends to the device
  /// for on-device confirmation. For other wallet types, signs locally.
  /// Throws [ViewOnlyWalletException] if the active wallet is view-only.
  Future<SignedTx> signTransaction({
    required Message message,
    required String recentBlockhash,
  }) async {
    // Check if active wallet is a Ledger
    final walletId = await _storage.loadSelectedWalletId();
    AppLogger.debug(_tag, 'signTransaction — walletId=$walletId');
    if (walletId != null) {
      final row = await _db.getWalletById(walletId);
      final type = row == null ? null : WalletType.fromDbString(row.walletType);
      AppLogger.debug(
        _tag,
        'signTransaction — row=${row?.address}, type=$type',
      );
      if (row != null && type == WalletType.ledger) {
        AppLogger.debug(_tag, 'routing to _signTransactionWithLedger');
        return _signTransactionWithLedger(
          message,
          recentBlockhash,
          row.address,
          row.derivationIndex ?? 0,
          _schemeFromRow(row),
        );
      }
    }

    // Standard keypair-based signing
    AppLogger.debug(_tag, 'falling through to local keypair signing');
    final keypair = await _getKeypair();
    return keypair.signMessage(
      message: message,
      recentBlockhash: recentBlockhash,
    );
  }

  /// Sign a transaction that already has a signer or two beyond the user
  /// wallet — used by the NFT mint flow, which generates an ephemeral
  /// mint keypair client-side that must co-sign alongside the user.
  ///
  /// Routes the user's signature through the wallet's native signer
  /// (local keypair / Ledger BLE). Social wallets are not wired through this
  /// legacy path — they throw [SocialTransactionSigningNotSupportedException]
  /// so the caller can surface a clear error in the UI. The live path,
  /// [signCompiledTx], signs them locally like any other stored key.
  ///
  /// Throws [ViewOnlyWalletException] if the active wallet is view-only.
  Future<SignedTx> signTransactionWithAdditionalSigners({
    required Message message,
    required String recentBlockhash,
    List<Ed25519HDKeyPair> additionalSigners = const [],
  }) async {
    final walletId = await _storage.loadSelectedWalletId();
    if (walletId != null) {
      final row = await _db.getWalletById(walletId);
      if (row != null) {
        final walletType = WalletType.fromDbString(row.walletType);
        switch (walletType) {
          case WalletType.ledger:
            return _signTransactionWithLedger(
              message,
              recentBlockhash,
              row.address,
              row.derivationIndex ?? 0,
              _schemeFromRow(row),
              additionalSigners: additionalSigners,
            );
          case WalletType.social:
            throw SocialTransactionSigningNotSupportedException();
          case WalletType.viewOnly:
            throw ViewOnlyWalletException();
          case WalletType.hd:
          case WalletType.importedKey:
            break; // fall through to local-keypair signing below
        }
      }
    }

    // Local keypair signing (HD / importedKey / legacy storage)
    final keypair = await _getKeypair();
    final userSigned = await keypair.signMessage(
      message: message,
      recentBlockhash: recentBlockhash,
    );
    if (additionalSigners.isEmpty) return userSigned;

    final messageBytes = userSigned.compiledMessage.toByteArray().toList();
    final extraSignatures = <Signature>[];
    for (final signer in additionalSigners) {
      final sig = await signer.sign(messageBytes);
      extraSignatures.add(sig);
    }
    return SignedTx(
      signatures: [...userSigned.signatures, ...extraSignatures],
      compiledMessage: userSigned.compiledMessage,
    );
  }

  /// Sign a pre-built transaction produced by the backend (e.g. the
  /// `/v2/tx/nft/mint` endpoint).
  ///
  /// Unlike [signTransactionWithAdditionalSigners], which takes a
  /// legacy [Message] and recompiles it, this method preserves the
  /// backend's compiled message verbatim — keeping its blockhash,
  /// address-table lookups (v0 txs), and any server-side signatures
  /// intact. The user's signature plus any [additionalSigners] are
  /// slotted into the signatures array by matching their pubkey
  /// against [SignedTx.compiledMessage.accountKeys].
  ///
  /// Required for v0 transactions with address lookup tables, which
  /// cannot be recompiled client-side without also fetching the ALTs.
  Future<SignedTx> signCompiledTx({
    required SignedTx unsignedTx,
    List<Ed25519HDKeyPair> additionalSigners = const [],
  }) async {
    final messageBytes = unsignedTx.compiledMessage.toByteArray().toList();
    final accountKeys = unsignedTx.compiledMessage.accountKeys;
    final requiredSigners = unsignedTx.compiledMessage.requiredSignatureCount;

    // Seed the signatures array with placeholders for every required
    // signer, preserving any signatures the backend already provided.
    final signatures = List<Signature>.generate(
      requiredSigners,
      (i) => i < unsignedTx.signatures.length
          ? unsignedTx.signatures[i]
          : Signature(
              List<int>.filled(64, 0), // ed25519 signature length
              publicKey: accountKeys[i],
            ),
    );

    void place(Signature sig, Ed25519HDPublicKey signerKey) {
      final idx = accountKeys.indexWhere(
        (k) => k.toBase58() == signerKey.toBase58(),
      );
      if (idx < 0 || idx >= requiredSigners) {
        throw StateError(
          'Signer ${signerKey.toBase58()} is not in the tx '
          'signer slots (found at index $idx, requiredSigners=$requiredSigners)',
        );
      }
      signatures[idx] = sig;
    }

    // 1. User signature — routed by wallet type.
    Signature userSignature;
    Ed25519HDPublicKey userPubkey;
    final walletId = await _storage.loadSelectedWalletId();
    final row = walletId == null ? null : await _db.getWalletById(walletId);
    final walletType = row == null
        ? null
        : WalletType.fromDbString(row.walletType);

    switch (walletType) {
      case WalletType.ledger:
        userPubkey = Ed25519HDPublicKey.fromBase58(row!.address);
        final sigBytes = await _withLedgerConnection(
          row.address,
          () => _ledgerService.signTransaction(
            Uint8List.fromList(messageBytes),
            account: row.derivationIndex ?? 0,
            scheme: _schemeFromRow(row),
          ),
        );
        userSignature = Signature(sigBytes.toList(), publicKey: userPubkey);
      case WalletType.viewOnly:
        throw ViewOnlyWalletException();
      case WalletType.hd:
      case WalletType.importedKey:
      case WalletType.social:
      case null:
        final task = await _buildIsolateSignTask(
          row: row,
          walletType: walletType,
          messageBytes: messageBytes,
        );
        final result = await compute(_signOnIsolate, task);
        userPubkey = Ed25519HDPublicKey(result.publicKeyBytes);
        userSignature = Signature(result.signatureBytes, publicKey: userPubkey);
    }
    place(userSignature, userPubkey);

    // 2. Additional keypair signers (mint keypair, etc.).
    for (final signer in additionalSigners) {
      place(await signer.sign(messageBytes), signer.publicKey);
    }

    return SignedTx(
      signatures: signatures,
      compiledMessage: unsignedTx.compiledMessage,
    );
  }

  /// Sign a transaction using a connected Ledger device.
  Future<SignedTx> _signTransactionWithLedger(
    Message message,
    String recentBlockhash,
    String address,
    int account,
    SolanaDerivationScheme scheme, {
    List<Ed25519HDKeyPair> additionalSigners = const [],
  }) async {
    final feePayer = Ed25519HDPublicKey.fromBase58(address);
    final compiledMessage = message.compile(
      recentBlockhash: recentBlockhash,
      feePayer: feePayer,
    );
    final messageBytes = compiledMessage.toByteArray().toList();

    final sigBytes = await _withLedgerConnection(
      address,
      () => _ledgerService.signTransaction(
        Uint8List.fromList(messageBytes),
        account: account,
        scheme: scheme,
      ),
    );

    final signature = Signature(sigBytes.toList(), publicKey: feePayer);

    final extraSignatures = <Signature>[];
    for (final signer in additionalSigners) {
      final sig = await signer.sign(messageBytes);
      extraSignatures.add(sig);
    }

    return SignedTx(
      signatures: [signature, ...extraSignatures],
      compiledMessage: compiledMessage,
    );
  }

  /// Check if a wallet exists in storage.
  Future<bool> hasWallet() async {
    // Multi-wallet: check DB first
    final hasWallets = await _db.hasAnyWallets();
    if (hasWallets) return true;

    // Legacy fallback
    return _storage.hasWallet();
  }

  /// Delete the wallet from storage (full reset).
  ///
  /// Also resets the social-auth SDK so any Google/Apple session it still
  /// holds is logged out; the next sign-in starts from a fresh account
  /// chooser rather than silently reusing the wiped identity.
  Future<void> deleteWallet() async {
    await GetIt.instance<SocialAuthService>().reset();
    await _walletRepo.resetAll();
  }

  /// Remove a single wallet.
  ///
  /// Stored key material (including a social row's) is deleted by the
  /// repository's removal path. Returns the ID of the replacement active
  /// wallet, or null if no wallets remain.
  Future<String?> removeWallet(String walletId) =>
      _walletRepo.removeWallet(walletId);

  /// Get the mnemonic for a specific seed phrase (for backup display).
  Future<String?> getMnemonicForSeedPhrase(String seedPhraseId) =>
      _storage.loadMnemonicForSeedPhrase(seedPhraseId);

  /// Get the stored mnemonic for display/backup.
  Future<String> getMnemonicForBackup() async => _getMnemonic();

  // ---------------------------------------------------------------------------
  // Multi-Wallet Support
  // ---------------------------------------------------------------------------

  /// Switch to a different wallet by its ID.
  ///
  /// Persists the selection and emits on [onWalletChanged].
  Future<void> switchWalletById(String walletId) async {
    final wallet = await _walletRepo.setActiveWallet(walletId);
    await _storage.storeSelectedWallet(wallet.address);
    _walletChangedController.add(wallet.address);
  }

  /// Switch to a different wallet address (legacy compat).
  Future<void> switchWallet(String address) async {
    await _storage.storeSelectedWallet(address);

    // Try to find the wallet in DB and set it as active
    final row = await _db.getWalletByAddress(address);
    if (row != null) {
      await _storage.storeSelectedWalletId(row.id);
    }

    _walletChangedController.add(address);
  }

  /// Clear wallet selection (revert to default derived address).
  Future<void> clearWalletSelection() async {
    await _storage.deleteSelectedWallet();
    await _storage.deleteSelectedWalletId();
    final address = await getAddress();
    _walletChangedController.add(address);
  }

  /// Check if a specific address is currently selected.
  Future<bool> isSelectedWallet(String address) async {
    final current = await getAddress();
    return current == address;
  }

  /// Check if the wallet at [address] is a Ledger wallet.
  Future<bool> isLedgerWallet(String address) async {
    final row = await _db.getWalletByAddress(address);
    if (row == null) return false;
    return WalletType.fromDbString(row.walletType) == WalletType.ledger;
  }

  /// Whether signing for [address] would first have to run the interactive
  /// Web3Auth re-login — i.e. it is a social wallet whose key is not on this
  /// device (wiped keystore, restored database, or a pre-migration row whose
  /// key never existed locally).
  ///
  /// Every social signing entry point loads its key through
  /// [_withSocialKeyRecovery], which answers a missing key by opening an OAuth
  /// browser tab. Callers that sign from a background path — see
  /// `AuthService._verifySignatureIfPossible` — must consult this first and
  /// defer, rather than ambush the user with a login they never asked for. A
  /// social wallet that answers false signs silently, exactly like an
  /// imported-key wallet.
  ///
  /// Side-effect free: the key slot is read for presence only, and the material
  /// never leaves this method.
  Future<bool> needsSocialKeyRecovery(String address) async {
    final row = await _db.getWalletByAddress(address);
    if (row == null) return false;
    if (WalletType.fromDbString(row.walletType) != WalletType.social) {
      return false;
    }
    // Mirrors the loaders' own miss condition — [_loadImportedRawKey] and
    // [_loadImportedSolanaSecretKey] throw [NoWalletException] on a null read,
    // which is precisely what triggers the recovery.
    return await _storage.loadPrivateKey(row.id) == null;
  }

  /// Whether the active wallet signs locally (HD seed phrase or imported
  /// private key, plus the legacy single-mnemonic fallback). Returns false
  /// for Ledger and social wallets where signing requires an external
  /// approval prompt. View-only wallets cannot sign at all — also false.
  ///
  /// Used by transaction-pipeline UIs to decide between
  /// "Approve in your wallet…" (external) and the local approving copy
  /// (local) copy.
  Future<bool> isLocalSigner() async {
    final walletId = await _storage.loadSelectedWalletId();
    if (walletId == null) {
      // Legacy fallback: single mnemonic in storage signs locally.
      return _storage.hasWallet();
    }
    final row = await _db.getWalletById(walletId);
    if (row == null) return false;
    final type = WalletType.fromDbString(row.walletType);
    return type == WalletType.hd || type == WalletType.importedKey;
  }

  /// Fire a wallet-data-changed notification without changing the selection.
  ///
  /// Used after link/unlink to trigger BLoC reloads across the app.
  Future<void> notifyWalletDataChanged() async {
    final address = await getAddress();
    _walletChangedController.add(address);
  }

  /// Dispose resources.
  void dispose() {
    _walletChangedController.close();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  /// Get the keypair for the active wallet.
  Future<Ed25519HDKeyPair> _getKeypair() async {
    final walletId = await _storage.loadSelectedWalletId();
    if (walletId != null) {
      return _getKeypairForWallet(walletId);
    }

    // Legacy fallback: single mnemonic
    final mnemonic = await _getMnemonic();
    return MultiChainDerivation.deriveSolana(mnemonic);
  }

  /// Build the inputs needed to sign [messageBytes] off-main-thread for
  /// the active local-key wallet. Reads mnemonic / private-key bytes from
  /// secure storage on the platform thread (cheap I/O), then hands the
  /// material plus the message to [_signOnIsolate] via [compute].
  ///
  /// Throws [ViewOnlyWalletException] / [NoWalletException] for paths
  /// that should never reach this branch.
  Future<_IsolateSignTask> _buildIsolateSignTask({
    required db.Wallet? row,
    required WalletType? walletType,
    required List<int> messageBytes,
  }) async {
    if (row == null || walletType == null) {
      // Legacy single-mnemonic fallback.
      final mnemonic = await _getMnemonic();
      return _IsolateSignTask(mnemonic: mnemonic, messageBytes: messageBytes);
    }

    switch (walletType) {
      case WalletType.hd:
        final seedPhraseId = row.seedPhraseId;
        if (seedPhraseId == null) throw NoWalletException();
        final mnemonic = await _storage.loadMnemonicForSeedPhrase(seedPhraseId);
        if (mnemonic == null) throw NoWalletException();
        return _IsolateSignTask(
          mnemonic: mnemonic,
          account: row.derivationIndex ?? 0,
          messageBytes: messageBytes,
        );

      case WalletType.importedKey:
      case WalletType.social:
        // Social rows hold their Solana key in the imported-key format. The
        // key is read — and, if missing, recovered through an interactive
        // re-login — here on the platform thread: neither secure storage nor
        // a login round-trip is reachable from inside the isolate.
        return _IsolateSignTask(
          privateKey: await _withSocialKeyRecovery(
            row,
            () => _loadImportedSolanaSecretKey(row),
          ),
          messageBytes: messageBytes,
        );

      case WalletType.viewOnly:
      case WalletType.ledger:
        // Switch in [signCompiledTx] handles these branches before
        // reaching here; surfacing as a state error makes the misuse loud.
        throw StateError(
          'Cannot build isolate sign task for wallet type $walletType',
        );
    }
  }

  /// Get the keypair for a specific wallet by ID.
  Future<Ed25519HDKeyPair> _getKeypairForWallet(String walletId) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();

    final walletType = WalletType.fromDbString(row.walletType);

    switch (walletType) {
      case WalletType.hd:
        final seedPhraseId = row.seedPhraseId;
        if (seedPhraseId == null) throw NoWalletException();
        final mnemonic = await _storage.loadMnemonicForSeedPhrase(seedPhraseId);
        if (mnemonic == null) throw NoWalletException();
        final scheme = _schemeFromRow(row);
        // Legacy/root Solana paths must derive via the stored scheme so the
        // keypair matches the address recorded at import; standard keeps the
        // existing (account/change) derivation.
        if (scheme != SolanaDerivationScheme.standard) {
          return MultiChainDerivation.deriveSolanaWithScheme(
            mnemonic,
            row.derivationIndex ?? 0,
            scheme,
          );
        }
        return MultiChainDerivation.deriveSolanaWithAccount(
          mnemonic,
          account: row.derivationIndex ?? 0,
        );

      case WalletType.importedKey:
      case WalletType.social:
        return Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: await _withSocialKeyRecovery(
            row,
            () => _loadImportedSolanaSecretKey(row),
          ),
        );

      case WalletType.viewOnly:
      case WalletType.ledger:
        throw ViewOnlyWalletException();
    }
  }

  /// Ensure the Ledger device is connected before issuing a sign call.
  ///
  /// If the BLE link is already up this is a no-op. Otherwise routes through
  /// [LedgerConnectController] to show the connect sheet and waits for the
  /// user to reconnect. Throws [LedgerNotConnectedException] if the user
  /// dismisses the sheet or the connect attempt fails.
  Future<void> _ensureLedgerConnected(String address) async {
    AppLogger.debug(
      _tag,
      '_ensureLedgerConnected($address) — '
      'isConnected=${_ledgerService.isConnected}',
    );
    if (_ledgerService.isConnected) return;
    final ok = await GetIt.instance<LedgerConnectController>()
        .requestConnection(address);
    AppLogger.debug(_tag, '_ensureLedgerConnected got ok=$ok');
    if (!ok) throw const LedgerNotConnectedException();
  }

  /// Wrap a Ledger operation so a stale connection (precheck passes but the
  /// BLE link is actually dead) gets recovered via the connect sheet instead
  /// of bubbling up as "Ledger device not connected".
  Future<T> _withLedgerConnection<T>(
    String address,
    Future<T> Function() op,
  ) async {
    await _ensureLedgerConnected(address);
    try {
      return await op();
    } on LedgerNotConnectedException {
      // Stale isConnected — force a fresh connection then retry once.
      final ok = await GetIt.instance<LedgerConnectController>()
          .requestConnection(address);
      if (!ok) throw const LedgerNotConnectedException();
      return op();
    }
  }

  /// Parse derivation scheme from a Drift wallet row.
  SolanaDerivationScheme _schemeFromRow(db.Wallet row) {
    final raw = row.derivationScheme;
    if (raw == null) return SolanaDerivationScheme.standard;
    return SolanaDerivationScheme.values.asNameMap()[raw] ??
        SolanaDerivationScheme.standard;
  }

  /// Internal: Get legacy mnemonic from storage.
  Future<String> _getMnemonic() async {
    final mnemonic = await _storage.loadMnemonic();
    if (mnemonic == null || mnemonic.isEmpty) {
      throw NoWalletException();
    }
    return mnemonic;
  }
}
