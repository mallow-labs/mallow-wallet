import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:ledger_ethereum/ledger_ethereum.dart'
    show Eip712LedgerField, Eip712LedgerMessage;
import 'package:keystone_ur/keystone_ur.dart' show EthDataType;
import 'package:ledger_solana/ledger_solana.dart';
import 'package:solana/base58.dart';
import 'package:pointycastle/digests/blake2b.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:web3dart/web3dart.dart'
    show Transaction, bytesToHex, hexToBytes, keccak256;

import '../config/environment.dart';
import '../database/database.dart' hide Wallet;
import '../database/database.dart' as db show Wallet;
import '../models/account.dart';
import '../network/ledger_connect_controller.dart';
import '../observability/app_logger.dart';
import '../security/secure_storage.dart';
import '../services/ledger_service.dart';
import '../services/keystone_sign_service.dart';
import '../services/seed_vault_service.dart';
import '../services/social_auth_service.dart';
import '../services/wallet_repository.dart';
import 'derivation.dart';
import 'ed25519_verify.dart';
import 'solana_v1_transaction.dart';
import 'eip712.dart';
import 'exceptions.dart';
import 'login_challenge.dart';

import '../../shared/utils/chain.dart';

const _tag = 'WalletManager';

/// Result of signing a backend login challenge for a wallet.
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
    this.scheme = SolanaDerivationScheme.standard,
    this.privateKey,
  });

  final String? mnemonic;
  final int account;
  final SolanaDerivationScheme scheme;
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
    keypair = await MultiChainDerivation.deriveSolanaWithScheme(
      task.mnemonic!,
      task.account,
      task.scheme,
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

/// Resolves the active wallet and signs with it.
///
/// Uses WalletRepository for wallet CRUD and seedPhraseId-based key derivation.
/// Creating and importing wallets belong to the onboarding/import flows, which
/// go through WalletRepository so every new seed lands in the recovery graph.
@lazySingleton
class WalletManager {
  WalletManager(
    this._storage,
    this._db,
    this._walletRepo,
    this._ledgerService,
    this._seedVaultService,
    this._keystoneSignService,
  );

  final SecureWalletStorage _storage;
  final MallowDatabase _db;
  final WalletRepository _walletRepo;
  final LedgerService _ledgerService;
  final SeedVaultService _seedVaultService;
  final KeystoneSignService _keystoneSignService;

  /// Stream controller for wallet change events.
  final _walletChangedController = StreamController<String>.broadcast();

  /// Stream that emits when the active wallet address changes.
  Stream<String> get onWalletChanged => _walletChangedController.stream;

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
  /// Routes each hardware wallet to its own signer — Ledger over BLE,
  /// Seed Vault over the on-device IPC — and every other type to the local
  /// keypair.
  /// Throws [ViewOnlyWalletException] if the active wallet is view-only.
  ///
  /// The switch is exhaustive deliberately. Written as `if (type == ledger)`
  /// this site compiled clean when a second hardware type was added and fell
  /// through to local keypair signing, which for a key we do not hold can only
  /// fail — and fails reporting "view-only", which is not what went wrong.
  Future<Signature> signMessage(List<int> message) async {
    final walletId = await _storage.loadSelectedWalletId();
    final row = walletId == null ? null : await _db.getWalletById(walletId);
    final type = row == null ? null : WalletType.fromDbString(row.walletType);

    switch (type) {
      case WalletType.ledger:
        return _signMessageWithLedger(
          message,
          address: row!.address,
          account: row.derivationIndex ?? 0,
          scheme: _schemeFromRow(row),
        );

      case WalletType.seedVault:
        return _signMessageWithSeedVault(message, address: row!.address);

      case WalletType.keystone:
        return _signMessageWithKeystone(message, row: row!);

      case WalletType.hd:
      case WalletType.importedKey:
      case WalletType.social:
      case WalletType.viewOnly:
      case null:
        // Local keypair signing, including the legacy single-mnemonic
        // fallback when nothing is selected. View-only throws inside.
        final keypair = await _getKeypair();
        return keypair.sign(message);
    }
  }

  /// Sign arbitrary data with a specific wallet's key.
  ///
  /// Used in the wallet link flow where we need to sign with a wallet
  /// other than the currently active one. Routes hardware wallets to their own
  /// signer (Ledger over BLE, Seed Vault over the on-device IPC).
  /// Throws [ViewOnlyWalletException] if the wallet cannot sign.
  ///
  /// Exhaustive for the same reason as [signMessage].
  Future<Signature> signMessageForWallet(
    String walletId,
    List<int> message, {
    String? expectedAddress,
    void Function()? ensureActive,
    Future<void>? cancelled,
  }) async {
    final row = await _db.getWalletById(walletId);
    if (row == null ||
        (expectedAddress != null && row.address != expectedAddress)) {
      throw NoWalletException();
    }
    ensureActive?.call();
    final type = WalletType.fromDbString(row.walletType);

    switch (type) {
      case WalletType.ledger:
        return _signMessageWithLedger(
          message,
          address: row.address,
          account: row.derivationIndex ?? 0,
          scheme: _schemeFromRow(row),
          ensureActive: ensureActive,
        );

      case WalletType.seedVault:
        ensureActive?.call();
        return _signMessageWithSeedVault(message, address: row.address);

      case WalletType.keystone:
        ensureActive?.call();
        // [cancelled] closes the sheet when the request is abandoned, so an
        // obsolete QR exchange does not hold up the requests behind it.
        final signature = await _signMessageWithKeystone(
          message,
          row: row,
          cancelled: cancelled,
        );
        // The QR exchange can take a minute; the request may have been
        // superseded while the user was scanning.
        ensureActive?.call();
        return signature;

      case WalletType.hd:
      case WalletType.importedKey:
      case WalletType.social:
      case WalletType.viewOnly:
        // The key loader enforces the view-only restriction.
        final keypair = await _getKeypairForWallet(walletId);
        ensureActive?.call();
        if (expectedAddress != null &&
            keypair.publicKey.toBase58() != expectedAddress) {
          throw StateError('Wallet key does not match the approved address');
        }
        return keypair.sign(message);
    }
  }

  /// Sign a message using the connected Ledger device, returning [Signature].
  Future<Signature> _signMessageWithLedger(
    List<int> message, {
    required String address,
    required int account,
    SolanaDerivationScheme scheme = SolanaDerivationScheme.standard,
    void Function()? ensureActive,
  }) async {
    final sigBytes = await _withLedgerConnection(address, () {
      ensureActive?.call();
      return _ledgerService.signMessage(
        Uint8List.fromList(message),
        account: account,
        scheme: scheme,
      );
    });
    return Signature(
      sigBytes.toList(),
      publicKey: Ed25519HDPublicKey.fromBase58(address),
    );
  }

  /// Sign a message with the device's Seed Vault, returning [Signature].
  ///
  /// Only the payload and the wallet's own [address] are passed.
  /// `SeedVaultService` resolves the seed's auth token, the account id and the
  /// derivation path from the vault's own account table and signs under the
  /// path the vault itself reported. There is deliberately no parameter for
  /// handing it a path from here: a reconstructed path that belongs to a
  /// different key produces a *valid* signature from the wrong address, which
  /// fails silently downstream rather than erroring.
  ///
  /// Unlike the Ledger app's off-chain message signing, Seed Vault does not
  /// wrap the payload, so these bytes are what gets signed and an ordinary
  /// ed25519 verification over them succeeds.
  Future<Signature> _signMessageWithSeedVault(
    List<int> message, {
    required String address,
  }) async {
    final sigBytes = await _seedVaultService.signMessage(
      Uint8List.fromList(message),
      address: address,
    );
    return Signature(
      sigBytes.toList(),
      publicKey: Ed25519HDPublicKey.fromBase58(address),
    );
  }

  /// Sign a message with a Keystone, returning [Signature].
  ///
  /// The device signs the bytes verbatim — it shows text it can read as
  /// text, anything else as hex — so an ordinary ed25519 verification over
  /// these bytes succeeds, as for Seed Vault. [KeystoneSignService] has
  /// already checked that before this returns.
  Future<Signature> _signMessageWithKeystone(
    List<int> message, {
    required db.Wallet row,
    Future<void>? cancelled,
  }) async {
    final sigBytes = await _signWithKeystone(
      row,
      message,
      KeystoneSignPurpose.message,
      cancelled: cancelled,
    );
    return Signature(
      sigBytes.toList(),
      publicKey: Ed25519HDPublicKey.fromBase58(row.address),
    );
  }

  /// One Keystone QR round trip for [row] over [payload].
  ///
  /// The request is built from the row's own fingerprint, index and scheme —
  /// the values the device reported at import — and the reply is accepted only
  /// once it verifies against [row]'s address.
  Future<Uint8List> _signWithKeystone(
    db.Wallet row,
    List<int> payload,
    KeystoneSignPurpose purpose, {
    Future<void>? cancelled,
  }) {
    // This is the Solana signer; Ethereum rows sign through
    // [_signEthereumWithKeystone]. A non-Solana row reaching here is an
    // invariant violation upstream; refuse it as the other Solana-only
    // loaders do.
    if (Chain.fromDbString(row.chain) != Chain.solana) {
      throw NonSolanaSigningWalletException();
    }
    return _keystoneSignService.signSolana(
      payload: Uint8List.fromList(payload),
      address: row.address,
      masterFingerprint: row.masterFingerprint ?? 0,
      derivationIndex: row.derivationIndex ?? 0,
      scheme: _schemeFromRow(row),
      purpose: purpose,
      cancelled: cancelled,
    );
  }

  /// Sign a message with a specific wallet and return the signature as base58.
  ///
  /// Routes Ledger through BLE and Seed Vault through the on-device IPC; HD,
  /// imported-key and social wallets through local keypair signing.
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

      case WalletType.seedVault:
        // This is also the login path: [signLoginChallenge] has no per-type
        // branch of its own, so the ownership proof the backend verifies is
        // produced right here. Seed Vault signs the bytes verbatim, so the
        // ordinary `{address, message, signature}` verify body works unchanged
        // — no memo-transaction shape like the Ledger one.
        final vaultSignature = await _signMessageWithSeedVault(
          message,
          address: row.address,
        );
        return vaultSignature.toBase58();

      case WalletType.keystone:
        // Also the login path, exactly as for Seed Vault above: Keystone signs
        // the challenge bytes verbatim and shows them as text, so the ordinary
        // verify body works.
        final keystoneSignature = await _signMessageWithKeystone(
          message,
          row: row,
        );
        return keystoneSignature.toBase58();

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
  /// Without [token], signs [message] verbatim (Sign in with Solana), but only
  /// once [checkSolanaLoginChallenge] accepts it as a fresh first-party sign-in
  /// for this row's address: it is signed with no review, so the server's word
  /// is not enough. A refusal throws [LoginChallengeRejectedException] before
  /// any signer, hardware included, is reached. With a token, signs
  /// `<message>\n\ntoken:<token>` for the legacy chain flows.
  /// Solana keeps the existing base58 ed25519 path (incl. social/Ledger).
  /// Ethereum and Tezos sign locally with the wallet's own key — the
  /// seed-derived one for HD rows, the stored raw key for imported/social rows
  /// (EIP-191 for ETH, Micheline/Blake2b/Ed25519 for Tezos) — to match how
  /// the reference web client signs and how the backend verifies. A Keystone
  /// Ethereum row signs the same EIP-191 message on the device. Ledger eth/tez
  /// has no path here.
  Future<LoginChallengeSignature> signLoginChallenge(
    String walletId, {
    required String message,
    String? token,
  }) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    final chain = Chain.fromDbString(row.chain);
    // Only Solana has a verbatim challenge; the other chains always sign the
    // fixed prefix plus a nonce, so a missing token there is a caller bug that
    // would otherwise sign arbitrary text.
    if (token == null && chain != Chain.solana) {
      throw LoginChallengeRejectedException('it carries no login token');
    }
    final messageToSign = token == null ? message : '$message\n\ntoken:$token';

    switch (chain) {
      case Chain.solana:
        if (token == null) {
          checkSolanaLoginChallenge(messageToSign, address: row.address);
        }
        final signature = await signMessageBase58ForWallet(
          walletId,
          utf8.encode(messageToSign),
        );
        return LoginChallengeSignature(chain: chain, signature: signature);

      case Chain.ethereum:
        final message = utf8.encode(messageToSign);
        final String signature;
        if (WalletType.fromDbString(row.walletType) == WalletType.keystone) {
          // EIP-191 on the device, checked against the row's address before
          // it is returned — the same proof the local keys produce.
          final sig = await _signEthereumWithKeystone(
            row,
            signData: Uint8List.fromList(message),
            dataType: EthDataType.personalMessage,
            digest: MultiChainDerivation.ethereumPersonalMessageDigest(message),
            chainId: Config.ethereumChainId,
          );
          signature = '0x${bytesToHex(sig)}';
        } else if (_usesStoredRawKey(row)) {
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
    String? token,
  }) async {
    final row = await _db.getWalletByAddress(address);
    if (row == null) throw NoWalletException();
    return signLoginChallenge(row.id, message: message, token: token);
  }

  /// Sign a locally-forged Tezos operation ([forgedHex] from
  /// `forgeOperationGroup`) with the Tezos wallet [walletId].
  ///
  /// HD, imported-key and social wallets sign locally. Ledger wallets sign
  /// on-device after their public key is checked against the approved address;
  /// the signature is verified before returning. Unsupported wallet types throw
  /// [TezosOperationSigningNotSupportedException].
  ///
  /// Returns the `edsig…` signature and `signedOperationHex`
  /// (`forgedHex ++ raw-signature-hex`) for `/injection/operation`.
  Future<({String signature, String signedOperationHex})> signTezosOperation(
    String walletId,
    String forgedHex, {
    String? expectedAddress,
    void Function()? ensureActive,
    Future<void>? cancelled,
  }) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    if (Chain.fromDbString(row.chain) != Chain.tezos) {
      throw StateError('Wallet $walletId is not a Tezos wallet');
    }
    if (expectedAddress != null && row.address != expectedAddress) {
      throw StateError('The Tezos wallet no longer matches the review');
    }
    ensureActive?.call();

    switch (WalletType.fromDbString(row.walletType)) {
      case WalletType.hd:
        final mnemonic = await _loadHdMnemonic(row);
        ensureActive?.call();
        return MultiChainDerivation.signTezosOperation(
          mnemonic,
          row.derivationIndex ?? 0,
          forgedHex,
          ensureActive: ensureActive,
        );
      case WalletType.importedKey:
      case WalletType.social:
        final seed = await _withSocialKeyRecovery(
          row,
          () => _loadImportedRawKey(row),
        );
        ensureActive?.call();
        return MultiChainDerivation.signTezosOperationWithSeed(
          seed,
          forgedHex,
          ensureActive: ensureActive,
        );
      case WalletType.ledger:
        return _withLedgerConnection(row.address, () async {
          ensureActive?.call();
          final publicKey = await _tezosLedgerPublicKey(
            row,
            cancelled: cancelled,
            ensureActive: ensureActive,
          );
          ensureActive?.call();
          final forged = hexToBytes(forgedHex);
          final signature = await _ledgerService.signTezosOperation(
            forged,
            account: row.derivationIndex ?? 0,
            cancelled: cancelled,
            ensureActive: ensureActive,
          );
          ensureActive?.call();
          await _verifyTezosLedgerSignature(
            publicKey,
            signature,
            Uint8List.fromList([3, ...forged]),
          );
          ensureActive?.call();
          return (
            signature: MultiChainDerivation.encodeTezosEdsig(signature),
            signedOperationHex:
                forgedHex + bytesToHex(signature, include0x: false),
          );
        }, cancelled: cancelled);
      case WalletType.viewOnly:
      // Seed Vault's whole purpose enum is one value, Solana transaction
      // signing, so it holds no Tezos key and never will. A Seed Vault row is
      // a Solana row anyway; reaching here at all means something upstream is
      // wrong, and refusing is the only safe answer.
      case WalletType.seedVault:
      // Keystone firmware has no Tezos app and no Tezos request type, so no
      // Keystone row is ever a Tezos row.
      case WalletType.keystone:
        throw TezosOperationSigningNotSupportedException();
    }
  }

  /// A browser message must be a packed Micheline string, never an operation
  /// or arbitrary digest that could authorize spending without a review.
  Future<String> signTezosPayloadForWallet(
    String walletId,
    Uint8List payload, {
    required String expectedAddress,
    required void Function() ensureActive,
    Future<void>? cancelled,
  }) async {
    if (payload.length < 6 ||
        payload[0] != 5 ||
        payload[1] != 1 ||
        ByteData.sublistView(payload).getUint32(2) != payload.length - 6) {
      throw const FormatException('Expected a packed Micheline string');
    }
    utf8.decode(payload.sublist(6));
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    if (Chain.fromDbString(row.chain) != Chain.tezos ||
        row.address != expectedAddress) {
      throw StateError('The Tezos wallet no longer matches the review');
    }
    ensureActive();
    switch (WalletType.fromDbString(row.walletType)) {
      case WalletType.hd:
        final mnemonic = await _loadHdMnemonic(row);
        ensureActive();
        return MultiChainDerivation.signTezosPayload(
          mnemonic,
          row.derivationIndex ?? 0,
          payload,
          ensureActive: ensureActive,
        );
      case WalletType.importedKey:
      case WalletType.social:
        final seed = await _withSocialKeyRecovery(
          row,
          () => _loadImportedRawKey(row),
        );
        ensureActive();
        return MultiChainDerivation.signTezosPayloadWithSeed(
          seed,
          payload,
          ensureActive: ensureActive,
        );
      case WalletType.ledger:
        return _withLedgerConnection(row.address, () async {
          ensureActive();
          final publicKey = await _tezosLedgerPublicKey(
            row,
            cancelled: cancelled,
            ensureActive: ensureActive,
          );
          ensureActive();
          final signature = await _ledgerService.signTezosMessage(
            payload,
            account: row.derivationIndex ?? 0,
            cancelled: cancelled,
            ensureActive: ensureActive,
          );
          ensureActive();
          await _verifyTezosLedgerSignature(publicKey, signature, payload);
          ensureActive();
          return MultiChainDerivation.encodeTezosEdsig(signature);
        }, cancelled: cancelled);
      case WalletType.viewOnly:
      case WalletType.seedVault:
      case WalletType.keystone:
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
    void Function()? ensureActive,
    Future<void>? cancelled,
  }) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    if (Chain.fromDbString(row.chain) != Chain.ethereum) {
      throw StateError('Wallet $walletId is not an Ethereum wallet');
    }
    ensureActive?.call();

    switch (WalletType.fromDbString(row.walletType)) {
      case WalletType.hd:
        final mnemonic = await _loadHdMnemonic(row);
        ensureActive?.call();
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
        ensureActive?.call();
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
        final sig = await _withLedgerConnection(row.address, () {
          ensureActive?.call();
          return _ledgerService.signEthereumTransaction(
            unsigned,
            account: row.derivationIndex ?? 0,
          );
        }, cancelled: cancelled);
        return MultiChainDerivation.encodeSignedEip1559Transaction(
          transaction,
          chainId,
          v: sig.v,
          r: sig.r,
          s: sig.s,
        );
      case WalletType.keystone:
        // The device is sent the same `0x02`-prefixed unsigned serialization a
        // Ledger signs, as a typed transaction, and returns r‖s‖v. The sign
        // service accepts the reply only when it recovers to this row's
        // address; the envelope is then reassembled exactly as for Ledger.
        if (!transaction.isEIP1559) {
          throw EthereumTransactionSigningNotSupportedException(
            'Keystone Ethereum signing supports EIP-1559 (type-2) '
            'transactions only.',
          );
        }
        final unsigned = MultiChainDerivation.unsignedEip1559Payload(
          transaction,
          chainId,
        );
        ensureActive?.call();
        final sig = await _signEthereumWithKeystone(
          row,
          signData: unsigned,
          dataType: EthDataType.typedTransaction,
          digest: keccak256(unsigned),
          chainId: chainId,
          cancelled: cancelled,
        );
        return MultiChainDerivation.encodeSignedEip1559Transaction(
          transaction,
          chainId,
          v: sig[64],
          r: sig.sublist(0, 32),
          s: sig.sublist(32, 64),
        );
      case WalletType.viewOnly:
      // Seed Vault signs Solana transactions and nothing else — there is no
      // secp256k1 path in its API — and a Seed Vault row is a Solana row, so
      // this arm exists to refuse rather than to fall through to a key that
      // cannot exist.
      case WalletType.seedVault:
        throw EthereumTransactionSigningNotSupportedException();
    }
  }

  /// EIP-191 `personal_sign` of [message] by the Ethereum wallet [walletId],
  /// for a website request the user reviewed. Returns the 65-byte `r‖s‖v`.
  ///
  /// [expectedAddress] is the address the review named; a row whose address
  /// differs (ignoring EIP-55 case) is refused before any key is loaded. The
  /// caller still verifies the returned signature recovers to that address,
  /// because a Ledger's reply proves nothing by arriving.
  Future<Uint8List> signEthereumPersonalMessageForWallet(
    String walletId,
    Uint8List message, {
    required String expectedAddress,
    void Function()? ensureActive,
    Future<void>? cancelled,
  }) async {
    final row = await _ethereumRowFor(walletId, expectedAddress);
    ensureActive?.call();
    switch (WalletType.fromDbString(row.walletType)) {
      case WalletType.hd:
        final mnemonic = await _loadHdMnemonic(row);
        ensureActive?.call();
        return hexToBytes(
          (await MultiChainDerivation.signEthereumPersonalMessage(
            mnemonic,
            row.derivationIndex ?? 0,
            message,
          )).substring(2),
        );
      case WalletType.importedKey:
      case WalletType.social:
        final priv = await _withSocialKeyRecovery(
          row,
          () => _loadImportedRawKey(row),
        );
        ensureActive?.call();
        return hexToBytes(
          (await MultiChainDerivation.signEthereumPersonalMessageWithKey(
            priv,
            message,
          )).substring(2),
        );
      case WalletType.ledger:
        return _withLedgerConnection(row.address, () {
          ensureActive?.call();
          return _ledgerService.signEthereumPersonalMessage(
            message,
            account: row.derivationIndex ?? 0,
          );
        }, cancelled: cancelled);
      case WalletType.keystone:
        ensureActive?.call();
        return _signEthereumWithKeystone(
          row,
          signData: Uint8List.fromList(message),
          dataType: EthDataType.personalMessage,
          digest: MultiChainDerivation.ethereumPersonalMessageDigest(message),
          chainId: Config.ethereumChainId,
          cancelled: cancelled,
        );
      case WalletType.viewOnly:
      case WalletType.seedVault:
        throw EthereumTransactionSigningNotSupportedException(
          'This wallet cannot sign Ethereum messages.',
        );
    }
  }

  /// Signs EIP-712 [typedData] the user reviewed, with the Ethereum wallet
  /// [walletId]. Returns the 65-byte `r‖s‖v`.
  ///
  /// Local keys sign [Eip712TypedData.digest]. A Ledger is sent the typed
  /// data itself and hashes it on the device, so it can show the user each
  /// domain and message field to confirm; only an Ethereum app too old for
  /// that falls back to signing the domain and message hashes, which it
  /// shows instead. The caller verifies the signature recovers to
  /// [expectedAddress] either way.
  Future<Uint8List> signEthereumTypedDataForWallet(
    String walletId,
    Eip712TypedData typedData, {
    required String expectedAddress,
    void Function()? ensureActive,
    Future<void>? cancelled,
  }) async {
    final row = await _ethereumRowFor(walletId, expectedAddress);
    ensureActive?.call();
    final digest = typedData.digest;
    switch (WalletType.fromDbString(row.walletType)) {
      case WalletType.hd:
        final mnemonic = await _loadHdMnemonic(row);
        ensureActive?.call();
        return MultiChainDerivation.signEthereumTypedDataDigest(
          mnemonic,
          row.derivationIndex ?? 0,
          digest,
        );
      case WalletType.importedKey:
      case WalletType.social:
        final priv = await _withSocialKeyRecovery(
          row,
          () => _loadImportedRawKey(row),
        );
        ensureActive?.call();
        return MultiChainDerivation.signEthereumTypedDataDigestWithKey(
          priv,
          digest,
        );
      case WalletType.ledger:
        final message = Eip712LedgerMessage(
          types: {
            for (final MapEntry(key: name, value: fields)
                in typedData.types.entries)
              name: [
                for (final field in fields)
                  Eip712LedgerField(field.name, field.type),
              ],
          },
          primaryType: typedData.primaryType,
          domain: typedData.canonicalDomain,
          message: typedData.canonicalMessage,
        );
        return _withLedgerConnection(row.address, () {
          ensureActive?.call();
          return _ledgerService.signEthereumTypedData(
            message: message,
            domainSeparator: typedData.domainSeparator,
            messageHash: typedData.structHash,
            account: row.derivationIndex ?? 0,
            cancelled: cancelled,
          );
        }, cancelled: cancelled);
      case WalletType.keystone:
        // The device hashes the JSON itself and shows its fields. The JSON is
        // re-serialized from the parsed payload that produced [digest], and
        // the reply must recover to this row's address over that digest, so a
        // device that hashed anything other than the reviewed payload is
        // refused.
        ensureActive?.call();
        return _signEthereumWithKeystone(
          row,
          signData: Uint8List.fromList(utf8.encode(typedData.json)),
          dataType: EthDataType.typedData,
          digest: digest,
          chainId: typedData.chainId?.toInt() ?? Config.ethereumChainId,
          cancelled: cancelled,
        );
      case WalletType.viewOnly:
      case WalletType.seedVault:
        throw EthereumTransactionSigningNotSupportedException(
          'This wallet cannot sign typed data.',
        );
    }
  }

  /// One Keystone QR round trip for the Ethereum [row]: the request names the
  /// row's own fingerprint and index, and [KeystoneSignService.signEthereum]
  /// accepts the reply only once it recovers to the row's address over
  /// [digest]. Returns `r‖s‖v` with v = 27/28.
  Future<Uint8List> _signEthereumWithKeystone(
    db.Wallet row, {
    required Uint8List signData,
    required EthDataType dataType,
    required Uint8List digest,
    required int chainId,
    Future<void>? cancelled,
  }) {
    if (Chain.fromDbString(row.chain) != Chain.ethereum) {
      throw StateError('Wallet ${row.id} is not an Ethereum wallet');
    }
    return _keystoneSignService.signEthereum(
      signData: signData,
      dataType: dataType,
      digest: digest,
      chainId: chainId,
      address: row.address,
      masterFingerprint: row.masterFingerprint ?? 0,
      derivationIndex: row.derivationIndex ?? 0,
      cancelled: cancelled,
    );
  }

  Future<db.Wallet> _ethereumRowFor(String walletId, String address) async {
    final row = await _db.getWalletById(walletId);
    if (row == null || row.address.toLowerCase() != address.toLowerCase()) {
      throw NoWalletException();
    }
    if (Chain.fromDbString(row.chain) != Chain.ethereum) {
      throw StateError('Wallet $walletId is not an Ethereum wallet');
    }
    return row;
  }

  /// The `edpk…` Ed25519 public key for the Tezos wallet [walletId], for
  /// building a `reveal` content on a never-revealed account.
  ///
  /// Supports local signers and Ledger; the Ledger key must match the wallet row.
  Future<String> getTezosPublicKey(
    String walletId, {
    String? expectedAddress,
    void Function()? ensureActive,
    Future<void>? cancelled,
  }) async {
    final row = await _db.getWalletById(walletId);
    if (row == null) throw NoWalletException();
    if (Chain.fromDbString(row.chain) != Chain.tezos) {
      throw StateError('Wallet $walletId is not a Tezos wallet');
    }

    if (expectedAddress != null && row.address != expectedAddress) {
      throw StateError('The Tezos wallet no longer matches the review');
    }
    ensureActive?.call();
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
        return _withLedgerConnection(row.address, () async {
          final key = await _tezosLedgerPublicKey(
            row,
            cancelled: cancelled,
            ensureActive: ensureActive,
          );
          ensureActive?.call();
          return MultiChainDerivation.encodeTezosEdpk(key);
        }, cancelled: cancelled);
      case WalletType.viewOnly:
      // Solana-only, as in [signTezosOperation]: there is no Tezos key to
      // publish for a Seed Vault or Keystone row.
      case WalletType.seedVault:
      case WalletType.keystone:
        throw TezosOperationSigningNotSupportedException();
    }
  }

  Future<Uint8List> _tezosLedgerPublicKey(
    db.Wallet row, {
    Future<void>? cancelled,
    void Function()? ensureActive,
  }) async {
    ensureActive?.call();
    final key = await _ledgerService.getTezosPublicKey(
      account: row.derivationIndex ?? 0,
      cancelled: cancelled,
      ensureActive: ensureActive,
    );
    ensureActive?.call();
    if (key.length != 32 ||
        MultiChainDerivation.tezosAddressFromPublicKey(key) != row.address) {
      throw StateError(
        'The Ledger key does not match the approved Tezos wallet',
      );
    }
    return key;
  }

  Future<void> _verifyTezosLedgerSignature(
    Uint8List publicKey,
    Uint8List signature,
    Uint8List payload,
  ) async {
    final hash = Blake2bDigest(digestSize: 32).process(payload);
    if (signature.length != 64 ||
        !await isValidEd25519Signature(
          hash,
          signature,
          base58encode(publicKey),
        )) {
      throw StateError(
        'The Ledger signature does not match the approved Tezos wallet',
      );
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
  /// restore onto a fresh install. A vault wallet's keys come back by
  /// reopening its social vault, which re-stores every row of the account, and
  /// [load] succeeds on the retry. Reopening can prompt (a sign-in, a
  /// passkey), so this must only ever be called from the platform thread.
  ///
  /// A social row with no account has nothing to reopen; a wallet from the
  /// older sign-in has no vault, and this app cannot re-create its key
  /// ([LegacySocialKeyUnavailableException], which says how to bring it
  /// back); and a vault that opens to a different wallet is refused. All fail
  /// loud rather than sign with a key that is not the row's. Non-social rows
  /// pass straight through.
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
  /// Hardware wallets compile the message and hand it to the device for an
  /// external confirmation — Ledger over BLE, Seed Vault over the on-device
  /// IPC. Every other type signs locally.
  /// Throws [ViewOnlyWalletException] if the active wallet is view-only.
  ///
  /// Exhaustive for the same reason as [signMessage].
  Future<SignedTx> signTransaction({
    required Message message,
    required String recentBlockhash,
  }) async {
    final walletId = await _storage.loadSelectedWalletId();
    AppLogger.debug(_tag, 'signTransaction — walletId=$walletId');
    final row = walletId == null ? null : await _db.getWalletById(walletId);
    final type = row == null ? null : WalletType.fromDbString(row.walletType);
    AppLogger.debug(_tag, 'signTransaction — row=${row?.address}, type=$type');

    switch (type) {
      case WalletType.ledger:
        AppLogger.debug(_tag, 'routing to _signTransactionWithLedger');
        return _signTransactionWithLedger(
          message,
          recentBlockhash,
          row!.address,
          row.derivationIndex ?? 0,
          _schemeFromRow(row),
        );

      case WalletType.seedVault:
        AppLogger.debug(_tag, 'routing to _signTransactionWithSeedVault');
        return _signTransactionWithSeedVault(
          message,
          recentBlockhash,
          row!.address,
        );

      case WalletType.keystone:
        return _signTransactionWithKeystone(message, recentBlockhash, row!);

      case WalletType.hd:
      case WalletType.importedKey:
      case WalletType.social:
      case WalletType.viewOnly:
      case null:
        AppLogger.debug(_tag, 'routing to local keypair signing');
        final keypair = await _getKeypair();
        return keypair.signMessage(
          message: message,
          recentBlockhash: recentBlockhash,
        );
    }
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
          case WalletType.seedVault:
            return _signTransactionWithSeedVault(
              message,
              recentBlockhash,
              row.address,
              additionalSigners: additionalSigners,
            );
          case WalletType.keystone:
            return _signTransactionWithKeystone(
              message,
              recentBlockhash,
              row,
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
    String? walletId,
    String? expectedAddress,
    void Function()? ensureActive,
    Future<void>? cancelled,
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
    final explicitlyPinned = walletId != null;
    walletId ??= await _storage.loadSelectedWalletId();
    final row = walletId == null ? null : await _db.getWalletById(walletId);
    if (explicitlyPinned && row == null) throw NoWalletException();
    if (expectedAddress != null &&
        (row == null || row.address != expectedAddress)) {
      throw NoWalletException();
    }
    ensureActive?.call();
    final walletType = row == null
        ? null
        : WalletType.fromDbString(row.walletType);

    switch (walletType) {
      case WalletType.ledger:
        userPubkey = Ed25519HDPublicKey.fromBase58(row!.address);
        final sigBytes = await _withLedgerConnection(row.address, () {
          ensureActive?.call();
          return _ledgerService.signTransaction(
            Uint8List.fromList(messageBytes),
            account: row.derivationIndex ?? 0,
            scheme: _schemeFromRow(row),
            cancelled: cancelled,
          );
        }, cancelled: cancelled);
        userSignature = Signature(sigBytes.toList(), publicKey: userPubkey);
      case WalletType.seedVault:
        userPubkey = Ed25519HDPublicKey.fromBase58(row!.address);
        // Seed Vault returns a detached 64-byte ed25519 signature over the
        // payload verbatim — the same contract the Ledger arm satisfies — so
        // the backend's compiled message, its blockhash and any address-table
        // lookups survive untouched and the signature slots straight in.
        ensureActive?.call();
        final vaultSigBytes = await _seedVaultService.signTransaction(
          Uint8List.fromList(messageBytes),
          address: row.address,
        );
        userSignature = Signature(
          vaultSigBytes.toList(),
          publicKey: userPubkey,
        );
      case WalletType.keystone:
        userPubkey = Ed25519HDPublicKey.fromBase58(row!.address);
        // Same detached-signature contract as the two arms above: the device
        // signs the compiled message bytes verbatim, so lookup tables, the
        // backend's blockhash and its co-signatures all survive. The service
        // has verified the reply against this address before it returns.
        ensureActive?.call();
        final keystoneSigBytes = await _signWithKeystone(
          row,
          messageBytes,
          KeystoneSignPurpose.transaction,
          cancelled: cancelled,
        );
        userSignature = Signature(
          keystoneSigBytes.toList(),
          publicKey: userPubkey,
        );
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
        ensureActive?.call();
        final result = await compute(_signOnIsolate, task);
        userPubkey = Ed25519HDPublicKey(result.publicKeyBytes);
        userSignature = Signature(result.signatureBytes, publicKey: userPubkey);
    }
    ensureActive?.call();
    if (expectedAddress != null && userPubkey.toBase58() != expectedAddress) {
      throw StateError('Wallet key does not match the approved address');
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

  /// Sign a v1 transaction with the active wallet, then each of
  /// [additionalSigners].
  ///
  /// Only a key the app holds can sign v1: see [activeSignerCanSignV1]. Ask
  /// that first and request v1 from a builder only when it is true; this
  /// throws [UnsupportedError] for any other signer rather than hand it bytes
  /// it would mis-parse.
  Future<SolanaV1Transaction> signV1Tx({
    required SolanaV1Transaction unsignedTx,
    List<Ed25519HDKeyPair> additionalSigners = const [],
  }) async {
    final walletId = await _storage.loadSelectedWalletId();
    final row = walletId == null ? null : await _db.getWalletById(walletId);
    final walletType = row == null
        ? null
        : WalletType.fromDbString(row.walletType);
    if (walletType == WalletType.viewOnly) throw ViewOnlyWalletException();
    if (!_signsV1(walletType)) {
      throw UnsupportedError('This wallet cannot sign a v1 transaction');
    }
    final messageBytes = unsignedTx.messageBytes;
    final task = await _buildIsolateSignTask(
      row: row,
      walletType: walletType,
      messageBytes: messageBytes.toList(),
    );
    final result = await compute(_signOnIsolate, task);
    var signed = unsignedTx.withSignature(
      Ed25519HDPublicKey(result.publicKeyBytes).toBase58(),
      result.signatureBytes,
    );
    for (final signer in additionalSigners) {
      final signature = await signer.sign(messageBytes);
      signed = signed.withSignature(
        signer.publicKey.toBase58(),
        signature.bytes,
      );
    }
    return signed;
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

  /// Sign a transaction with the device's Seed Vault.
  ///
  /// Compiles the message exactly as the Ledger path does: Seed Vault signs
  /// the payload verbatim and returns a detached 64-byte ed25519 signature, so
  /// the compiled message goes straight through.
  ///
  /// Only the payload and [address] reach the service — see
  /// [_signMessageWithSeedVault] for why no derivation path is passed from
  /// here.
  Future<SignedTx> _signTransactionWithSeedVault(
    Message message,
    String recentBlockhash,
    String address, {
    List<Ed25519HDKeyPair> additionalSigners = const [],
  }) async {
    final feePayer = Ed25519HDPublicKey.fromBase58(address);
    final compiledMessage = message.compile(
      recentBlockhash: recentBlockhash,
      feePayer: feePayer,
    );
    final messageBytes = compiledMessage.toByteArray().toList();

    final sigBytes = await _seedVaultService.signTransaction(
      Uint8List.fromList(messageBytes),
      address: address,
    );

    final signature = Signature(sigBytes.toList(), publicKey: feePayer);

    final extraSignatures = <Signature>[];
    for (final signer in additionalSigners) {
      extraSignatures.add(await signer.sign(messageBytes));
    }

    return SignedTx(
      signatures: [signature, ...extraSignatures],
      compiledMessage: compiledMessage,
    );
  }

  /// Sign a transaction with a Keystone. Compiles exactly as the Ledger and
  /// Seed Vault paths do; the device returns a detached signature over the
  /// compiled message.
  Future<SignedTx> _signTransactionWithKeystone(
    Message message,
    String recentBlockhash,
    db.Wallet row, {
    List<Ed25519HDKeyPair> additionalSigners = const [],
  }) async {
    final feePayer = Ed25519HDPublicKey.fromBase58(row.address);
    final compiledMessage = message.compile(
      recentBlockhash: recentBlockhash,
      feePayer: feePayer,
    );
    final messageBytes = compiledMessage.toByteArray().toList();

    final sigBytes = await _signWithKeystone(
      row,
      messageBytes,
      KeystoneSignPurpose.transaction,
    );

    final signature = Signature(sigBytes.toList(), publicKey: feePayer);

    final extraSignatures = <Signature>[];
    for (final signer in additionalSigners) {
      extraSignatures.add(await signer.sign(messageBytes));
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

  /// Delete every wallet from storage (the storage half of a factory reset).
  /// Best-effort, like the [WalletRepository.resetAll] it runs.
  Future<List<EraseFailure>> deleteWallet() => _walletRepo.resetAll();

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

  /// Whether the wallet at [address] signs on external hardware — a Ledger, or
  /// the device's Seed Vault.
  ///
  /// Hardware-generic rather than Ledger-specific because every caller is
  /// asking the same question: does producing a signature here need an
  /// interactive approval outside this process? Callers that must branch on
  /// *which* device do so on the concrete [WalletType]; nobody should be
  /// answering that question with a second predicate.
  Future<bool> isHardwareWallet(String address) async {
    final row = await _db.getWalletByAddress(address);
    if (row == null) return false;
    return WalletType.fromDbString(row.walletType).isHardware;
  }

  /// The wallet type behind [address], or null when no wallet row holds it.
  Future<WalletType?> walletTypeOf(String address) async {
    final row = await _db.getWalletByAddress(address);
    return row == null ? null : WalletType.fromDbString(row.walletType);
  }

  /// Whether signing for [address] would first have to recover its key —
  /// i.e. it is a social wallet whose key is not on this device (a wiped
  /// keystore, or a restored database).
  ///
  /// Every social signing entry point loads its key through
  /// [_withSocialKeyRecovery], which answers a missing key by reopening the
  /// wallet's social vault (possibly with a sign-in sheet or a passkey
  /// prompt), or by failing for a wallet that has none. Callers that sign
  /// from a background path — see
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

  /// Whether the selected wallet row signs through Keystone, using the same
  /// stored selection as [signCompiledTx] when no wallet id is supplied.
  Future<bool> activeSignerIsKeystone() async {
    final walletId = await _storage.loadSelectedWalletId();
    final row = walletId == null ? null : await _db.getWalletById(walletId);
    return row != null &&
        WalletType.fromDbString(row.walletType) == WalletType.keystone;
  }

  /// Whether the active wallet can sign a v1 transaction.
  ///
  /// True for the wallets whose key the app holds (seed phrase, imported key,
  /// social login, and the legacy single-mnemonic fallback): they sign the
  /// message bytes with ed25519 and never parse them. Ledger, Seed Vault and
  /// Keystone parse the transaction on the device to show it, and none of
  /// them is known to read v1, so they stay on v0.
  Future<bool> activeSignerCanSignV1() async {
    final walletId = await _storage.loadSelectedWalletId();
    final row = walletId == null ? null : await _db.getWalletById(walletId);
    return _signsV1(
      row == null ? null : WalletType.fromDbString(row.walletType),
    );
  }

  static bool _signsV1(WalletType? walletType) => switch (walletType) {
    WalletType.hd ||
    WalletType.importedKey ||
    WalletType.social ||
    null => true,
    WalletType.ledger ||
    WalletType.seedVault ||
    WalletType.keystone ||
    WalletType.viewOnly => false,
  };

  /// Whether the active wallet signs locally (HD seed phrase or imported
  /// private key, plus the legacy single-mnemonic fallback). Returns false for
  /// hardware wallets (Ledger, Seed Vault) and social wallets, where signing
  /// requires an external approval prompt. View-only wallets cannot sign at
  /// all — also false.
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
    // Deliberately an allow-list, not a deny-list: a wallet type added later
    // reads as external until someone puts it here on purpose. Seed Vault
    // answers false for free by that shape, which is the right answer — its
    // signature comes from an OS approval Activity, not from us — so keep the
    // shape rather than converting this to a set of exclusions.
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
          scheme: _schemeFromRow(row),
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
      case WalletType.seedVault:
      case WalletType.keystone:
        // The switch in [signCompiledTx] handles these branches before
        // reaching here; surfacing as a state error makes the misuse loud.
        // None of them can be served from an isolate anyway: an isolate
        // reaches neither the BLE link nor the platform channel behind
        // Seed Vault's approval Activity, nor the sheet behind a Keystone's QR
        // exchange.
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
      case WalletType.seedVault:
      case WalletType.keystone:
        // There is no keypair to hand back: mallow holds no key material for
        // any of these rows, by design for the three hardware types.
        throw ViewOnlyWalletException();
    }
  }

  /// Ensure the Ledger device is connected before issuing a sign call.
  ///
  /// If the BLE link is already up this is a no-op. Otherwise routes through
  /// [LedgerConnectController] to show the connect sheet and waits for the
  /// user to reconnect. Throws [LedgerNotConnectedException] if the user
  /// dismisses the sheet or the connect attempt fails.
  Future<void> _ensureLedgerConnected(
    String address, {
    Future<void>? cancelled,
  }) async {
    AppLogger.debug(
      _tag,
      '_ensureLedgerConnected($address) — '
      'isConnected=${_ledgerService.isConnected}',
    );
    if (_ledgerService.isConnected) return;
    final ok = await GetIt.instance<LedgerConnectController>()
        .requestConnection(address, cancelled: cancelled);
    AppLogger.debug(_tag, '_ensureLedgerConnected got ok=$ok');
    if (!ok) throw const LedgerNotConnectedException();
  }

  /// Wrap a Ledger operation so a stale connection (precheck passes but the
  /// BLE link is actually dead) gets recovered via the connect sheet instead
  /// of bubbling up as "Ledger device not connected".
  Future<T> _withLedgerConnection<T>(
    String address,
    Future<T> Function() op, {
    Future<void>? cancelled,
  }) async {
    await _ensureLedgerConnected(address, cancelled: cancelled);
    try {
      return await op();
    } on LedgerNotConnectedException {
      // Stale isConnected — force a fresh connection then retry once.
      final ok = await GetIt.instance<LedgerConnectController>()
          .requestConnection(address, cancelled: cancelled);
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
