import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/base58.dart';
import 'package:solana/solana.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

/// A database whose row deletes fail for chosen ids, so the removal path can
/// be observed part-way through — the only way to prove what a failed step
/// leaves behind.
class _DeleteFailingDb extends MallowDatabase {
  _DeleteFailingDb() : super.forTesting(NativeDatabase.memory());

  final failingWalletIds = <String>{};
  final failingSeedPhraseIds = <String>{};

  @override
  Future<void> deleteWalletById(String id) {
    if (failingWalletIds.contains(id)) {
      return Future.error(StateError('row delete failed'));
    }
    return super.deleteWalletById(id);
  }

  @override
  Future<void> deleteSeedPhraseById(String id) {
    if (failingSeedPhraseIds.contains(id)) {
      return Future.error(StateError('seed row delete failed'));
    }
    return super.deleteSeedPhraseById(id);
  }
}

/// A database that appends to a shared log whenever its rows are cleared, so
/// a test can place that step against the vault deletes around it.
class _OrderRecordingDb extends MallowDatabase {
  _OrderRecordingDb(this.log) : super.forTesting(NativeDatabase.memory());

  final List<String> log;

  @override
  Future<void> clearAll() {
    log.add('db.clearAll');
    return super.clearAll();
  }
}

/// Standard BIP-39 test vector — a valid 12-word mnemonic.
const _abandonMnemonic =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// A second valid mnemonic (different from [_abandonMnemonic]) so dedupe and
/// multi-seed-phrase behaviour can be exercised distinctly.
const _legalMnemonic =
    'legal winner thank year wave sausage worth useful legal winner thank yellow';

/// A third BIP-39 test vector, for the cases that need a live seed phrase and
/// two dormant ones at the same time.
const _letterMnemonic =
    'letter advice cage absurd amount doctor acoustic avoid letter advice '
    'cage above';

/// The three-chain key material one social login yields. Each address uses the
/// shape its chain uses (base58 / `0x` / tz1) so the address-keyed lookups
/// behave as they do in production; the stored keys are opaque strings — the
/// repository persists them verbatim and never parses them.
const _socialSolana = SocialChainCredential(
  address: 'So1SociaL11111111111111111111111111111111111',
  storedKey: 'social-solana-stored-key',
);
const _socialEthereum = SocialChainCredential(
  address: '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed',
  storedKey: 'social-ethereum-stored-key',
);
const _socialTezos = SocialChainCredential(
  address: 'tz1SociaL1111111111111111111111111111',
  storedKey: 'social-tezos-stored-key',
);

