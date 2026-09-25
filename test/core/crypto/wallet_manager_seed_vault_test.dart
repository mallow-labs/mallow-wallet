import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:web3dart/web3dart.dart' show Transaction;

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

class _MockLedgerService extends Mock implements LedgerService {}

class _MockSeedVaultService extends Mock implements SeedVaultService {}

/// Who actually produced a signature, inferred from its bytes.
///
/// The two external signers are mocked to return constant, mutually distinct
/// fills, so a signature that is neither is one this process computed from key
/// material it holds — which is precisely what a hardware wallet must never
/// produce.
enum _Signer { local, ledger, seedVault, refused }

const _ledgerFill = 0xAA;
const _vaultFill = 0x5A;

final _ledgerSig = Uint8List.fromList(List<int>.filled(64, _ledgerFill));
final _vaultSig = Uint8List.fromList(List<int>.filled(64, _vaultFill));

/// Standard BIP-39 test vector, for the HD row's seed.
const _mnemonic =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// Ed25519 seed behind the imported-key / social rows.
final _importedSeed = List<int>.generate(32, (i) => i + 1);

/// Ed25519 seed behind the transfer recipient — any second valid account.
final _recipientSeed = List<int>.generate(32, (i) => 200 - i);

final _payload = utf8.encode('mallow Login\n\ntoken:abc123');
final _blockhash = base58encode(List<int>.filled(32, 3));

const _walletId = 'row-1';

/// The signer each wallet type must route to, for every Solana signing entry
/// point (bar the overrides in [_expectedSigner]).
///
/// Keyed by [WalletType] rather than written as a list of the types we happen
/// to remember, so a value added to the enum without a decision here fails the
/// suite instead of quietly inheriting whatever the fall-through branch does.
const _routing = <WalletType, _Signer>{
  WalletType.hd: _Signer.local,
  WalletType.importedKey: _Signer.local,
  WalletType.social: _Signer.local,
  WalletType.viewOnly: _Signer.refused,
  WalletType.ledger: _Signer.ledger,
  WalletType.seedVault: _Signer.seedVault,
};

_Signer _expectedSigner(WalletType type, String probe) {
  // The legacy additional-signers path was never wired for social wallets: it
  // refuses so the caller can say so, rather than signing with a key the live
  // path would have used.
  if (type == WalletType.social &&
      probe == 'signTransactionWithAdditionalSigners') {
    return _Signer.refused;
  }
  return _routing[type]!;
}

bool _isFill(List<int> sig, int value) =>
    sig.length == 64 && sig.every((b) => b == value);

