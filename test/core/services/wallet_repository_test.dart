import 'dart:convert';

import 'package:drift/native.dart';
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

/// Standard BIP-39 test vector — a valid 12-word mnemonic.
const _abandonMnemonic =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// A second valid mnemonic (different from [_abandonMnemonic]) so dedupe and
/// multi-seed-phrase behaviour can be exercised distinctly.
const _legalMnemonic =
    'legal winner thank year wave sausage worth useful legal winner thank yellow';

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

        final ok = await repo.restoreFromGraph(graphJson);
        expect(ok, isTrue);

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

    test('restoreFromGraph returns false on malformed JSON', () async {
      expect(await repo.restoreFromGraph('{not valid json'), isFalse);
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
}
