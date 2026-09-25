import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_solana/ledger_solana.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/seed_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/seed_vault/services/seed_vault_connect_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockSeedVault extends Mock implements SeedVaultService {}

class _MockRepo extends Mock implements WalletRepository {}

class _MockTokens extends Mock implements TokenRepository {}

class _MockPortfolio extends Mock implements PortfolioRepository {}

class _MockPrefs extends Mock implements PreferencesService {}

class _MockSession extends Mock implements SessionManager {}

/// Seed Vault is a *hardware* signer reached through a full-screen OS Activity,
/// so the import flow has three properties that are not cosmetic:
///
/// - it must never offer the `root` derivation path. Seed Vault does not
///   pre-derive it, so a root card would cost the user a password prompt for an
///   account almost nobody holds — and `seedVaultDerivationPath` throws for it,
///   so a card that reached signing would throw rather than render;
/// - it must not yank the user's active Profile on import. Importing the
///   Seed Vault backing of a wallet the active Profile already links must
///   leave the user where they were; silently switching changes which identity
///   every subsequent backend write is attributed to;
/// - a refused `ACCESS_SEED_VAULT` must reach a state that offers a way out.
///   The permission can be permanently denied while the device still reports
///   Seed Vault as available, so the entry row renders and then dead-ends.
void main() {
  const standardPath0 = "bip32:/m'/44'/501'/0'/0'";
  const legacyPath0 = "bip32:/m'/44'/501'/0'";
  const rootPath = "bip32:/m'/44'/501'";
  const standardPath1 = "bip32:/m'/44'/501'/1'/0'";

  const addrStandard0 = 'SoStandard0000000000000000000000000000000000';
  const addrLegacy0 = 'SoLegacy00000000000000000000000000000000000';
  const addrRoot = 'SoRoot0000000000000000000000000000000000000';
  const addrStandard1 = 'SoStandard1111111111111111111111111111111111';

  SeedVaultAccount row(
    String address,
    String path, {
    required int accountId,
    int authToken = 7,
  }) => SeedVaultAccount(
    authToken: authToken,
    accountId: accountId,
    address: address,
    derivationPath: path,
  );

  late _MockSeedVault seedVault;
  late _MockRepo repo;
  late _MockTokens tokens;
  late _MockPortfolio portfolio;
  late _MockPrefs prefs;
  late _MockSession session;

  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(SolanaDerivationScheme.standard);
  });

  setUp(() {
    seedVault = _MockSeedVault();
    repo = _MockRepo();
    tokens = _MockTokens();
    portfolio = _MockPortfolio();
    prefs = _MockPrefs();
    session = _MockSession();

    // The bloc reaches the session through the service locator, matching the
    // codebase's bloc -> sl<> convention.
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    sl.registerSingleton<SessionManager>(session);
    when(() => session.switchToWallet(any())).thenAnswer((_) async {});
    when(
      () => session.activeProfileContainsAnyAddress(any()),
    ).thenReturn(false);

    when(seedVault.isAvailable).thenAnswer((_) async => true);
    when(seedVault.hasPermission).thenAnswer((_) async => true);
    when(seedVault.requestPermission).thenAnswer((_) async => true);
    when(seedVault.authorizeSeed).thenAnswer((_) async => 7);
    when(seedVault.listAccounts).thenAnswer((_) async => const []);
    when(
      () => seedVault.markAsUserWallet(
        authToken: any(named: 'authToken'),
        accountId: any(named: 'accountId'),
      ),
    ).thenAnswer((_) async {});

    when(repo.getAllWallets).thenAnswer((_) async => const []);
    when(repo.getAccountViews).thenAnswer((_) async => const <Account>[]);
    when(repo.peekNextAccountNumber).thenAnswer((_) async => 1);

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
    when(() => prefs.showLegacySolanaImport).thenReturn(false);
    when(() => prefs.setShowLegacySolanaImport(any())).thenAnswer((_) async {});
  });

  tearDown(() {
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
  });

  SeedVaultConnectBloc build() =>
      SeedVaultConnectBloc(seedVault, repo, tokens, portfolio, prefs);

  group('derivation-path parsing', () {
    test('reads the standard and legacy Solana paths', () {
      expect(parseSeedVaultSolanaPath(standardPath0), (
        index: 0,
        scheme: SolanaDerivationScheme.standard,
      ));
      expect(parseSeedVaultSolanaPath(standardPath1), (
        index: 1,
        scheme: SolanaDerivationScheme.standard,
      ));
      expect(parseSeedVaultSolanaPath(legacyPath0), (
        index: 0,
        scheme: SolanaDerivationScheme.legacy,
      ));
    });

    test('normalizes the bip44 URI form, which hardens implicitly', () {
      expect(parseSeedVaultSolanaPath('bip44:/m/44/501/2/0'), (
        index: 2,
        scheme: SolanaDerivationScheme.standard,
      ));
    });

    test('refuses the root path — it is the one scheme Seed Vault does not '
        'pre-derive', () {
      expect(parseSeedVaultSolanaPath(rootPath), isNull);
      // And the service agrees: building that path is an error, so a card for
      // it could never sign.
      expect(
        () => seedVaultDerivationPath(0, SolanaDerivationScheme.root),
        throwsArgumentError,
      );
    });

    test('refuses a non-Solana coin type', () {
      expect(parseSeedVaultSolanaPath("bip32:/m'/44'/60'/0'/0'"), isNull);
    });
  });

  group('gates', () {
    blocTest<SeedVaultConnectBloc, SeedVaultConnectState>(
      'a device without Seed Vault reaches the unavailable state instead of an '
      'empty picker',
      setUp: () => when(seedVault.isAvailable).thenAnswer((_) async => false),
      build: build,
      act: (bloc) => bloc.add(const SeedVaultStarted()),
      expect: () => [isA<SeedVaultPreparing>(), isA<SeedVaultUnavailable>()],
    );

    blocTest<SeedVaultConnectBloc, SeedVaultConnectState>(
      'a refused permission surfaces the settings CTA state rather than a dead '
      'end — it can be permanently denied while the device still reports '
      'Seed Vault as available',
      setUp: () {
        when(seedVault.hasPermission).thenAnswer((_) async => false);
        when(seedVault.requestPermission).thenAnswer((_) async => false);
      },
      build: build,
      act: (bloc) => bloc.add(const SeedVaultStarted()),
      expect: () => [
        isA<SeedVaultPreparing>(),
        isA<SeedVaultPermissionDenied>(),
      ],
      verify: (_) => verifyNever(seedVault.authorizeSeed),
    );

    blocTest<SeedVaultConnectBloc, SeedVaultConnectState>(
      'an already-authorized seed reaches the picker with no approval Activity '
      '— reading the content provider raises no Seed Vault UI',
      setUp: () => when(seedVault.listAccounts).thenAnswer(
        (_) async => [row(addrStandard0, standardPath0, accountId: 1)],
      ),
      build: build,
      act: (bloc) => bloc.add(const SeedVaultStarted()),
      verify: (_) => verifyNever(seedVault.authorizeSeed),
    );

    blocTest<SeedVaultConnectBloc, SeedVaultConnectState>(
      'nothing authorized yet asks the user to authorize a seed',
      setUp: () {
        var call = 0;
        when(seedVault.listAccounts).thenAnswer(
          (_) async => call++ == 0
              ? const []
              : [row(addrStandard0, standardPath0, accountId: 1)],
        );
      },
      build: build,
      act: (bloc) => bloc.add(const SeedVaultStarted()),
      verify: (_) => verify(seedVault.authorizeSeed).called(1),
    );
  });

  group('picker cards', () {
    blocTest<SeedVaultConnectBloc, SeedVaultConnectState>(
      'never builds a root card, even when the vault reports the root path',
      setUp: () {
        when(() => prefs.showLegacySolanaImport).thenReturn(true);
        when(seedVault.listAccounts).thenAnswer(
          (_) async => [
            row(addrStandard0, standardPath0, accountId: 1),
            row(addrLegacy0, legacyPath0, accountId: 2),
            row(addrRoot, rootPath, accountId: 3),
          ],
        );
      },
      build: build,
      act: (bloc) => bloc.add(const SeedVaultStarted()),
      verify: (bloc) {
        final loaded = bloc.state as SeedVaultAccountsLoaded;
        final rows = loaded.accounts.expand((a) => a.wallets).toList();
        expect(rows.map((w) => w.address), [addrStandard0, addrLegacy0]);
        expect(
          rows.map((w) => w.scheme),
          isNot(contains(SolanaDerivationScheme.root)),
        );
      },
    );

    blocTest<SeedVaultConnectBloc, SeedVaultConnectState>(
      'hides the legacy rows until the gear toggle asks for them',
      setUp: () {
        when(seedVault.listAccounts).thenAnswer(
          (_) async => [
            row(addrStandard0, standardPath0, accountId: 1),
            row(addrLegacy0, legacyPath0, accountId: 2),
          ],
        );
      },
      build: build,
      act: (bloc) => bloc.add(const SeedVaultStarted()),
      verify: (bloc) {
        final loaded = bloc.state as SeedVaultAccountsLoaded;
        expect(loaded.accounts.single.wallets.map((w) => w.address), [
          addrStandard0,
        ]);
      },
    );

    blocTest<SeedVaultConnectBloc, SeedVaultConnectState>(
      'borrows a stored name only from a seedVault account at the same index — '
      'a Ledger account there is a different account, and the import still '
      'allocates a fresh number for it',
      setUp: () {
        when(repo.getAccountViews).thenAnswer(
          (_) async => const [
            Account(
              id: 'acct-ledger',
              name: 'My Ledger',
              kind: AccountKind.hardware,
              derivationIndex: 0,
            ),
            Account(
              id: 'acct-sv',
              name: 'My Seeker',
              kind: AccountKind.seedVault,
              derivationIndex: 1,
            ),
          ],
        );
        when(seedVault.listAccounts).thenAnswer(
          (_) async => [
            row(addrStandard0, standardPath0, accountId: 1),
            row(addrStandard1, standardPath1, accountId: 2),
          ],
        );
      },
      build: build,
      act: (bloc) => bloc.add(const SeedVaultStarted()),
      verify: (bloc) {
        final loaded = bloc.state as SeedVaultAccountsLoaded;
        expect(loaded.accounts[0].importedName, isNull);
        expect(loaded.accounts[1].importedName, 'My Seeker');
      },
    );
  });

  group('import', () {
    const wallet = WalletInfo(
      id: 'w-1',
      address: addrStandard0,
      name: 'Solana',
      walletType: WalletType.seedVault,
      chain: 'solana',
      accountId: 'acct-1',
      derivationIndex: 0,
    );

    void stubOneAccount() {
      when(seedVault.listAccounts).thenAnswer(
        (_) async => [row(addrStandard0, standardPath0, accountId: 1)],
      );
      when(
        () => repo.addSeedVaultWallet(
          any(),
          any(),
          derivationIndex: any(named: 'derivationIndex'),
          derivationScheme: any(named: 'derivationScheme'),
        ),
      ).thenAnswer((_) async => wallet);
    }

    /// Run the flow up to a completed import of the one visible row.
    Future<SeedVaultConnectBloc> importOne() async {
      final bloc = build();
      bloc.add(const SeedVaultStarted());
      final loaded =
          await bloc.stream.firstWhere((s) => s is SeedVaultAccountsLoaded)
              as SeedVaultAccountsLoaded;
      bloc.add(
        SeedVaultToggleWallet(loaded.accounts.single.wallets.single.key),
      );
      await bloc.stream.first;
      bloc.add(const SeedVaultImportRequested());
      await bloc.stream.firstWhere((s) => s is SeedVaultImported);
      return bloc;
    }

    test('persists the selected row and flags it as a user wallet so other '
        'wallets on the device can discover it', () async {
      stubOneAccount();
      final bloc = await importOne();
      addTearDown(bloc.close);

      // Captured rather than matched literally: the scheme is part of a
      // wallet's identity, so an import that persisted the wrong one would
      // later produce a valid signature from a different address.
      final captured = verify(
        () => repo.addSeedVaultWallet(
          captureAny(),
          captureAny(),
          derivationIndex: captureAny(named: 'derivationIndex'),
          derivationScheme: captureAny(named: 'derivationScheme'),
        ),
      ).captured;
      expect(captured, [
        addrStandard0,
        'Solana',
        0,
        SolanaDerivationScheme.standard,
      ]);
      verify(
        () => seedVault.markAsUserWallet(authToken: 7, accountId: 1),
      ).called(1);
    });

    test('switches the session to the imported wallet when no Profile covers '
        'it', () async {
      stubOneAccount();
      final bloc = await importOne();
      addTearDown(bloc.close);

      verify(() => session.switchToWallet('w-1')).called(1);
    });

    test(
      'does NOT switch the session when the active Profile already covers '
      'an imported address — importing the Seed Vault backing of a wallet '
      'the Profile already links must leave the user on that Profile',
      () async {
        stubOneAccount();
        when(
          () => session.activeProfileContainsAnyAddress(any()),
        ).thenReturn(true);

        final bloc = await importOne();
        addTearDown(bloc.close);

        verifyNever(() => session.switchToWallet(any()));
        expect(bloc.state, isA<SeedVaultImported>());
      },
    );
  });
}
