import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keystone_ur/keystone_ur.dart' show EthDataType;
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/eip712.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/keystone_sign_service.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/web3dart.dart'
    show
        EthPrivateKey,
        Transaction,
        keccak256,
        padUint8ListTo32,
        sign,
        unsignedIntToBytes;

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

class _MockLedgerService extends Mock implements LedgerService {}

class _MockSeedVaultService extends Mock implements SeedVaultService {}

class _MockKeystoneSignService extends Mock implements KeystoneSignService {}

/// Who actually produced a signature, inferred from its bytes.
///
/// The two external signers are mocked to return constant, mutually distinct
/// fills, so a signature that is neither is one this process computed from key
/// material it holds — which is precisely what a hardware wallet must never
/// produce.
enum _Signer { local, ledger, seedVault, keystone, refused }

const _ledgerFill = 0xAA;
const _vaultFill = 0x5A;
const _keystoneFill = 0x4B;
const _keystoneFingerprint = 0x12121212;

final _ledgerSig = Uint8List.fromList(List<int>.filled(64, _ledgerFill));
final _vaultSig = Uint8List.fromList(List<int>.filled(64, _vaultFill));
final _keystoneSig = Uint8List.fromList(List<int>.filled(64, _keystoneFill));

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
  WalletType.keystone: _Signer.keystone,
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
  if (_isFill(sig, _keystoneFill)) return _Signer.keystone;
  return _Signer.local;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MallowDatabase db;
  late SecureWalletStorage storage;
  late WalletManager manager;
  late _MockLedgerService ledger;
  late _MockSeedVaultService seedVault;
  late _MockKeystoneSignService keystone;

  /// The last call the Keystone service received.
  Invocation? lastKeystoneCall;

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
    registerFallbackValue(KeystoneSignPurpose.transaction);
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

    keystone = _MockKeystoneSignService();
    lastKeystoneCall = null;
    when(
      () => keystone.signSolana(
        payload: any(named: 'payload'),
        address: any(named: 'address'),
        masterFingerprint: any(named: 'masterFingerprint'),
        derivationIndex: any(named: 'derivationIndex'),
        scheme: any(named: 'scheme'),
        purpose: any(named: 'purpose'),
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((inv) async {
      lastKeystoneCall = inv;
      return _keystoneSig;
    });

    storage = SecureWalletStorage(fss, vault);
    final prefs = await PreferencesService.create();
    manager = WalletManager(
      storage,
      db,
      WalletRepository(db, storage, prefs),
      ledger,
      seedVault,
      keystone,
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
      case WalletType.keystone:
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
        masterFingerprint: Value(
          type == WalletType.keystone ? _keystoneFingerprint : null,
        ),
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

  group('pinned browser signing', () {
    test(
      'an explicit wallet is used even when global selection changes',
      () async {
        final address = await installRow(WalletType.importedKey);
        await storage.storeSelectedWalletId('another-wallet');
        final original = unsignedTx(address);
        final signed = await manager.signCompiledTx(
          unsignedTx: original,
          walletId: _walletId,
          expectedAddress: address,
        );
        expect(
          signed.compiledMessage.toByteArray().toList(),
          original.compiledMessage.toByteArray().toList(),
        );
        expect(
          signed.signatures.single.publicKey,
          Ed25519HDPublicKey.fromBase58(address),
        );
      },
    );
    test(
      'missing pinned wallet cannot fall through to the global signer',
      () async {
        final address = await installRow(WalletType.importedKey);
        await expectLater(
          manager.signCompiledTx(
            unsignedTx: unsignedTx(address),
            walletId: 'missing',
            expectedAddress: address,
          ),
          throwsA(isA<NoWalletException>()),
        );
      },
    );
    test('cancelled approval never dispatches to external custody', () async {
      final address = await installRow(WalletType.seedVault);
      await expectLater(
        manager.signCompiledTx(
          unsignedTx: unsignedTx(address),
          walletId: _walletId,
          expectedAddress: address,
          ensureActive: () => throw StateError('cancelled'),
        ),
        throwsStateError,
      );
      verifyNever(
        () => seedVault.signTransaction(any(), address: any(named: 'address')),
      );
    });
    for (final scheme in [
      SolanaDerivationScheme.legacy,
      SolanaDerivationScheme.root,
    ]) {
      test(
        'compiled signing retains the stored ${scheme.name} derivation scheme',
        () async {
          await installRow(WalletType.hd);
          final key = await MultiChainDerivation.deriveSolanaWithScheme(
            _mnemonic,
            0,
            scheme,
          );
          await db.upsertWalletEntry(
            WalletsCompanion.insert(
              id: _walletId,
              address: key.address,
              name: 'Wallet',
              walletType: 'hd',
              seedPhraseId: const Value('seed-1'),
              derivationIndex: const Value(0),
              derivationScheme: Value(scheme.name),
              createdAt: 0,
            ),
          );
          final original = unsignedTx(key.address);
          final signed = await manager.signCompiledTx(
            unsignedTx: original,
            walletId: _walletId,
            expectedAddress: key.address,
          );
          final expected = await key.sign(
            original.compiledMessage.toByteArray().toList(),
          );
          expect(signed.signatures.single.bytes, expected.bytes);
        },
      );
    }
  });

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
      final address = await installRow(WalletType.seedVault);

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

      Config.debugOverrides['API_BASE_URL'] = 'https://api.example.com';
      addTearDown(() => Config.debugOverrides.remove('API_BASE_URL'));
      final issued = DateTime.now().toUtc();
      String signIn(String domain) =>
          '$domain wants you to sign in with your Solana account:\n'
          '$address\n\nSign in to mallow.\n\nURI: https://$domain\n'
          'Version: 1\nNonce: abc12345\n'
          'Issued At: ${issued.toIso8601String()}\n'
          'Expiration Time: '
          '${issued.add(const Duration(minutes: 5)).toIso8601String()}';
      final signInMessage = signIn('example.com');
      await manager.signLoginChallenge(_walletId, message: signInMessage);
      expect(
        lastSeedVaultCall!.positionalArguments.first,
        equals(utf8.encode(signInMessage)),
      );

      // A sign-in for any other site is refused before the OS approval
      // screen is ever raised.
      lastSeedVaultCall = null;
      await expectLater(
        manager.signLoginChallenge(_walletId, message: signIn('othersite.xyz')),
        throwsA(isA<LoginChallengeRejectedException>()),
      );
      expect(lastSeedVaultCall, isNull);
    });
  });

  group('Seed Vault is called with the address and nothing else', () {
    // The whole point: SeedVaultService resolves the auth token and the
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

  group('activeSignerIsKeystone', () {
    for (final type in WalletType.values) {
      test('reports ${type.name} from the stored selected row', () async {
        await installRow(type);
        expect(
          await manager.activeSignerIsKeystone(),
          type == WalletType.keystone,
        );
      });
    }

    test('false when nothing is selected', () async {
      expect(await manager.activeSignerIsKeystone(), isFalse);
    });

    test('false when the stored selected row no longer exists', () async {
      await installRow(WalletType.keystone);
      await storage.storeSelectedWalletId('missing');
      expect(await manager.activeSignerIsKeystone(), isFalse);
    });
  });

  group('Keystone routing', () {
    test(
      'signCompiledTx sends the compiled message with the row identity',
      () async {
        final address = await installRow(WalletType.keystone);
        final original = unsignedTx(address);

        final signed = await manager.signCompiledTx(unsignedTx: original);

        // The device signs the compiled message bytes verbatim, and the request
        // must name the fingerprint, index and scheme stored on the row — a
        // reconstructed path that belongs to another key would come back as a
        // valid signature from the wrong address.
        final args = lastKeystoneCall!.namedArguments;
        expect(
          args[#payload],
          equals(original.compiledMessage.toByteArray().toList()),
        );
        expect(args[#address], address);
        expect(args[#masterFingerprint], _keystoneFingerprint);
        expect(args[#derivationIndex], 0);
        expect(args[#scheme], SolanaDerivationScheme.standard);
        expect(args[#purpose], KeystoneSignPurpose.transaction);
        expect(signed.signatures.single.bytes, _keystoneSig);
        expect(
          signed.compiledMessage.toByteArray().toList(),
          original.compiledMessage.toByteArray().toList(),
        );
      },
    );

    test('message signing asks for a message, not a transaction', () async {
      await installRow(WalletType.keystone);
      await manager.signMessageBase58ForWallet(_walletId, _payload);
      expect(
        lastKeystoneCall!.namedArguments[#purpose],
        KeystoneSignPurpose.message,
      );
      expect(lastKeystoneCall!.namedArguments[#payload], equals(_payload));
    });

    test('the flow cancellation reaches the QR exchange', () async {
      final address = await installRow(WalletType.keystone);
      final cancelled = Completer<void>().future;
      await manager.signCompiledTx(
        unsignedTx: unsignedTx(address),
        cancelled: cancelled,
      );
      expect(lastKeystoneCall!.namedArguments[#cancelled], same(cancelled));
    });

    test("a website message request's cancellation reaches the QR "
        'exchange', () async {
      // An abandoned browser request must close its sheet, or the obsolete
      // QR exchange holds up every request queued behind it.
      final address = await installRow(WalletType.keystone);
      final cancelled = Completer<void>().future;
      await manager.signMessageForWallet(
        _walletId,
        _payload,
        expectedAddress: address,
        cancelled: cancelled,
      );
      expect(lastKeystoneCall!.namedArguments[#cancelled], same(cancelled));
    });

    test('a superseded request never reaches the device', () async {
      final address = await installRow(WalletType.keystone);
      await expectLater(
        manager.signCompiledTx(
          unsignedTx: unsignedTx(address),
          walletId: _walletId,
          expectedAddress: address,
          ensureActive: () => throw StateError('cancelled'),
        ),
        throwsStateError,
      );
      expect(lastKeystoneCall, isNull);
    });

    test('a non-Solana Keystone row is refused before any QR', () async {
      await installRow(WalletType.keystone, chain: Chain.ethereum);
      await expectLater(
        manager.signMessageForWallet(_walletId, _payload),
        throwsA(isA<NonSolanaSigningWalletException>()),
      );
      expect(lastKeystoneCall, isNull);
    });

    test('Tezos signing refuses a Keystone row', () async {
      await installRow(WalletType.keystone, chain: Chain.tezos);
      await expectLater(
        manager.signTezosOperation(_walletId, '00'),
        throwsA(isA<TezosOperationSigningNotSupportedException>()),
      );
      await expectLater(
        manager.getTezosPublicKey(_walletId),
        throwsA(isA<TezosOperationSigningNotSupportedException>()),
      );
    });

    test('isLocalSigner is false for a Keystone wallet', () async {
      await installRow(WalletType.keystone);
      expect(await manager.isLocalSigner(), isFalse);
    });

    test('walletTypeOf reports a Keystone row', () async {
      final address = await installRow(WalletType.keystone);
      expect(await manager.walletTypeOf(address), WalletType.keystone);
      expect(await manager.walletTypeOf('unknown'), isNull);
    });
  });

  group('isHardwareWallet', () {
    for (final type in [
      WalletType.ledger,
      WalletType.seedVault,
      WalletType.keystone,
    ]) {
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
  group('Keystone Ethereum routing', () {
    // A real secp256k1 key stands in for the device, so the bytes the manager
    // reassembles can be compared with what a local key signs: deterministic
    // (RFC 6979) signatures make the two byte-identical when the manager sends
    // the right payload and puts r, s and v back in the right places.
    final deviceKey = EthPrivateKey(
      Uint8List.fromList(List<int>.generate(32, (i) => i + 11)),
    );
    final ethAddress = deviceKey.address.eip55With0x;
    const ethIndex = 4;
    final transaction = Transaction(
      to: EthereumAddress.fromHex('0x1111111111111111111111111111111111111111'),
      value: EtherAmount.inWei(BigInt.from(12345)),
      maxGas: 21000,
      maxFeePerGas: EtherAmount.inWei(BigInt.from(30000000000)),
      maxPriorityFeePerGas: EtherAmount.inWei(BigInt.from(1000000000)),
      nonce: 7,
    );

    Uint8List signDigest(Uint8List digest, {int vOffset = 0}) {
      final sig = sign(digest, deviceKey.privateKey);
      return Uint8List.fromList([
        ...padUint8ListTo32(unsignedIntToBytes(sig.r)),
        ...padUint8ListTo32(unsignedIntToBytes(sig.s)),
        sig.v - 27 + vOffset,
      ]);
    }

    setUp(() async {
      registerFallbackValue(EthDataType.personalMessage);
      await db.upsertWalletEntry(
        WalletsCompanion.insert(
          id: _walletId,
          address: ethAddress,
          name: 'Ethereum',
          walletType: WalletType.keystone.toDbString(),
          chain: Value(Chain.ethereum.toDbString()),
          derivationIndex: const Value(ethIndex),
          masterFingerprint: const Value(_keystoneFingerprint),
          createdAt: 0,
        ),
      );
      // The service's contract: it returns r‖s‖v with v = 27/28, already
      // checked against the row address. The fake signs the digest it is
      // handed, so a wrong digest shows up as a wrong signature below.
      when(
        () => keystone.signEthereum(
          signData: any(named: 'signData'),
          dataType: any(named: 'dataType'),
          digest: any(named: 'digest'),
          chainId: any(named: 'chainId'),
          address: any(named: 'address'),
          masterFingerprint: any(named: 'masterFingerprint'),
          derivationIndex: any(named: 'derivationIndex'),
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer((inv) async {
        lastKeystoneCall = inv;
        return signDigest(
          inv.namedArguments[#digest] as Uint8List,
          vOffset: 27,
        );
      });
    });

    test('a transaction is sent as a typed transaction and reassembles to '
        'the bytes a local key signs', () async {
      final signed = await manager.signEthereumTransaction(
        _walletId,
        transaction,
        chainId: 1,
      );

      final args = lastKeystoneCall!.namedArguments;
      final unsigned = MultiChainDerivation.unsignedEip1559Payload(
        transaction,
        1,
      );
      expect(args[#dataType], EthDataType.typedTransaction);
      expect(args[#signData], equals(unsigned));
      expect(args[#digest], equals(keccak256(unsigned)));
      expect(args[#chainId], 1);
      expect(args[#address], ethAddress);
      expect(args[#masterFingerprint], _keystoneFingerprint);
      expect(args[#derivationIndex], ethIndex);
      expect(
        signed,
        equals(
          await MultiChainDerivation.signEthereumTransactionWithKey(
            deviceKey.privateKey,
            transaction,
            1,
          ),
        ),
      );
    });

    test('a legacy transaction is refused before any QR', () async {
      await expectLater(
        manager.signEthereumTransaction(
          _walletId,
          Transaction(maxGas: 21000),
          chainId: 1,
        ),
        throwsA(isA<EthereumTransactionSigningNotSupportedException>()),
      );
      expect(lastKeystoneCall, isNull);
    });

    test(
      'personal_sign sends the raw message and matches a local key',
      () async {
        final message = Uint8List.fromList(utf8.encode('hello from a dapp'));
        final sig = await manager.signEthereumPersonalMessageForWallet(
          _walletId,
          message,
          expectedAddress: ethAddress,
        );

        final args = lastKeystoneCall!.namedArguments;
        expect(args[#dataType], EthDataType.personalMessage);
        expect(args[#signData], equals(message));
        expect(
          '0x${sig.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
          await MultiChainDerivation.signEthereumPersonalMessageWithKey(
            deviceKey.privateKey,
            message,
          ),
        );
      },
    );

    test('typed data sends JSON that hashes to the reviewed digest', () async {
      final typedData = Eip712TypedData.parse({
        'types': {
          'Mail': [
            {'name': 'contents', 'type': 'string'},
            {'name': 'amount', 'type': 'uint256'},
          ],
        },
        'primaryType': 'Mail',
        'domain': {'name': 'mallow', 'version': '1', 'chainId': 5},
        'message': {'contents': 'hi', 'amount': '1000000000000000000000'},
      });

      final sig = await manager.signEthereumTypedDataForWallet(
        _walletId,
        typedData,
        expectedAddress: ethAddress,
      );

      final args = lastKeystoneCall!.namedArguments;
      expect(args[#dataType], EthDataType.typedData);
      expect(args[#digest], equals(typedData.digest));
      expect(args[#chainId], 5);
      // The device hashes the JSON itself: what it is sent must hash to the
      // digest the review showed.
      final sent = Eip712TypedData.parse(
        utf8.decode(args[#signData] as Uint8List),
      );
      expect(sent.digest, equals(typedData.digest));
      expect(
        MultiChainDerivation.recoverEthereumAddress(typedData.digest, sig),
        ethAddress.toLowerCase(),
      );
    });

    test('login without a token is refused before the device', () async {
      await expectLater(
        manager.signLoginChallenge(_walletId, message: 'anything at all'),
        throwsA(isA<LoginChallengeRejectedException>()),
      );
      expect(lastKeystoneCall, isNull);
    });

    test('login signs EIP-191 on the device and returns hex', () async {
      final result = await manager.signLoginChallenge(
        _walletId,
        message: 'mallow Login',
        token: 'abc123',
      );

      final message = utf8.encode('mallow Login\n\ntoken:abc123');
      expect(
        lastKeystoneCall!.namedArguments[#dataType],
        EthDataType.personalMessage,
      );
      expect(result.chain, Chain.ethereum);
      expect(
        result.signature,
        await MultiChainDerivation.signEthereumPersonalMessageWithKey(
          deviceKey.privateKey,
          message,
        ),
      );
    });

    test('the Solana signers still refuse the Ethereum row', () async {
      await expectLater(
        manager.signMessageForWallet(_walletId, _payload),
        throwsA(isA<NonSolanaSigningWalletException>()),
      );
    });
  });
}