_Signer _classify(List<int> sig) {
  if (_isFill(sig, _ledgerFill)) return _Signer.ledger;
  if (_isFill(sig, _vaultFill)) return _Signer.seedVault;
  return _Signer.local;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MallowDatabase db;
  late SecureWalletStorage storage;
  late WalletManager manager;
  late _MockLedgerService ledger;
  late _MockSeedVaultService seedVault;

  /// The last call the Seed Vault service received, so a test can assert on the
  /// exact argument list rather than only on the values.
  Invocation? lastSeedVaultCall;

  late Ed25519HDPublicKey recipient;

  /// Address used by the rows that hold no local key (view-only + both
  /// hardware types). Any valid base58 Ed25519 pubkey does.
  late String externalAddress;

  final fssStore = <String, String>{};
  final vaultStore = <String, String>{};

  setUpAll(() async {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(SolanaDerivationScheme.standard);
    recipient = (await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: _recipientSeed,
    )).publicKey;
    externalAddress = (await Ed25519HDKeyPair.fromPrivateKeyBytes(
      privateKey: _importedSeed,
    )).address;
  });

  setUp(() async {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    final fss = _MockFss();
    final vault = _MockVault();
    fssStore.clear();
    vaultStore.clear();
    lastSeedVaultCall = null;
    SharedPreferences.setMockInitialValues({});

    when(
      () => fss.read(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((inv) async => fssStore[inv.namedArguments[#key] as String]);

    when(
      () => fss.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((inv) async {
      fssStore[inv.namedArguments[#key] as String] =
          inv.namedArguments[#value] as String;
    });

    when(() => vault.read(any(), prompt: any(named: 'prompt'))).thenAnswer(
      (inv) async => vaultStore[inv.positionalArguments[0] as String],
    );

    when(() => vault.write(any(), any())).thenAnswer((inv) async {
      vaultStore[inv.positionalArguments[0] as String] =
          inv.positionalArguments[1] as String;
    });

    ledger = _MockLedgerService();
    when(() => ledger.isConnected).thenReturn(true);
    when(
      () => ledger.signTransaction(
        any(),
        account: any(named: 'account'),
        scheme: any(named: 'scheme'),
      ),
    ).thenAnswer((_) async => _ledgerSig);
    when(
      () => ledger.signMessage(
        any(),
        account: any(named: 'account'),
        scheme: any(named: 'scheme'),
      ),
    ).thenAnswer((_) async => _ledgerSig);

    seedVault = _MockSeedVaultService();
    when(
      () => seedVault.signTransaction(any(), address: any(named: 'address')),
    ).thenAnswer((inv) async {
      lastSeedVaultCall = inv;
      return _vaultSig;
    });
    when(
      () => seedVault.signMessage(any(), address: any(named: 'address')),
    ).thenAnswer((inv) async {
      lastSeedVaultCall = inv;
      return _vaultSig;
    });

    storage = SecureWalletStorage(fss, vault);
    final prefs = await PreferencesService.create();
    manager = WalletManager(
      storage,
      db,
      WalletRepository(db, storage, prefs),
      ledger,
      seedVault,
    );
  });

  tearDown(() => db.close());

  /// Insert the single wallet row under test, with whatever key material its
  /// type needs, and make it the global selection. Returns its address.
  ///
  /// The switch is exhaustive, so a new [WalletType] cannot be added without
  /// deciding here what key material it holds.
  Future<String> installRow(
    WalletType type, {
    Chain chain = Chain.solana,
  }) async {
    String address;
    String? seedPhraseId;

    switch (type) {
      case WalletType.hd:
        seedPhraseId = 'seed-1';
        await storage.storeMnemonicForSeedPhrase(seedPhraseId, _mnemonic);
        address = (await MultiChainDerivation.deriveSolanaWithAccount(
          _mnemonic,
          account: 0,
        )).address;
      case WalletType.importedKey:
      case WalletType.social:
        await storage.storePrivateKey(_walletId, base58encode(_importedSeed));
        address = externalAddress;
      case WalletType.viewOnly:
      case WalletType.ledger:
      case WalletType.seedVault:
        // Nothing to store — none of these rows has key material on device.
        address = externalAddress;
    }

    await db.upsertWalletEntry(
      WalletsCompanion.insert(
        id: _walletId,
        address: address,
        name: 'Wallet',
        walletType: type.toDbString(),
        chain: Value(chain.toDbString()),
        seedPhraseId: Value(seedPhraseId),
        derivationIndex: const Value(0),
        createdAt: 0,
      ),
    );
    await storage.storeSelectedWalletId(_walletId);
    return address;
  }

  Message transferMessage(String from) => Message.only(
    SystemInstruction.transfer(
      fundingAccount: Ed25519HDPublicKey.fromBase58(from),
      recipientAccount: recipient,
      lamports: 1,
    ),
  );

  SignedTx unsignedTx(String feePayerAddress) {
    final payer = Ed25519HDPublicKey.fromBase58(feePayerAddress);
    return SignedTx(
      compiledMessage: transferMessage(
        feePayerAddress,
      ).compile(recentBlockhash: _blockhash, feePayer: payer),
    );
  }

  /// Every Solana signing entry point, reduced to "the signature bytes the
  /// user's wallet produced".
  final probes = <String, Future<List<int>> Function(String address)>{
    'signMessage': (_) async => (await manager.signMessage(_payload)).bytes,
    'signMessageForWallet': (_) async =>
        (await manager.signMessageForWallet(_walletId, _payload)).bytes,
    'signMessageBase58ForWallet': (_) async => base58decode(
      await manager.signMessageBase58ForWallet(_walletId, _payload),
    ),
    'signTransaction': (address) async => (await manager.signTransaction(
      message: transferMessage(address),
      recentBlockhash: _blockhash,
    )).signatures.first.bytes,
    'signTransactionWithAdditionalSigners': (address) async =>
        (await manager.signTransactionWithAdditionalSigners(
          message: transferMessage(address),
          recentBlockhash: _blockhash,
        )).signatures.first.bytes,
    'signCompiledTx': (address) async => (await manager.signCompiledTx(
      unsignedTx: unsignedTx(address),
    )).signatures.first.bytes,
  };

  group('no signing entry point falls through', () {
    // Half of the WalletManager routing sites were `if (type == ledger)`, not
    // switches, so adding a wallet type compiled clean and silently landed on
    // local keypair signing — which for a key we do not hold fails as
    // "view-only", pointing the reader at the wrong problem. Worse, a type we
    // *do* hold a key for would have signed with it. This matrix is the guard
    // that survives the next wallet type: it walks WalletType.values, so a new
    // value with no declared routing fails here rather than shipping.
    for (final type in WalletType.values) {
      for (final probe in probes.keys) {
        test('${type.name} / $probe routes to its declared signer', () async {
          expect(
            _routing.containsKey(type),
            isTrue,
            reason:
                'WalletType.${type.name} has no declared signer. Add it to '
                '_routing — deciding it deliberately is the point of this test.',
          );

          final address = await installRow(type);
          final expected = _expectedSigner(type, probe);

          if (expected == _Signer.refused) {
            await expectLater(
              probes[probe]!(address),
              throwsA(isA<Exception>()),
              reason:
                  'WalletType.${type.name} cannot sign here, so $probe must '
                  'fail loudly rather than produce a signature.',
            );
            return;
          }

          final signature = await probes[probe]!(address);
          expect(
            _classify(signature),
            expected,
            reason:
                '$probe signed a WalletType.${type.name} wallet with the wrong '
                'signer. A local signature here means the routing fell '
                'through to key material this process holds.',
          );
        });
      }
    }
  });

  group('Seed Vault routing', () {
    test('signTransaction hands the compiled message to Seed Vault', () async {
      final address = await installRow(WalletType.seedVault);

      final signed = await manager.signTransaction(
        message: transferMessage(address),
        recentBlockhash: _blockhash,
      );

      // Seed Vault signs the payload verbatim and returns a detached 64-byte
      // signature, so what it signed must be exactly the compiled message that
      // ends up on the wire — not a re-serialization of it.
      expect(
        lastSeedVaultCall!.positionalArguments.first,
        equals(signed.compiledMessage.toByteArray().toList()),
      );
      expect(signed.signatures.first.bytes, _vaultSig);
    });

    test(
      'signTransactionWithAdditionalSigners keeps the extra signers',
      () async {
        final address = await installRow(WalletType.seedVault);
        final extra = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: _recipientSeed,
        );

        final signed = await manager.signTransactionWithAdditionalSigners(
          message: transferMessage(address),
          recentBlockhash: _blockhash,
          additionalSigners: [extra],
        );

        // The mint flow's ephemeral co-signer must survive the hardware route,
        // or a mint signed on a Seed Vault wallet is short a signature.
        expect(signed.signatures, hasLength(2));
        expect(signed.signatures.first.bytes, _vaultSig);
        expect(signed.signatures[1].publicKey, extra.publicKey);
      },
    );

    test('signCompiledTx preserves the backend blockhash', () async {
      final address = await installRow(WalletType.seedVault);
      final unsigned = unsignedTx(address);

      final signed = await manager.signCompiledTx(unsignedTx: unsigned);

      // The point of signCompiledTx is that the server's compiled message goes
      // through untouched (v0 address-table lookups cannot be recompiled
      // client-side); the hardware arm must not recompile it either.
      expect(signed.compiledMessage, unsigned.compiledMessage);
      expect(signed.signatures.first.bytes, _vaultSig);
    });

    test('signMessageBase58ForWallet is the login path', () async {
      await installRow(WalletType.seedVault);

      final base58 = await manager.signMessageBase58ForWallet(
        _walletId,
        _payload,
      );

      // Seed Vault does not wrap the payload the way the Ledger app's
      // off-chain message signing does, so the login challenge is signed as-is
      // and the ordinary {address, message, signature} verify body holds.
      expect(lastSeedVaultCall!.positionalArguments.first, equals(_payload));
      expect(base58decode(base58), _vaultSig);
      expect(lastSeedVaultCall!.memberName, #signMessage);

      // The same bytes reach the backend through signLoginChallenge, which has
      // no wallet-type branch of its own.
      final challenge = await manager.signLoginChallenge(
        _walletId,
        message: 'mallow Login',
        token: 'abc123',
      );
      expect(challenge.chain, Chain.solana);
      expect(base58decode(challenge.signature), _vaultSig);
      expect(challenge.publicKey, isNull);
    });
  });

  group('Seed Vault is called with the address and nothing else', () {
    // D5's whole point: SeedVaultService resolves the auth token and the
    // derivation path from the vault's own account table and signs under the
    // path the vault reported. A path reconstructed here that belongs to a
    // different key yields a *valid* signature from the wrong address, which
    // fails silently rather than erroring. There is deliberately no parameter
    // to pass one through — these assertions fail if a refactor adds one.
    test('signTransaction passes (payload, address:) only', () async {
      final address = await installRow(WalletType.seedVault);

      await manager.signTransaction(
        message: transferMessage(address),
        recentBlockhash: _blockhash,
      );

      expect(lastSeedVaultCall!.positionalArguments, hasLength(1));
      expect(lastSeedVaultCall!.namedArguments.keys, [#address]);
      expect(lastSeedVaultCall!.namedArguments[#address], address);
    });

    test('signMessage passes (payload, address:) only', () async {
      final address = await installRow(WalletType.seedVault);

      await manager.signMessageForWallet(_walletId, _payload);

      expect(lastSeedVaultCall!.positionalArguments, hasLength(1));
      expect(lastSeedVaultCall!.namedArguments.keys, [#address]);
      expect(lastSeedVaultCall!.namedArguments[#address], address);
    });

    test('signCompiledTx passes (payload, address:) only', () async {
      final address = await installRow(WalletType.seedVault);

      await manager.signCompiledTx(unsignedTx: unsignedTx(address));

      expect(lastSeedVaultCall!.positionalArguments, hasLength(1));
      expect(lastSeedVaultCall!.namedArguments.keys, [#address]);
      expect(lastSeedVaultCall!.namedArguments[#address], address);
    });
  });

  group('Seed Vault is Solana-only', () {
    // PURPOSE_SIGN_SOLANA_TRANSACTION is the entire purpose enum, so there is
    // no secp256k1 or Tezos key behind a Seed Vault row and never will be. A
    // row on another chain is already an invariant violation; these arms exist
    // so it fails loudly instead of reaching for key material that cannot
    // exist.
    test('signTezosOperation refuses', () async {
      await installRow(WalletType.seedVault, chain: Chain.tezos);

      await expectLater(
        manager.signTezosOperation(_walletId, 'ab'),
        throwsA(isA<TezosOperationSigningNotSupportedException>()),
      );
      verifyNever(
        () => seedVault.signTransaction(any(), address: any(named: 'address')),
      );
    });

    test('getTezosPublicKey refuses', () async {
      await installRow(WalletType.seedVault, chain: Chain.tezos);

      await expectLater(
        manager.getTezosPublicKey(_walletId),
        throwsA(isA<TezosOperationSigningNotSupportedException>()),
      );
    });

    test('signEthereumTransaction refuses', () async {
      await installRow(WalletType.seedVault, chain: Chain.ethereum);

      await expectLater(
        manager.signEthereumTransaction(
          _walletId,
          Transaction(maxGas: 21000),
          chainId: 1,
        ),
        throwsA(isA<EthereumTransactionSigningNotSupportedException>()),
      );
      verifyNever(
        () => seedVault.signTransaction(any(), address: any(named: 'address')),
      );
    });
  });

  group('mallow never holds a Seed Vault key', () {
    test('the keypair loader refuses a Seed Vault row', () async {
      await installRow(WalletType.seedVault);

      // getPublicKey funnels through _getKeypairForWallet, the one place that
      // would have to materialise a private key. It must refuse for the same
      // reason it refuses Ledger: there is nothing to materialise.
      await expectLater(
        manager.getPublicKey(),
        throwsA(isA<ViewOnlyWalletException>()),
      );
    });

    test('isLocalSigner is false for a Seed Vault wallet', () async {
      await installRow(WalletType.seedVault);

      // The transaction pipeline picks its copy from this: a Seed Vault
      // signature comes from an OS approval Activity, so the user must be told
      // to approve elsewhere, not shown the local approving copy.
      expect(await manager.isLocalSigner(), isFalse);
    });

    test('isLocalSigner stays true for a local wallet', () async {
      await installRow(WalletType.importedKey);
      expect(await manager.isLocalSigner(), isTrue);
    });
  });

  group('isHardwareWallet', () {
    for (final type in [WalletType.ledger, WalletType.seedVault]) {
      test('is true for ${type.name}', () async {
        // Hardware-generic on purpose: the callers that gate background
        // signing are asking whether a signature needs an interactive approval
        // outside this process, and both devices answer yes.
        final address = await installRow(type);
        expect(await manager.isHardwareWallet(address), isTrue);
      });
    }

    for (final type in [
      WalletType.hd,
      WalletType.importedKey,
      WalletType.social,
      WalletType.viewOnly,
    ]) {
      test('is false for ${type.name}', () async {
        final address = await installRow(type);
        expect(await manager.isHardwareWallet(address), isFalse);
      });
    }

    test('is false for an unknown address', () async {
      expect(await manager.isHardwareWallet(externalAddress), isFalse);
    });
  });
}
