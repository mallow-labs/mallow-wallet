import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mocktail/mocktail.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

class _MockWalletRepository extends Mock implements WalletRepository {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockSecureWalletStorage extends Mock implements SecureWalletStorage {}

class _MockPreferencesService extends Mock implements PreferencesService {}

class _MockProfileLookupService extends Mock implements ProfileLookupService {}

class _MockAuthService extends Mock implements AuthService {}

class _MockBulkUserLookupResponse extends Mock
    implements BulkUserLookupResponse {}

/// Minimal [LoginResult] — every field is defaulted or nullable, so the login's
/// payload is irrelevant to these tests; only *when* it resolves matters.
const _loginResult = LoginResult(user: User());

WalletInfo _sol(String id, String address, {String account = 'acc-1'}) =>
    WalletInfo(
      id: id,
      address: address,
      name: id,
      walletType: WalletType.hd,
      chain: 'solana',
      accountId: account,
    );

WalletInfo _evm(String id, String address, {String account = 'acc-1'}) =>
    WalletInfo(
      id: id,
      address: address,
      name: id,
      walletType: WalletType.importedKey,
      chain: 'ethereum',
      accountId: account,
    );

Account _account(List<WalletInfo> wallets, {String id = 'acc-1'}) =>
    Account(id: id, name: 'Account 01', wallets: wallets);

void main() {
  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(<WalletInfo>[]);
    registerFallbackValue(_MockBulkUserLookupResponse());
  });

  late _MockWalletRepository repo;
  late _MockWalletManager walletManager;
  late _MockSecureWalletStorage storage;
  late _MockPreferencesService prefs;
  late _MockProfileLookupService profileLookup;
  late _MockAuthService authService;
  late SessionManager session;

  /// Stands in for `AuthService.currentAddress`. The stubbed `switchWallet`
  /// drives it through the real lifecycle: `_clearSession` nulls it
  /// synchronously, then the (async) login sets it to the new address. That
  /// null window is the wallet-switch race, so the tests below can observe it.
  String? liveAddress;

  setUp(() {
    repo = _MockWalletRepository();
    walletManager = _MockWalletManager();
    storage = _MockSecureWalletStorage();
    prefs = _MockPreferencesService();
    profileLookup = _MockProfileLookupService();
    authService = _MockAuthService();
    session = SessionManager(
      repo,
      walletManager,
      storage,
      prefs,
      profileLookup,
    );

    // SessionManager resolves AuthService lazily via GetIt (rather than by
    // constructor injection) to avoid a DI cycle with the login pipeline.
    liveAddress = null;
    final getIt = GetIt.instance;
    if (getIt.isRegistered<AuthService>()) getIt.unregister<AuthService>();
    getIt.registerSingleton<AuthService>(authService);
    when(() => authService.currentAddress).thenAnswer((_) => liveAddress);
    when(() => authService.switchWallet(any())).thenAnswer((inv) async {
      liveAddress = null; // _clearSession()
      await Future<void>.delayed(Duration.zero); // the network login
      liveAddress = inv.positionalArguments.first as String;
      return _loginResult;
    });
    when(() => repo.getActiveWallet()).thenAnswer((_) async => null);

    // Default stubs for the writes switchToAccount performs.
    when(() => storage.storeLoginMode(any())).thenAnswer((_) async {});
    when(() => storage.storeSelectedAccountId(any())).thenAnswer((_) async {});
    when(() => storage.deleteActiveProfileId()).thenAnswer((_) async {});
    when(() => walletManager.switchWalletById(any())).thenAnswer((_) async {});
    when(() => prefs.lastSolanaWalletId(any())).thenReturn(null);
    when(
      () => prefs.setLastSolanaWalletId(any(), any()),
    ).thenAnswer((_) async {});
  });

  tearDown(() {
    final getIt = GetIt.instance;
    if (getIt.isRegistered<AuthService>()) getIt.unregister<AuthService>();
  });

  group('resolveSolanaSigner', () {
    test('single-Solana account resolves its only wallet', () async {
      final wallet = _sol('w1', 'ADDR_1');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([wallet]),
        ],
      );

      await session.switchToAccount('acc-1');
      final signer = await session.resolveSolanaSigner();

      // Why: an unambiguous account must resolve straight to its wallet.
      expect(signer?.id, 'w1');
    });

    test(
      'multi-Solana account defaults to the first wallet without prompting',
      () async {
        final w1 = _sol('w1', 'ADDR_1');
        final w2 = _sol('w2', 'ADDR_2');
        when(() => repo.getAccountViews()).thenAnswer(
          (_) async => [
            _account([w1, w2]),
          ],
        );

        await session.switchToAccount('acc-1');
        final signer = await session.resolveSolanaSigner();

        // Why: a multi-Solana account must never interrupt with a chooser —
        // wallet selection now lives inside the flow that needs it. With no
        // remembered choice it silently defaults to the first wallet.
        expect(signer?.id, 'w1');
        verifyNever(() => prefs.setLastSolanaWalletId(any(), any()));
      },
    );

    test('multi-Solana account honors the remembered choice', () async {
      final w1 = _sol('w1', 'ADDR_1');
      final w2 = _sol('w2', 'ADDR_2');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([w1, w2]),
        ],
      );
      when(() => prefs.lastSolanaWalletId('acc-1')).thenReturn('w2');

      await session.switchToAccount('acc-1');
      final signer = await session.resolveSolanaSigner();

      // Why: a direct wallet tap (persisted via preferredWalletId) must
      // stick as the account's default signer across resolves.
      expect(signer?.id, 'w2');
    });
  });

  group('switchToAccount', () {
    test(
      'activates the account\'s Solana wallet and persists the selection',
      () async {
        final sol = _sol('w1', 'SOL_ADDR');
        const eth = WalletInfo(
          id: 'w-eth',
          address: 'ETH_ADDR',
          name: 'eth',
          walletType: WalletType.hd,
          chain: 'ethereum',
          accountId: 'acc-1',
        );
        when(() => repo.getAccountViews()).thenAnswer(
          (_) async => [
            _account([sol, eth]),
          ],
        );

        await session.switchToAccount('acc-1');

        // Why: login is single-address (`/v0/login`) on the account's Solana
        // signer, so switching must activate that wallet — never the Ethereum
        // sibling — which drives the re-login, and persist the account so the
        // next cold start restores it.
        verify(() => walletManager.switchWalletById('w1')).called(1);
        verify(() => storage.storeSelectedAccountId('acc-1')).called(1);
      },
    );
  });

  group('sessionWalletForAddressCaseInsensitive', () {
    // An EVM holder threaded through the transfer flow arrives EIP-55
    // checksummed (mixed case) while the session stores one casing — the
    // shared lookup both `ensureSigner` and the EVM transfer service rely on
    // must fold case so the holder resolves to the wallet that can sign it.
    const lower = '0xabcdef0000000000000000000000000000000abc';
    const checksummed = '0xABCdef0000000000000000000000000000000ABC';
    const ethHolder = WalletInfo(
      id: 'w-eth',
      address: lower,
      name: 'eth',
      walletType: WalletType.hd,
      chain: 'ethereum',
      accountId: 'acc-1',
    );

    Future<void> activate() async {
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([_sol('w1', 'SOL_ADDR'), ethHolder]),
        ],
      );
      await session.switchToAccount('acc-1');
    }

    test('matches a checksummed holder against the stored casing', () async {
      await activate();
      expect(
        session.sessionWalletForAddressCaseInsensitive(checksummed),
        ethHolder,
      );
    });

    test('returns null for an address outside the session scope', () async {
      await activate();
      expect(session.sessionWalletForAddressCaseInsensitive('0xdead'), isNull);
    });

    test('returns null for an empty address', () async {
      await activate();
      expect(session.sessionWalletForAddressCaseInsensitive(''), isNull);
    });
  });

  group('switchToWallet', () {
    test(
      'Solana wallet: takes its account along, activating it exactly once',
      () async {
        final sol = _sol('w1', 'SOL_ADDR');
        when(() => repo.getWalletById('w1')).thenAnswer((_) async => sol);
        when(() => repo.getAccountViews()).thenAnswer(
          (_) async => [
            _account([sol]),
          ],
        );

        await session.switchToWallet('w1');

        // Why: post-import flows must anchor the session to the wallet's
        // account so the header shows "Account NN". The account has a Solana
        // signer, so switchToAccount activates it — switchToWallet must NOT
        // redundantly switch a second time.
        verify(() => storage.storeSelectedAccountId('acc-1')).called(1);
        verify(() => walletManager.switchWalletById('w1')).called(1);
      },
    );

    test('Eth/Tezos-only account: anchors the account AND moves auth onto the '
        'wallet (the reported bug path)', () async {
      const eth = WalletInfo(
        id: 'w-eth',
        address: 'ETH_ADDR',
        name: 'eth',
        walletType: WalletType.hd,
        chain: 'ethereum',
        accountId: 'acc-1',
      );
      when(() => repo.getWalletById('w-eth')).thenAnswer((_) async => eth);
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([eth]),
        ],
      );

      await session.switchToWallet('w-eth');

      // Why: an account with no Solana wallet resolves no signer, so
      // switchToAccount's no-signer fallback re-points the active wallet onto
      // the chosen wallet (preferredWalletId) — anchoring the session to the
      // account (header shows "Account NN", not the chain label) and re-logging
      // auth onto the wallet with a single switch. Asserting called(1) guards
      // the double-switch regression (the redundant explicit tail is gone).
      verify(() => storage.storeSelectedAccountId('acc-1')).called(1);
      verify(() => walletManager.switchWalletById('w-eth')).called(1);
    });

    test('account-less wallet: bare wallet switch, no session anchor', () async {
      const orphan = WalletInfo(
        id: 'w-orphan',
        address: 'ORPHAN_ADDR',
        name: 'orphan',
        walletType: WalletType.viewOnly,
        chain: 'solana',
      );
      when(
        () => repo.getWalletById('w-orphan'),
      ).thenAnswer((_) async => orphan);

      await session.switchToWallet('w-orphan');

      // Why: a legacy/orphan wallet with no account row can't anchor a session;
      // fall back to a plain wallet switch rather than crashing on a null id.
      verify(() => walletManager.switchWalletById('w-orphan')).called(1);
      verifyNever(() => repo.getAccountViews());
      verifyNever(() => storage.storeSelectedAccountId(any()));
    });
  });

  group('selectSourceWallet', () {
    test(
      'remembers the wallet, re-anchors its account, and switches the signer',
      () async {
        final wallet = _sol('wX', 'ADDR_X', account: 'acc-2');
        when(() => repo.getAccountViews()).thenAnswer(
          (_) async => [
            _account([wallet], id: 'acc-2'),
          ],
        );

        await session.selectSourceWallet(wallet);

        // Why: the picked source must drive the re-login (switchWalletById),
        // persist as the account's default so it sticks next time,
        // and re-anchor the active account so per-chain resolution is correct.
        verify(() => prefs.setLastSolanaWalletId('acc-2', 'wX')).called(1);
        verify(() => walletManager.switchWalletById('wX')).called(1);
        verify(() => storage.storeSelectedAccountId('acc-2')).called(1);
      },
    );

    test(
      'a Profile session keeps its identity when the source crosses accounts',
      () async {
        final a1 = _sol('w1', 'ADDR_1');
        final a2 = _sol('w2', 'ADDR_2', account: 'acc-2');
        when(() => repo.getAccountViews()).thenAnswer(
          (_) async => [
            _account([a1]),
            _account([a2], id: 'acc-2'),
          ],
        );
        when(
          () => storage.storeActiveProfileId(any()),
        ).thenAnswer((_) async {});
        final profile = ProfileGroup(
          wallets: [a1, a2],
          isAnon: false,
          userId: 'u1',
          username: 'alice',
        );
        await session.switchToProfile(profile);

        await session.selectSourceWallet(a2);

        // Why: switching to a wallet under a different account must re-anchor
        // the active account (so signing resolves) WITHOUT dropping Profile
        // mode — the drawer header stays the Profile identity.
        expect(session.isProfileMode, isTrue);
        expect(session.activeProfile?.username, 'alice');
        expect(session.activeAccount?.id, 'acc-2');
        verify(() => walletManager.switchWalletById('w2')).called(1);
      },
    );

    test(
      'resolves only after the re-login completes (the wallet-switch race)',
      () async {
        final wallet = _sol('wX', 'ADDR_X', account: 'acc-2');
        when(() => repo.getAccountViews()).thenAnswer(
          (_) async => [
            _account([wallet], id: 'acc-2'),
          ],
        );

        await session.selectSourceWallet(wallet);

        // Why: the switch persists the DB selection immediately but nulls
        // `currentAddress` until the /v0/login lands. Every authority read off
        // `currentAddress` — burn, offers accept/cancel, settle, buy/bid —
        // dispatches right after this await, so if it resolved during the null
        // window those flows fail "No wallet connected". Asserting merely that
        // `selectSourceWallet` was called would pass even then; the address at
        // resolution time is the only assertion that observes the defect.
        expect(liveAddress, 'ADDR_X');
        expect(session.ownsAddress('ADDR_X'), isTrue);
      },
    );

    test('a failed login rolls the selection back and rethrows', () async {
      final previous = _sol('wPrev', 'ADDR_PREV');
      final target = _sol('wX', 'ADDR_X', account: 'acc-2');
      when(() => repo.getActiveWallet()).thenAnswer((_) async => previous);
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([previous]),
          _account([target], id: 'acc-2'),
        ],
      );
      await session.switchToAccount('acc-1');
      clearInteractions(walletManager); // ignore the setup's own activation
      when(
        () => authService.switchWallet('ADDR_X'),
      ).thenThrow(Exception('offline'));

      await expectLater(
        session.selectSourceWallet(target),
        throwsA(isA<Exception>()),
      );

      // Why: `switchWalletById` has already durably re-pointed the wallet by
      // the time the login fails. Leaving it there strands the app with
      // getAddress() -> target but no authenticated session, and every
      // 401-retry path dead. The invariant is that the selection never points
      // at the target after a failed switch — and the error must reach the
      // caller so the flow can keep the previous source and surface it.
      verify(() => walletManager.switchWalletById('wX')).called(1);
      verify(() => walletManager.switchWalletById('wPrev')).called(1);
      expect(session.activeAccount?.id, 'acc-1');
    });

    test('records the last-Solana-wallet pref only for Solana wallets', () async {
      final ethWallet = _evm('wE', '0xAbCd', account: 'acc-2');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([ethWallet], id: 'acc-2'),
        ],
      );

      await session.selectSourceWallet(ethWallet);

      // Why: the pref is read back by resolveSolanaSigner against
      // `account.solanaWallets`. Writing an ETH/Tezos wallet id there finds no
      // match on read, so the account silently falls back to solWallets.first —
      // destroying the user's remembered Solana choice from an unrelated
      // ETH interaction, unrecoverably without an explicit re-pick.
      verifyNever(() => prefs.setLastSolanaWalletId(any(), any()));
      verify(() => walletManager.switchWalletById('wE')).called(1);
    });
  });

  group('ownsAddress', () {
    test('matches any wallet in the session, not just the active one', () async {
      final a = _sol('w1', 'ADDR_1');
      final b = _sol('w2', 'ADDR_2');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([a, b]),
        ],
      );
      await session.switchToAccount('acc-1');

      // Why: ownership/eligibility questions ("is this mine") span the whole
      // session — art held by a non-active session wallet is still the user's.
      expect(session.ownsAddress('ADDR_2'), isTrue);
      expect(session.ownsAddress('ADDR_STRANGER'), isFalse);
    });

    test('matches an EVM address across checksum casing', () async {
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([_evm('wE', '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed')]),
        ],
      );
      await session.switchToAccount('acc-1');

      // Why: the backend echoes owner addresses lowercased, while the device
      // stores the EIP-55 checksummed form. A raw == comparison silently drops
      // every EVM holding — the exact bug apiOwnerAddress normalisation exists
      // to prevent.
      expect(
        session.ownsAddress('0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed'),
        isTrue,
      );
      expect(
        session.ownsAddress('0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED'),
        isTrue,
      );
    });

    test('matches the active signer even when it is not a session wallet', () {
      liveAddress = 'ADDR_ACTIVE';

      // Why: in Profile mode `sessionWallets` is the profile's linked wallets
      // only, and it is empty for the whole window between cold start and
      // restoreActiveProfile rebuilding the group (and stays empty when that
      // lookup fails offline). A sessionAddresses-only predicate would deny
      // every ownership gate on launch.
      expect(session.sessionAddresses, isEmpty);
      expect(session.ownsAddress('ADDR_ACTIVE'), isTrue);
    });

    test('null and empty are never owned', () {
      expect(session.ownsAddress(null), isFalse);
      expect(session.ownsAddress(''), isFalse);
    });
  });

  group('sessionWalletsForChain', () {
    test('returns every wallet on the chain, including view-only', () async {
      final signable = _sol('w1', 'ADDR_1');
      const watchOnly = WalletInfo(
        id: 'w2',
        address: 'ADDR_2',
        name: 'w2',
        walletType: WalletType.viewOnly,
        chain: 'solana',
        accountId: 'acc-1',
      );
      final eth = _evm('w3', '0xAbC');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([signable, watchOnly, eth]),
        ],
      );
      await session.switchToAccount('acc-1');

      // Why: this backs display-only pickers (receive), where an address is all
      // you need — excluding view-only wallets there would hide addresses the
      // user can legitimately receive into. Contrast sessionWalletForChain,
      // which is canSign-gated because it resolves a *signer*.
      expect(session.sessionWalletsForChain(Chain.solana).map((w) => w.id), [
        'w1',
        'w2',
      ]);
      expect(session.sessionWalletsForChain(Chain.ethereum).map((w) => w.id), [
        'w3',
      ]);
    });
  });

  // A Profile session sources only from the wallets linked in its user record.
  // The active account is anchored to the profile's signer so per-chain
  // resolution works, but seed creation auto-derives a Solana + Ethereum +
  // Tezos wallet into every account — siblings a profile need not link. Reading
  // them put an XTZ balance under a Solana-only profile; signing or receiving
  // through them would move funds on a wallet the profile doesn't own.
  group('profile scoping (never source outside the linked set)', () {
    const tez = WalletInfo(
      id: 'w-tez',
      address: 'tz1_UNLINKED',
      name: 'tez',
      walletType: WalletType.hd,
      chain: 'tezos',
      accountId: 'acc-1',
    );

    /// A profile linking only [linkedSol], anchored to an account that also
    /// holds an auto-derived Tezos sibling.
    Future<void> profileLinkingOnlySolana(WalletInfo linkedSol) async {
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([linkedSol, tez]),
        ],
      );
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});
      await session.switchToProfile(
        ProfileGroup(
          wallets: [linkedSol],
          isAnon: false,
          userId: 'u1',
          username: 'alice',
        ),
      );
    }

    test('no signer on a chain the profile does not link', () async {
      await profileLinkingOnlySolana(_sol('w1', 'SOL_LINKED'));

      expect(session.sessionWalletForChain(Chain.solana)?.id, 'w1');
      // Not the account's tz1 sibling: a Solana-only profile has no Tezos
      // signer, and the caller must disable the action rather than sign with a
      // wallet outside the profile.
      expect(session.sessionWalletForChain(Chain.tezos), isNull);
    });

    test('no receive address on a chain the profile does not link', () async {
      await profileLinkingOnlySolana(_sol('w1', 'SOL_LINKED'));

      expect(session.sessionWalletsForChain(Chain.tezos), isEmpty);
    });

    test(
      'an Account session still falls back to its account siblings',
      () async {
        when(() => repo.getAccountViews()).thenAnswer(
          (_) async => [
            _account([_sol('w1', 'SOL_A'), tez]),
          ],
        );
        await session.switchToAccount('acc-1');

        // Why: an Account's scope *is* its wallets, so the per-chain fallback is
        // correct there — the narrowing is specific to Profile sessions.
        expect(session.sessionWalletForChain(Chain.tezos)?.id, 'w-tez');
        expect(session.sessionWalletsForChain(Chain.tezos), hasLength(1));
      },
    );

    test(
      'scopedToSession drops an address the profile does not link',
      () async {
        await profileLinkingOnlySolana(_sol('w1', 'SOL_LINKED'));

        expect(session.scopedToSession('SOL_LINKED'), 'SOL_LINKED');
        // The globally-selected wallet is not guaranteed to be in the profile —
        // the active account it anchors to carries auto-derived Ethereum/Tezos
        // siblings the profile never linked, so every sourcing decision filters
        // here.
        expect(session.scopedToSession('tz1_UNLINKED'), isNull);
        expect(session.scopedToSession(''), isNull);
      },
    );

    test(
      'an Account session passes every address through scopedToSession',
      () async {
        when(() => repo.getAccountViews()).thenAnswer(
          (_) async => [
            _account([_sol('w1', 'SOL_A')]),
          ],
        );
        await session.switchToAccount('acc-1');

        expect(session.scopedToSession('ANY_ADDRESS'), 'ANY_ADDRESS');
      },
    );
  });

  group('switchToProfile', () {
    test('Tezos-only profile: re-points the active wallet onto the held Tezos '
        'signer (the reported stale-balance path)', () async {
      const tez = WalletInfo(
        id: 'w-tez',
        address: 'tz1_ADDR',
        name: 'tez',
        walletType: WalletType.hd,
        chain: 'tezos',
        accountId: 'acc-2',
      );
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([tez], id: 'acc-2'),
        ],
      );
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});

      const profile = ProfileGroup(
        wallets: [tez],
        isAnon: false,
        userId: 'u1',
        username: 'alice',
      );
      await session.switchToProfile(profile);

      // Why: a profile with no held Solana signer used to activate no wallet, so
      // switchWalletById never fired — the wallet-change stream stayed silent
      // and the token-balance blocs never reloaded, leaving the previous
      // session's balances on screen. The fallback must re-point onto the held
      // Tezos wallet so onWalletChanged fires and the session identity is right.
      expect(session.isProfileMode, isTrue);
      expect(session.activeAccount?.id, 'acc-2');
      verify(() => walletManager.switchWalletById('w-tez')).called(1);
    });

    test('🛑 browse-only profile re-points onto its OWN held watch-only wallet '
        '— the previous profile must not stay the active signer', () async {
      const watch = WalletInfo(
        id: 'w-watch',
        address: 'SOL_WATCH',
        name: 'watch',
        walletType: WalletType.viewOnly,
        chain: 'solana',
        accountId: 'acc-2',
      );
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([watch], id: 'acc-2'),
        ],
      );
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});

      const profile = ProfileGroup(
        wallets: [watch],
        isAnon: false,
        userId: 'u1',
        username: 'alice',
      );
      await session.switchToProfile(profile);

      // Why: leaving the selection on the previous profile's signer is not a
      // cosmetic staleness. `WalletManager.getAddress()` reads that selection
      // and Solana's signing path reads it straight through
      // (`SolanaRpcService.buildSolTransferTx`, the executor's keypair lookup),
      // as do the callers that re-login off it — so the session kept signing
      // and authenticating as the profile the user had just left. The profile
      // can't sign, but the wallet the app points at must still be its own.
      expect(session.isProfileMode, isTrue);
      expect(session.activeAccount?.id, 'acc-2');
      verify(() => walletManager.switchWalletById('w-watch')).called(1);
    });

    test('a synthetic view-only placeholder is never activated — it has no DB '
        'row, so switchWalletById would throw on it', () async {
      // What `ProfileLookupService.buildProfileGroups` mints for a linked
      // address the user never imported: no accountId, id `view-only:<addr>`.
      const placeholder = WalletInfo(
        id: 'view-only:SOL_LINKED',
        address: 'SOL_LINKED',
        name: 'View-only',
        walletType: WalletType.viewOnly,
        chain: 'solana',
      );
      const held = WalletInfo(
        id: 'w-held-eth',
        address: '0xHELD',
        name: 'held',
        walletType: WalletType.viewOnly,
        chain: 'ethereum',
        accountId: 'acc-2',
      );
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([held], id: 'acc-2'),
        ],
      );
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});

      // Placeholder first, so a naive "first wallet" fallback would pick it.
      const profile = ProfileGroup(
        wallets: [placeholder, held],
        isAnon: false,
        userId: 'u1',
        username: 'alice',
      );
      await session.switchToProfile(profile);

      verify(() => walletManager.switchWalletById('w-held-eth')).called(1);
    });

    test('an account-less but row-backed wallet IS activated — "held" is the '
        'absence of a placeholder id, not the presence of an accountId', () async {
      // `wallets.accountId` is nullable and `restoreFromGraph` can write null,
      // so a legacy Keychain restore leaves real rows with no account —
      // `switchToWallet` has an explicit orphan branch for them. Testing on
      // accountId would skip one and leave the previous profile selected, which
      // is the whole bug.
      const orphan = WalletInfo(
        id: 'w-orphan',
        address: 'SOL_ORPHAN',
        name: 'orphan',
        walletType: WalletType.viewOnly,
        chain: 'solana',
      );
      when(() => repo.getAccountViews()).thenAnswer((_) async => []);
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});

      const profile = ProfileGroup(
        wallets: [orphan],
        isAnon: false,
        userId: 'u1',
        username: 'alice',
      );
      await session.switchToProfile(profile);

      verify(() => walletManager.switchWalletById('w-orphan')).called(1);
    });

    test('browse-only fallback prefers the held Solana wallet over a held '
        'wallet on another chain', () async {
      // Why: `WalletManager.getAddress()` returns the selected row's address
      // whatever chain it sits on, so selecting the ETH wallet would answer a
      // Solana read with a `0x` address.
      const eth = WalletInfo(
        id: 'w-eth',
        address: '0xWATCH',
        name: 'eth',
        walletType: WalletType.viewOnly,
        chain: 'ethereum',
        accountId: 'acc-2',
      );
      const sol = WalletInfo(
        id: 'w-sol',
        address: 'SOL_WATCH',
        name: 'sol',
        walletType: WalletType.viewOnly,
        chain: 'solana',
        accountId: 'acc-2',
      );
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([eth, sol], id: 'acc-2'),
        ],
      );
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});

      const profile = ProfileGroup(
        wallets: [eth, sol], // ETH first — order must not decide this
        isAnon: false,
        userId: 'u1',
        username: 'alice',
      );
      await session.switchToProfile(profile);

      verify(() => walletManager.switchWalletById('w-sol')).called(1);
    });
  });

  group('activeProfileContainsAnyAddress', () {
    test('Account session never claims to own an address', () async {
      final w1 = _sol('w1', 'ADDR_1');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([w1]),
        ],
      );

      await session.switchToAccount('acc-1');

      // Why: an Account session has no Profile to stay on, so a post-import
      // switch must proceed as before — this always reports false.
      expect(session.activeProfileContainsAnyAddress(['ADDR_1']), isFalse);
    });

    test('Profile session owns a read-only linked address', () async {
      const watch = WalletInfo(
        id: 'w-watch',
        address: 'SOL_WATCH',
        name: 'watch',
        walletType: WalletType.viewOnly,
        chain: 'solana',
        accountId: 'acc-1',
      );
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([watch]),
        ],
      );
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});
      await session.switchToProfile(
        const ProfileGroup(
          wallets: [watch],
          isAnon: false,
          userId: 'u1',
          username: 'alice',
        ),
      );

      // Why: this drives the import auto-switch decision — importing the real
      // key for a read-only linked wallet (SOL_WATCH) must keep the user on
      // their Profile, so ownership is matched even for a view-only placeholder.
      expect(
        session.activeProfileContainsAnyAddress(['SOL_WATCH', 'OTHER']),
        isTrue,
      );
      // A profile that shares none of the imported addresses does not match, so
      // an unrelated import still switches to its new account.
      expect(session.activeProfileContainsAnyAddress(['OTHER']), isFalse);
    });

    test('EVM linked address matches a checksummed import (casing)', () async {
      // The profile links the address lowercased (as the API returns it)...
      const linkedLower = '0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed';
      // ...but the caller passes the EIP-55 checksummed form (e.g. after ENS
      // resolution in the watch flow).
      const checksummed = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
      const eth = WalletInfo(
        id: 'w-eth',
        address: linkedLower,
        name: 'eth',
        walletType: WalletType.viewOnly,
        chain: 'ethereum',
        accountId: 'acc-1',
      );
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([eth]),
        ],
      );
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});
      await session.switchToProfile(
        const ProfileGroup(
          wallets: [eth],
          isAnon: false,
          userId: 'u1',
          username: 'alice',
        ),
      );

      // Why: without normalising both sides the checksummed import misses the
      // lowercase-linked wallet, and the post-import auto-switch wrongly jumps
      // the session off the user's Profile onto the fresh Account.
      expect(session.activeProfileContainsAnyAddress([checksummed]), isTrue);
    });
  });

  group('applyProfileEdit', () {
    Future<void> switchToAlice() async {
      final w1 = _sol('w1', 'ADDR_1');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([w1]),
        ],
      );
      when(() => storage.storeActiveProfileId(any())).thenAnswer((_) async {});
      await session.switchToProfile(
        ProfileGroup(
          wallets: [w1],
          isAnon: false,
          userId: 'alice',
          username: 'alice',
          displayName: 'Alice',
          imageUrl: 'https://img/old.png',
        ),
      );
    }

    test('updates the active profile identity so headers repaint the new name '
        '(the reported stale-header bug)', () async {
      await switchToAlice();
      var notified = false;
      session.addListener(() => notified = true);

      await session.applyProfileEdit(
        username: 'alice',
        displayName: 'Alice B',
        imageUrl: 'https://img/new.png',
      );

      // Why: the home/drawer/settings headers read the name and avatar from
      // activeProfile (displayName getter), which is otherwise rebuilt only on
      // a profile switch — an Edit Profile save must refresh it in place and
      // notify, or every header keeps the pre-edit identity.
      expect(session.activeProfile?.displayName, 'Alice B');
      expect(session.activeProfile?.imageUrl, 'https://img/new.png');
      expect(notified, isTrue);
    });

    test('a username change re-persists the active-profile id', () async {
      await switchToAlice();

      await session.applyProfileEdit(username: 'alice2');

      // Why: the group's userId IS the username (buildProfileGroups), so a
      // rename must re-store the persisted id — otherwise the next cold
      // start's restoreActiveProfile can't find the group and the session
      // silently loses its profile identity.
      expect(session.displayName, 'alice2');
      expect(session.activeProfile?.userId, 'alice2');
      verify(() => storage.storeActiveProfileId('alice2')).called(1);
    });

    test('is a no-op outside Profile mode', () async {
      final w1 = _sol('w1', 'ADDR_1');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([w1]),
        ],
      );
      await session.switchToAccount('acc-1');

      await session.applyProfileEdit(username: 'ghost');

      // Why: an Account session has no profile identity to patch — it must not
      // fabricate one or persist a profile id.
      expect(session.activeProfile, isNull);
      verifyNever(() => storage.storeActiveProfileId(any()));
    });
  });

  group('restoreActiveProfile', () {
    test('reconstructs the persisted Profile so the session spans all linked '
        'wallets after a cold start', () async {
      final w1 = _sol('w1', 'ADDR_1');
      final w2 = _sol('w2', 'ADDR_2', account: 'acc-2');

      // Cold start: restore() lands in profile mode but attaches no profile.
      when(() => storage.loadLoginMode()).thenAnswer((_) async => 'profile');
      when(() => storage.loadSelectedWalletId()).thenAnswer((_) async => 'w1');
      when(
        () => storage.loadSelectedAccountId(),
      ).thenAnswer((_) async => 'acc-1');
      when(
        () => storage.loadActiveProfileId(),
      ).thenAnswer((_) async => 'alice');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([w1]),
        ],
      );

      await session.restore();

      // Why: before reconstruction a profile session has no attached group, so
      // sessionWallets is empty — the receive sheet falls back to the single
      // active signer (the reported "only one wallet" symptom).
      expect(session.isProfileMode, isTrue);
      expect(session.sessionWallets, isEmpty);

      final profile = ProfileGroup(
        wallets: [w1, w2],
        isAnon: false,
        userId: 'alice',
        username: 'alice',
      );
      when(() => repo.getAllWallets()).thenAnswer((_) async => [w1, w2]);
      when(
        () => profileLookup.bulkLookup(any()),
      ).thenAnswer((_) async => const BulkLookupResult());
      when(
        () => profileLookup.lastResponse,
      ).thenReturn(_MockBulkUserLookupResponse());
      when(
        () => profileLookup.buildProfileGroups(any(), any()),
      ).thenReturn(([profile], const ProfileGroup(wallets: [], isAnon: true)));

      await session.restoreActiveProfile();

      // Why: once authenticated, the session must re-attach the persisted
      // profile so sessionWallets spans its full linked set (held + view-only)
      // — the receive sheet then lists every wallet, not just the signer.
      expect(session.activeProfile?.username, 'alice');
      expect(session.sessionWallets.map((w) => w.id), ['w1', 'w2']);
    });

    test('is a no-op outside Profile mode (no bulk lookup)', () async {
      final w1 = _sol('w1', 'ADDR_1');
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          _account([w1]),
        ],
      );
      await session.switchToAccount('acc-1');

      await session.restoreActiveProfile();

      // Why: an Account session has no profile to rebuild — it must not hit the
      // network or mutate the session.
      expect(session.activeProfile, isNull);
      verifyNever(() => profileLookup.bulkLookup(any()));
    });
  });

  group('warmProfileLookup', () {
    test('warms the bulk lookup for every local wallet when cold', () async {
      final w1 = _sol('w1', 'ADDR_1');
      final w2 = _sol('w2', 'ADDR_2', account: 'acc-2');
      when(() => profileLookup.lastResponse).thenReturn(null);
      when(() => repo.getAllWallets()).thenAnswer((_) async => [w1, w2]);
      when(
        () => profileLookup.bulkLookup(any()),
      ).thenAnswer((_) async => const BulkLookupResult());

      await session.warmProfileLookup();

      // Why: owned/created gates must resolve profile-linked wallets in ANY
      // session mode at startup, so the cache is seeded with every address.
      final captured = verify(
        () => profileLookup.bulkLookup(captureAny()),
      ).captured.single;
      expect(captured, ['ADDR_1', 'ADDR_2']);
    });

    test('skips the lookup when the cache is already warm', () async {
      when(
        () => profileLookup.lastResponse,
      ).thenReturn(_MockBulkUserLookupResponse());

      await session.warmProfileLookup();

      // Why: restoreActiveProfile / the drawer may have populated it already —
      // don't fire a redundant network call at startup.
      verifyNever(() => profileLookup.bulkLookup(any()));
    });
  });
}