/// Generates a deterministic, valid base58-encoded 64-byte Solana keypair so
/// imported-key paths can be tested without randomness. Returns the importable
/// key string and the address it normalizes to.
Future<({String key, String address})> _importableKey(int seedByte) async {
  final seed = List<int>.filled(32, seedByte);
  final kp = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: seed);
  final pub = await kp.extractPublicKey();
  final bytes = <int>[...seed, ...pub.bytes];
  return (key: base58encode(bytes), address: kp.address);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MallowDatabase db;
  late _MockFss fss;
  late _MockVault vault;
  late SecureWalletStorage storage;
  late PreferencesService prefs;
  late WalletRepository repo;

  // In-memory backing stores so writes round-trip back to reads.
  final fssStore = <String, String>{};
  final vaultStore = <String, String>{};

  setUp(() async {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    fss = _MockFss();
    vault = _MockVault();
    fssStore.clear();
    vaultStore.clear();
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

    when(
      () => fss.delete(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((inv) async {
      fssStore.remove(inv.namedArguments[#key] as String);
    });

    when(
      () => fss.readAll(
        iOptions: any(named: 'iOptions'),
        aOptions: any(named: 'aOptions'),
      ),
    ).thenAnswer((_) async => Map<String, String>.from(fssStore));

    when(() => vault.read(any(), prompt: any(named: 'prompt'))).thenAnswer(
      (inv) async => vaultStore[inv.positionalArguments[0] as String],
    );

    when(() => vault.write(any(), any())).thenAnswer((inv) async {
      vaultStore[inv.positionalArguments[0] as String] =
          inv.positionalArguments[1] as String;
    });

    when(() => vault.delete(any())).thenAnswer((inv) async {
      vaultStore.remove(inv.positionalArguments[0] as String);
    });

    when(
      () => vault.listKeys(),
    ).thenAnswer((_) async => vaultStore.keys.toList());

    storage = SecureWalletStorage(fss, vault);
    prefs = await PreferencesService.create();
    repo = WalletRepository(db, storage, prefs);
  });

  tearDown(() => db.close());

  // Imports a Solana-only HD wallet at each [indices] entry via the multi-chain
  // picker flow (deriveAccountsForPicker → importAccountsFromPhrase). Lets tests
  // add single-chain HD wallets at specific indices without spelling out the
  // full WalletImportSelection each time.
  Future<List<WalletInfo>> importSolanaAt(
    String spId,
    List<int> indices,
  ) async {
    final maxIndex = indices.reduce((a, b) => a > b ? a : b);
    final picker = await repo.deriveAccountsForPicker(
      spId,
      count: maxIndex + 1,
    );
    final selections = [
      for (final i in indices)
        WalletImportSelection(
          index: i,
          chain: Chain.solana,
          address: picker.accounts[i].solanaStandard,
        ),
    ];
    return repo.importAccountsFromPhrase(spId, selections);
  }

  // Seeds a phrase with a single Solana HD wallet at index 0 (auto-selected) —
  // the pre-multi-chain "starter wallet" shape. Use when a test needs exactly
  // one HD wallet rather than the full multi-chain onboarding account that
  // createSeedPhrase(autoDerive: true) now produces.
  Future<SeedPhraseInfo> seedSingleWallet() async {
    final sp = await repo.createSeedPhrase(_abandonMnemonic, autoDerive: false);
    await importSolanaAt(sp.id, [0]);
    return sp;
  }

  // Runs a social login with the standard three-chain credential set.
  Future<({List<WalletInfo> wallets, bool existed})> addSocial({
    String provider = 'google',
    String name = 'Google Wallet',
    SocialChainCredential? solana,
  }) => repo.addSocialAccount(
    provider: provider,
    name: name,
    solana: solana ?? _socialSolana,
    ethereum: _socialEthereum,
    tezos: _socialTezos,
  );

  // ---------------------------------------------------------------------------
  // createSeedPhrase / createNewSeedPhrase
  // ---------------------------------------------------------------------------

  group('createSeedPhrase', () {
    test('derives the full multi-chain account at index 0, stores mnemonic, '
        'and auto-selects the Solana wallet', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic);

      expect(sp.name, 'Seed 1');

      // The initial wallet is the complete account: one HD wallet per chain
      // (Solana, Ethereum, Tezos) at derivation index 0 — not Solana-only.
      final wallets = await repo.getWalletsForSeedPhrase(sp.id);
      expect(wallets, hasLength(3));
      expect(wallets.map((w) => w.chain).toSet(), {
        'solana',
        'ethereum',
        'tezos',
      });
      expect(wallets.every((w) => w.walletType == WalletType.hd), isTrue);
      expect(wallets.every((w) => w.derivationIndex == 0), isTrue);

      // Solana address matches direct derivation — the repo persisted the
      // right key.
      final solana = wallets.firstWhere((w) => w.chain == 'solana');
      final expectedAddr = await MultiChainDerivation.getSolanaAddressAtIndex(
        _abandonMnemonic,
        0,
      );
      expect(solana.address, expectedAddr);

      // Auto-selects the Solana wallet so the session logs in on Solana.
      final active = await repo.getActiveWallet();
      expect(active?.id, solana.id);

      // Mnemonic persisted under the seed phrase.
      expect(await storage.loadMnemonicForSeedPhrase(sp.id), _abandonMnemonic);
    });

    test('normalizes case and surrounding whitespace before storing', () async {
      final sp = await repo.createSeedPhrase(
        '  ${_abandonMnemonic.toUpperCase()}\n',
      );
      expect(await storage.loadMnemonicForSeedPhrase(sp.id), _abandonMnemonic);
    });

    test('dedupes by mnemonic — re-submitting returns the existing seed '
        'phrase without creating a duplicate', () async {
      final first = await repo.createSeedPhrase(_abandonMnemonic);
      final second = await repo.createSeedPhrase(_abandonMnemonic);

      expect(second.id, first.id);
      expect(await repo.getAllSeedPhrases(), hasLength(1));
    });

    test(
      'dedupe is case-insensitive (matches against normalized form)',
      () async {
        final first = await repo.createSeedPhrase(_abandonMnemonic);
        final second = await repo.createSeedPhrase(
          _abandonMnemonic.toUpperCase(),
        );

        expect(second.id, first.id);
        expect(await repo.getAllSeedPhrases(), hasLength(1));
      },
    );

    test('rejects an invalid mnemonic with ArgumentError', () async {
      expect(
        () => repo.createSeedPhrase('not a real mnemonic at all friend'),
        throwsArgumentError,
      );
      expect(await repo.getAllSeedPhrases(), isEmpty);
    });

    test('autoDerive:false creates the seed phrase but no wallet and no '
        'selection', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );

      expect(await repo.getWalletsForSeedPhrase(sp.id), isEmpty);
      expect(await repo.getActiveWallet(), isNull);
    });

    test('a second distinct seed phrase is named "Seed 2"', () async {
      await repo.createSeedPhrase(_abandonMnemonic);
      final second = await repo.createSeedPhrase(_legalMnemonic);
      expect(second.name, 'Seed 2');
      expect(await repo.getAllSeedPhrases(), hasLength(2));
    });

    test(
      'concurrent identical creates do not produce duplicate seed phrases',
      () async {
        // Exercises the create lock that serializes dedupe-by-mnemonic.
        final results = await Future.wait([
          repo.createSeedPhrase(_abandonMnemonic),
          repo.createSeedPhrase(_abandonMnemonic),
        ]);

        expect(results[0].id, results[1].id);
        expect(await repo.getAllSeedPhrases(), hasLength(1));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // importAccountsFromPhrase
  // ---------------------------------------------------------------------------

  group('importAccountsFromPhrase', () {
    test(
      'imports a wallet at each requested index, each under its own account',
      () async {
        final sp = await seedSingleWallet(); // idx0
        final imported = await importSolanaAt(sp.id, [1, 2]);

        expect(imported.map((w) => w.derivationIndex), [1, 2]);
        expect(await repo.getWalletsForSeedPhrase(sp.id), hasLength(3));

        // Each derivation index is its own seed account (one per index).
        final seedAccounts = (await repo.getAccountViews())
            .where((a) => a.seedPhraseId == sp.id)
            .toList();
        expect(seedAccounts.map((a) => a.derivationIndex).toSet(), {0, 1, 2});
      },
    );

    test('skips selections whose address is already imported', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic); // idx0 imported
      final imported = await importSolanaAt(sp.id, [0, 1]);

      // idx0's Solana address already present → only idx1 is added.
      expect(imported, hasLength(1));
      expect(imported.single.derivationIndex, 1);
    });

    test(
      'returns empty and changes nothing when every selection already exists',
      () async {
        final sp = await repo.createSeedPhrase(_abandonMnemonic);
        final active = await repo.getActiveWallet();

        final imported = await importSolanaAt(sp.id, [0]);

        expect(imported, isEmpty);
        // Selection untouched.
        expect((await repo.getActiveWallet())?.id, active?.id);
      },
    );

    test('auto-selects the first imported Solana wallet only when nothing is '
        'selected', () async {
      // autoDerive:false so there is no selection yet.
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      expect(await repo.getActiveWallet(), isNull);

      final imported = await importSolanaAt(sp.id, [0, 1]);
      expect((await repo.getActiveWallet())?.id, imported.first.id);
    });

    test('does not steal the selection if one already exists', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic); // selects idx0
      final selectedBefore = (await repo.getActiveWallet())!.id;

      await importSolanaAt(sp.id, [1]);

      expect((await repo.getActiveWallet())!.id, selectedBefore);
    });

    // Why: the picker resolves the seed phrase before the user chooses, and a
    // removal committed in between deletes the row *and* its mnemonic. HD rows
    // written under a seed phrase that is gone are wallets that show on screen
    // and cannot sign — and a restore brings them back exactly that way.
    test('refuses a seed phrase the database no longer has', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final picker = await repo.deriveAccountsForPicker(sp.id, count: 1);
      final selection = WalletImportSelection(
        index: 0,
        chain: Chain.solana,
        address: picker.accounts.first.solanaStandard,
      );
      await db.deleteSeedPhraseById(sp.id); // as a concurrent removal would

      await expectLater(
        repo.importAccountsFromPhrase(sp.id, [selection]),
        throwsStateError,
      );
      expect(await repo.getAllWallets(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Standalone wallets (imported key / view-only / ledger / social)
  // ---------------------------------------------------------------------------

  group('addImportedKeyWallet', () {
    test('adds the wallet, persists the private key, and auto-selects when '
        'no selection exists', () async {
      final k = await _importableKey(0x11);
      final wallet = await repo.addImportedKeyWallet(k.key, 'Imported');

      expect(wallet.address, k.address);
      expect(wallet.walletType, WalletType.importedKey);
      expect(wallet.seedPhraseId, isNull);
      expect(await storage.loadPrivateKey(wallet.id), isNotNull);
      expect((await repo.getActiveWallet())?.id, wallet.id);
    });

    test(
      'throws DuplicateWalletException for an already-imported address',
      () async {
        final k = await _importableKey(0x22);
        await repo.addImportedKeyWallet(k.key, 'First');

        expect(
          () => repo.addImportedKeyWallet(k.key, 'Second'),
          throwsA(isA<DuplicateWalletException>()),
        );
        // Only the first wallet remains.
        expect(await repo.getAllWallets(), hasLength(1));
      },
    );

    test(
      'does not change the active selection when one already exists',
      () async {
        final sp = await repo.createSeedPhrase(_abandonMnemonic);
        final hdId = (await repo.getActiveWallet())!.id;

        final k = await _importableKey(0x33);
        await repo.addImportedKeyWallet(k.key, 'Imported');

        // HD wallet stays active — caller must explicitly switch.
        expect((await repo.getActiveWallet())!.id, hdId);
        expect(sp.id, isNotNull);
      },
    );
  });

  group('addViewOnlyWallet', () {
    test('adds a view-only wallet that cannot sign', () async {
      final wallet = await repo.addViewOnlyWallet('SoMeAddr111', 'Watch');
      expect(wallet.walletType, WalletType.viewOnly);
      expect(wallet.canSign, isFalse);
    });

    test('throws DuplicateWalletException for a duplicate address', () async {
      await repo.addViewOnlyWallet('DupAddr', 'A');
      expect(
        () => repo.addViewOnlyWallet('DupAddr', 'B'),
        throwsA(isA<DuplicateWalletException>()),
      );
    });

    test(
      'dedupes an EVM address across checksummed and lowercase casing',
      () async {
        // Why: the same EVM account can arrive EIP-55 checksummed (ENS
        // resolution) or lowercased (pasted). Exact-match dedupe let both
        // through and created duplicate wallet rows — the lookup must match
        // case-insensitively for 0x addresses.
        const checksummed = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
        const lowercased = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';
        await repo.addViewOnlyWallet(checksummed, 'A');
        expect(
          () => repo.addViewOnlyWallet(lowercased, 'B'),
          throwsA(isA<DuplicateWalletException>()),
        );
      },
    );

    test('surfaces DuplicateWalletException when legacy rows already hold the '
        'same EVM address in two casings', () async {
      // Why: before the case-insensitive dedupe landed, exact-match lookup
      // let a checksummed and a lowercased row for one EVM account coexist.
      // Wallets.address has no unique index, so both rows survive the update
      // and the `lower()` lookup matches two of them. The user must still get
      // a duplicate error — not a StateError that permanently breaks adding
      // that address.
      const checksummed = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
      const lowercased = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';
      for (final (i, address) in [checksummed, lowercased].indexed) {
        await db.upsertWalletEntry(
          WalletsCompanion.insert(
            id: 'legacy-dupe-$i',
            address: address,
            name: 'Legacy $i',
            walletType: WalletType.viewOnly.toDbString(),
            createdAt: 0,
          ),
        );
      }

      expect(
        () => repo.addViewOnlyWallet(checksummed, 'C'),
        throwsA(isA<DuplicateWalletException>()),
      );
    });

    test('Solana addresses stay case-sensitive (no false dedupe)', () async {
      // Why: base58 is case-significant — two Solana addresses differing only
      // in case are genuinely distinct and must both import. The EVM-only
      // guard keeps `lower()` from collapsing them.
      await repo.addViewOnlyWallet('SoLAnaAddr', 'A');
      final second = await repo.addViewOnlyWallet('soLanaaddr', 'B');
      expect(second.walletType, WalletType.viewOnly);
    });
  });

  group('addLedgerWallet', () {
    test('stores derivation scheme and device id', () async {
      final wallet = await repo.addLedgerWallet(
        'LedgerAddr',
        'Nano',
        derivationIndex: 3,
        derivationScheme: SolanaDerivationScheme.legacy,
        ledgerDeviceId: 'ble-device-42',
      );

      expect(wallet.walletType, WalletType.ledger);
      expect(wallet.derivationIndex, 3);
      expect(wallet.derivationScheme, SolanaDerivationScheme.legacy);
      expect(await storage.loadLedgerDeviceId(wallet.id), 'ble-device-42');

      // Round-trips through the DB with the scheme preserved.
      final reloaded = await repo.getWalletById(wallet.id);
      expect(reloaded?.derivationScheme, SolanaDerivationScheme.legacy);
    });

    test('does not persist a device id when none is provided', () async {
      final wallet = await repo.addLedgerWallet('LedgerAddr2', 'Nano2');
      expect(await storage.loadLedgerDeviceId(wallet.id), isNull);
    });

    test('throws DuplicateWalletException for a duplicate address', () async {
      await repo.addLedgerWallet('LAddr', 'A');
      expect(
        () => repo.addLedgerWallet('LAddr', 'B'),
        throwsA(isA<DuplicateWalletException>()),
      );
    });

    test('imports each derivation index into its own account', () async {
      // Index 0: standard + legacy rows share one account; index 1 is separate.
      final i0Standard = await repo.addLedgerWallet('L0s', 'Solana');
      final i0Legacy = await repo.addLedgerWallet(
        'L0l',
        'Solana (legacy)',
        derivationScheme: SolanaDerivationScheme.legacy,
      );
      final i1Standard = await repo.addLedgerWallet(
        'L1s',
        'Solana',
        derivationIndex: 1,
      );

      // Same index → same account; different index → different account.
      expect(i0Standard.accountId, i0Legacy.accountId);
      expect(i0Standard.accountId, isNot(i1Standard.accountId));
    });
  });

  group('addSeedVaultWallet', () {
    test('writes a Solana seedVault row with its derivation data', () async {
      final wallet = await repo.addSeedVaultWallet(
        'SeedVaultAddr',
        'Seeker',
        derivationIndex: 2,
        derivationScheme: SolanaDerivationScheme.legacy,
      );

      expect(wallet.walletType, WalletType.seedVault);
      // Seed Vault exposes one signing purpose, so a row is always Solana —
      // the chain is not a caller choice.
      expect(wallet.chain, Chain.solana.toDbString());
      expect(wallet.derivationIndex, 2);
      expect(wallet.derivationScheme, SolanaDerivationScheme.legacy);

      // Round-trips through the DB with the type and scheme preserved: a
      // wrong scheme signs correctly from the wrong address.
      final reloaded = await repo.getWalletById(wallet.id);
      expect(reloaded?.walletType, WalletType.seedVault);
      expect(reloaded?.derivationScheme, SolanaDerivationScheme.legacy);
    });

    // Why: the key never leaves the vault, so there is nothing of ours to
    // persist. A stored secret here would be a copy we could leak and would
    // have to erase on removal — `_deleteWalletData` has no arm for one.
    test('stores no secret for the wallet', () async {
      final wallet = await repo.addSeedVaultWallet('SV-NoSecret', 'Seeker');

      expect(await storage.loadPrivateKey(wallet.id), isNull);
      expect(await storage.loadLedgerDeviceId(wallet.id), isNull);

      // Nothing in secure storage is keyed to this wallet's id. That is the
      // property `_deleteWalletData` relies on: it has no Seed Vault arm, so a
      // per-wallet secret written here would survive removal forever.
      bool keyedToWallet(String id) =>
          [...fssStore.keys, ...vaultStore.keys].any((k) => k.contains(id));
      expect(keyedToWallet(wallet.id), isFalse);

      // Contrast: a Ledger import with a device id *does* write one, so the
      // check above is testing the store, not an empty matcher.
      final ledger = await repo.addLedgerWallet(
        'L-WithDevice',
        'Nano',
        ledgerDeviceId: 'ble-device-1',
      );
      expect(keyedToWallet(ledger.id), isTrue);
    });

    test('creates its own account, separate from a Ledger at the same '
        'derivation index', () async {
      // The reason AccountKind.seedVault exists. Hardware accounts resolve by
      // derivation index alone, so sharing the `hardware` kind would put a
      // Ledger address and a Seed Vault address — two unrelated devices —
      // behind one account card, and removing "the account" would take both.
      final ledger = await repo.addLedgerWallet('L-idx0', 'Nano');
      final seedVault = await repo.addSeedVaultWallet('SV-idx0', 'Seeker');

      expect(seedVault.accountId, isNot(ledger.accountId));

      final views = await repo.getAccountViews();
      final kinds = views.map((a) => a.kind).toSet();
      expect(kinds, containsAll([AccountKind.hardware, AccountKind.seedVault]));
    });

    test('Solana rows at one index share an account; a second index does '
        'not', () async {
      final i0Standard = await repo.addSeedVaultWallet('SV0s', 'Solana');
      final i0Legacy = await repo.addSeedVaultWallet(
        'SV0l',
        'Solana (legacy)',
        derivationScheme: SolanaDerivationScheme.legacy,
      );
      final i1 = await repo.addSeedVaultWallet(
        'SV1s',
        'Solana',
        derivationIndex: 1,
      );

      expect(i0Standard.accountId, i0Legacy.accountId);
      expect(i0Standard.accountId, isNot(i1.accountId));
    });

    // Why: a watch-only row is a placeholder for an address the user does not
    // hold. Importing the same address as a signer is an upgrade, not a
    // collision — refusing it would strand the user with an address they can
    // now sign for and no way to say so.
    test('supersedes a watch-only wallet at the same address', () async {
      final solanaAddress = (await _importableKey(9)).address;
      final watch = await repo.addViewOnlyWallet(solanaAddress, 'Watching');

      final imported = await repo.addSeedVaultWallet(solanaAddress, 'Seeker');

      expect(imported.walletType, WalletType.seedVault);
      expect(await repo.getWalletById(watch.id), isNull);
      final rows = (await repo.getAllWallets())
          .where((w) => w.address == solanaAddress)
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.walletType, WalletType.seedVault);
    });

    test('throws DuplicateWalletException for an address a signer already '
        'holds', () async {
      await repo.addSeedVaultWallet('SV-Dup', 'A');
      expect(
        () => repo.addSeedVaultWallet('SV-Dup', 'B'),
        throwsA(isA<DuplicateWalletException>()),
      );
    });

    // Why: `_deleteWalletData` is a chain of `if`s over the wallet type, not a
    // switch, so a type it does not name is removed silently and correctly
    // only for as long as that type owns nothing. This asserts the premise
    // behind having no Seed Vault arm there.
    test('removal leaves nothing behind', () async {
      final wallet = await repo.addSeedVaultWallet('SV-Remove', 'Seeker');
      final accountId = wallet.accountId;

      await repo.removeWallet(wallet.id);

      expect(await repo.getWalletById(wallet.id), isNull);
      expect(
        (await repo.getAccountViews()).map((a) => a.id),
        isNot(contains(accountId)),
      );
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      expect(graph['wallets'], isEmpty);
      expect(graph['accounts'], isEmpty);
    });

    // Why: the recovery graph is the only copy of the wallet list that
    // survives a database loss. A row whose type does not round-trip comes
    // back as an HD wallet with no seed behind it — visible, and unable to
    // sign.
    test('round-trips through the recovery graph as a seedVault row', () async {
      final wallet = await repo.addSeedVaultWallet(
        'SV-Graph',
        'Seeker',
        derivationIndex: 4,
      );

      final graphJson = await storage.loadAccountGraph();
      expect(graphJson, isNotNull);

      // Wipe the DB but keep the graph — the device-loss shape.
      await db.clearAll();
      expect(await repo.getAllWallets(), isEmpty);

      expect(
        await repo.restoreFromGraph(graphJson!),
        isA<RestoreRestored>(),
        // A Seed Vault row carries no secret of ours, so nothing about it can
        // be "missing" and abort the restore.
      );

      final restored = await repo.getWalletById(wallet.id);
      expect(restored?.walletType, WalletType.seedVault);
      expect(restored?.derivationIndex, 4);
      expect(restored?.chain, Chain.solana.toDbString());
      final account = (await repo.getAccountViews()).single;
      expect(account.kind, AccountKind.seedVault);
    });
  });

  group('addSocialAccount', () {
    test('persists the provider so it survives a reload', () async {
      final result = await repo.addSocialAccount(
        provider: 'google',
        name: 'Google Wallet',
        solana: _socialSolana,
        ethereum: _socialEthereum,
        tezos: _socialTezos,
      );
      for (final wallet in result.wallets) {
        final reloaded = await repo.getWalletById(wallet.id);
        expect(reloaded?.socialProvider, 'google');
        expect(reloaded?.badge, WalletBadge.google);
      }
    });

    // Why: a social account is rebuilt from scratch on every device the
    // identity signs in on — nothing about it carries over except the keys the
    // provider re-derives. Its default avatar must therefore be reproducible
    // from the identity alone; a random seed would give the user a different
    // avatar per install for what they know as one account.
    test('seeds the avatar from the Solana address, so re-importing the same '
        'identity on a fresh install draws the same avatar', () async {
      await addSocial();
      final account = (await repo.getAccountViews()).single;
      expect(account.avatarSeed, _socialSolana.address);

      // A fresh install: empty database, same social identity.
      final otherDb = MallowDatabase.forTesting(NativeDatabase.memory());
      addTearDown(otherDb.close);
      final otherRepo = WalletRepository(otherDb, storage, prefs);
      await otherRepo.addSocialAccount(
        provider: 'google',
        name: 'Google Wallet',
        solana: _socialSolana,
        ethereum: _socialEthereum,
        tezos: _socialTezos,
      );

      expect(
        (await otherRepo.getAccountViews()).single.avatarSeed,
        account.avatarSeed,
      );
    });

    // Why: one social login is one identity across three chains, and each row
    // owns the key it signs with. The account must therefore be built exactly
    // once per identity (a re-login completes it, never forks it), and no row
    // may exist without its key — a keyless signing row dead-ends the user at
    // the signature step.
    test('creates one social account with a keyed row per chain', () async {
      final result = await addSocial();

      expect(result.existed, isFalse);
      expect(result.wallets, hasLength(3));

      final accounts = await repo.getAccountViews();
      expect(accounts, hasLength(1));
      expect(accounts.single.kind, AccountKind.social);
      // Account label comes from the global counter, not the row label.
      expect(accounts.single.name, 'Account 01');
      expect(accounts.single.typeBadge, WalletBadge.google);

      final rows = await repo.getAllWallets();
      expect(rows, hasLength(3));
      expect(
        {for (final w in rows) w.chain: w.address},
        {
          'solana': _socialSolana.address,
          'ethereum': _socialEthereum.address,
          'tezos': _socialTezos.address,
        },
      );
      expect(rows.every((w) => w.walletType == WalletType.social), isTrue);
      expect(rows.every((w) => w.socialProvider == 'google'), isTrue);
      expect(rows.every((w) => w.name == 'Google Wallet'), isTrue);
      expect(rows.every((w) => w.accountId == accounts.single.id), isTrue);
      expect(rows.every((w) => w.badge == WalletBadge.google), isTrue);

      // Each row's key is retrievable under its own row id — that is what the
      // imported-key signing paths load.
      for (final w in rows) {
        expect(
          await storage.loadPrivateKey(w.id),
          switch (w.chain) {
            'solana' => _socialSolana.storedKey,
            'ethereum' => _socialEthereum.storedKey,
            _ => _socialTezos.storedKey,
          },
          reason: '${w.chain} row must own its key',
        );
      }

      // Onboarding case: the Solana row becomes the active wallet.
      expect((await repo.getActiveWallet())?.address, _socialSolana.address);
    });

    test('records the provider badge for an Apple login', () async {
      final result = await addSocial(provider: 'apple', name: 'Apple Wallet');

      final reloaded = await repo.getWalletById(result.wallets.first.id);
      expect(reloaded?.socialProvider, 'apple');
      expect(reloaded?.badge, WalletBadge.apple);
    });

    test('re-login is idempotent — same rows, keys re-stored', () async {
      final first = await addSocial();

      // Simulate the restore case: the DB survives, the keystore does not. The
      // re-login must make the existing rows signable again rather than adding
      // a second account for the same identity.
      for (final w in first.wallets) {
        await storage.deletePrivateKey(w.id);
      }

      final second = await addSocial();

      expect(second.existed, isTrue);
      expect(
        second.wallets.map((w) => w.id).toSet(),
        first.wallets.map((w) => w.id).toSet(),
      );
      expect(await repo.getAllWallets(), hasLength(3));
      expect(await repo.getAccountViews(), hasLength(1));
      for (final w in second.wallets) {
        expect(await storage.loadPrivateKey(w.id), isNotNull);
      }
    });

    test('completes a partial account — missing chain rows join the existing '
        'account', () async {
      final first = await addSocial();
      final solana = first.wallets.firstWhere((w) => w.chain == 'solana');
      for (final w in first.wallets.where((w) => w.chain != 'solana')) {
        await repo.removeWallet(w.id);
      }
      expect(await repo.getAllWallets(), hasLength(1));

      final second = await addSocial();

      expect(second.existed, isTrue);
      final rows = await repo.getAllWallets();
      expect(rows, hasLength(3));
      expect(rows.map((w) => w.chain).toSet(), {'solana', 'ethereum', 'tezos'});
      // Same account as the surviving Solana row, and no second one.
      expect(rows.map((w) => w.accountId).toSet(), {solana.accountId});
      expect(await repo.getAccountViews(), hasLength(1));
      expect(
        rows.firstWhere((w) => w.chain == 'solana').id,
        solana.id,
        reason: 'the pre-existing row is reused, not replaced',
      );
    });

    test('re-parents chain rows stranded under a dead account', () async {
      // Why: [removeWallet] deletes exactly one row and does no account-level
      // cleanup, so dropping the Solana row alone leaves the account without
      // the row that identifies the identity — the next login mints a *new*
      // account. Reusing the surviving Ethereum/Tezos rows without re-parenting
      // them keeps them under the dead account, where getWalletsForAccount
      // cannot see them: the account card shows a Solana-only social account
      // and the send gates lose two chains.
      final first = await addSocial();
      final deadAccountId = first.wallets.first.accountId!;
      final solana = first.wallets.firstWhere((w) => w.chain == 'solana');
      final tezos = first.wallets.firstWhere((w) => w.chain == 'tezos');
      await repo.removeWallet(solana.id);

      final second = await addSocial();

      expect(
        second.existed,
        isFalse,
        reason: 'the row identifying the account is gone',
      );
      final accountId = second.wallets
          .firstWhere((w) => w.chain == 'solana')
          .accountId!;
      expect(accountId, isNot(deadAccountId));

      // The returned wallets must report the corrected account — callers write
      // the account card straight from them.
      expect(second.wallets.map((w) => w.accountId).toSet(), {accountId});

      final rows = await repo.getWalletsForAccount(accountId);
      expect(rows.map((w) => w.chain).toSet(), {'solana', 'ethereum', 'tezos'});
      expect(
        rows.map((w) => w.id),
        contains(tezos.id),
        reason: 'the pre-existing row is re-parented, not duplicated',
      );
      expect(await repo.getAllWallets(), hasLength(3));
      expect(await repo.getWalletsForAccount(deadAccountId), isEmpty);
    });

    test('supersedes a watch-only wallet at one of the addresses', () async {
      final watch = await repo.addViewOnlyWallet(_socialTezos.address, 'Watch');

      final result = await addSocial();

      expect(result.existed, isFalse);
      final rows = await repo.getAllWallets();
      expect(rows, hasLength(3));
      expect(rows.map((w) => w.id), isNot(contains(watch.id)));
      final tezos = rows.firstWhere((w) => w.chain == 'tezos');
      expect(tezos.walletType, WalletType.social);
      expect(await storage.loadPrivateKey(tezos.id), _socialTezos.storedKey);
      // The emptied watch-only account is not left dangling.
      final accounts = await repo.getAccountViews();
      expect(accounts, hasLength(1));
      expect(accounts.single.kind, AccountKind.social);
    });

    test('throws when another signing wallet type holds one of the '
        'addresses', () async {
      // An HD / imported-key / Ledger row is someone else's key custody. The
      // social login must not adopt it — that would re-point a wallet the user
      // controls elsewhere at a key we just minted.
      final k = await _importableKey(0x71);
      await repo.addImportedKeyWallet(k.key, 'Imported');

      await expectLater(
        addSocial(
          solana: SocialChainCredential(
            address: k.address,
            storedKey: 'social-solana-stored-key',
          ),
        ),
        throwsA(isA<DuplicateWalletException>()),
      );
      expect(await repo.getAllWallets(), hasLength(1));
    });

    test(
      'a collision on a later chain aborts before anything is written',
      () async {
        // Duplicate detection runs across all three addresses up front; the EVM
        // arm matches case-insensitively, so a lowercased row still collides
        // with the checksummed address the login derives. Without that up-front
        // pass, a third-chain collision would leave a half-built account and an
        // orphaned Solana row behind.
        await db.upsertWalletEntry(
          WalletsCompanion.insert(
            id: 'hd-evm',
            address: _socialEthereum.address.toLowerCase(),
            name: 'Ethereum',
            walletType: WalletType.hd.toDbString(),
            createdAt: 0,
          ),
        );

        await expectLater(
          addSocial(),
          throwsA(isA<DuplicateWalletException>()),
        );

        expect((await repo.getAllWallets()).map((w) => w.id), ['hd-evm']);
        expect(await repo.getAccountViews(), isEmpty);
        expect(await storage.loadSelectedWalletId(), isNull);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Watch-only precedence: a signing import replaces a watch-only wallet of the
  // same address, but a real signer already there is still a duplicate.
  // ---------------------------------------------------------------------------

  group('signing import supersedes a watch-only wallet', () {
    // A view-only Solana address matching the imported-key vector for byte 0x11,
    // so the two collide on the same address.
    Future<String> watchAt(int seedByte) async {
      final k = await _importableKey(seedByte);
      await repo.addViewOnlyWallet(k.address, 'Watch');
      return k.address;
    }

    test('addImportedKeyWallet deletes the watch-only wallet and its account, '
        'then imports the signer', () async {
      final k = await _importableKey(0x11);
      await repo.addViewOnlyWallet(k.address, 'Watch');
      final watchAccounts = await repo.getAccountViews();
      expect(watchAccounts, hasLength(1));
      expect(watchAccounts.single.kind, AccountKind.viewOnly);

      final signer = await repo.addImportedKeyWallet(k.key, 'Imported');

      // Exactly one wallet remains — the signer — at the same address, and it
      // can sign. The watch-only account is gone (not left dangling/empty).
      final wallets = await repo.getAllWallets();
      expect(wallets, hasLength(1));
      expect(wallets.single.id, signer.id);
      expect(wallets.single.address, k.address);
      expect(signer.walletType, WalletType.importedKey);
      expect(signer.canSign, isTrue);

      final accounts = await repo.getAccountViews();
      expect(accounts, hasLength(1));
      expect(accounts.single.kind, AccountKind.privateKey);
    });

    test(
      'addLedgerWallet replaces a watch-only wallet at the same address',
      () async {
        final addr = await watchAt(0x12);

        final signer = await repo.addLedgerWallet(addr, 'Nano');

        final wallets = await repo.getAllWallets();
        expect(wallets, hasLength(1));
        expect(wallets.single.id, signer.id);
        expect(signer.walletType, WalletType.ledger);
      },
    );

    test(
      'addSocialAccount replaces a watch-only wallet at the same address',
      () async {
        final addr = await watchAt(0x13);

        final result = await addSocial(
          provider: 'apple',
          name: 'Apple Wallet',
          solana: SocialChainCredential(
            address: addr,
            storedKey: _socialSolana.storedKey,
          ),
        );

        // The watch-only row is gone; only the three social chain rows remain,
        // with the social signer now owning the previously-watched address.
        final wallets = await repo.getAllWallets();
        expect(wallets, hasLength(3));
        final signer = wallets.singleWhere((w) => w.address == addr);
        expect(signer.walletType, WalletType.social);
        expect(result.wallets.map((w) => w.id), contains(signer.id));
      },
    );

    test('importAccountsFromPhrase upgrades a watch-only wallet at the derived '
        'address instead of skipping it', () async {
      // Watch the seed's index-0 Solana address before importing the phrase.
      final addr0 = await MultiChainDerivation.getSolanaAddressAtIndex(
        _abandonMnemonic,
        0,
      );
      await repo.addViewOnlyWallet(addr0, 'Watch');

      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final imported = await importSolanaAt(sp.id, [0]);

      // The address is imported as an HD signer (not skipped as a duplicate),
      // and the watch-only account was cleared.
      expect(imported, hasLength(1));
      expect(imported.single.address, addr0);
      expect(imported.single.walletType, WalletType.hd);

      final wallets = await repo.getAllWallets();
      expect(wallets.where((w) => w.address == addr0), hasLength(1));
      expect(
        (await repo.getAccountViews()).where(
          (a) => a.kind == AccountKind.viewOnly,
        ),
        isEmpty,
      );
    });

    test('re-selects a replacement when the superseded watch-only wallet was '
        'the active selection', () async {
      final k = await _importableKey(0x14);
      final watch = await repo.addViewOnlyWallet(k.address, 'Watch');
      // The lone watch-only wallet auto-selected on add.
      expect((await repo.getActiveWallet())?.id, watch.id);

      await repo.addImportedKeyWallet(k.key, 'Imported');

      // The dangling selection is not left pointing at the deleted wallet.
      expect((await repo.getActiveWallet())?.id, isNot(watch.id));
    });

    // The prune is the commit point of the view-only removal every one of
    // these imports depends on: a keystore that refuses it removed nothing, so
    // the import must add nothing either. Otherwise the address ends up with a
    // watch-only row and a signing row — the state every import guard forbids
    // — and the new secret is in the vault behind a graph that never named it.
    test('a refused graph prune aborts an imported-key import', () async {
      final k = await _importableKey(0x16);
      final watch = await repo.addViewOnlyWallet(k.address, 'Watch');
      when(
        () => vault.write('mallow_account_graph', any()),
      ).thenThrow(PlatformException(code: 'write_failed'));

      await expectLater(
        repo.addImportedKeyWallet(k.key, 'Imported'),
        throwsA(isA<GraphSyncException>()),
      );

      expect((await repo.getAllWallets()).map((w) => w.id), [watch.id]);
      expect(
        vaultStore.keys.where((key) => key.startsWith('mallow_pk_')),
        isEmpty,
      );
    });

    test('a refused graph prune aborts a Ledger import', () async {
      final addr = await watchAt(0x17);
      final before = (await repo.getAllWallets()).single;
      when(
        () => vault.write('mallow_account_graph', any()),
      ).thenThrow(PlatformException(code: 'write_failed'));

      await expectLater(
        repo.addLedgerWallet(addr, 'Nano', ledgerDeviceId: 'dev-1'),
        throwsA(isA<GraphSyncException>()),
      );

      expect((await repo.getAllWallets()).map((w) => w.id), [before.id]);
      expect(await storage.loadLedgerDeviceId(before.id), isNull);
    });

    test('a refused graph prune aborts an HD import', () async {
      final addr0 = await MultiChainDerivation.getSolanaAddressAtIndex(
        _abandonMnemonic,
        0,
      );
      final watch = await repo.addViewOnlyWallet(addr0, 'Watch');
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      when(
        () => vault.write('mallow_account_graph', any()),
      ).thenThrow(PlatformException(code: 'write_failed'));

      await expectLater(
        repo.importAccountsFromPhrase(sp.id, [
          WalletImportSelection(index: 0, chain: Chain.solana, address: addr0),
        ]),
        throwsA(isA<GraphSyncException>()),
      );

      final wallets = await repo.getAllWallets();
      expect(wallets.map((w) => w.id), [watch.id]);
      expect(wallets.single.walletType, WalletType.viewOnly);
    });

    test('still throws for a duplicate of a real (signing) wallet', () async {
      final k = await _importableKey(0x15);
      await repo.addImportedKeyWallet(k.key, 'First');

      // A second signing import of the same address is a genuine duplicate —
      // watch-only precedence must not weaken duplicate detection for signers.
      expect(
        () => repo.addLedgerWallet(k.address, 'Second'),
        throwsA(isA<DuplicateWalletException>()),
      );
      expect(await repo.getAllWallets(), hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // setActiveWallet / getActiveSelection
  // ---------------------------------------------------------------------------

  group('setActiveWallet', () {
    test('persists the new active wallet', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic);
      final second = (await importSolanaAt(sp.id, [1])).single;

      final result = await repo.setActiveWallet(second.id);

      expect(result.id, second.id);
      expect((await repo.getActiveWallet())?.id, second.id);
    });

    test('throws StateError for an unknown wallet id', () async {
      expect(() => repo.setActiveWallet('nope'), throwsStateError);
    });
  });

  group('getActiveSelection', () {
    test('returns null when no wallet is selected', () async {
      expect(await repo.getActiveSelection(), isNull);
    });

    test(
      'returns null when the selected id no longer maps to a wallet',
      () async {
        await storage.storeSelectedWalletId('ghost-id');
        expect(await repo.getActiveSelection(), isNull);
        expect(await repo.getActiveWallet(), isNull);
      },
    );

    test('returns the owning account paired with the active wallet', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic);
      final activeId = (await repo.getActiveWallet())!.id;

      final selection = await repo.getActiveSelection();
      expect(selection, isNotNull);
      final (account, wallet) = selection!;
      expect(wallet.id, activeId);
      // Under the Accounts model the account has its own UUID and groups the
      // seed phrase's wallets at derivation index 0.
      expect(account.kind, AccountKind.seed);
      expect(account.seedPhraseId, sp.id);
      expect(account.derivationIndex, 0);
      expect(account.wallets.map((w) => w.id), contains(activeId));
    });
  });

  // ---------------------------------------------------------------------------
  // getAccountViews
  // ---------------------------------------------------------------------------

  group('getAccountViews', () {
    test(
      'returns one account per derivation index and one per standalone wallet',
      () async {
        // seedSingleWallet derives index 0; importSolanaAt adds index 1.
        // Under the Accounts model each index is its own account (not one
        // account per seed phrase), so this seed phrase yields TWO accounts.
        final sp = await seedSingleWallet();
        final idx0 = (await repo.getActiveWallet())!.id;
        final idx1 = (await importSolanaAt(sp.id, [1])).single.id;
        final view = await repo.addViewOnlyWallet('Watch1', 'Watch');

        final accounts = await repo.getAccountViews();
        expect(accounts, hasLength(3));

        final seedAccounts = accounts
            .where((a) => a.seedPhraseId == sp.id)
            .toList();
        expect(seedAccounts, hasLength(2));
        expect(seedAccounts.map((a) => a.derivationIndex).toSet(), {0, 1});
        // Each derivation-index account holds exactly its one wallet.
        final account0 = seedAccounts.firstWhere((a) => a.derivationIndex == 0);
        final account1 = seedAccounts.firstWhere((a) => a.derivationIndex == 1);
        expect(account0.wallets.single.id, idx0);
        expect(account1.wallets.single.id, idx1);

        // The view-only wallet is its own standalone account.
        final standalone = accounts.firstWhere(
          (a) => a.kind == AccountKind.viewOnly,
        );
        expect(standalone.wallets.single.id, view.id);
        // Every account carries a stable, non-empty avatar seed.
        expect(accounts.every((a) => a.avatarSeed.isNotEmpty), isTrue);
      },
    );

    test('returns empty when there are no wallets', () async {
      expect(await repo.getAccountViews(), isEmpty);
    });
  });

  group('getWalletsForAccount', () {
    // Why: social key recovery is handed only an account id and must resolve
    // that account's provider and Solana address from its rows. Returning a
    // neighbouring account's rows would send the user through an OAuth login
    // for the wrong identity, so scoping is the property under test.
    test('returns only the rows of the named account', () async {
      final social = await addSocial();
      await seedSingleWallet();

      final accounts = await repo.getAccountViews();
      final socialAccountId = accounts
          .firstWhere((a) => a.kind == AccountKind.social)
          .id;

      final rows = await repo.getWalletsForAccount(socialAccountId);
      expect(
        rows.map((w) => w.id).toSet(),
        social.wallets.map((w) => w.id).toSet(),
      );
      expect(rows.every((w) => w.socialProvider == 'google'), isTrue);
    });

    test('returns empty for an unknown account id', () async {
      expect(await repo.getWalletsForAccount('no-such-account'), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // deriveAddressesForPicker
  // ---------------------------------------------------------------------------

  group('deriveAddressesForPicker', () {
    test(
      'marks already-imported addresses and returns the requested range',
      () async {
        final sp = await repo.createSeedPhrase(
          _abandonMnemonic,
        ); // idx0 imported

        final picks = await repo.deriveAddressesForPicker(sp.id, count: 3);

        expect(picks.map((p) => p.index), [0, 1, 2]);
        expect(picks[0].alreadyImported, isTrue); // idx0 was imported
        expect(picks[1].alreadyImported, isFalse);
        expect(picks[2].alreadyImported, isFalse);

        // Derived addresses are correct.
        final expected0 = await MultiChainDerivation.getSolanaAddressAtIndex(
          _abandonMnemonic,
          0,
        );
        expect(picks[0].address, expected0);
      },
    );

    test('honours a non-zero startIndex', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final picks = await repo.deriveAddressesForPicker(
        sp.id,
        count: 2,
        startIndex: 5,
      );
      expect(picks.map((p) => p.index), [5, 6]);
    });

    test('throws StateError when the seed phrase has no mnemonic', () async {
      expect(() => repo.deriveAddressesForPicker('missing'), throwsStateError);
    });
  });

  group('deriveAccountsForPicker', () {
    test('surfaces the stored account name for already-imported indices so a '
        'user-edited name shows in the picker', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      await importSolanaAt(sp.id, [0]); // creates the index-0 seed account

      final account = (await repo.getAccountViews()).firstWhere(
        (a) => a.seedPhraseId == sp.id && a.derivationIndex == 0,
      );
      await repo.renameAccount(account.id, 'My Trading Wallet');

      final picker = await repo.deriveAccountsForPicker(sp.id, count: 2);

      // Imported index carries its (edited) name; an un-imported index has no
      // entry, so the picker falls back to the generic `Account NN`.
      expect(picker.importedNamesByIndex[0], 'My Trading Wallet');
      expect(picker.importedNamesByIndex.containsKey(1), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // reorderWalletsInGroup / renameWallet
  // ---------------------------------------------------------------------------

  test(
    'reorderWalletsInGroup reassigns sortIndex 0..n in given order',
    () async {
      final sp = await seedSingleWallet();
      final w0 = (await repo.getWalletsForSeedPhrase(sp.id)).single;
      final w1 = (await importSolanaAt(sp.id, [1])).single;

      await repo.reorderWalletsInGroup([w1.id, w0.id]);

      final reordered = await repo.getWalletsForSeedPhrase(sp.id);
      // getWalletsForSeedPhrase returns rows ordered by sortIndex.
      expect(reordered.map((w) => w.id), [w1.id, w0.id]);
      expect(reordered[0].sortIndex, 0);
      expect(reordered[1].sortIndex, 1);
    },
  );

  test('renameWallet updates the persisted name', () async {
    final k = await _importableKey(0x44);
    final wallet = await repo.addImportedKeyWallet(k.key, 'Old');

    await repo.renameWallet(wallet.id, 'New Name');

    expect((await repo.getWalletById(wallet.id))?.name, 'New Name');
  });

  // ---------------------------------------------------------------------------
  // removeWallet
  // ---------------------------------------------------------------------------

  group('removeWallet', () {
    test('returns null for an unknown wallet id', () async {
      expect(await repo.removeWallet('nope'), isNull);
    });

    test('removing a non-active wallet keeps the current selection', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic); // active = idx0
      final activeId = (await repo.getActiveWallet())!.id;
      final extra = (await importSolanaAt(sp.id, [1])).single;

      final replacement = await repo.removeWallet(extra.id);

      expect(replacement, activeId);
      expect((await repo.getActiveWallet())!.id, activeId);
    });

    test('removing the active wallet selects a remaining wallet', () async {
      final sp = await seedSingleWallet();
      final active = (await repo.getActiveWallet())!;
      final other = (await importSolanaAt(sp.id, [1])).single;

      final replacement = await repo.removeWallet(active.id);

      expect(replacement, isNotNull);
      expect(replacement, other.id);
      expect((await repo.getActiveWallet())!.id, other.id);
    });

    test('removing the active wallet prefers a Solana replacement over an '
        'earlier non-Solana row', () async {
      // Why: Solana signing resolves its keypair from the *global selection*
      // ([WalletInfo.bindsGlobalSigner]) rather than an explicit wallet id, so
      // a Tezos/Ethereum row left as the selection makes getPublicKey() and
      // signMessage() throw. Picking by sortIndex alone lands on the social
      // Tezos row here, which is exactly that state.
      final social = await addSocial();
      final k = await _importableKey(0x44);
      final imported = await repo.addImportedKeyWallet(k.key, 'Sol');
      final active = social.wallets.firstWhere((w) => w.chain == 'solana');
      expect((await repo.getActiveWallet())!.id, active.id);

      final replacement = await repo.removeWallet(active.id);

      expect(replacement, imported.id);
      final selected = (await repo.getActiveWallet())!;
      expect(selected.bindsGlobalSigner, isTrue);
    });

    test('falls back to the first remaining wallet when no Solana row is '
        'left', () async {
      // The preference is best-effort: a session with no Solana wallet at all
      // must still keep a selection rather than clear it.
      final social = await addSocial();
      final active = social.wallets.firstWhere((w) => w.chain == 'solana');

      final replacement = await repo.removeWallet(active.id);

      expect(replacement, isNotNull);
      expect((await repo.getActiveWallet())!.id, replacement);
      expect((await repo.getActiveWallet())!.bindsGlobalSigner, isFalse);
    });

    test(
      'removing the last wallet clears the selection and returns null',
      () async {
        final k = await _importableKey(0x55);
        final wallet = await repo.addImportedKeyWallet(k.key, 'Solo');

        final replacement = await repo.removeWallet(wallet.id);

        expect(replacement, isNull);
        expect(await repo.getActiveWallet(), isNull);
        expect(await repo.hasAnyWallets(), isFalse);
      },
    );

    test('removing the last HD wallet of a seed phrase deletes the seed '
        'phrase and its mnemonic', () async {
      final sp = await seedSingleWallet();
      final only = (await repo.getWalletsForSeedPhrase(sp.id)).single;

      await repo.removeWallet(only.id);

      expect(await repo.getAllSeedPhrases(), isEmpty);
      expect(await storage.loadMnemonicForSeedPhrase(sp.id), isNull);
    });

    test(
      'removing one of several HD wallets keeps the seed phrase + mnemonic',
      () async {
        final sp = await seedSingleWallet();
        final first = (await repo.getWalletsForSeedPhrase(sp.id)).single;
        await importSolanaAt(sp.id, [1]);

        await repo.removeWallet(first.id);

        expect(await repo.getAllSeedPhrases(), hasLength(1));
        expect(
          await storage.loadMnemonicForSeedPhrase(sp.id),
          _abandonMnemonic,
        );
      },
    );

    test(
      'removing an imported-key wallet deletes its stored private key',
      () async {
        final k = await _importableKey(0x66);
        final wallet = await repo.addImportedKeyWallet(k.key, 'Imp');
        expect(await storage.loadPrivateKey(wallet.id), isNotNull);

        await repo.removeWallet(wallet.id);

        expect(await storage.loadPrivateKey(wallet.id), isNull);
      },
    );

    test('removing a wallet deletes its tracked pending EVM transactions '
        'and leaves other wallets alone', () async {
      // Why: a pending row carries recipient/value/calldata and drives an
      // actionable Pending cell. Surviving permanent deletion, it resurfaces on
      // re-import of the same address and a Speed Up tapped there re-signs the
      // stale stored payload. Rows are keyed by the lowercased address, so the
      // cleanup must normalize the (possibly checksummed) wallet address.
      const checksummed = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
      const lowercased = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';
      final wallet = await repo.addViewOnlyWallet(checksummed, 'Evm');
      for (final address in [lowercased, '0xother']) {
        await db.upsertPendingEvmTransaction(
          PendingEvmTransactionsCompanion.insert(
            walletAddress: address,
            nonce: 3,
            chainId: 1,
            kind: 'send',
            status: 'pending',
            toAddress: '0xbbbb',
            valueWei: '1',
            data: '',
            gasLimit: 21000,
            metadataJson: '{"title":"Send"}',
            candidatesJson: '[]',
            createdAt: 0,
          ),
        );
      }

      await repo.removeWallet(wallet.id);

      expect(
        (await db.getPendingEvmTransactions()).map((r) => r.walletAddress),
        ['0xother'],
      );
    });

    test('removing a social wallet deletes its stored private key', () async {
      // Why: a social row owns a local signing key now, so the cleanup that
      // used to cover only imported-key wallets must cover it too — otherwise
      // deleting the wallet leaves a live key in the keystore.
      final social = await addSocial();
      final row = social.wallets.first;
      expect(await storage.loadPrivateKey(row.id), isNotNull);

      await repo.removeWallet(row.id);

      expect(await storage.loadPrivateKey(row.id), isNull);
    });

    test('removing a ledger wallet deletes its stored device id', () async {
      final wallet = await repo.addLedgerWallet(
        'LedDel',
        'Nano',
        ledgerDeviceId: 'dev-1',
      );
      expect(await storage.loadLedgerDeviceId(wallet.id), 'dev-1');

      await repo.removeWallet(wallet.id);

      expect(await storage.loadLedgerDeviceId(wallet.id), isNull);
    });

    test('removeWallets deletes a seed phrase whose wallets all go in the '
        'same call', () async {
      // Why: "last wallet of its seed phrase" has to be decided across the
      // whole removal set. Decided per wallet it reads "not the last" for
      // every one of them, stranding the seed phrase row — and its mnemonic —
      // behind wallets that no longer exist.
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final wallets = await importSolanaAt(sp.id, [0, 1]);
      final k = await _importableKey(0x71);
      final keeper = await repo.addImportedKeyWallet(k.key, 'Keeper');

      final replacement = await repo.removeWallets(wallets.map((w) => w.id));

      expect(replacement, keeper.id);
      expect(await repo.getAllSeedPhrases(), isEmpty);
      expect(await storage.loadMnemonicForSeedPhrase(sp.id), isNull);
      expect(vaultStore.containsKey('mallow_mnemonic_seed_${sp.id}'), isFalse);
      // The seed's account rows go with it. Nothing cascades in the database,
      // so an account left behind points at a seed phrase that is gone and
      // shows as a card holding no wallets — one the next sync writes into the
      // graph and a restore faithfully re-creates.
      final accounts = await repo.getAccountViews();
      expect(accounts, hasLength(1));
      expect(accounts.single.wallets.map((w) => w.id), [keeper.id]);
    });

    // Why: a row whose secret is already gone is the worse half of the pair —
    // the wallet still shows and can no longer sign, the next plain sync
    // writes it back into the graph, and the restore pre-check then counts it
    // as a missing imported key and aborts every restore from then on. A key
    // whose row is gone is only an orphan the wipe sweep collects.
    test(
      'a failed wallet-row delete leaves the signing key in place',
      () async {
        final failingDb = _DeleteFailingDb();
        addTearDown(failingDb.close);
        final failingRepo = WalletRepository(failingDb, storage, prefs);
        final k = await _importableKey(0x7a);
        final wallet = await failingRepo.addImportedKeyWallet(k.key, 'Imp');
        expect(await storage.loadPrivateKey(wallet.id), isNotNull);
        failingDb.failingWalletIds.add(wallet.id);

        await expectLater(
          failingRepo.removeWallet(wallet.id),
          throwsA(isA<StateError>()),
        );

        expect(await storage.loadPrivateKey(wallet.id), isNotNull);
        expect(await failingRepo.getWalletById(wallet.id), isNotNull);
      },
    );

    // The seed branch runs rows-then-secret for the same reason, and this is
    // the half that cannot be undone: a mnemonic erased under a seed row that
    // is still there leaves every wallet it derives unable to sign, and a
    // restore faithfully brings them back that way.
    test(
      'a failed seed-phrase row delete leaves the mnemonic in place',
      () async {
        final failingDb = _DeleteFailingDb();
        addTearDown(failingDb.close);
        final failingRepo = WalletRepository(failingDb, storage, prefs);
        final sp = await failingRepo.createSeedPhrase(_abandonMnemonic);
        final wallets = await failingRepo.getAllWallets();
        failingDb.failingSeedPhraseIds.add(sp.id);

        await expectLater(
          failingRepo.removeWallets(wallets.map((w) => w.id)),
          throwsA(isA<StateError>()),
        );

        expect(
          await storage.loadMnemonicForSeedPhrase(sp.id),
          _abandonMnemonic,
        );
      },
    );

    // The mirror case: the secret delete comes *after* the graph prune and the
    // row delete, so a vault that refuses it (iOS reports `delete_failed` for
    // a Keychain status it cannot classify) leaves an orphan the wipe sweep
    // collects — nothing indexes it any more. Failing the removal over that
    // would tell the user nothing was removed about a removal already done,
    // and abandon the deletes queued behind it.
    test('a failing mnemonic delete does not fail the removal', () async {
      final sp = await seedSingleWallet();
      final wallet = (await repo.getAllWallets()).single;
      final k = await _importableKey(0x7d);
      final keeper = await repo.addImportedKeyWallet(k.key, 'Keeper');
      when(
        () => vault.delete('mallow_mnemonic_seed_${sp.id}'),
      ).thenThrow(PlatformException(code: 'delete_failed'));

      expect(await repo.removeWallet(wallet.id), keeper.id);

      expect(await repo.getWalletById(wallet.id), isNull);
      expect(await repo.getAllSeedPhrases(), isEmpty);
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      expect(
        (graph['seedPhrases'] as List<dynamic>).map(
          (e) => (e as Map<String, dynamic>)['id'],
        ),
        isNot(contains(sp.id)),
      );
    });

    test('removeWallets keeps a seed phrase when a sibling stays', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final wallets = await importSolanaAt(sp.id, [0, 1, 2]);

      await repo.removeWallets([wallets[0].id, wallets[1].id]);

      expect(await repo.getAllSeedPhrases(), hasLength(1));
      expect(await storage.loadMnemonicForSeedPhrase(sp.id), _abandonMnemonic);
      expect((await repo.getAllWallets()).map((w) => w.id), [wallets[2].id]);
    });

    test('removeWallets ignores ids with no row and returns null for an all '
        'unknown set', () async {
      expect(await repo.removeWallets(['nope', 'also-nope']), isNull);
      expect(await repo.removeWallets(const []), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // resetAll
  // ---------------------------------------------------------------------------

  test('resetAll removes every wallet and seed phrase', () async {
    final sp = await repo.createSeedPhrase(_abandonMnemonic);
    await importSolanaAt(sp.id, [1]);
    final k = await _importableKey(0x77);
    await repo.addImportedKeyWallet(k.key, 'Imp');
    // A pending EVM row is durable user state, but it only has meaning while
    // its wallet exists — a full reset must not leave it behind for the next
    // import of the same address to pick up as an actionable Pending cell.
    await db.upsertPendingEvmTransaction(
      PendingEvmTransactionsCompanion.insert(
        walletAddress: '0xaaaa',
        nonce: 1,
        chainId: 1,
        kind: 'send',
        status: 'pending',
        toAddress: '0xbbbb',
        valueWei: '1',
        data: '',
        gasLimit: 21000,
        metadataJson: '{"title":"Send"}',
        candidatesJson: '[]',
        createdAt: 0,
      ),
    );

    await repo.resetAll();

    expect(await repo.getAllWallets(), isEmpty);
    expect(await repo.getAllSeedPhrases(), isEmpty);
    expect(await repo.hasAnyWallets(), isFalse);
    expect(await db.getPendingEvmTransactions(), isEmpty);
  });

  test('resetAll wipes stored preferences', () async {
    // "Reset app" reads as a factory reset. Recent send recipients are the
    // sharp edge: left behind, the previous seed phrase's counterparties are
    // still suggested to whoever re-onboards on this device.
    await prefs.saveRecentSendAddress('So1anaRecipient111');
    await prefs.setExplorer('solanafm');

    await repo.resetAll();

    expect(prefs.recentSendAddresses, isEmpty);
    expect(prefs.explorer, 'solscan');
  });

  // Why the order matters: a reset the user (or the OS) ends between the two
  // steps used to leave wallet rows on disk with their secrets already erased.
  // The next boot has wallets, so the eager backfill writes a recovery graph
  // naming secrets that are gone — and every restore from then on aborts on
  // entries nothing can satisfy.
  test('resetAll clears the rows before it erases any secret', () async {
    final log = <String>[];
    final orderedDb = _OrderRecordingDb(log);
    addTearDown(orderedDb.close);
    final orderedRepo = WalletRepository(orderedDb, storage, prefs);
    await orderedRepo.createSeedPhrase(_abandonMnemonic);
    when(() => vault.delete(any())).thenAnswer((inv) async {
      log.add('vault.delete');
      vaultStore.remove(inv.positionalArguments[0] as String);
    });

    await orderedRepo.resetAll();

    expect(log.first, 'db.clearAll');
    expect(log, contains('vault.delete'));
    expect(await orderedRepo.getAllWallets(), isEmpty);
  });

  test(
    'resetAll empties the database even when the secret erase fails',
    () async {
      await repo.createSeedPhrase(_abandonMnemonic);
      when(
        () => vault.listKeys(),
      ).thenThrow(PlatformException(code: 'list_failed'));

      final failures = await repo.resetAll();

      expect(failures.map((f) => f.step), contains('vault.listKeys'));
      expect(await repo.getAllWallets(), isEmpty);
      expect(await repo.getAllSeedPhrases(), isEmpty);
    },
  );

  // ---------------------------------------------------------------------------
  // Wallet-graph sync + restore
  // ---------------------------------------------------------------------------

  group('wallet graph sync + restore', () {
    test(
      'syncWalletGraph writes a v3 graph that round-trips accounts via restore',
      () async {
        final sp = await seedSingleWallet();
        await importSolanaAt(sp.id, [1]);
        final view = await repo.addViewOnlyWallet('Watch', 'W');
        final social = (await addSocial(
          provider: 'apple',
          name: 'Apple Wallet',
        )).wallets.singleWhere((w) => w.chain == 'solana');
        final activeId = (await repo.getActiveWallet())!.id;

        // Capture the account UUIDs + avatar seeds so we can prove they survive
        // recovery (rather than being re-synthesized with fresh seeds).
        final before = await repo.getAccountViews();
        expect(before, hasLength(4));
        final seedById = {for (final a in before) a.id: a.avatarSeed};

        await repo.syncWalletGraph();
        final graphJson = await storage.loadAccountGraph();
        expect(graphJson, isNotNull);
        final decoded = jsonDecode(graphJson!) as Map<String, dynamic>;
        expect(decoded['version'], 3);
        expect(decoded['accounts'], hasLength(4));

        // Wipe the DB but keep the graph, then restore from it.
        await db.clearAll();
        expect(await repo.getAllWallets(), isEmpty);

        final result = await repo.restoreFromGraph(graphJson);
        expect(result, isA<RestoreRestored>());

        expect(await repo.getAllSeedPhrases(), hasLength(1));
        // Seed idx-0 + imported idx-1 + watch-only + the social account's
        // three chain rows.
        expect(await repo.getAllWallets(), hasLength(6));
        expect((await repo.getActiveWallet())?.id, activeId);
        expect(
          (await repo.getAllWallets()).map((w) => w.id),
          contains(view.id),
        );

        // The social provider survives the destructive rebuild via the graph,
        // so the brand badge keeps rendering after recovery.
        final restoredSocial = await repo.getWalletById(social.id);
        expect(restoredSocial?.socialProvider, 'apple');
        expect(restoredSocial?.badge, WalletBadge.apple);

        // Accounts restored with identical ids + avatar seeds.
        final after = await repo.getAccountViews();
        expect(after, hasLength(4));
        expect({for (final a in after) a.id: a.avatarSeed}, seedById);
      },
    );

    test('restoreFromGraph fails on malformed JSON', () async {
      expect(
        await repo.restoreFromGraph('{not valid json'),
        isA<RestoreFailed>(),
      );
    });

    // Restore is all-or-nothing. A graph whose seed phrase cannot be read back
    // from the vault must write *nothing*: rows without keys put wallets on
    // screen that cannot sign, and a partial restore used to leave a subset
    // that the next graph sync wrote back over the full graph — orphaning the
    // rest of the user's seeds for good.
    test(
      'restoreFromGraph aborts and writes nothing when a seed is unreadable',
      () async {
        final sp = await seedSingleWallet();
        await repo.addViewOnlyWallet('Watch', 'W');
        await repo.syncWalletGraph();
        final graphJson = (await storage.loadAccountGraph())!;
        await db.clearAll();

        // Keychain misread (or a key that never existed): the seed's vault
        // item is gone while the graph still lists it.
        vaultStore.remove('mallow_mnemonic_seed_${sp.id}');

        final result = await repo.restoreFromGraph(graphJson);

        expect(result, isA<RestoreAborted>());
        final aborted = result as RestoreAborted;
        expect(aborted.missingSeedPhrases, 1);
        expect(aborted.totalSeedPhrases, 1);
        // Nothing restored — not even the view-only row, which needs no key.
        expect(await repo.getAllSeedPhrases(), isEmpty);
        expect(await repo.getAllWallets(), isEmpty);
        expect(await repo.getAccountViews(), isEmpty);
      },
    );

    test('restoreFromGraph aborts when an imported key is unreadable, '
        'but a missing social key does not abort', () async {
      final k = await _importableKey(0x51);
      final imported = await repo.addImportedKeyWallet(k.key, 'Imported');
      await addSocial();
      await repo.syncWalletGraph();
      final graphJson = (await storage.loadAccountGraph())!;
      await db.clearAll();

      // Social keys are recoverable by re-login, so their absence is fine.
      vaultStore.removeWhere(
        (key, _) =>
            key.startsWith('mallow_pk_') && key != 'mallow_pk_${imported.id}',
      );
      expect(await repo.restoreFromGraph(graphJson), isA<RestoreRestored>());
      await db.clearAll();

      // An imported key is not recoverable: abort, write nothing.
      vaultStore.remove('mallow_pk_${imported.id}');
      final result = await repo.restoreFromGraph(graphJson);

      expect(result, isA<RestoreAborted>());
      expect((result as RestoreAborted).missingImportedKeys, 1);
      expect(await repo.getAllWallets(), isEmpty);
    });

    test('restoreFromGraph treats a vault read error as missing', () async {
      final sp = await seedSingleWallet();
      await repo.syncWalletGraph();
      final graphJson = (await storage.loadAccountGraph())!;
      await db.clearAll();

      when(
        () => vault.read(
          'mallow_mnemonic_seed_${sp.id}',
          prompt: any(named: 'prompt'),
        ),
      ).thenThrow(PlatformException(code: 'read_failed'));

      expect(await repo.restoreFromGraph(graphJson), isA<RestoreAborted>());
      expect(await repo.getAllWallets(), isEmpty);
    });

    // A graph stored by an older build can name a wallet that same write
    // removed. Storing that id makes getActiveWallet() answer null against a
    // row that will never exist, and nothing repairs it — the session boots
    // with wallets on file and no active one until the user switches by hand.
    // Leaving the selection empty is the same outcome, so the restore picks
    // one of the rows it just wrote instead.
    test(
      'restoreFromGraph replaces a selection no restored wallet matches',
      () async {
        await seedSingleWallet();
        await repo.syncWalletGraph();
        final graph =
            jsonDecode((await storage.loadAccountGraph())!)
                as Map<String, dynamic>;
        graph['selectedWalletId'] = 'ghost-id';
        await db.clearAll();
        await storage.deleteSelectedWalletId();

        expect(
          await repo.restoreFromGraph(jsonEncode(graph)),
          isA<RestoreRestored>(),
        );

        final wallets = await repo.getAllWallets();
        expect(wallets, hasLength(1));
        expect(await storage.loadSelectedWalletId(), wallets.single.id);
        expect(await repo.getActiveWallet(), isNotNull);
      },
    );

    // The selection lives in the plugin store, which survives an iOS
    // reinstall — so a restore can land next to an id naming a wallet it
    // never wrote. Both ids dangling used to leave getActiveWallet() null for
    // good; now the restore re-points the selection at what it did write,
    // preferring a row that can back the Solana signer.
    test(
      'restoreFromGraph readableOnly re-points a selection it skipped',
      () async {
        // Import the readable seed's Tezos and Ethereum rows first, so its
        // Solana row is NOT the first restored wallet: picking it proves the
        // signer preference rather than "take whatever came first".
        final readable = await repo.createSeedPhrase(
          _abandonMnemonic,
          autoDerive: false,
        );
        final picker = await repo.deriveAccountsForPicker(
          readable.id,
          count: 2,
        );
        await repo.importAccountsFromPhrase(readable.id, [
          WalletImportSelection(
            index: 0,
            chain: Chain.tezos,
            address: picker.accounts[0].tezos!,
          ),
          WalletImportSelection(
            index: 0,
            chain: Chain.ethereum,
            address: picker.accounts[0].ethereum!,
          ),
        ]);
        final solana = (await repo.importAccountsFromPhrase(readable.id, [
          WalletImportSelection(
            index: 1,
            chain: Chain.solana,
            address: picker.accounts[1].solanaStandard,
          ),
        ])).single;

        final lost = await repo.createSeedPhrase(_legalMnemonic);
        final lostWallet = (await repo.getWalletsForSeedPhrase(lost.id)).first;
        await repo.setActiveWallet(lostWallet.id);
        await repo.syncWalletGraph();
        final graphJson = (await storage.loadAccountGraph())!;

        // The database is gone; the stored selection is not, and it names a
        // wallet of the seed this restore is about to skip.
        await db.clearAll();
        vaultStore.remove('mallow_mnemonic_seed_${lost.id}');
        expect(await storage.loadSelectedWalletId(), lostWallet.id);

        expect(
          await repo.restoreFromGraph(graphJson, readableOnly: true),
          isA<RestoreRestored>(),
        );

        expect(await storage.loadSelectedWalletId(), solana.id);
        expect((await repo.getActiveWallet())?.id, solana.id);
      },
    );

    // `bindsGlobalSigner` names the chain that reads the selection, not a row
    // that can sign: a watch-only Solana row passes it. Parking the selection
    // there hands the Solana signer an address with no key — the wallet is
    // back, on screen, and every signature fails — when the same restore
    // wrote a Solana row that can sign.
    test('restoreFromGraph prefers a restored Solana row that can sign over a '
        'watch-only one', () async {
      // The watch-only row is written first, so it is also the row a
      // "take the first Solana one" rule would land on.
      final watch = await repo.addViewOnlyWallet(
        'So1anaWatchOn1y1111111111111111111111111111',
        'Watch',
      );
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final signer = (await importSolanaAt(sp.id, [0])).single;
      await repo.syncWalletGraph();
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      // Both stored ids dangle, which is what puts the restore in charge of
      // the choice.
      graph['selectedWalletId'] = 'ghost-id';
      await db.clearAll();
      await storage.deleteSelectedWalletId();

      expect(
        await repo.restoreFromGraph(jsonEncode(graph)),
        isA<RestoreRestored>(),
      );

      expect((await repo.getAllWallets()).first.id, watch.id);
      expect(await storage.loadSelectedWalletId(), signer.id);
    });

    // No Solana row can sign here, and the choice is between a keyless Solana
    // row and a signing row of another chain. Solana still wins: it is the one
    // chain whose signing resolves the keypair from the selection, so leaving
    // the selection off-chain breaks it for every Solana flow while gaining
    // Ethereum nothing — its signing takes an explicit wallet id. This is the
    // same order [_removeWallets] picks a replacement in.
    test('restoreFromGraph still prefers a Solana row when none of them can '
        'sign', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final picker = await repo.deriveAccountsForPicker(sp.id, count: 1);
      // Ethereum first: "the first restored row" would stop here.
      final ethereum = (await repo.importAccountsFromPhrase(sp.id, [
        WalletImportSelection(
          index: 0,
          chain: Chain.ethereum,
          address: picker.accounts[0].ethereum!,
        ),
      ])).single;
      final watch = await repo.addViewOnlyWallet(
        'So1anaWatchOn1y1111111111111111111111111111',
        'Watch',
      );
      await repo.syncWalletGraph();
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      graph['selectedWalletId'] = 'ghost-id';
      await db.clearAll();
      await storage.deleteSelectedWalletId();

      expect(
        await repo.restoreFromGraph(jsonEncode(graph)),
        isA<RestoreRestored>(),
      );

      expect((await repo.getAllWallets()).first.id, ethereum.id);
      expect(await storage.loadSelectedWalletId(), watch.id);
    });

    // The stored id is only re-pointed when it dangles. It survives an iOS
    // reinstall, so after a restore that wrote the row it names it is a live
    // choice the user made — overwriting it with the restore's own preference
    // would move the active wallet (and the /v0/login identity with it) under
    // a user who changed nothing.
    test('restoreFromGraph keeps a stored selection the restore wrote a row '
        'for', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final picker = await repo.deriveAccountsForPicker(sp.id, count: 1);
      final ethereum = (await repo.importAccountsFromPhrase(sp.id, [
        WalletImportSelection(
          index: 0,
          chain: Chain.ethereum,
          address: picker.accounts[0].ethereum!,
        ),
      ])).single;
      // A Solana row the preference above would take if the stored id were
      // ignored — so this test cannot pass by accident.
      await importSolanaAt(sp.id, [0]);
      await repo.setActiveWallet(ethereum.id);
      await repo.syncWalletGraph();
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      graph['selectedWalletId'] = 'ghost-id';
      await db.clearAll();

      expect(
        await repo.restoreFromGraph(jsonEncode(graph)),
        isA<RestoreRestored>(),
      );

      expect(await storage.loadSelectedWalletId(), ethereum.id);
    });

    // A restore that writes no wallet at all leaves the stored id naming a row
    // that does not exist. Left there, getActiveWallet() answers null for the
    // whole session and the wallet switcher is the only repair; cleared, the
    // next wallet the user adds becomes the selection.
    test('restoreFromGraph clears the selection when it restores no wallet '
        'at all', () async {
      // A seed with no wallets of its own is readable, so the partial restore
      // runs — and writes nothing but the seed and its accounts.
      final readable = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final lost = await repo.createSeedPhrase(_legalMnemonic);
      final lostWallet = (await repo.getWalletsForSeedPhrase(lost.id)).first;
      await repo.setActiveWallet(lostWallet.id);
      await repo.syncWalletGraph();
      final graphJson = (await storage.loadAccountGraph())!;

      await db.clearAll();
      vaultStore.remove('mallow_mnemonic_seed_${lost.id}');
      expect(await storage.loadSelectedWalletId(), lostWallet.id);

      final result = await repo.restoreFromGraph(graphJson, readableOnly: true);

      expect(result, isA<RestoreRestored>());
      expect((result as RestoreRestored).wallets, 0);
      expect(await repo.getAllWallets(), isEmpty);
      expect((await repo.getAllSeedPhrases()).map((sp) => sp.id), [
        readable.id,
      ]);
      expect(await storage.loadSelectedWalletId(), isNull);
    });

    // The opt-in way past the abort. Without it one unreadable entry blocks
    // every restore forever, and the only other action on the screen — Start
    // fresh — erases the *readable* seeds' vault items too. What must not
    // happen is the graph being rewritten: the skipped entries stay listed, so
    // the boot-time dormant restore retries them at every launch and a later
    // Restore can still take them.
    test('restoreFromGraph readableOnly writes what reads and leaves the rest '
        'in the graph', () async {
      final readable = await repo.createSeedPhrase(_abandonMnemonic);
      final lostSeed = await repo.createSeedPhrase(_legalMnemonic);
      final goodKey = await repo.addImportedKeyWallet(
        (await _importableKey(0x91)).key,
        'Imported',
      );
      final lostKey = await repo.addImportedKeyWallet(
        (await _importableKey(0x92)).key,
        'Imported too',
      );
      final view = await repo.addViewOnlyWallet('Watch', 'W');
      await repo.syncWalletGraph();
      final graphJson = (await storage.loadAccountGraph())!;
      final keptWalletIds = {
        ...(await repo.getWalletsForSeedPhrase(readable.id)).map((w) => w.id),
        goodKey.id,
        view.id,
      };
      await db.clearAll();

      vaultStore.remove('mallow_mnemonic_seed_${lostSeed.id}');
      vaultStore.remove('mallow_pk_${lostKey.id}');
      clearInteractions(vault);

      final result = await repo.restoreFromGraph(graphJson, readableOnly: true);

      expect(result, isA<RestoreRestored>());
      final restored = result as RestoreRestored;
      expect(restored.skippedSeedPhrases, 1);
      expect(restored.skippedImportedKeys, 1);
      expect((await repo.getAllSeedPhrases()).map((s) => s.id), [readable.id]);
      expect(
        (await repo.getAllWallets()).map((w) => w.id).toSet(),
        keptWalletIds,
      );

      verifyNever(() => vault.write('mallow_account_graph', any()));
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      expect(
        (graph['seedPhrases'] as List<dynamic>).map(
          (e) => (e as Map<String, dynamic>)['id'],
        ),
        contains(lostSeed.id),
      );
      expect(
        (graph['wallets'] as List<dynamic>).map(
          (e) => (e as Map<String, dynamic>)['id'],
        ),
        contains(lostKey.id),
      );
    });

    // Nothing readable is the case the offer must not be made for: a partial
    // restore would write zero rows and report success.
    test(
      'restoreFromGraph readableOnly still aborts when nothing reads',
      () async {
        final sp = await seedSingleWallet();
        await repo.syncWalletGraph();
        final graphJson = (await storage.loadAccountGraph())!;
        await db.clearAll();
        vaultStore.remove('mallow_mnemonic_seed_${sp.id}');

        final result = await repo.restoreFromGraph(
          graphJson,
          readableOnly: true,
        );

        expect(result, isA<RestoreAborted>());
        expect((result as RestoreAborted).hasReadable, isFalse);
        expect(await repo.getAllWallets(), isEmpty);
        expect(await repo.getAllSeedPhrases(), isEmpty);
      },
    );

    // Keyless rows are not "something can be read". A partial restore here
    // would write the watch-only and Ledger rows, report success, and leave a
    // database with wallets in it — which is exactly the state that stops the
    // Restore screen appearing again, so the user is told their seed came
    // back and then has no way left to ask for it.
    test('view-only and Ledger rows do not offer a partial restore', () async {
      final sp = await seedSingleWallet();
      await repo.addViewOnlyWallet('Watch', 'W');
      await repo.addLedgerWallet('LedgerAddr', 'Nano');
      await repo.syncWalletGraph();
      final graphJson = (await storage.loadAccountGraph())!;
      await db.clearAll();
      vaultStore.remove('mallow_mnemonic_seed_${sp.id}');

      final aborted = await repo.restoreFromGraph(graphJson) as RestoreAborted;
      expect(aborted.readableWallets, 0);
      expect(aborted.hasReadable, isFalse);

      // And the opt-in path refuses rather than writing the keyless rows.
      expect(
        await repo.restoreFromGraph(graphJson, readableOnly: true),
        isA<RestoreAborted>(),
      );
      expect(await repo.getAllWallets(), isEmpty);
    });

    // A social row is the one keyless-in-the-vault case that still counts: its
    // per-chain key is minted again by re-logging in, so restoring it hands
    // the user a wallet they can sign with.
    test('a social wallet does offer a partial restore', () async {
      final sp = await seedSingleWallet();
      await addSocial();
      await repo.syncWalletGraph();
      final graphJson = (await storage.loadAccountGraph())!;
      await db.clearAll();
      vaultStore.remove('mallow_mnemonic_seed_${sp.id}');

      final aborted = await repo.restoreFromGraph(graphJson) as RestoreAborted;
      expect(aborted.hasReadable, isTrue);

      expect(
        await repo.restoreFromGraph(graphJson, readableOnly: true),
        isA<RestoreRestored>(),
      );
      expect(await repo.getAllWallets(), isNotEmpty);
    });

    // An import whose every selection was already taken leaves an account row
    // behind that no wallet references. The full restore writes it; the
    // partial one used to keep only the accounts its restored wallets pointed
    // at, quietly losing the account (and its avatar and number) for good.
    test('readableOnly keeps a restored seed\'s wallet-less account', () async {
      final readable = await repo.createSeedPhrase(_abandonMnemonic);
      final lost = await repo.createSeedPhrase(_legalMnemonic);
      await repo.syncWalletGraph();
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      (graph['accounts'] as List<dynamic>).add({
        'id': 'empty-account',
        'seedPhraseId': readable.id,
        'derivationIndex': 4,
        'kind': AccountKind.seed.toDbString(),
        'name': 'Account 09',
        'avatarSeed': 'empty-account-seed',
        'sortIndex': 9,
      });
      await db.clearAll();
      vaultStore.remove('mallow_mnemonic_seed_${lost.id}');

      expect(
        await repo.restoreFromGraph(jsonEncode(graph), readableOnly: true),
        isA<RestoreRestored>(),
      );

      final accounts = await db.getAllAccounts();
      expect(accounts.map((a) => a.id), contains('empty-account'));
      // The skipped seed's accounts still stay out.
      expect(accounts.map((a) => a.seedPhraseId), isNot(contains(lost.id)));
    });

    test('restoreFromGraph rolls back every row when a write fails', () async {
      await seedSingleWallet();
      await repo.syncWalletGraph();
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      await db.clearAll();

      // Corrupt the last wallet entry so its insert throws after the seed
      // phrase and account rows have already been written inside the
      // transaction.
      final wallets = graph['wallets'] as List<dynamic>;
      (wallets.last as Map<String, dynamic>)['walletType'] = null;

      final result = await repo.restoreFromGraph(jsonEncode(graph));

      expect(result, isA<RestoreFailed>());
      expect(await repo.getAllSeedPhrases(), isEmpty);
      expect(await repo.getAccountViews(), isEmpty);
      expect(await repo.getAllWallets(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Graph carry-over, explicit prune, dormant restore
  // ---------------------------------------------------------------------------

  group('graph carry-over + explicit prune', () {
    Future<Map<String, dynamic>> storedGraph() async =>
        jsonDecode((await storage.loadAccountGraph())!) as Map<String, dynamic>;

    Set<String> seedIdsIn(Map<String, dynamic> g) =>
        (g['seedPhrases'] as List<dynamic>)
            .map((e) => (e as Map<String, dynamic>)['id'] as String)
            .toSet();

    // Regression: after a transient keystore misread routed a launch to
    // onboarding, the first new seed overwrote the graph with only itself,
    // orphaning every other seed in the vault. A seed the DB does not know is
    // not a seed that is gone.
    test('a stored seed the DB lacks survives a sync (carry-over)', () async {
      final old = await repo.createSeedPhrase(_abandonMnemonic);
      await repo.syncWalletGraph();
      // Simulate the misread-routed fresh session: empty DB, graph intact.
      await db.clearAll();

      final fresh = await repo.createSeedPhrase(_legalMnemonic);

      final graph = await storedGraph();
      expect(seedIdsIn(graph), {old.id, fresh.id});
      // The old seed's accounts and wallets came along, not just its id.
      expect(
        (graph['wallets'] as List<dynamic>).where(
          (w) => (w as Map<String, dynamic>)['seedPhraseId'] == old.id,
        ),
        isNotEmpty,
      );
      expect(
        (graph['accounts'] as List<dynamic>).where(
          (a) => (a as Map<String, dynamic>)['seedPhraseId'] == old.id,
        ),
        isNotEmpty,
      );
    });

    test(
      'a stored non-seed wallet the DB lacks is carried with its account',
      () async {
        final k = await _importableKey(0x61);
        final imported = await repo.addImportedKeyWallet(k.key, 'Imported');
        await db.clearAll();

        await repo.createSeedPhrase(_legalMnemonic);

        final graph = await storedGraph();
        final wallets = (graph['wallets'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final carried = wallets.singleWhere((w) => w['id'] == imported.id);
        expect(
          (graph['accounts'] as List<dynamic>).cast<Map<String, dynamic>>().map(
            (a) => a['id'],
          ),
          contains(carried['accountId']),
        );
      },
    );

    test('an explicit removal prunes the seed from the graph', () async {
      final sp = await seedSingleWallet();
      final wallet = (await repo.getAllWallets()).single;

      await repo.removeWallet(wallet.id);

      expect(seedIdsIn(await storedGraph()), isNot(contains(sp.id)));
      // And later plain syncs do not bring it back.
      await repo.createSeedPhrase(_legalMnemonic);
      expect(seedIdsIn(await storedGraph()), isNot(contains(sp.id)));
    });

    // The graph write is the commit point of a removal. If it fails, the
    // wallet, its secret and its rows must all still be there — otherwise the
    // next sync would carry the pruned-but-not-written entry straight back
    // with no secret behind it.
    test('removeWallet deletes nothing when the graph prune fails', () async {
      final sp = await seedSingleWallet();
      final wallet = (await repo.getAllWallets()).single;
      when(
        () => vault.write('mallow_account_graph', any()),
      ).thenThrow(PlatformException(code: 'write_failed'));

      await expectLater(
        repo.removeWallet(wallet.id),
        throwsA(isA<GraphSyncException>()),
      );

      expect(await repo.getWalletById(wallet.id), isNotNull);
      expect(await repo.getAllSeedPhrases(), hasLength(1));
      expect(vaultStore.containsKey('mallow_mnemonic_seed_${sp.id}'), isTrue);
    });

    // Carry-over is only as safe as the read it carries from. A keystore that
    // answered "no graph" here would carry nothing over, and the write that
    // follows would replace the graph with the new seed alone — the exact
    // orphaning carry-over exists to prevent. So the read throws, and a plain
    // sync must swallow it and leave the stored graph untouched.
    test('a failed stored-graph read leaves the stored graph alone', () async {
      final old = await repo.createSeedPhrase(_abandonMnemonic);
      await repo.syncWalletGraph();
      final storedBefore = vaultStore['mallow_account_graph'];
      expect(storedBefore, isNotNull);
      // Simulate the misread-routed fresh session: empty DB, graph intact.
      await db.clearAll();

      when(
        () => vault.read('mallow_account_graph', prompt: any(named: 'prompt')),
      ).thenThrow(PlatformException(code: 'read_failed'));
      clearInteractions(vault);

      final fresh = await repo.createSeedPhrase(_legalMnemonic);

      verifyNever(() => vault.write('mallow_account_graph', any()));
      expect(vaultStore['mallow_account_graph'], storedBefore);
      expect(seedIdsIn(jsonDecode(storedBefore!) as Map<String, dynamic>), {
        old.id,
      });

      // Skipping the write costs nothing permanently: once the keystore
      // answers again, the next sync writes the fresh seed from the database
      // and carries the old one over.
      when(
        () => vault.read('mallow_account_graph', prompt: any(named: 'prompt')),
      ).thenAnswer((_) async => vaultStore['mallow_account_graph']);
      await repo.syncWalletGraph();
      expect(seedIdsIn(await storedGraph()), {old.id, fresh.id});
    });

    // The same unreadable keystore on a removal path must abort the removal.
    // A prune computed against a graph nobody could read would write back the
    // database's content minus the removed ids and drop every carried entry
    // with it, leaving their vault items with no index to find them by.
    test('removeWallet deletes nothing when the graph read fails', () async {
      final sp = await seedSingleWallet();
      final wallet = (await repo.getAllWallets()).single;
      when(
        () => vault.read('mallow_account_graph', prompt: any(named: 'prompt')),
      ).thenThrow(PlatformException(code: 'read_failed'));

      await expectLater(
        repo.removeWallet(wallet.id),
        throwsA(isA<GraphSyncException>()),
      );

      expect(await repo.getWalletById(wallet.id), isNotNull);
      expect(await repo.getAllSeedPhrases(), hasLength(1));
      expect(vaultStore.containsKey('mallow_mnemonic_seed_${sp.id}'), isTrue);
    });

    // ------------------------------------------------------------------
    // removeAccount: one prune for the whole account, before any delete
    // ------------------------------------------------------------------

    Set<String> idsIn(Map<String, dynamic> graph, String key) =>
        (graph[key] as List<dynamic>)
            .map((e) => (e as Map<String, dynamic>)['id'] as String)
            .toSet();

    // Makes the graph write fail from the moment it would drop [walletId].
    // Writes that still name the wallet go through, so a removal that commits
    // one wallet at a time gets several successful writes — and several
    // completed deletions — before it fails.
    void failGraphWriteOnceDropping(String walletId) {
      when(() => vault.write('mallow_account_graph', any())).thenAnswer((
        inv,
      ) async {
        final value = inv.positionalArguments[1] as String;
        final graph = jsonDecode(value) as Map<String, dynamic>;
        if (!idsIn(graph, 'wallets').contains(walletId)) {
          throw PlatformException(code: 'write_failed');
        }
        vaultStore['mallow_account_graph'] = value;
      });
    }

    // Every graph write, paired with the number of wallet rows the database
    // still held when it happened — enough to prove a prune landed *before*
    // any deletion rather than after.
    final graphWrites = <({Map<String, dynamic> graph, int dbWallets})>[];
    void recordGraphWrites() {
      graphWrites.clear();
      when(() => vault.write('mallow_account_graph', any())).thenAnswer((
        inv,
      ) async {
        final value = inv.positionalArguments[1] as String;
        graphWrites.add((
          graph: jsonDecode(value) as Map<String, dynamic>,
          dbWallets: (await db.getAllWallets()).length,
        ));
        vaultStore['mallow_account_graph'] = value;
      });
    }

    // Why: an account holds several wallets, so removing it one wallet at a
    // time commits a prune per wallet. A failure on the second one then leaves
    // the first wallet, its secret and its rows already gone while every
    // caller tells the user "Nothing was removed." — and skips the cleanup
    // (forgetWalletSig) it only runs on success.
    test('removeAccount deletes nothing when the graph prune fails', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic);
      final account = (await repo.getAccountViews()).single;
      final walletIds = account.wallets.map((w) => w.id).toList();
      expect(walletIds, hasLength(3));
      // Fails only once the write drops the account's last wallet — so a
      // per-wallet removal gets to delete the first two before it throws.
      failGraphWriteOnceDropping(walletIds.last);

      await expectLater(
        repo.removeAccount(account.id),
        throwsA(isA<GraphSyncException>()),
      );

      expect((await repo.getAllWallets()).map((w) => w.id), walletIds);
      expect(await repo.getAccountViews(), hasLength(1));
      expect(await repo.getAllSeedPhrases(), hasLength(1));
      expect(vaultStore.containsKey('mallow_mnemonic_seed_${sp.id}'), isTrue);
      // The stored graph is untouched too — no half-pruned copy was left
      // behind for the next boot to restore from.
      expect(idsIn(await storedGraph(), 'wallets'), walletIds.toSet());
    });

    test('removeAccount prunes the account, its wallets and its seed phrase '
        'in a single write, before anything is deleted', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic);
      final account = (await repo.getAccountViews()).single;
      final walletIds = account.wallets.map((w) => w.id).toSet();
      recordGraphWrites();

      await repo.removeAccount(account.id);

      final commit = graphWrites.first;
      // The commit point names everything that is going — including the seed
      // phrase, which is only "last wallet gone" across the whole set.
      expect(idsIn(commit.graph, 'wallets').intersection(walletIds), isEmpty);
      expect(idsIn(commit.graph, 'accounts'), isNot(contains(account.id)));
      expect(idsIn(commit.graph, 'seedPhrases'), isNot(contains(sp.id)));
      // And the database still held every row at that moment: graph first.
      expect(commit.dbWallets, walletIds.length);
    });

    // ------------------------------------------------------------------
    // One write, and a selection the graph can honour
    // ------------------------------------------------------------------

    // Why one write: the prune is computed from the database *as it will be*,
    // so the closing sync that used to follow rebuilt identical bytes. Every
    // extra keystore write is another chance to fail, and it falls outside the
    // all-or-nothing promise the prune makes — a failure there left the graph
    // and the deletes disagreeing with no way to report it.
    test('a removal writes the graph exactly once', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final wallets = await importSolanaAt(sp.id, [0, 1]);
      final active = (await repo.getActiveWallet())!;
      final other = wallets.firstWhere((w) => w.id != active.id);
      recordGraphWrites();

      await repo.removeWallet(other.id);

      expect(graphWrites, hasLength(1));
      // The single write already describes the database the deletes left
      // behind — including the selection, which this removal did not touch.
      final graph = graphWrites.single.graph;
      expect(
        idsIn(graph, 'wallets'),
        (await repo.getAllWallets()).map((w) => w.id).toSet(),
      );
      expect(graph['selectedWalletId'], await storage.loadSelectedWalletId());
    });

    // Why: the prune filters the removed wallet out of the graph but used to
    // copy the stored selection in unchecked, so the committed graph named a
    // wallet it had just dropped. The repair sync that followed was
    // catch-and-log, so one keystore hiccup left that dangling selection in
    // the graph for good — and a restore from it boots with no active wallet.
    test('removing the active wallet commits a graph whose selection it '
        'still contains', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      final wallets = await importSolanaAt(sp.id, [0, 1]);
      final active = (await repo.getActiveWallet())!;
      expect(wallets.map((w) => w.id), contains(active.id));
      recordGraphWrites();

      final replacement = await repo.removeWallet(active.id);

      expect(graphWrites, hasLength(1));
      final graph = graphWrites.single.graph;
      expect(graph['selectedWalletId'], replacement);
      expect(idsIn(graph, 'wallets'), contains(replacement));
      // Storage agrees with the graph, and the session still has an active
      // wallet — the state a dangling selection silently destroys.
      expect(await storage.loadSelectedWalletId(), replacement);
      expect((await repo.getActiveWallet())?.id, replacement);
    });

    test(
      'removing the last wallet commits a graph with no selection',
      () async {
        final k = await _importableKey(0x7b);
        final wallet = await repo.addImportedKeyWallet(k.key, 'Solo');
        recordGraphWrites();

        expect(await repo.removeWallet(wallet.id), isNull);

        expect(graphWrites, hasLength(1));
        expect(graphWrites.single.graph['selectedWalletId'], isNull);
        expect(await storage.loadSelectedWalletId(), isNull);
      },
    );

    // Why: nothing cascades in the database — an account's seed phrase is a
    // plain nullable column — so the account row outlived the seed phrase and
    // every wallet it held. The sync then wrote that empty account into the
    // graph, a restore re-created it, and `getAccountViews` showed a card with
    // no wallets under a seed phrase that no longer exists.
    test('removing the last wallet of a seed drops its account from the '
        'database and the graph', () async {
      final sp = await seedSingleWallet();
      final account = (await repo.getAccountViews()).single;
      final wallet = (await repo.getAllWallets()).single;
      final k = await _importableKey(0x7c);
      final keeper = await repo.addImportedKeyWallet(k.key, 'Keeper');

      await repo.removeWallet(wallet.id);

      final graph = await storedGraph();
      expect(seedIdsIn(graph), isNot(contains(sp.id)));
      expect(idsIn(graph, 'accounts'), isNot(contains(account.id)));
      expect((await repo.getAccountViews()).map((a) => a.id), [
        (await repo.getWalletById(keeper.id))!.accountId,
      ]);
    });

    // The decision this pins: a graph that does not parse has nothing to
    // carry, so the next sync overwrites it with the database's content. That
    // is the opposite of a failed *read*, which must leave the stored graph
    // alone (the test above) — one says "these bytes are unusable", the other
    // says "I could not see the keystore". Collapsing the two either strands
    // an install behind bytes nobody can read, or orphans every carried seed.
    test('an unparseable stored graph is replaced, not carried', () async {
      final sp = await repo.createSeedPhrase(_abandonMnemonic);
      vaultStore['mallow_account_graph'] = '{not valid json';

      await repo.syncWalletGraph();

      final graph = await storedGraph();
      expect(seedIdsIn(graph), {sp.id});
      expect(
        idsIn(graph, 'wallets'),
        (await repo.getAllWallets()).map((w) => w.id).toSet(),
      );
    });
  });

  group('restoreDormantFromGraph', () {
    test('restores a graph-only seed whose vault item is readable', () async {
      final old = await repo.createSeedPhrase(_abandonMnemonic);
      final oldWallets = await repo.getAllWallets();
      await db.clearAll();
      await repo.createSeedPhrase(_legalMnemonic); // carries `old` over
      final selectedBefore = await storage.loadSelectedWalletId();

      final result = await repo.restoreDormantFromGraph();

      expect(result.seedPhrasesRestored, 1);
      expect(result.walletsRestored, oldWallets.length);
      expect(result.duplicatesDropped, 0);
      expect(result.skipped, 0);
      expect(
        (await repo.getAllSeedPhrases()).map((s) => s.id),
        contains(old.id),
      );
      expect(await repo.getAllWallets(), hasLength(oldWallets.length + 3));
      // The active selection is never touched by a dormant restore.
      expect(await storage.loadSelectedWalletId(), selectedBefore);
    });

    test(
      'skips (and keeps) a dormant seed whose vault item reads nil',
      () async {
        final old = await repo.createSeedPhrase(_abandonMnemonic);
        await db.clearAll();
        await repo.createSeedPhrase(_legalMnemonic);
        // Transient miss this launch.
        final saved = vaultStore.remove('mallow_mnemonic_seed_${old.id}')!;

        final result = await repo.restoreDormantFromGraph();

        expect(result.skipped, 1);
        expect(result.seedPhrasesRestored, 0);
        expect(result.duplicatesDropped, 0);
        expect(
          (await repo.getAllSeedPhrases()).map((s) => s.id),
          isNot(contains(old.id)),
        );
        // Still in the graph for the next launch.
        final graph =
            jsonDecode((await storage.loadAccountGraph())!)
                as Map<String, dynamic>;
        expect(
          (graph['seedPhrases'] as List<dynamic>).map(
            (e) => (e as Map<String, dynamic>)['id'],
          ),
          contains(old.id),
        );
        // And once readable again, it comes back.
        vaultStore['mallow_mnemonic_seed_${old.id}'] = saved;
        expect((await repo.restoreDormantFromGraph()).seedPhrasesRestored, 1);
      },
    );

    test(
      'drops a dormant seed whose mnemonic equals a live seed (duplicate)',
      () async {
        // The user re-imported the same phrase after the misread: two ids, one
        // secret. The dormant copy is pruned and its vault item deleted; the
        // live one keeps the secret.
        final old = await repo.createSeedPhrase(_abandonMnemonic);
        await db.clearAll();
        final live = await repo.createSeedPhrase(_abandonMnemonic);
        expect(live.id, isNot(old.id));

        final result = await repo.restoreDormantFromGraph();

        expect(result.duplicatesDropped, 1);
        expect(result.seedPhrasesRestored, 0);
        expect(
          vaultStore.containsKey('mallow_mnemonic_seed_${old.id}'),
          isFalse,
        );
        expect(vaultStore['mallow_mnemonic_seed_${live.id}'], _abandonMnemonic);
        final graph =
            jsonDecode((await storage.loadAccountGraph())!)
                as Map<String, dynamic>;
        expect(
          (graph['seedPhrases'] as List<dynamic>).map(
            (e) => (e as Map<String, dynamic>)['id'],
          ),
          [live.id],
        );
      },
    );

    // Regression: a nil read of a LIVE seed used to fall through to "not a
    // duplicate", restoring the dormant seed as a SECOND row for a secret that
    // was already live. Wallet rows are upserted by id and `address` has no
    // unique index, so the copy is permanent — the next launch finds both ids
    // in the database and never compares them again. Waiting for a launch that
    // can compare costs one launch; the duplicate costs forever.
    test('skips every dormant seed while a LIVE seed does not read', () async {
      final old = await repo.createSeedPhrase(_abandonMnemonic);
      await db.clearAll();
      final live = await repo.createSeedPhrase(_abandonMnemonic);
      // The live seed's vault read fails this launch; the dormant one reads.
      final saved = vaultStore.remove('mallow_mnemonic_seed_${live.id}')!;

      final result = await repo.restoreDormantFromGraph();

      expect(result.skipped, 1);
      expect(result.seedPhrasesRestored, 0);
      // A nil read is not "duplicate" either: nothing is deleted or pruned.
      expect(result.duplicatesDropped, 0);
      expect(vaultStore.containsKey('mallow_mnemonic_seed_${old.id}'), isTrue);
      expect(
        (await repo.getAllSeedPhrases()).map((s) => s.id),
        isNot(contains(old.id)),
      );
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      expect(
        (graph['seedPhrases'] as List<dynamic>).map(
          (e) => (e as Map<String, dynamic>)['id'],
        ),
        contains(old.id),
      );

      // Next launch the live seed reads again, and the deferred comparison
      // resolves the way it always should have: same secret, one copy.
      vaultStore['mallow_mnemonic_seed_${live.id}'] = saved;
      final second = await repo.restoreDormantFromGraph();
      expect(second.duplicatesDropped, 1);
      expect(second.seedPhrasesRestored, 0);
    });

    test(
      'restores a dormant imported key and drops one whose address is live',
      () async {
        final k = await _importableKey(0x71);
        final imported = await repo.addImportedKeyWallet(k.key, 'Imported');
        await db.clearAll();
        await repo.createSeedPhrase(_legalMnemonic);

        expect((await repo.restoreDormantFromGraph()).walletsRestored, 1);
        expect(await repo.getWalletById(imported.id), isNotNull);

        // Now make it dormant again under a NEW id with the same address live:
        // the dormant copy is the duplicate. (A different seed this round, so
        // the carried-over seed is restored rather than counted as a duplicate.)
        await db.clearAll();
        await repo.createSeedPhrase(_abandonMnemonic);
        final again = await repo.addImportedKeyWallet(k.key, 'Imported again');
        expect(again.id, isNot(imported.id));

        final result = await repo.restoreDormantFromGraph();

        expect(result.seedPhrasesRestored, 1);
        expect(result.duplicatesDropped, 1);
        expect(vaultStore.containsKey('mallow_pk_${imported.id}'), isFalse);
        expect(vaultStore.containsKey('mallow_pk_${again.id}'), isTrue);
      },
    );

    // Regression: "the address is live" was the whole duplicate test for a
    // dormant imported key, so a view-only row — which holds no key and cannot
    // sign — made the app delete the only copy of that key. The user was left
    // watching an address they could no longer spend from.
    test('keeps a dormant imported key whose live row is view-only', () async {
      final k = await _importableKey(0x81);
      final imported = await repo.addImportedKeyWallet(k.key, 'Imported');
      await db.clearAll();
      await repo.addViewOnlyWallet(k.address, 'Watching');
      clearInteractions(vault);

      final result = await repo.restoreDormantFromGraph();

      expect(result.skipped, 1);
      expect(result.duplicatesDropped, 0);
      expect(result.walletsRestored, 0);
      verifyNever(() => vault.delete('mallow_pk_${imported.id}'));
      expect(vaultStore.containsKey('mallow_pk_${imported.id}'), isTrue);
      // Still dormant: kept in the graph for a launch that can decide.
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      expect(
        (graph['wallets'] as List<dynamic>).map(
          (e) => (e as Map<String, dynamic>)['id'],
        ),
        contains(imported.id),
      );
    });

    // Regression: the live-signing test ran for imported keys only, so a
    // dormant *social* row at an address whose only live row is view-only was
    // called a duplicate and its `mallow_pk_` key deleted. A social key does
    // come back with the next login, but this is still the only copy on the
    // device, and the view-only row it was measured against cannot sign.
    test('keeps a dormant social key whose live row is view-only', () async {
      final social = await addSocial();
      final solana = social.wallets.singleWhere((w) => w.chain == 'solana');
      await db.clearAll();
      await repo.addViewOnlyWallet(_socialSolana.address, 'Watching');
      clearInteractions(vault);

      final result = await repo.restoreDormantFromGraph();

      // The Solana row is kept; its two siblings, at addresses nothing holds,
      // are restored as usual.
      expect(result.skipped, 1);
      expect(result.walletsRestored, 2);
      expect(result.duplicatesDropped, 0);
      verifyNever(() => vault.delete('mallow_pk_${solana.id}'));
      expect(vaultStore.containsKey('mallow_pk_${solana.id}'), isTrue);
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      expect(
        (graph['wallets'] as List<dynamic>).map(
          (e) => (e as Map<String, dynamic>)['id'],
        ),
        contains(solana.id),
      );
    });

    test(
      'drops a dormant imported key whose live row holds a readable key',
      () async {
        // The same key imported twice: two ids, one secret, and the live row
        // can sign with it. Only then is deleting the dormant copy safe.
        final k = await _importableKey(0x82);
        final dormant = await repo.addImportedKeyWallet(k.key, 'Imported');
        await db.clearAll();
        final live = await repo.addImportedKeyWallet(k.key, 'Imported again');
        expect(live.id, isNot(dormant.id));

        final result = await repo.restoreDormantFromGraph();

        expect(result.duplicatesDropped, 1);
        expect(result.skipped, 0);
        expect(vaultStore.containsKey('mallow_pk_${dormant.id}'), isFalse);
        expect(vaultStore.containsKey('mallow_pk_${live.id}'), isTrue);
        final graph =
            jsonDecode((await storage.loadAccountGraph())!)
                as Map<String, dynamic>;
        expect(
          (graph['wallets'] as List<dynamic>).map(
            (e) => (e as Map<String, dynamic>)['id'],
          ),
          isNot(contains(dormant.id)),
        );
      },
    );

    test(
      'keeps a dormant imported key when the live row key reads nil',
      () async {
        // Same address, same secret — but the live row's own key does not read
        // this launch, so it cannot be shown to hold the secret. Deleting the
        // dormant copy on that evidence can leave no copy at all.
        final k = await _importableKey(0x83);
        final dormant = await repo.addImportedKeyWallet(k.key, 'Imported');
        await db.clearAll();
        final live = await repo.addImportedKeyWallet(k.key, 'Imported again');
        vaultStore.remove('mallow_pk_${live.id}');

        final result = await repo.restoreDormantFromGraph();

        expect(result.skipped, 1);
        expect(result.duplicatesDropped, 0);
        expect(vaultStore.containsKey('mallow_pk_${dormant.id}'), isTrue);
      },
    );

    // A read that throws is "unknown", the same as a nil read: the entry is
    // left exactly as it is. What must not happen is the throw ending the
    // pass — the entries after it would never be looked at, and the launch
    // would report counts that do not add up.
    test('a dormant seed whose read throws is skipped, and the entries after '
        'it still run', () async {
      final broken = await repo.createSeedPhrase(_abandonMnemonic);
      final good = await repo.createSeedPhrase(_legalMnemonic);
      await db.clearAll(); // both dormant; the graph still lists them
      when(
        () => vault.read(
          'mallow_mnemonic_seed_${broken.id}',
          prompt: any(named: 'prompt'),
        ),
      ).thenThrow(PlatformException(code: 'read_failed'));
      clearInteractions(vault);

      final result = await repo.restoreDormantFromGraph();

      expect(result.skipped, 1);
      expect(result.seedPhrasesRestored, 1);
      expect((await repo.getAllSeedPhrases()).map((s) => s.id), [good.id]);
      // The unreadable one is untouched, in the vault and in the graph.
      verifyNever(() => vault.delete('mallow_mnemonic_seed_${broken.id}'));
      expect(
        vaultStore.containsKey('mallow_mnemonic_seed_${broken.id}'),
        isTrue,
      );
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      expect(
        (graph['seedPhrases'] as List<dynamic>).map(
          (e) => (e as Map<String, dynamic>)['id'],
        ),
        contains(broken.id),
      );
    });

    // The live-read failure is decided once for the launch, so it must stop
    // *every* dormant seed, not just the one that asked first. It is also the
    // one skip that can become permanent — a live seed that never reads again
    // holds the others back at every cold start — so the result says so.
    test(
      'a nil live-seed read skips both dormant seeds and reports why',
      () async {
        final first = await repo.createSeedPhrase(_abandonMnemonic);
        await db.clearAll();
        final second = await repo.createSeedPhrase(_legalMnemonic);
        await db.clearAll();
        final live = await repo.createSeedPhrase(_letterMnemonic);
        vaultStore.remove('mallow_mnemonic_seed_${live.id}');
        clearInteractions(vault);

        final result = await repo.restoreDormantFromGraph();

        expect(result.skipped, 2);
        expect(result.liveSeedUnreadable, isTrue);
        expect(result.isEmpty, isFalse);
        expect(result.seedPhrasesRestored, 0);
        expect(result.duplicatesDropped, 0);
        verifyNever(() => vault.delete(any()));
        expect(
          vaultStore.containsKey('mallow_mnemonic_seed_${first.id}'),
          isTrue,
        );
        expect(
          vaultStore.containsKey('mallow_mnemonic_seed_${second.id}'),
          isTrue,
        );
      },
    );

    // Every cold start of every synced user runs this. Reading each live seed
    // up front to answer "is anything dormant?" spends N vault decrypts and
    // holds N plaintext mnemonics in memory for zero work.
    test('reads no secret when the graph and the database agree', () async {
      await repo.createSeedPhrase(_abandonMnemonic);
      await repo.syncWalletGraph();
      clearInteractions(vault);

      final result = await repo.restoreDormantFromGraph();

      expect(result.isEmpty, isTrue);
      // The graph itself comes through the same channel, so exclude its key:
      // what must not happen is a *secret* read.
      verifyNever(
        () => vault.read(
          any(that: isNot('mallow_account_graph')),
          prompt: any(named: 'prompt'),
        ),
      );
    });

    // Regression: one bad entry threw out of the loop, so the entries after it
    // were never looked at and the caller lost every count it reports.
    test('a malformed dormant entry does not stop the others', () async {
      final broken = await repo.createSeedPhrase(_abandonMnemonic);
      final good = await repo.createSeedPhrase(_legalMnemonic);
      await db.clearAll(); // both dormant; the graph still lists them

      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      for (final sp
          in (graph['seedPhrases'] as List<dynamic>)
              .cast<Map<String, dynamic>>()) {
        if (sp['id'] == broken.id) sp.remove('name');
      }
      await storage.storeAccountGraph(jsonEncode(graph));

      final result = await repo.restoreDormantFromGraph();

      expect(result.skipped, 1);
      expect(result.seedPhrasesRestored, 1);
      expect((await repo.getAllSeedPhrases()).map((s) => s.id), [good.id]);
    });

    // The importable form of the Solana key a mnemonic derives at [index] —
    // the same key material the HD wallet row at that address holds. Lets a
    // test stand an imported-key row and a seed wallet at one address, which
    // is the collision the live database forbids and the graph can hold.
    Future<({String key, String address})> seedWalletKey(
      String mnemonic, {
      int index = 0,
    }) async {
      final kp = await MultiChainDerivation.deriveSolanaWithAccount(
        mnemonic,
        account: index,
      );
      final data = await kp.extract();
      return (
        key: base58encode([...data.bytes, ...data.publicKey.bytes]),
        address: kp.address,
      );
    }

    // Regression: the wallet pass asked "is this address live?" of a snapshot
    // taken before the seed pass ran, so a dormant seed and a dormant imported
    // key at one address were both written — two signing rows at one address,
    // which every import path refuses against the live database, and nothing
    // merges them afterwards.
    test(
      'a dormant seed and a dormant key at one address leave one row',
      () async {
        final k = await seedWalletKey(_abandonMnemonic);
        final imported = await repo.addImportedKeyWallet(k.key, 'Imported');
        await db.clearAll(); // the key entry goes dormant
        final seed = await repo.createSeedPhrase(_abandonMnemonic);
        await db.clearAll(); // and so does the seed that derives the same key
        await repo.createSeedPhrase(
          _legalMnemonic,
        ); // a live wallet, as at boot

        final result = await repo.restoreDormantFromGraph();

        expect(result.seedPhrasesRestored, 1);
        expect(result.duplicatesDropped, 1);
        final atAddress = (await repo.getAllWallets())
            .where((w) => w.address == k.address)
            .toList();
        expect(atAddress, hasLength(1));
        expect(atAddress.single.seedPhraseId, seed.id);
        // The dormant key is the copy that goes: the seed derives it again.
        expect(vaultStore.containsKey('mallow_pk_${imported.id}'), isFalse);
        final graph =
            jsonDecode((await storage.loadAccountGraph())!)
                as Map<String, dynamic>;
        expect(
          (graph['wallets'] as List<dynamic>).map(
            (e) => (e as Map<String, dynamic>)['id'],
          ),
          isNot(contains(imported.id)),
        );
      },
    );

    // Regression: the live mnemonics were read once, before the loop, so a
    // second dormant seed holding the SAME phrase was compared against a set
    // that did not include the seed just restored from it — and was written as
    // a second seed row with a second copy of every wallet it derives.
    test('two dormant seeds with one mnemonic restore once', () async {
      final first = await repo.createSeedPhrase(_abandonMnemonic);
      await db.clearAll();
      final second = await repo.createSeedPhrase(_abandonMnemonic);
      expect(second.id, isNot(first.id));
      await db.clearAll();
      await repo.createSeedPhrase(_legalMnemonic);

      final result = await repo.restoreDormantFromGraph();

      expect(result.seedPhrasesRestored, 1);
      expect(result.duplicatesDropped, 1);
      expect(result.skipped, 0);
      final liveIds = (await repo.getAllSeedPhrases()).map((s) => s.id).toSet();
      expect(liveIds, hasLength(2)); // the legal seed, and one abandon copy
      final restored = liveIds.contains(first.id) ? first.id : second.id;
      final dropped = restored == first.id ? second.id : first.id;
      expect(liveIds, isNot(contains(dropped)));
      expect(vaultStore['mallow_mnemonic_seed_$restored'], _abandonMnemonic);
      expect(vaultStore.containsKey('mallow_mnemonic_seed_$dropped'), isFalse);
      // One set of wallets, not two: no address appears twice.
      final addresses = (await repo.getAllWallets())
          .map((w) => w.address)
          .toList();
      expect(addresses.toSet(), hasLength(addresses.length));
    });

    // Regression: the seed pass wrote every wallet the graph listed for the
    // seed without checking those addresses against the live database, so a
    // live imported key and a restored seed wallet became two signing rows at
    // one address. The address identifies the key, so the row already there
    // holds this key material; dropping the entry loses nothing, because the
    // mnemonic that derives it is exactly what is being restored.
    test(
      'a restored seed skips the wallet whose address a live row holds',
      () async {
        final k = await seedWalletKey(_abandonMnemonic);
        final seed = await repo.createSeedPhrase(_abandonMnemonic);
        final derivedRows = await repo.getAllWallets();
        final collides = derivedRows.firstWhere((w) => w.address == k.address);
        await db.clearAll();
        final live = await repo.addImportedKeyWallet(k.key, 'Imported');

        final result = await repo.restoreDormantFromGraph();

        expect(result.seedPhrasesRestored, 1);
        expect(result.walletsRestored, derivedRows.length - 1);
        expect(result.duplicatesDropped, 1); // the colliding wallet entry
        final atAddress = (await repo.getAllWallets())
            .where((w) => w.address == k.address)
            .toList();
        expect(atAddress.single.id, live.id);
        // Nothing irrecoverable went with the entry: the seed is back, its
        // mnemonic is untouched, and the live row keeps its key.
        expect(vaultStore['mallow_mnemonic_seed_${seed.id}'], _abandonMnemonic);
        expect(vaultStore.containsKey('mallow_pk_${live.id}'), isTrue);
        // Pruned, not left dormant forever: its seed is live now, so no later
        // pass would ever look at it again.
        final graph =
            jsonDecode((await storage.loadAccountGraph())!)
                as Map<String, dynamic>;
        expect(
          (graph['wallets'] as List<dynamic>).map(
            (e) => (e as Map<String, dynamic>)['id'],
          ),
          isNot(contains(collides.id)),
        );
      },
    );

    // Spec: a malformed entry counts as skipped. An address-less one returned
    // silently, so a launch that looked at one entry and did nothing with it
    // reported `isEmpty` — and the caller sent nothing to Sentry at all.
    test('an address-less dormant wallet entry counts as skipped', () async {
      final k = await _importableKey(0xa1);
      final imported = await repo.addImportedKeyWallet(k.key, 'Imported');
      await db.clearAll();
      await repo.createSeedPhrase(_legalMnemonic);

      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      for (final w
          in (graph['wallets'] as List<dynamic>).cast<Map<String, dynamic>>()) {
        if (w['id'] == imported.id) w.remove('address');
      }
      await storage.storeAccountGraph(jsonEncode(graph));

      final result = await repo.restoreDormantFromGraph();

      expect(result.skipped, 1);
      expect(result.isEmpty, isFalse); // the counts still reach the caller
      expect(result.walletsRestored, 0);
      expect(result.duplicatesDropped, 0);
    });

    // Every prune is a full graph rebuild — three table reads, a graph read
    // and a Keychain write — and this runs before the first route is resolved.
    // One write for the launch, not one per duplicate entry.
    test('duplicates from both passes cost one graph write', () async {
      final k = await _importableKey(0xb1);
      final dormantSeed = await repo.createSeedPhrase(_abandonMnemonic);
      final dormantKey = await repo.addImportedKeyWallet(k.key, 'Imported');
      await db.clearAll();
      final liveSeed = await repo.createSeedPhrase(_abandonMnemonic);
      final liveKey = await repo.addImportedKeyWallet(k.key, 'Imported again');
      clearInteractions(vault);

      final result = await repo.restoreDormantFromGraph();

      expect(result.duplicatesDropped, 2);
      expect(result.skipped, 0);
      verify(() => vault.write('mallow_account_graph', any())).called(1);
      expect(
        vaultStore.containsKey('mallow_mnemonic_seed_${dormantSeed.id}'),
        isFalse,
      );
      expect(vaultStore.containsKey('mallow_pk_${dormantKey.id}'), isFalse);
      expect(
        vaultStore['mallow_mnemonic_seed_${liveSeed.id}'],
        _abandonMnemonic,
      );
      expect(vaultStore.containsKey('mallow_pk_${liveKey.id}'), isTrue);
    });

    // The graph write is the commit point of the prune too. If it fails,
    // every secret must still be there — a deleted secret whose entry the
    // graph still lists is an entry the next launch tries to restore with
    // nothing behind it.
    test(
      'a failed prune deletes nothing and counts the duplicate as skipped',
      () async {
        final dormant = await repo.createSeedPhrase(_abandonMnemonic);
        await db.clearAll();
        await repo.createSeedPhrase(_abandonMnemonic);
        when(
          () => vault.write('mallow_account_graph', any()),
        ).thenThrow(PlatformException(code: 'write_failed'));

        final result = await repo.restoreDormantFromGraph();

        expect(result.skipped, 1);
        expect(result.duplicatesDropped, 0);
        expect(
          vaultStore.containsKey('mallow_mnemonic_seed_${dormant.id}'),
          isTrue,
        );
      },
    );

    // The boot path reads the graph for its own backfill check; reading it
    // again here costs a second protected-data probe and Keychain fetch on
    // every cold start.
    test('takes the graph the caller already read', () async {
      final old = await repo.createSeedPhrase(_abandonMnemonic);
      await db.clearAll();
      await repo.createSeedPhrase(_legalMnemonic);
      final graphJson = (await storage.loadAccountGraph())!;
      clearInteractions(vault);

      final result = await repo.restoreDormantFromGraph(graphJson: graphJson);

      expect(result.seedPhrasesRestored, 1);
      expect(
        (await repo.getAllSeedPhrases()).map((s) => s.id),
        contains(old.id),
      );
      verifyNever(
        () => vault.read('mallow_account_graph', prompt: any(named: 'prompt')),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Concurrent mutations
  // ---------------------------------------------------------------------------

  // The recovery graph is rebuilt from the *whole* database on every mutation,
  // so two mutations in flight un-prune each other. A removal prunes an entry
  // and only then deletes its rows and its secret; anything that syncs the
  // graph inside that gap reads a database that still holds the rows and
  // writes the entry straight back — now indexing a secret about to be
  // deleted. That entry is a zombie: the reinstall restore aborts on it at
  // every attempt, and the only other action on that screen erases the
  // readable seeds too.
  group('concurrent mutations', () {
    Future<Set<String>> storedSeedIds() async {
      final graph =
          jsonDecode((await storage.loadAccountGraph())!)
              as Map<String, dynamic>;
      return (graph['seedPhrases'] as List<dynamic>)
          .map((e) => (e as Map<String, dynamic>)['id'] as String)
          .toSet();
    }

    // A plain sync is not a rare partner: the Edit-accounts screen reorders
    // every account it lists, and a removal starts from that same list.
    test('a reorder running with a removal does not resurrect the removed '
        'seed', () async {
      final keep = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      await importSolanaAt(keep.id, [0, 1, 2, 3, 4]);
      final doomed = await repo.createSeedPhrase(
        _legalMnemonic,
        autoDerive: false,
      );
      await importSolanaAt(doomed.id, [0]);
      final accounts = await repo.getAccountViews();
      final victim = accounts.singleWhere((a) => a.seedPhraseId == doomed.id);
      final order = accounts.map((a) => a.id).toList().reversed.toList();

      await Future.wait([
        repo.removeAccount(victim.id),
        repo.reorderAccounts(order),
      ]);

      expect(await storedSeedIds(), isNot(contains(doomed.id)));
      expect(
        vaultStore.containsKey('mallow_mnemonic_seed_${doomed.id}'),
        isFalse,
      );
    });

    // Two removals do it to each other: each computes its prune from a
    // database snapshot the other has not deleted from yet.
    test('two removals do not resurrect each other', () async {
      final a = await repo.createSeedPhrase(_abandonMnemonic);
      final b = await repo.createSeedPhrase(_legalMnemonic);
      final accounts = await repo.getAccountViews();
      final accA = accounts.singleWhere((x) => x.seedPhraseId == a.id);
      final accB = accounts.singleWhere((x) => x.seedPhraseId == b.id);

      await Future.wait([
        repo.removeAccount(accA.id),
        repo.removeAccount(accB.id),
      ]);

      expect(await storedSeedIds(), isEmpty);
      expect(vaultStore.containsKey('mallow_mnemonic_seed_${a.id}'), isFalse);
      expect(vaultStore.containsKey('mallow_mnemonic_seed_${b.id}'), isFalse);
      expect(await repo.getAllWallets(), isEmpty);
    });

    // The boot path runs both of these: the eager backfill sync and the
    // dormant restore, whose prune has the same delete-after-commit gap.
    test('a sync running with the dormant restore leaves no entry whose vault '
        'item is gone', () async {
      final dormant = await repo.createSeedPhrase(_abandonMnemonic);
      await db.clearAll();
      await repo.createSeedPhrase(_abandonMnemonic); // same secret, now live

      // Two keystore writes in flight land in whatever order the platform
      // finishes them; nothing orders one round trip against another. Pin the
      // order that hurts — the write issued first lands last — so the test
      // measures the interleaving rather than the machine it runs on.
      var remaining = 2;
      when(() => vault.write('mallow_account_graph', any())).thenAnswer((
        inv,
      ) async {
        final value = inv.positionalArguments[1] as String;
        await Future<void>.delayed(Duration(milliseconds: 10 * remaining--));
        vaultStore['mallow_account_graph'] = value;
      });

      await Future.wait([
        repo.syncWalletGraph(),
        repo.restoreDormantFromGraph(),
      ]);

      final ids = await storedSeedIds();
      expect(ids, isNot(contains(dormant.id)));
      for (final id in ids) {
        expect(
          vaultStore.containsKey('mallow_mnemonic_seed_$id'),
          isTrue,
          reason: 'the graph names seed $id, whose mnemonic is gone',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Global account counter
  // ---------------------------------------------------------------------------

  group('global account counter', () {
    // Names of every account, keyed by derivation index where present, so a
    // test can assert what number each account received.
    Future<Map<int?, String>> accountNamesByIndex() async {
      final views = await repo.getAccountViews();
      return {for (final a in views) a.derivationIndex: a.name};
    }

    test(
      'names accounts Account 01, 02, … sequentially across one import',
      () async {
        final sp = await repo.createSeedPhrase(
          _abandonMnemonic,
          autoDerive: false,
        );
        await importSolanaAt(sp.id, [0, 1, 2]);

        expect(await accountNamesByIndex(), {
          0: 'Account 01',
          1: 'Account 02',
          2: 'Account 03',
        });
      },
    );

    test('shares one counter across account kinds (view-only continues the '
        'sequence)', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      await importSolanaAt(sp.id, [0, 1]); // Account 01, 02

      await repo.addViewOnlyWallet(
        'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH',
        'My Watch',
      );

      final views = await repo.getAccountViews();
      final viewOnly = views.firstWhere((a) => a.kind == AccountKind.viewOnly);
      // The view-only account label comes from the global counter, not its
      // bespoke wallet name.
      expect(viewOnly.name, 'Account 03');
    });

    test(
      'high-water mark: deleting an account does not reuse its number',
      () async {
        final sp = await repo.createSeedPhrase(
          _abandonMnemonic,
          autoDerive: false,
        );
        final imported = await importSolanaAt(sp.id, [0, 1, 2]); // 01, 02, 03

        // Remove Account 02 (derivation index 1).
        final wallet1 = imported.firstWhere((w) => w.derivationIndex == 1);
        await repo.removeWallet(wallet1.id);

        // Import another index — it must continue past the high-water mark (03),
        // not refill the freed 02.
        await importSolanaAt(sp.id, [3]);

        final names = await accountNamesByIndex();
        expect(names[3], 'Account 04');
      },
    );

    test('resetAll restarts numbering at Account 01', () async {
      final sp = await repo.createSeedPhrase(
        _abandonMnemonic,
        autoDerive: false,
      );
      await importSolanaAt(sp.id, [0, 1, 2]); // 01, 02, 03

      await repo.resetAll();

      final sp2 = await repo.createSeedPhrase(
        _legalMnemonic,
        autoDerive: false,
      );
      await importSolanaAt(sp2.id, [0]);

      expect((await accountNamesByIndex())[0], 'Account 01');
    });
  });

  // WHY: the push-token sync mirrors the wallets held on this device, and it
  // learns about changes from this counter alone. Hanging it off the mutation
  // lock rather than off each add/remove entry point is deliberate — a new
  // mutation added later cannot forget to signal, which is the exact class of
  // omission that left push dead in production for months.
  group('walletsRevision', () {
    test('bumps when a wallet is added', () async {
      final before = repo.walletsRevision.value;

      await repo.addViewOnlyWallet('WatchAddr111', 'Watch');

      expect(repo.walletsRevision.value, greaterThan(before));
    });

    test('bumps when a wallet is removed', () async {
      final wallet = await repo.addViewOnlyWallet('WatchAddr222', 'Watch');
      final before = repo.walletsRevision.value;

      await repo.removeWallet(wallet.id);

      expect(repo.walletsRevision.value, greaterThan(before));
    });

    test('does not bump when a mutation throws', () async {
      // A rejected duplicate changed nothing, so a listener that re-reads and
      // re-POSTs on every bump would be doing it for no reason.
      await repo.addViewOnlyWallet('DupWatch333', 'A');
      final before = repo.walletsRevision.value;

      await expectLater(
        () => repo.addViewOnlyWallet('DupWatch333', 'B'),
        throwsA(anything),
      );

      expect(repo.walletsRevision.value, before);
    });

    test('notifies listeners so the sync is scheduled', () async {
      var notified = 0;
      repo.walletsRevision.addListener(() => notified++);

      await repo.addViewOnlyWallet('WatchAddr444', 'Watch');

      expect(notified, greaterThan(0));
    });
  });
}
