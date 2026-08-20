import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_ethereum/ledger_ethereum.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/ledger_open_app.dart';
import 'package:mallow_wallet/core/services/ledger_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/ledger/services/ledger_connect_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/base58.dart';

import 'ledger_connect_bloc_test.mocks.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

@GenerateMocks([
  LedgerService,
  WalletRepository,
  TokenRepository,
  PortfolioRepository,
  PreferencesService,
  SessionManager,
])
void main() {
  late MockLedgerService mockLedger;
  late MockWalletRepository mockRepo;
  late MockTokenRepository mockTokens;
  late MockPortfolioRepository mockPortfolio;
  late MockPreferencesService mockPrefs;
  late MockSessionManager mockSession;

  // LedgerDevice is @immutable with a const constructor — use a real instance
  // rather than mocking it (mockito's generated mock trips duplicate_ignore).
  const fakeDevice = LedgerDevice(
    id: 'mock-device-id',
    name: 'Mock Ledger',
    connectionType: ConnectionType.ble,
    deviceInfo: LedgerDeviceType.nanoX,
  );

  // Two deterministic 32-byte pubkeys → addresses.
  final pubkey1 = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final pubkey2 = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  final address1 = base58encode(pubkey1);
  final address2 = base58encode(pubkey2);

  setUp(() {
    mockLedger = MockLedgerService();
    mockRepo = MockWalletRepository();
    mockTokens = MockTokenRepository();
    mockPortfolio = MockPortfolioRepository();
    mockPrefs = MockPreferencesService();
    mockSession = MockSessionManager();

    // The bloc reaches the session via the service locator (matching the
    // codebase's bloc → sl<> convention), so register the mock there.
    if (sl.isRegistered<SessionManager>()) {
      sl.unregister<SessionManager>();
    }
    sl.registerSingleton<SessionManager>(mockSession);
    when(mockSession.switchToWallet(any)).thenAnswer((_) async {});
    // Import consults the Profile-containment guard before its post-import
    // auto-switch; default to Account mode (no active Profile linking the
    // addresses) so the import switches the session as before.
    when(mockSession.activeProfileContainsAnyAddress(any)).thenReturn(false);

    when(mockLedger.connectedDevice).thenReturn(fakeDevice);
    when(
      mockLedger.discoverAccounts(
        count: anyNamed('count'),
        startIndex: anyNamed('startIndex'),
        scheme: anyNamed('scheme'),
      ),
    ).thenAnswer((_) async => [pubkey1, pubkey2]);

    when(mockRepo.getAllWallets()).thenAnswer((_) async => const []);
    when(mockRepo.getAccountViews()).thenAnswer((_) async => const <Account>[]);
    when(mockRepo.peekNextAccountNumber()).thenAnswer((_) async => 1);
    when(mockTokens.getCachedBalances(any)).thenAnswer((_) async => const []);
    when(mockTokens.getTokenBalances(any)).thenAnswer((_) async => const []);
    when(mockTokens.cacheBalances(any, any)).thenAnswer((_) async {});
    when(mockTokens.calculateTotalValue(any)).thenReturn(0);
    when(mockPortfolio.artworkCountForOwner(any)).thenAnswer((_) async => 0);
    when(mockPrefs.showLegacySolanaImport).thenReturn(false);
  });

  tearDown(() {
    if (sl.isRegistered<SessionManager>()) {
      sl.unregister<SessionManager>();
    }
  });

  WalletInfo ledgerWallet(
    String address,
    int index, {
    String chain = 'solana',
  }) => WalletInfo(
    id: 'wallet-$address',
    address: address,
    name: 'Ledger ${index + 1}',
    walletType: WalletType.ledger,
    chain: chain,
    // Real imports always link the wallet to its "Account NN" row; the
    // session anchors to this id so the drawer/home show the account name.
    accountId: 'account-$index',
    derivationIndex: index,
    derivationScheme: SolanaDerivationScheme.standard,
  );

  group('LedgerConnectBloc importAccounts', () {
    blocTest<LedgerConnectBloc, LedgerConnectState>(
      'anchors the session to the last imported account',
      build: () {
        when(
          mockRepo.addLedgerWallet(
            address1,
            any,
            derivationIndex: anyNamed('derivationIndex'),
            derivationScheme: anyNamed('derivationScheme'),
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        ).thenAnswer((_) async => ledgerWallet(address1, 0));
        when(
          mockRepo.addLedgerWallet(
            address2,
            any,
            derivationIndex: anyNamed('derivationIndex'),
            derivationScheme: anyNamed('derivationScheme'),
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        ).thenAnswer((_) async => ledgerWallet(address2, 1));

        return LedgerConnectBloc(
          mockLedger,
          mockRepo,
          mockTokens,
          mockPortfolio,
          mockPrefs,
        );
      },
      act: (bloc) async {
        bloc.add(const LedgerConnectEvent.loadAccounts());
        await Future<void>.delayed(Duration.zero);
        // Two derivation-index cards (Account 01 / Account 02), one Solana
        // wallet each; select both via their header "select all".
        bloc.add(const LedgerConnectEvent.toggleAccount(0));
        bloc.add(const LedgerConnectEvent.toggleAccount(1));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const LedgerConnectEvent.importAccounts());
      },
      verify: (_) {
        verify(
          mockRepo.addLedgerWallet(
            address1,
            any,
            derivationScheme: anyNamed('derivationScheme'),
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        ).called(1);
        verify(
          mockRepo.addLedgerWallet(
            address2,
            any,
            derivationIndex: 1,
            derivationScheme: anyNamed('derivationScheme'),
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        ).called(1);

        // The critical assertion: the session must switch to the LAST imported
        // wallet — switchToWallet takes its whole account along so the drawer/
        // home header show "Account NN" instead of the wallet's chain-label
        // name. Routing to the first wallet would surface the wrong account.
        // (The Solana-signer vs Eth/Tezos-fallback orchestration lives in
        // SessionManager.switchToWallet and is covered by its own test.)
        verify(mockSession.switchToWallet('wallet-$address2')).called(1);
        verifyNever(mockSession.switchToWallet('wallet-$address1'));
      },
    );

    blocTest<LedgerConnectBloc, LedgerConnectState>(
      'does not activate when no accounts are selected',
      build: () => LedgerConnectBloc(
        mockLedger,
        mockRepo,
        mockTokens,
        mockPortfolio,
        mockPrefs,
      ),
      act: (bloc) async {
        bloc.add(const LedgerConnectEvent.loadAccounts());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const LedgerConnectEvent.importAccounts());
      },
      verify: (_) {
        verifyNever(
          mockRepo.addLedgerWallet(
            any,
            any,
            derivationIndex: anyNamed('derivationIndex'),
            derivationScheme: anyNamed('derivationScheme'),
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        );
        verifyNever(mockSession.switchToWallet(any));
      },
    );
  });

  group('LedgerConnectBloc Ethereum routing', () {
    // The lowercase address the device returns, and its EIP-55 form, which the
    // bloc checksums to before building the card / persisting the wallet.
    const deviceAddress = '0x52908400098527886e0f7030069857d2e4169ee7';
    const checksummed = '0x52908400098527886E0F7030069857D2E4169EE7';

    blocTest<LedgerConnectBloc, LedgerConnectState>(
      'opening the Ethereum app imports an ethereum-chain wallet',
      build: () {
        when(mockLedger.connect(fakeDevice)).thenAnswer((_) async {});
        // Auto-detection: the device reports the Ethereum app is open.
        when(mockLedger.getOpenApp()).thenAnswer(
          (_) async => const LedgerAppInfo(name: 'Ethereum', version: '1.0.0'),
        );
        when(
          mockLedger.discoverEthereumAccounts(
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
          ),
        ).thenAnswer(
          (_) async => [
            EthereumLedgerAddress(
              publicKey: Uint8List(65),
              address: deviceAddress,
            ),
          ],
        );
        when(
          mockRepo.addLedgerWallet(
            checksummed,
            any,
            derivationIndex: anyNamed('derivationIndex'),
            derivationScheme: anyNamed('derivationScheme'),
            chain: anyNamed('chain'),
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        ).thenAnswer(
          (_) async => const WalletInfo(
            id: 'wallet-eth',
            address: checksummed,
            name: 'Ethereum',
            walletType: WalletType.ledger,
            chain: 'ethereum',
            derivationIndex: 0,
          ),
        );

        return LedgerConnectBloc(
          mockLedger,
          mockRepo,
          mockTokens,
          mockPortfolio,
          mockPrefs,
        );
      },
      act: (bloc) async {
        // Connect resolves the open app to Ethereum; loadAccounts (normally
        // dispatched by the screen on `connected`) then derives ETH addresses.
        bloc.add(const LedgerConnectEvent.connectDevice(fakeDevice));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const LedgerConnectEvent.loadAccounts());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const LedgerConnectEvent.toggleAccount(0));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const LedgerConnectEvent.importAccounts());
      },
      verify: (_) {
        // Intent: the wallet must be persisted on the Ethereum chain (not the
        // Solana default), named "Ethereum", from the checksummed address.
        verify(
          mockRepo.addLedgerWallet(
            checksummed,
            'Ethereum',
            derivationScheme: anyNamed('derivationScheme'),
            chain: Chain.ethereum,
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        ).called(1);
        // Solana derivation must never be used for an Ethereum-app session.
        verifyNever(
          mockLedger.discoverAccounts(
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            scheme: anyNamed('scheme'),
          ),
        );
      },
    );
  });

  group('LedgerConnectBloc Tezos routing', () {
    // The bloc encodes the device's raw Ed25519 public key to a tz1 address via
    // the same helper the seed path uses, then persists that.
    final tezosAddress = MultiChainDerivation.tezosAddressFromPublicKey(
      pubkey1,
    );

    blocTest<LedgerConnectBloc, LedgerConnectState>(
      'opening the Tezos app imports a tezos-chain wallet',
      build: () {
        when(mockLedger.connect(fakeDevice)).thenAnswer((_) async {});
        // Auto-detection: the device reports the Tezos Wallet app is open.
        when(mockLedger.getOpenApp()).thenAnswer(
          (_) async =>
              const LedgerAppInfo(name: 'Tezos Wallet', version: '3.0.0'),
        );
        when(
          mockLedger.discoverTezosAccounts(
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
          ),
        ).thenAnswer((_) async => [pubkey1]);
        when(
          mockRepo.addLedgerWallet(
            tezosAddress,
            any,
            derivationIndex: anyNamed('derivationIndex'),
            derivationScheme: anyNamed('derivationScheme'),
            chain: anyNamed('chain'),
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        ).thenAnswer(
          (_) async => WalletInfo(
            id: 'wallet-xtz',
            address: tezosAddress,
            name: 'Tezos',
            walletType: WalletType.ledger,
            chain: 'tezos',
            accountId: 'account-xtz',
            derivationIndex: 0,
          ),
        );

        return LedgerConnectBloc(
          mockLedger,
          mockRepo,
          mockTokens,
          mockPortfolio,
          mockPrefs,
        );
      },
      act: (bloc) async {
        bloc.add(const LedgerConnectEvent.connectDevice(fakeDevice));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const LedgerConnectEvent.loadAccounts());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const LedgerConnectEvent.toggleAccount(0));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const LedgerConnectEvent.importAccounts());
      },
      verify: (_) {
        // Intent: the wallet must be persisted on the Tezos chain, named
        // "Tezos", from the tz1 address derived from the device public key.
        verify(
          mockRepo.addLedgerWallet(
            tezosAddress,
            'Tezos',
            derivationScheme: anyNamed('derivationScheme'),
            chain: Chain.tezos,
            ledgerDeviceId: anyNamed('ledgerDeviceId'),
          ),
        ).called(1);
        // Solana derivation must never be used for a Tezos-app session.
        verifyNever(
          mockLedger.discoverAccounts(
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            scheme: anyNamed('scheme'),
          ),
        );

        // The reported bug: the session must switch to the imported wallet so
        // the header shows "Account 05", not the wallet's "Tezos" chain label.
        // switchToWallet anchors the account and (for a Tezos-only account with
        // no Solana signer) moves auth onto the wallet — verified in
        // SessionManager.switchToWallet's own test.
        verify(mockSession.switchToWallet('wallet-xtz')).called(1);
      },
    );
  });
}
