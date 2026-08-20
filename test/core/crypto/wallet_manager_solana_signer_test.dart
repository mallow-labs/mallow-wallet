import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/mnemonic_vault.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockFss extends Mock implements FlutterSecureStorage {}

class _MockVault extends Mock implements MnemonicVault {}

class _MockLedgerService extends Mock implements LedgerService {}

/// The Solana signing entry points resolve their keypair from the *globally
/// selected* wallet ([WalletInfo.bindsGlobalSigner]), not from an explicit
/// wallet id, so nothing stops the selection sitting on an Ethereum or Tezos
/// row — the wallet-removal fallback prefers a Solana row but cannot guarantee
/// one exists. These tests pin how that reaches the user.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MallowDatabase db;
  late SecureWalletStorage storage;
  late WalletManager manager;

  final fssStore = <String, String>{};
  final vaultStore = <String, String>{};

  setUp(() async {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    final fss = _MockFss();
    final vault = _MockVault();
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

    when(() => vault.read(any(), prompt: any(named: 'prompt'))).thenAnswer(
      (inv) async => vaultStore[inv.positionalArguments[0] as String],
    );

    when(() => vault.write(any(), any())).thenAnswer((inv) async {
      vaultStore[inv.positionalArguments[0] as String] =
          inv.positionalArguments[1] as String;
    });

    storage = SecureWalletStorage(fss, vault);
    final prefs = await PreferencesService.create();
    manager = WalletManager(
      storage,
      db,
      WalletRepository(db, storage, prefs),
      _MockLedgerService(),
    );
  });

  tearDown(() => db.close());

  /// Insert a signing row on [chain] and make it the global selection.
  Future<void> selectRow({
    required WalletType walletType,
    required Chain chain,
  }) async {
    const id = 'row-1';
    await db.upsertWalletEntry(
      WalletsCompanion.insert(
        id: id,
        address: 'addr-1',
        name: 'Wallet',
        walletType: walletType.toDbString(),
        chain: Value(chain.toDbString()),
        createdAt: 0,
      ),
    );
    await storage.storePrivateKey(id, 'deadbeef');
    await storage.storeSelectedWalletId(id);
  }

  for (final walletType in [WalletType.social, WalletType.importedKey]) {
    for (final chain in [Chain.ethereum, Chain.tezos]) {
      test(
        'getPublicKey on a ${walletType.name} ${chain.name} selection throws '
        'NonSolanaSigningWalletException',
        () async {
          // Why: these rows store a raw hex secret (secp256k1 key / ed25519
          // seed), not the base58 Solana keypair the loader decodes. A bare
          // StateError here is unclassified by [AppFailure.from], so the user
          // gets a crashy "Bad state: …" instead of copy telling them to
          // switch wallets.
          await selectRow(walletType: walletType, chain: chain);

          await expectLater(
            manager.getPublicKey(),
            throwsA(isA<NonSolanaSigningWalletException>()),
          );
        },
      );
    }
  }
}
