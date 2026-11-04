import 'dart:async';
import 'dart:typed_data';

import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:keystone_ur/keystone_ur.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/keystone/services/keystone_connect_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/solana.dart' show Ed25519HDPublicKey;

class _MockRepo extends Mock implements WalletRepository {}

class _MockTokens extends Mock implements TokenRepository {}

class _MockPortfolio extends Mock implements PortfolioRepository {}

class _MockSession extends Mock implements SessionManager {}

/// The export a user scans is untrusted, and its contents decide which key
/// every later signature comes from. These tests pin that the import maps each
/// exported path to the scheme and index the row will sign with, keeps the
/// device's fingerprint on every row, and refuses exports it cannot honour.
void main() {
  const fingerprint = 0x23D048F0;

  Uint8List key(int fill) => Uint8List.fromList(List<int>.filled(32, fill));
  String address(int fill) => Ed25519HDPublicKey(key(fill)).toBase58();

  KeystoneHdKey hdKey(
    int fill,
    String path, {
    int masterFingerprint = fingerprint,
  }) => KeystoneHdKey(
    keyData: key(fill),
    origin: KeystoneKeypath.parse(path, sourceFingerprint: masterFingerprint),
  );

  UR export(List<KeystoneHdKey> keys, {int masterFingerprint = fingerprint}) =>
      KeystoneMultiAccounts(
        masterFingerprint: masterFingerprint,
        keys: keys,
        device: 'Keystone 3 Pro',
      ).toUr();

  late _MockRepo repo;
  late _MockTokens tokens;
  late _MockPortfolio portfolio;
  late _MockSession session;

  setUpAll(() {
    registerFallbackValue(SolanaDerivationScheme.standard);
    registerFallbackValue(Chain.solana);
    registerFallbackValue(<String>[]);
  });

  setUp(() {
    repo = _MockRepo();
    tokens = _MockTokens();
    portfolio = _MockPortfolio();
    session = _MockSession();
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    sl.registerSingleton<SessionManager>(session);
    when(() => session.switchToWallet(any())).thenAnswer((_) async {});
    when(
      () => session.activeProfileContainsAnyAddress(any()),
    ).thenReturn(false);

    when(repo.getAllWallets).thenAnswer((_) async => const []);
    when(repo.getAccountViews).thenAnswer((_) async => const <Account>[]);
    when(repo.peekNextAccountNumber).thenAnswer((_) async => 1);
    when(
      () => repo.addKeystoneWallet(
        any(),
        any(),
        masterFingerprint: any(named: 'masterFingerprint'),
        derivationIndex: any(named: 'derivationIndex'),
        derivationScheme: any(named: 'derivationScheme'),
        accountName: any(named: 'accountName'),
      ),
    ).thenAnswer((inv) async {
      return WalletInfo(
        id: 'w-${inv.positionalArguments[0]}',
        address: inv.positionalArguments[0] as String,
        name: inv.positionalArguments[1] as String,
        walletType: WalletType.keystone,
        chain: 'solana',
      );
    });

    when(
      () => tokens.getCachedBalances(any()),
    ).thenAnswer((_) async => const []);
    when(
      () => tokens.getTokenBalances(any()),
    ).thenAnswer((_) async => const []);
    when(() => tokens.cacheBalances(any(), any())).thenAnswer((_) async {});
    when(() => tokens.calculateTotalValue(any())).thenReturn(0);
    when(
      () => portfolio.artworkCountForOwner(any()),
    ).thenAnswer((_) async => 0);
  });

  tearDown(() {
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
  });

  KeystoneConnectBloc build() => KeystoneConnectBloc(repo, tokens, portfolio);

  Future<KeystoneAccountsLoaded> loaded(KeystoneConnectBloc bloc) async =>
      await bloc.stream.firstWhere(
            (s) =>
                s is KeystoneAccountsLoaded &&
                s.accounts.every((a) => a.isEnriched),
          )
          as KeystoneAccountsLoaded;

  group('parseKeystoneCode', () {
    test('maps every Solana path shape to its scheme and index', () {
      final parsed = parseKeystoneCode(
        export([
          hdKey(1, "m/44'/501'/0'/0'"),
          hdKey(2, "m/44'/501'/0'"),
          hdKey(3, "m/44'/501'"),
          hdKey(4, "m/44'/501'/7'/0'"),
        ]),
      );

      expect(parsed.masterFingerprint, fingerprint);
      expect(parsed.ethereum, isNull);
      final byAddress = {for (final w in parsed.solana) w.address: w};
      expect(byAddress[address(1)]?.scheme, SolanaDerivationScheme.standard);
      expect(byAddress[address(1)]?.index, 0);
      expect(byAddress[address(2)]?.scheme, SolanaDerivationScheme.legacy);
      expect(byAddress[address(3)]?.scheme, SolanaDerivationScheme.root);
      expect(byAddress[address(3)]?.index, 0);
      expect(byAddress[address(4)]?.index, 7);
    });

    test('refuses a code with neither Solana accounts nor an Ethereum '
        'key', () {
      expect(
        () => parseKeystoneCode(export([hdKey(1, "m/44'/60'/0'")])),
        throwsA(
          isA<UrDecodeException>().having(
            (e) => e.message,
            'message',
            contains('no Solana or Ethereum accounts'),
          ),
        ),
      );
    });

    test('refuses an export with no fingerprint', () {
      // Zero is what an absent field decodes to; every request would name it
      // and the device would refuse them all.
      expect(
        () => parseKeystoneCode(
          export([hdKey(1, "m/44'/501'/0'/0'")], masterFingerprint: 0),
        ),
        throwsA(isA<UrDecodeException>()),
      );
    });
  });

  test('a scanned export becomes one card per index, standard first', () async {
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(
      KeystoneExportScanned(
        export([
          hdKey(2, "m/44'/501'/0'"),
          hdKey(1, "m/44'/501'/0'/0'"),
          hdKey(5, "m/44'/501'/1'/0'"),
        ]),
      ),
    );
    final state = await loaded(bloc);

    expect(state.masterFingerprint, fingerprint);
    expect(state.accounts.map((a) => a.index), [0, 1]);
    // Legacy rows are shown, not hidden behind a toggle: the export is already
    // the user's choice of path.
    expect(state.accounts.first.wallets.map((w) => w.scheme), [
      SolanaDerivationScheme.standard,
      SolanaDerivationScheme.legacy,
    ]);
  });

  test('a refused export goes back to the scanner with the reason', () async {
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/60'/0'")])));
    final state = await bloc.stream.first;

    expect(state, isA<KeystoneScanning>());
    expect(
      (state as KeystoneScanning).error,
      'That code has no Solana or Ethereum accounts. On your Keystone, open '
      'Connect Software Wallet and choose Solflare or MetaMask.',
    );
  });

  for (final (name, ur, kind, diagnostic) in [
    (
      'malformed CBOR',
      UR(kKeystoneExportType, Uint8List.fromList([0xff])),
      UrDecodeErrorKind.malformed,
      'malformed CBOR',
    ),
    (
      'too many keys',
      export(List.generate(65, (_) => hdKey(1, "m/44'/501'/0'/0'"))),
      UrDecodeErrorKind.limitExceeded,
      '65 keys exceeds the limit of 64',
    ),
    (
      'a non-hardened Solana path',
      export([hdKey(1, "m/44'/501'/0'/0")]),
      UrDecodeErrorKind.malformed,
      'non-hardened path',
    ),
  ]) {
    test(
      'an export with $name shows guidance instead of diagnostics',
      () async {
        expect(
          () => parseKeystoneCode(ur),
          throwsA(
            isA<UrDecodeException>()
                .having((e) => e.kind, 'kind', kind)
                .having((e) => e.message, 'diagnostic', contains(diagnostic)),
          ),
        );
        final bloc = build();
        addTearDown(bloc.close);

        bloc.add(KeystoneExportScanned(ur));
        final state = await bloc.stream.first;

        expect(state, isA<KeystoneScanning>());
        expect(
          (state as KeystoneScanning).error,
          "That code couldn't be read. On your Keystone, open Connect "
          'Software Wallet and choose Solflare or MetaMask.',
        );
        verifyNever(repo.peekNextAccountNumber);

        bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
        expect(
          (await loaded(bloc)).accounts.single.wallets.single.address,
          address(1),
        );
      },
    );
  }

  test('rescan during enrichment does not resurrect the old export', () async {
    final artworks = Completer<int>();
    when(
      () => portfolio.artworkCountForOwner(address(1)),
    ).thenAnswer((_) => artworks.future);
    final bloc = build();
    addTearDown(bloc.close);
    final states = <KeystoneConnectState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);

    bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
    await bloc.stream.firstWhere((s) => s is KeystoneAccountsLoaded);
    bloc.add(const KeystoneRescanRequested());
    await bloc.stream.firstWhere((s) => s is KeystoneScanning);
    final countAfterRescan = states.length;

    artworks.complete(3);
    await pumpEventQueue();

    expect(bloc.state, isA<KeystoneScanning>());
    expect(states, hasLength(countAfterRescan));
  });

  test(
    'a stale device never replaces the new device or its import identity',
    () async {
      const otherFingerprint = 0x11111111;
      final artworks = Completer<int>();
      when(
        () => portfolio.artworkCountForOwner(address(1)),
      ).thenAnswer((_) => artworks.future);
      final bloc = build();
      addTearDown(bloc.close);

      bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
      await bloc.stream.firstWhere((s) => s is KeystoneAccountsLoaded);
      bloc.add(const KeystoneRescanRequested());
      await bloc.stream.firstWhere((s) => s is KeystoneScanning);
      bloc.add(
        KeystoneExportScanned(
          export([
            hdKey(2, "m/44'/501'/0'/0'", masterFingerprint: otherFingerprint),
          ], masterFingerprint: otherFingerprint),
        ),
      );
      final newDevice = await loaded(bloc);

      artworks.complete(3);
      await pumpEventQueue();

      final state = bloc.state as KeystoneAccountsLoaded;
      expect(state.masterFingerprint, otherFingerprint);
      expect(state.accounts.single.wallets.single.address, address(2));
      bloc.add(
        KeystoneToggleWallet(newDevice.accounts.single.wallets.single.key),
      );
      bloc.add(const KeystoneImportRequested());
      await bloc.stream.firstWhere((s) => s is KeystoneImported);
      verify(
        () => repo.addKeystoneWallet(
          address(2),
          'Solana',
          masterFingerprint: otherFingerprint,
        ),
      ).called(1);
    },
  );

  test(
    'duplicate scans are ignored during loading and in the picker',
    () async {
      final nextNumber = Completer<int>();
      when(repo.peekNextAccountNumber).thenAnswer((_) => nextNumber.future);
      final bloc = build();
      addTearDown(bloc.close);
      final scan = KeystoneExportScanned(
        export([hdKey(1, "m/44'/501'/0'/0'")]),
      );

      bloc.add(scan);
      bloc.add(scan);
      await pumpEventQueue();
      nextNumber.complete(1);
      final state = await loaded(bloc);
      bloc.add(KeystoneToggleWallet(state.accounts.single.wallets.single.key));
      await bloc.stream.firstWhere(
        (s) => s is KeystoneAccountsLoaded && s.selectedKeys.isNotEmpty,
      );
      bloc.add(scan);
      await pumpEventQueue();

      expect((bloc.state as KeystoneAccountsLoaded).selectedKeys, isNotEmpty);
      verify(repo.peekNextAccountNumber).called(1);
      verify(() => portfolio.artworkCountForOwner(address(1))).called(1);
    },
  );

  for (final stage in ['account number', 'wallets', 'account names']) {
    test('rescan during $stage lookup discards the pending export', () async {
      final gate = Completer<void>();
      switch (stage) {
        case 'account number':
          when(repo.peekNextAccountNumber).thenAnswer((_) async {
            await gate.future;
            return 1;
          });
        case 'wallets':
          when(repo.getAllWallets).thenAnswer((_) async {
            await gate.future;
            return const [];
          });
        case 'account names':
          when(repo.getAccountViews).thenAnswer((_) async {
            await gate.future;
            return const <Account>[];
          });
      }
      final bloc = build();
      addTearDown(bloc.close);
      final states = <KeystoneConnectState>[];
      final subscription = bloc.stream.listen(states.add);
      addTearDown(subscription.cancel);
      bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
      await pumpEventQueue();
      bloc.add(const KeystoneRescanRequested());
      await bloc.stream.firstWhere((s) => s is KeystoneScanning);

      gate.complete();
      await pumpEventQueue();

      expect(bloc.state, isA<KeystoneScanning>());
      expect(states.whereType<KeystoneAccountsLoaded>(), isEmpty);
      verifyNever(() => portfolio.artworkCountForOwner(any()));
    });
  }

  test('a superseded lookup error does not replace the new picker', () async {
    final pendingWallets = Completer<List<WalletInfo>>();
    var lookups = 0;
    when(repo.getAllWallets).thenAnswer((_) {
      return lookups++ == 0 ? pendingWallets.future : Future.value(const []);
    });
    final bloc = build();
    addTearDown(bloc.close);
    bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
    await pumpEventQueue();
    bloc.add(const KeystoneRescanRequested());
    await bloc.stream.firstWhere((s) => s is KeystoneScanning);
    bloc.add(KeystoneExportScanned(export([hdKey(2, "m/44'/501'/0'/0'")])));
    final state = await loaded(bloc);

    pendingWallets.completeError(StateError('old lookup failed'));
    await pumpEventQueue();

    expect(bloc.state, same(state));
  });

  test(
    'enrichment finishing during import does not reopen the picker',
    () async {
      final artworks = Completer<int>();
      final savedWallet = Completer<WalletInfo>();
      when(
        () => portfolio.artworkCountForOwner(address(1)),
      ).thenAnswer((_) => artworks.future);
      when(
        () => repo.addKeystoneWallet(
          any(),
          any(),
          masterFingerprint: any(named: 'masterFingerprint'),
          derivationIndex: any(named: 'derivationIndex'),
          derivationScheme: any(named: 'derivationScheme'),
        ),
      ).thenAnswer((_) => savedWallet.future);
      final bloc = build();
      addTearDown(bloc.close);
      bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
      final state =
          await bloc.stream.firstWhere((s) => s is KeystoneAccountsLoaded)
              as KeystoneAccountsLoaded;
      bloc.add(KeystoneToggleWallet(state.accounts.single.wallets.single.key));
      bloc.add(const KeystoneImportRequested());
      await bloc.stream.firstWhere((s) => s is KeystoneImporting);

      artworks.complete(3);
      await pumpEventQueue();
      expect(bloc.state, isA<KeystoneImporting>());

      savedWallet.complete(
        WalletInfo(
          id: 'imported',
          address: address(1),
          name: 'Solana',
          walletType: WalletType.keystone,
          chain: 'solana',
        ),
      );
      await bloc.stream.firstWhere((s) => s is KeystoneImported);
    },
  );

  test('import writes each row with the fingerprint, index and scheme it was '
      'exported under, ascending by index', () async {
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(
      KeystoneExportScanned(
        export([hdKey(5, "m/44'/501'/1'/0'"), hdKey(2, "m/44'/501'/0'")]),
      ),
    );
    final state = await loaded(bloc);
    // Tap index 1 first: the import must still run in index order so the
    // previewed `Account NN` names are the ones assigned.
    for (final account in state.accounts.reversed) {
      bloc.add(KeystoneToggleWallet(account.wallets.single.key));
    }
    bloc.add(const KeystoneImportRequested());
    await bloc.stream.firstWhere((s) => s is KeystoneImported);

    final calls = verify(
      () => repo.addKeystoneWallet(
        captureAny(),
        captureAny(),
        masterFingerprint: captureAny(named: 'masterFingerprint'),
        derivationIndex: captureAny(named: 'derivationIndex'),
        derivationScheme: captureAny(named: 'derivationScheme'),
      ),
    ).captured;
    expect(calls, [
      address(2),
      'Solana (legacy)',
      fingerprint,
      0,
      SolanaDerivationScheme.legacy,
      address(5),
      'Solana',
      fingerprint,
      1,
      SolanaDerivationScheme.standard,
    ]);
    verify(() => session.switchToWallet('w-${address(5)}')).called(1);
  });

  test('import names the account the user named in the picker', () async {
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(
      KeystoneExportScanned(
        export([hdKey(1, "m/44'/501'/0'/0'"), hdKey(5, "m/44'/501'/1'/0'")]),
      ),
    );
    final state = await loaded(bloc);
    bloc
      ..add(const KeystoneRenameAccount(1, 'Savings'))
      ..add(KeystoneToggleWallet(state.accounts[0].wallets.single.key))
      ..add(KeystoneToggleWallet(state.accounts[1].wallets.single.key))
      ..add(const KeystoneImportRequested());
    await bloc.stream.firstWhere((s) => s is KeystoneImported);

    final calls = verify(
      () => repo.addKeystoneWallet(
        any(),
        any(),
        masterFingerprint: any(named: 'masterFingerprint'),
        derivationIndex: captureAny(named: 'derivationIndex'),
        derivationScheme: any(named: 'derivationScheme'),
        chain: any(named: 'chain'),
        accountName: captureAny(named: 'accountName'),
      ),
    ).captured;
    expect(calls, [0, null, 1, 'Savings']);
  });

  test('start over drops the names typed in the picker', () async {
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
    await loaded(bloc);
    bloc.add(const KeystoneRenameAccount(0, 'Savings'));
    final named =
        await bloc.stream.firstWhere((s) => s is KeystoneAccountsLoaded)
            as KeystoneAccountsLoaded;
    expect(named.customNames, {0: 'Savings'});

    bloc.add(const KeystoneRescanRequested());
    await bloc.stream.firstWhere((s) => s is KeystoneScanning);
    bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
    expect((await loaded(bloc)).customNames, isEmpty);
  });

  test('import leaves the active Profile alone when it already links an '
      'imported address', () async {
    when(() => session.activeProfileContainsAnyAddress(any())).thenReturn(true);
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
    final state = await loaded(bloc);
    bloc.add(KeystoneToggleWallet(state.accounts.single.wallets.single.key));
    bloc.add(const KeystoneImportRequested());
    await bloc.stream.firstWhere((s) => s is KeystoneImported);

    verifyNever(() => session.switchToWallet(any()));
  });

  test('an already-imported address cannot be selected', () async {
    when(repo.getAllWallets).thenAnswer(
      (_) async => [
        WalletInfo(
          id: 'existing',
          address: address(1),
          name: 'Solana',
          walletType: WalletType.keystone,
          chain: 'solana',
        ),
      ],
    );
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
    final state = await loaded(bloc);
    final wallet = state.accounts.single.wallets.single;
    expect(wallet.alreadyImported, isTrue);

    bloc.add(KeystoneToggleWallet(wallet.key));
    bloc.add(const KeystoneImportRequested());
    await pumpEventQueue();
    verifyNever(
      () => repo.addKeystoneWallet(
        any(),
        any(),
        masterFingerprint: any(named: 'masterFingerprint'),
        derivationIndex: any(named: 'derivationIndex'),
        derivationScheme: any(named: 'derivationScheme'),
      ),
    );
  });

  test('another Keystone\'s account name is not borrowed', () async {
    when(repo.getAccountViews).thenAnswer(
      (_) async => [
        Account(
          id: 'other',
          name: 'My other Keystone',
          kind: AccountKind.keystone,
          derivationIndex: 0,
          wallets: [
            WalletInfo(
              id: 'o',
              address: address(9),
              name: 'Solana',
              walletType: WalletType.keystone,
              chain: 'solana',
              masterFingerprint: 0x11111111,
            ),
          ],
        ),
      ],
    );
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
    final state = await loaded(bloc);

    expect(state.accounts.single.importedName, isNull);
  });
  group('Ethereum in a multi-chain export', () {
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon about';
    final account = bip32.BIP32
        .fromSeed(bip39.mnemonicToSeed(mnemonic))
        .derivePath("m/44'/60'/0'");

    KeystoneHdKey ethKey({String? note = 'account.standard'}) => KeystoneHdKey(
      keyData: account.publicKey,
      chainCode: account.chainCode,
      origin: KeystoneKeypath.parse(
        "m/44'/60'/0'",
        sourceFingerprint: fingerprint,
      ),
      note: note,
    );

    test('lists an Ethereum wallet at each Solana account index', () async {
      final bloc = build();
      addTearDown(bloc.close);

      bloc.add(
        KeystoneExportScanned(
          export([
            hdKey(1, "m/44'/501'/0'"),
            hdKey(2, "m/44'/501'/3'"),
            ethKey(),
          ]),
        ),
      );
      final state = await loaded(bloc);

      final eth = state.accounts
          .expand((a) => a.wallets)
          .where((w) => w.chain == Chain.ethereum);
      expect(eth.map((w) => w.accountIndex), [0, 3]);
      for (final w in eth) {
        expect(w.scheme, isNull);
        expect(
          w.address,
          await MultiChainDerivation.getEthereumAddressAtIndex(
            mnemonic,
            w.accountIndex,
          ),
        );
      }
    });

    test('an Ethereum key that is not a curve point adds no Ethereum rows '
        'and keeps the Solana ones', () {
      // x = 0 has no y on secp256k1. The decoder checks only length and
      // prefix, so derivation is where it fails.
      final parsed = parseKeystoneCode(
        export([
          hdKey(1, "m/44'/501'/0'"),
          KeystoneHdKey(
            keyData: Uint8List.fromList([0x02, ...List.filled(32, 0)]),
            chainCode: Uint8List.fromList(List.filled(32, 9)),
            origin: KeystoneKeypath.parse(
              "m/44'/60'/0'",
              sourceFingerprint: fingerprint,
            ),
            note: 'account.standard',
          ),
        ]),
      );
      expect(parsed.solana, hasLength(1));
      expect(parsed.ethereum, isNull);
    });

    test('a Ledger-layout Ethereum key adds no Ethereum rows', () {
      final parsed = parseKeystoneCode(
        export([
          hdKey(1, "m/44'/501'/0'"),
          ethKey(note: 'account.ledger_legacy'),
        ]),
      );
      expect(parsed.solana, hasLength(1));
      expect(parsed.ethereum, isNull);
    });

    test('the picker shows the Ethereum row after the Solana one, and import '
        'writes it as an Ethereum Keystone row on the same index', () async {
      when(
        () => repo.addKeystoneWallet(
          any(),
          any(),
          masterFingerprint: any(named: 'masterFingerprint'),
          derivationIndex: any(named: 'derivationIndex'),
          derivationScheme: any(named: 'derivationScheme'),
          chain: any(named: 'chain'),
        ),
      ).thenAnswer(
        (inv) async => WalletInfo(
          id: 'w-${inv.positionalArguments[0]}',
          address: inv.positionalArguments[0] as String,
          name: inv.positionalArguments[1] as String,
          walletType: WalletType.keystone,
          chain: (inv.namedArguments[#chain] as Chain).toDbString(),
        ),
      );
      final bloc = build();
      addTearDown(bloc.close);

      bloc.add(
        KeystoneExportScanned(export([hdKey(1, "m/44'/501'/2'"), ethKey()])),
      );
      final state = await loaded(bloc);
      final rows = state.accounts.single.wallets;
      expect(rows.map((w) => w.chain), [Chain.solana, Chain.ethereum]);

      bloc.add(const KeystoneToggleAccount(2));
      await bloc.stream.firstWhere(
        (s) => s is KeystoneAccountsLoaded && s.selectedKeys.length == 2,
      );
      bloc.add(const KeystoneImportRequested());
      await bloc.stream.firstWhere((s) => s is KeystoneImported);

      final ethAddress = await MultiChainDerivation.getEthereumAddressAtIndex(
        mnemonic,
        2,
      );
      verify(
        () => repo.addKeystoneWallet(
          ethAddress,
          'Ethereum',
          masterFingerprint: fingerprint,
          derivationIndex: 2,
          chain: Chain.ethereum,
        ),
      ).called(1);
      // The session lands on the Solana row, the chain the app signs in with.
      verify(() => session.switchToWallet('w-${address(1)}')).called(1);
    });

    group('an Ethereum-only export', () {
      Account keystoneAccount(
        int index, {
        int masterFingerprint = fingerprint,
        String? name,
      }) => Account(
        id: 'acct-$masterFingerprint-$index',
        name: name ?? 'Account $index',
        kind: AccountKind.keystone,
        derivationIndex: index,
        wallets: [
          WalletInfo(
            id: 'sol-$masterFingerprint-$index',
            address: address(index + 1),
            name: 'Solana',
            walletType: WalletType.keystone,
            chain: 'solana',
            masterFingerprint: masterFingerprint,
          ),
        ],
      );

      setUp(() {
        when(() => session.refreshActiveAccount()).thenAnswer((_) async {});
        when(
          () => repo.addKeystoneWallet(
            any(),
            any(),
            masterFingerprint: any(named: 'masterFingerprint'),
            derivationIndex: any(named: 'derivationIndex'),
            derivationScheme: any(named: 'derivationScheme'),
            chain: any(named: 'chain'),
          ),
        ).thenAnswer(
          (inv) async => WalletInfo(
            id: 'w-${inv.positionalArguments[0]}',
            address: inv.positionalArguments[0] as String,
            name: inv.positionalArguments[1] as String,
            walletType: WalletType.keystone,
            chain: (inv.namedArguments[#chain] as Chain).toDbString(),
          ),
        );
      });

      test("reads MetaMask's crypto-hdkey with the device's fingerprint", () {
        final code = parseKeystoneCode(ethKey().toUr());
        expect(code.masterFingerprint, fingerprint);
        expect(code.solana, isEmpty);
        expect(code.ethereum, isNotNull);
      });

      test('a Ledger layout alone is refused with the path to choose', () {
        expect(
          () => parseKeystoneCode(ethKey(note: 'account.ledger_legacy').toUr()),
          throwsA(
            isA<UrDecodeException>().having(
              (e) => e.message,
              'message',
              contains('choose MetaMask, then BIP44 Standard'),
            ),
          ),
        );
      });

      test("lists an Ethereum row on each of this device's imported "
          'accounts, and no other device\'s', () async {
        when(repo.getAccountViews).thenAnswer(
          (_) async => [
            keystoneAccount(5, name: 'Savings'),
            keystoneAccount(1, masterFingerprint: 0x11111111),
            keystoneAccount(0),
          ],
        );
        final bloc = build();
        addTearDown(bloc.close);

        bloc.add(KeystoneExportScanned(ethKey().toUr()));
        final state = await loaded(bloc);

        expect(state.masterFingerprint, fingerprint);
        expect(state.accounts.map((a) => a.index), [0, 5]);
        expect(state.accounts.last.importedName, 'Savings');
        for (final a in state.accounts) {
          final row = a.wallets.single;
          expect(row.chain, Chain.ethereum);
          expect(
            row.address,
            await MultiChainDerivation.getEthereumAddressAtIndex(
              mnemonic,
              a.index,
            ),
          );
        }
      });

      test(
        'a multi-accounts export with only the Ethereum key works too',
        () async {
          when(
            repo.getAccountViews,
          ).thenAnswer((_) async => [keystoneAccount(2)]);
          final bloc = build();
          addTearDown(bloc.close);

          bloc.add(KeystoneExportScanned(export([ethKey()])));
          final state = await loaded(bloc);

          expect(state.accounts.single.index, 2);
          expect(state.accounts.single.wallets.single.chain, Chain.ethereum);
        },
      );

      test('with no accounts from this device, keeps the key and asks for '
          'a Solana code, which then gets the Ethereum rows', () async {
        when(repo.getAccountViews).thenAnswer(
          (_) async => [keystoneAccount(0, masterFingerprint: 0x11111111)],
        );
        final bloc = build();
        addTearDown(bloc.close);

        bloc.add(KeystoneExportScanned(ethKey().toUr()));
        final state =
            await bloc.stream.firstWhere((s) => s is KeystoneScanning)
                as KeystoneScanning;

        expect(state.error, isNull);
        expect(state.notice, contains('Now scan a Solana code'));
        expect(state.canReturn, isFalse);
        expect(state.canStartOver, isTrue);

        bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/4'")])));
        final picker = await loaded(bloc);
        expect(picker.accounts.single.index, 4);
        expect(picker.accounts.single.wallets.map((w) => w.chain), [
          Chain.solana,
          Chain.ethereum,
        ]);
      });

      test('import joins the existing account and refreshes the session '
          'instead of switching', () async {
        when(
          repo.getAccountViews,
        ).thenAnswer((_) async => [keystoneAccount(3)]);
        final bloc = build();
        addTearDown(bloc.close);

        bloc.add(KeystoneExportScanned(ethKey().toUr()));
        await loaded(bloc);
        bloc.add(const KeystoneToggleAccount(3));
        bloc.add(const KeystoneImportRequested());
        await bloc.stream.firstWhere((s) => s is KeystoneImported);

        verify(
          () => repo.addKeystoneWallet(
            any(),
            'Ethereum',
            masterFingerprint: fingerprint,
            derivationIndex: 3,
            chain: Chain.ethereum,
          ),
        ).called(1);
        verify(() => session.refreshActiveAccount()).called(1);
        verifyNever(() => session.switchToWallet(any()));
      });

      test('a failed session refresh does not fail the import', () async {
        when(
          () => session.refreshActiveAccount(),
        ).thenThrow(StateError('refresh failed'));
        when(
          repo.getAccountViews,
        ).thenAnswer((_) async => [keystoneAccount(0)]);
        final bloc = build();
        addTearDown(bloc.close);

        bloc.add(KeystoneExportScanned(ethKey().toUr()));
        await loaded(bloc);
        bloc.add(const KeystoneToggleAccount(0));
        bloc.add(const KeystoneImportRequested());

        expect(
          await bloc.stream.firstWhere(
            (s) => s is KeystoneImported || s is KeystoneConnectError,
          ),
          isA<KeystoneImported>(),
        );
      });

      test('an Ethereum row at a new index still switches to it', () async {
        // A multi-chain export's Ethereum row picked alone at an index with no
        // account yet makes a new account; staying put would leave the user
        // on the old one, or on none during onboarding.
        final bloc = build();
        addTearDown(bloc.close);

        bloc.add(
          KeystoneExportScanned(export([hdKey(1, "m/44'/501'/4'"), ethKey()])),
        );
        final state = await loaded(bloc);
        final eth = state.accounts.single.wallets.firstWhere(
          (w) => w.chain == Chain.ethereum,
        );
        bloc.add(KeystoneToggleWallet(eth.key));
        bloc.add(const KeystoneImportRequested());
        await bloc.stream.firstWhere((s) => s is KeystoneImported);

        verify(() => session.switchToWallet('w-${eth.address}')).called(1);
        verifyNever(() => session.refreshActiveAccount());
      });
    });

    group('several codes', () {
      Future<KeystoneScanning> scanAnother(KeystoneConnectBloc bloc) async {
        bloc.add(const KeystoneScanAnotherRequested());
        return await bloc.stream.firstWhere((s) => s is KeystoneScanning)
            as KeystoneScanning;
      }

      test('a second code adds its rows and keeps the selection and loaded '
          'balances', () async {
        final bloc = build();
        addTearDown(bloc.close);

        bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
        final first = await loaded(bloc);
        final solanaKey = first.accounts.single.wallets.single.key;
        bloc.add(KeystoneToggleWallet(solanaKey));
        await bloc.stream.firstWhere(
          (s) => s is KeystoneAccountsLoaded && s.selectedKeys.isNotEmpty,
        );

        final scanning = await scanAnother(bloc);
        expect(scanning.canReturn, isTrue);
        bloc.add(KeystoneExportScanned(ethKey().toUr()));
        final merged = await loaded(bloc);

        expect(merged.accounts.single.wallets.map((w) => w.chain), [
          Chain.solana,
          Chain.ethereum,
        ]);
        expect(merged.selectedKeys, {solanaKey});
        verify(() => portfolio.artworkCountForOwner(address(1))).called(1);
      });

      test(
        'a code from another device is refused and the picker is kept',
        () async {
          final bloc = build();
          addTearDown(bloc.close);

          bloc.add(
            KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])),
          );
          await loaded(bloc);
          await scanAnother(bloc);
          bloc.add(
            KeystoneExportScanned(
              export([
                hdKey(2, "m/44'/501'/0'/0'", masterFingerprint: 0x11111111),
              ], masterFingerprint: 0x11111111),
            ),
          );
          final refused =
              await bloc.stream.firstWhere(
                    (s) => s is KeystoneScanning && s.error != null,
                  )
                  as KeystoneScanning;
          expect(refused.error, contains('Tap Start over'));
          expect(refused.canReturn, isTrue);

          bloc.add(const KeystoneBackToAccountsRequested());
          final back =
              await bloc.stream.firstWhere((s) => s is KeystoneAccountsLoaded)
                  as KeystoneAccountsLoaded;
          expect(back.masterFingerprint, fingerprint);
          expect(back.accounts.single.wallets.single.address, address(1));
        },
      );

      test('start over forgets every code scanned', () async {
        final bloc = build();
        addTearDown(bloc.close);

        bloc.add(KeystoneExportScanned(ethKey().toUr()));
        await bloc.stream.firstWhere((s) => s is KeystoneScanning);
        bloc.add(const KeystoneRescanRequested());
        final reset =
            await bloc.stream.firstWhere((s) => s is KeystoneScanning)
                as KeystoneScanning;
        expect(reset.canStartOver, isFalse);

        bloc.add(KeystoneExportScanned(export([hdKey(1, "m/44'/501'/0'/0'")])));
        final state = await loaded(bloc);
        expect(state.accounts.single.wallets.map((w) => w.chain), [
          Chain.solana,
        ]);
      });
    });
  });
}
