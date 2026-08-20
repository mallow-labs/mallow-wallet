import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/core/security/redacted.dart';
import 'package:mallow_wallet/features/accounts/services/import_wallets_bloc.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'import_wallets_bloc_test.mocks.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

@GenerateMocks([
  WalletRepository,
  TokenRepository,
  PortfolioRepository,
  PreferencesService,
  SecureWalletStorage,
  SessionManager,
])
void main() {
  // The pending-mnemonic path derives addresses via `compute` (an isolate), so
  // the test binding must be initialised for that derivation to run.
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockWalletRepository mockWalletRepo;
  late MockTokenRepository mockTokenRepo;
  late MockPortfolioRepository mockPortfolioRepo;
  late MockPreferencesService mockPrefs;
  late MockSecureWalletStorage mockSecureStorage;
  late MockSessionManager mockSession;

  const testSeedPhraseId = 'seed-123';
  // Mirrors ImportWalletsBloc._batchSize: the pending-mnemonic path derives a
  // real batch of this many accounts through `compute`.
  const initialBatchSize = 5;
  const solAddr = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const ethAddr = '0x1111111111111111111111111111111111111111';
  const tezAddr = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

  const account0 = AccountAddresses(
    index: 0,
    solanaStandard: solAddr,
    ethereum: ethAddr,
    tezos: tezAddr,
  );

  const importedWallet = WalletInfo(
    id: 'wallet-1',
    address: solAddr,
    name: 'Solana',
    walletType: WalletType.hd,
    chain: 'solana',
  );

  PickerAccount pickerAccount0() => const PickerAccount(
    index: 0,
    wallets: [
      PickerWallet(
        accountIndex: 0,
        chain: Chain.solana,
        address: solAddr,
        alreadyImported: false,
        artworkCount: 3,
        balanceUsd: 12.5,
      ),
      PickerWallet(
        accountIndex: 0,
        chain: Chain.tezos,
        address: tezAddr,
        alreadyImported: false,
      ),
      PickerWallet(
        accountIndex: 0,
        chain: Chain.ethereum,
        address: ethAddr,
        alreadyImported: false,
      ),
    ],
  );

  setUp(() {
    mockWalletRepo = MockWalletRepository();
    mockTokenRepo = MockTokenRepository();
    mockPortfolioRepo = MockPortfolioRepository();
    mockPrefs = MockPreferencesService();
    mockSecureStorage = MockSecureWalletStorage();
    mockSession = MockSessionManager();

    // Default: legacy paths off; enrichment returns a non-empty balance so the
    // account renders activity chips.
    when(mockPrefs.showLegacySolanaImport).thenReturn(false);
    // Default: Account session (null scope) with every network active, so all
    // derived chains surface.
    when(mockSession.settingsScopeId()).thenAnswer((_) async => null);
    when(
      mockSecureStorage.loadNetworkEnabled(any, scope: anyNamed('scope')),
    ).thenAnswer((_) async => true);
    when(mockWalletRepo.peekNextAccountNumber()).thenAnswer((_) async => 1);
    when(mockTokenRepo.getTokenBalances(any)).thenAnswer((_) async => []);
    when(mockTokenRepo.calculateTotalValue(any)).thenReturn(12.5);
    when(
      mockPortfolioRepo.artworkCountForOwner(any),
    ).thenAnswer((_) async => 3);
  });

  ImportWalletsBloc buildBloc() => ImportWalletsBloc(
    mockWalletRepo,
    mockTokenRepo,
    mockPortfolioRepo,
    mockPrefs,
    mockSecureStorage,
    mockSession,
  );

  group('loadAddresses', () {
    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'derives one card per index and pre-selects the first account when the '
      'phrase has no prior imports',
      setUp: () {
        when(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
          ),
        ).thenAnswer(
          (_) async => const AccountPickerInfo(
            accounts: [account0],
            alreadyImported: {},
          ),
        );
      },
      build: buildBloc,
      act: (bloc) =>
          bloc.add(const ImportWalletsEvent.loadAddresses(testSeedPhraseId)),
      expect: () => [
        const ImportWalletsState.loading(),
        // First loaded emission: the first account's wallets are pre-selected
        // immediately (independent of activity/enrichment) to nudge the common
        // single-account import case.
        isA<ImportWalletsLoaded>()
            .having((s) => s.accounts.length, 'accounts', 1)
            .having(
              (s) => s.accounts.first.wallets.length,
              'wallet rows',
              3, // solana + tezos + ethereum
            )
            .having((s) => s.selectedKeys, 'selectedKeys', {
              '0:solana:',
              '0:tezos:',
              '0:ethereum:',
            }),
        // Enrichment merges balances without disturbing the selection.
        isA<ImportWalletsLoaded>().having(
          (s) => s.selectedKeys,
          'selectedKeys',
          {'0:solana:', '0:tezos:', '0:ethereum:'},
        ),
      ],
    );

    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'omits derived addresses for chains disabled in the active session scope',
      setUp: () {
        // A Profile session: the filter must read the profile-scoped preference,
        // not the shared account scope. Tezos is off for this profile; Ethereum
        // and Solana stay on, so the Tezos row must not appear in the picker
        // (nor be importable). This is the per-scope "honor active networks on
        // import" behavior.
        when(
          mockSession.settingsScopeId(),
        ).thenAnswer((_) async => 'profile-1');
        when(
          mockSecureStorage.loadNetworkEnabled(Chain.tezos, scope: 'profile-1'),
        ).thenAnswer((_) async => false);
        when(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
            deriveEthereum: anyNamed('deriveEthereum'),
            deriveTezos: anyNamed('deriveTezos'),
          ),
        ).thenAnswer(
          (_) async => const AccountPickerInfo(
            accounts: [account0],
            alreadyImported: {},
          ),
        );
      },
      build: buildBloc,
      act: (bloc) =>
          bloc.add(const ImportWalletsEvent.loadAddresses(testSeedPhraseId)),
      expect: () => [
        const ImportWalletsState.loading(),
        isA<ImportWalletsLoaded>()
            .having(
              (s) => s.accounts.first.wallets.map((w) => w.chain).toList(),
              'chains shown',
              [Chain.solana, Chain.ethereum],
            )
            .having((s) => s.selectedKeys, 'selectedKeys exclude tezos', {
              '0:solana:',
              '0:ethereum:',
            }),
        isA<ImportWalletsLoaded>().having(
          (s) => s.accounts.first.wallets.any((w) => w.chain == Chain.tezos),
          'tezos hidden after enrichment',
          false,
        ),
      ],
      verify: (_) {
        // The filter resolved the session scope and read storage under it,
        // proving the preference is per-scope (profile-isolated), not global.
        verify(
          mockSecureStorage.loadNetworkEnabled(Chain.tezos, scope: 'profile-1'),
        ).called(greaterThanOrEqualTo(1));
        // A hidden chain is not merely filtered out of the rows — it is never
        // derived, so the user does not wait on key derivation for a chain
        // they switched off. Ethereum stays on: only the disabled chain drops.
        final flags = verify(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
            deriveEthereum: captureAnyNamed('deriveEthereum'),
            deriveTezos: captureAnyNamed('deriveTezos'),
          ),
        ).captured;
        expect(flags, [true, false]);
      },
    );

    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'does not pre-select when the phrase already has an imported wallet',
      setUp: () {
        when(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
          ),
        ).thenAnswer(
          (_) async => const AccountPickerInfo(
            accounts: [account0],
            alreadyImported: {solAddr},
          ),
        );
      },
      build: buildBloc,
      act: (bloc) =>
          bloc.add(const ImportWalletsEvent.loadAddresses(testSeedPhraseId)),
      expect: () => [
        const ImportWalletsState.loading(),
        // The first account is already imported, so nothing is pre-selected;
        // the user explicitly opts into any additional accounts.
        isA<ImportWalletsLoaded>()
            .having((s) => s.accounts.first.isImported, 'isImported', true)
            .having((s) => s.selectedKeys, 'selectedKeys', isEmpty),
        // Enrichment pass leaves the empty selection untouched.
        isA<ImportWalletsLoaded>().having(
          (s) => s.selectedKeys,
          'selectedKeys',
          isEmpty,
        ),
      ],
    );

    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'shows the stored name for an already-imported, renamed account',
      setUp: () {
        when(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
          ),
        ).thenAnswer(
          (_) async => const AccountPickerInfo(
            accounts: [account0],
            alreadyImported: {solAddr},
            importedNamesByIndex: {0: 'My Trading Wallet'},
          ),
        );
      },
      build: buildBloc,
      act: (bloc) =>
          bloc.add(const ImportWalletsEvent.loadAddresses(testSeedPhraseId)),
      expect: () => [
        const ImportWalletsState.loading(),
        // The edited name surfaces on the card instead of the generic
        // `Account NN`.
        isA<ImportWalletsLoaded>().having(
          (s) => s.accounts.first.importedName,
          'importedName',
          'My Trading Wallet',
        ),
        // Enrichment re-emit preserves the name (carried through withWallets).
        isA<ImportWalletsLoaded>().having(
          (s) => s.accounts.first.importedName,
          'importedName',
          'My Trading Wallet',
        ),
      ],
    );

    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'emits fixed error copy when derivation throws (no raw exception text)',
      setUp: () {
        when(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
          ),
        ).thenThrow(Exception('derive failed'));
      },
      build: buildBloc,
      act: (bloc) =>
          bloc.add(const ImportWalletsEvent.loadAddresses(testSeedPhraseId)),
      expect: () => [
        const ImportWalletsState.loading(),
        const ImportWalletsState.error(
          'Could not load addresses. Please try again.',
        ),
      ],
    );
  });

  group('loadFromMnemonic', () {
    // A 12-word BIP-39 test vector — lets the pending-mnemonic path derive real
    // addresses without mocking the static MultiChainDerivation helper.
    const abandon =
        'abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon about';

    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'folds a phrase already on the device into its existing seed so prior '
      'imports surface as already-imported',
      setUp: () {
        when(
          mockWalletRepo.findSeedPhraseIdForMnemonic(any),
        ).thenAnswer((_) async => testSeedPhraseId);
        when(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
          ),
        ).thenAnswer(
          (_) async => const AccountPickerInfo(
            accounts: [account0],
            alreadyImported: {solAddr},
          ),
        );
      },
      build: buildBloc,
      act: (bloc) => bloc.add(
        const ImportWalletsEvent.loadFromMnemonic(Redacted(abandon)),
      ),
      expect: () => [
        const ImportWalletsState.loading(),
        // Derived against the existing seed graph: the prior Solana wallet is
        // already-imported (rendered toggled-on, locked) and nothing is
        // pre-selected — exactly the "adding more" behaviour of the existing
        // seed path, not a fresh import.
        isA<ImportWalletsLoaded>()
            .having((s) => s.seedPhraseId, 'seedPhraseId', testSeedPhraseId)
            .having((s) => s.accounts.first.isImported, 'isImported', true)
            .having((s) => s.selectedKeys, 'selectedKeys', isEmpty),
        isA<ImportWalletsLoaded>().having(
          (s) => s.selectedKeys,
          'selectedKeys',
          isEmpty,
        ),
      ],
      verify: (_) {
        verify(mockWalletRepo.findSeedPhraseIdForMnemonic(abandon)).called(1);
        // Routed through the existing-seed derivation, not the in-memory path.
        verify(
          mockWalletRepo.deriveAccountsForPicker(
            testSeedPhraseId,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
          ),
        ).called(greaterThanOrEqualTo(1));
      },
    );

    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'holds a brand-new phrase in memory and pre-selects the first account',
      setUp: () {
        when(
          mockWalletRepo.findSeedPhraseIdForMnemonic(any),
        ).thenAnswer((_) async => null);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(
        const ImportWalletsEvent.loadFromMnemonic(Redacted(abandon)),
      ),
      // The pending path derives in a background isolate (`compute`); give the
      // round-trip time to settle before assertions run.
      wait: const Duration(seconds: 2),
      expect: () => [
        const ImportWalletsState.loading(),
        // Pending mnemonic: nothing is imported yet, so the first account is
        // pre-selected to nudge the common single-account case.
        isA<ImportWalletsLoaded>()
            .having((s) => s.seedPhraseId, 'seedPhraseId', '')
            .having((s) => s.selectedKeys, 'selectedKeys', {
              '0:solana:',
              '0:tezos:',
              '0:ethereum:',
            }),
        // One enrichment emission per derived card: an account merges as soon
        // as its own balance/artwork calls settle, so the slowest address in
        // the batch cannot hold every other card's chips in shimmer.
        ...List.filled(
          initialBatchSize,
          isA<ImportWalletsLoaded>().having(
            (s) => s.selectedKeys,
            'selectedKeys',
            {'0:solana:', '0:tezos:', '0:ethereum:'},
          ),
        ),
      ],
      verify: (_) {
        // A pending mnemonic derives in memory — never against the wallet graph.
        verifyNever(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
          ),
        );
      },
    );
  });

  group('toggleAccount', () {
    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'deselects every child wallet when all are currently selected',
      build: buildBloc,
      seed: () => ImportWalletsState.loaded(
        seedPhraseId: testSeedPhraseId,
        accounts: [pickerAccount0()],
        selectedKeys: const {'0:solana:', '0:tezos:', '0:ethereum:'},
      ),
      act: (bloc) => bloc.add(const ImportWalletsEvent.toggleAccount(0)),
      expect: () => [
        isA<ImportWalletsLoaded>().having(
          (s) => s.selectedKeys,
          'selectedKeys',
          isEmpty,
        ),
      ],
    );
  });

  group('importSelected', () {
    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'imports only the selected wallets and emits imported',
      setUp: () {
        when(
          mockWalletRepo.importAccountsFromPhrase(any, any),
        ).thenAnswer((_) async => [importedWallet]);
      },
      build: buildBloc,
      seed: () => ImportWalletsState.loaded(
        seedPhraseId: testSeedPhraseId,
        accounts: [pickerAccount0()],
        selectedKeys: const {'0:solana:'},
      ),
      act: (bloc) => bloc.add(const ImportWalletsEvent.importSelected()),
      expect: () => [
        isA<ImportWalletsLoaded>().having(
          (s) => s.isImporting,
          'isImporting',
          true,
        ),
        const ImportWalletsState.imported([importedWallet]),
      ],
      verify: (_) {
        final captured =
            verify(
                  mockWalletRepo.importAccountsFromPhrase(any, captureAny),
                ).captured.single
                as List<WalletImportSelection>;
        expect(captured, hasLength(1));
        expect(captured.single.chain, Chain.solana);
        expect(captured.single.index, 0);
        expect(captured.single.scheme, isNull);
      },
    );
  });

  group('setIncludeLegacy', () {
    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'persists the preference and surfaces the legacy Solana row',
      setUp: () {
        when(mockPrefs.setShowLegacySolanaImport(any)).thenAnswer((_) async {});
        when(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: true,
          ),
        ).thenAnswer(
          (_) async => const AccountPickerInfo(
            accounts: [
              AccountAddresses(
                index: 0,
                solanaStandard: solAddr,
                ethereum: ethAddr,
                tezos: tezAddr,
                solanaLegacy: 'LEGACYsolanaAddr1111111111111111111111111',
                solanaRoot: 'ROOTsolanaAddr11111111111111111111111111111',
              ),
            ],
            alreadyImported: {},
          ),
        );
      },
      build: buildBloc,
      seed: () => ImportWalletsState.loaded(
        seedPhraseId: testSeedPhraseId,
        accounts: [pickerAccount0()],
      ),
      act: (bloc) => bloc.add(const ImportWalletsEvent.setIncludeLegacy(true)),
      expect: () => [
        // 1) Placeholder rows appear immediately so the user sees a shimmer
        // where the legacy address will land while it derives.
        isA<ImportWalletsLoaded>()
            .having((s) => s.includeLegacy, 'includeLegacy', true)
            .having(
              (s) => s.accounts.first.wallets.firstWhere(
                (w) => w.scheme == SolanaDerivationScheme.legacy,
              ),
              'pending legacy row',
              isA<PickerWallet>().having(
                (w) => w.addressPending,
                'addressPending',
                true,
              ),
            ),
        // 2) Re-derived with real legacy + root Solana rows (3 → 5 rows).
        isA<ImportWalletsLoaded>()
            .having((s) => s.includeLegacy, 'includeLegacy', true)
            .having(
              (s) => s.accounts.first.wallets
                  .where((w) => w.scheme == SolanaDerivationScheme.legacy)
                  .single,
              'real legacy row',
              isA<PickerWallet>().having(
                (w) => w.addressPending,
                'addressPending',
                false,
              ),
            ),
        // 3) Followed by an enrichment emission (selection unchanged by toggle).
        isA<ImportWalletsLoaded>(),
      ],
      verify: (_) {
        verify(mockPrefs.setShowLegacySolanaImport(true)).called(1);
      },
    );

    blocTest<ImportWalletsBloc, ImportWalletsState>(
      'drops the legacy rows without re-deriving when toggled off',
      setUp: () {
        when(mockPrefs.setShowLegacySolanaImport(any)).thenAnswer((_) async {});
      },
      build: buildBloc,
      seed: () => ImportWalletsState.loaded(
        seedPhraseId: testSeedPhraseId,
        includeLegacy: true,
        accounts: [
          PickerAccount(
            index: 0,
            wallets: [
              ...pickerAccount0().wallets,
              const PickerWallet(
                accountIndex: 0,
                chain: Chain.solana,
                scheme: SolanaDerivationScheme.legacy,
                address: 'LEGACYsolanaAddr1111111111111111111111111',
                alreadyImported: false,
              ),
            ],
          ),
        ],
      ),
      act: (bloc) => bloc.add(const ImportWalletsEvent.setIncludeLegacy(false)),
      expect: () => [
        isA<ImportWalletsLoaded>()
            .having((s) => s.includeLegacy, 'includeLegacy', false)
            .having(
              (s) => s.accounts.first.wallets.any((w) => w.scheme != null),
              'has legacy rows',
              false,
            ),
      ],
      verify: (_) {
        verifyNever(
          mockWalletRepo.deriveAccountsForPicker(
            any,
            count: anyNamed('count'),
            startIndex: anyNamed('startIndex'),
            includeLegacy: anyNamed('includeLegacy'),
          ),
        );
      },
    );

    test('toggling legacy off mid-enrichment is not undone by the late '
        'merge', () async {
      // The settings sheet stays open while enrichment runs, so the user can
      // turn legacy off before the network calls settle. The merge must apply
      // its counts to the rows on screen now — merging the pre-toggle snapshot
      // back in would resurrect the legacy rows the user just dismissed.
      when(mockPrefs.showLegacySolanaImport).thenReturn(true);
      when(mockPrefs.setShowLegacySolanaImport(any)).thenAnswer((_) async {});
      when(
        mockWalletRepo.deriveAccountsForPicker(
          any,
          count: anyNamed('count'),
          startIndex: anyNamed('startIndex'),
          includeLegacy: anyNamed('includeLegacy'),
        ),
      ).thenAnswer(
        (_) async => const AccountPickerInfo(
          accounts: [
            AccountAddresses(
              index: 0,
              solanaStandard: solAddr,
              ethereum: ethAddr,
              tezos: tezAddr,
              solanaLegacy: 'LEGACYsolanaAddr1111111111111111111111111',
              solanaRoot: 'ROOTsolanaAddr11111111111111111111111111111',
            ),
          ],
          alreadyImported: {},
        ),
      );

      // Hold enrichment open so the toggle lands while the merge is in flight.
      final gate = Completer<int>();
      when(
        mockPortfolioRepo.artworkCountForOwner(any),
      ).thenAnswer((_) => gate.future);

      final bloc = buildBloc();
      addTearDown(bloc.close);
      final states = <ImportWalletsState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);

      bloc.add(const ImportWalletsEvent.loadAddresses(testSeedPhraseId));
      await _settleUntil(
        () => states.whereType<ImportWalletsLoaded>().isNotEmpty,
      );
      expect(
        (states.last as ImportWalletsLoaded).accounts.first.wallets.where(
          (w) => w.scheme != null,
        ),
        isNotEmpty,
        reason: 'legacy rows are on screen before the toggle',
      );

      bloc.add(const ImportWalletsEvent.setIncludeLegacy(false));
      await _settleUntil(
        () => states.any((s) => s is ImportWalletsLoaded && !s.includeLegacy),
      );

      final beforeMerge = states.length;
      gate.complete(3);
      await _settleUntil(() => states.length > beforeMerge);

      final merged = states.last as ImportWalletsLoaded;
      expect(merged.includeLegacy, isFalse);
      expect(
        merged.accounts.first.wallets.where((w) => w.scheme != null),
        isEmpty,
        reason: 'the late merge must not re-insert the dismissed legacy rows',
      );
      // The surviving standard row still receives its counts — dropping the
      // whole merge would strand the card in shimmer instead.
      expect(merged.accounts.first.isEnriched, isTrue);
    });
  });
}

/// Pump the microtask/event queue until [condition] holds, so a test can wait
/// on a bloc emission without a fixed delay. Fails loudly rather than hanging.
Future<void> _settleUntil(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (!condition()) {
    fail('condition never became true while waiting for a bloc emission');
  }
}
