import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/ensure_signer.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'ensure_signer_test.mocks.dart';

@GenerateMocks([SessionManager, AuthService])
void main() {
  late MockSessionManager mockSession;
  late MockAuthService mockAuth;

  // The wallet that holds the artwork (a signable, non-active session wallet).
  const signerAddress = 'Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS';
  // The currently-active signer, distinct from the holder.
  const activeAddress = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  // A session wallet that cannot sign (imported by address only).
  const watchOnlyAddress = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  // Authorities that are not in the session at all (delegate scenario).
  const outsiderAddress = '4Nd1mBQtrMJVYVfKf2PJy9NZUZdTAsp7D4xWLs4gDB4T';
  const otherOutsiderAddress = '7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2';

  // The watch-only prompt body shipped as the default (artwork-holder copy).
  const defaultWatchOnlyMessage =
      'This artwork is held by a watch-only wallet in your account. '
      'Import its private key to sign for it.';

  const holderWallet = WalletInfo(
    id: 'holder-wallet',
    address: signerAddress,
    name: 'holder',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct-holder',
  );
  const activeWallet = WalletInfo(
    id: 'active-wallet',
    address: activeAddress,
    name: 'active',
    walletType: WalletType.hd,
    chain: 'solana',
    accountId: 'acct-active',
  );
  const watchOnlyWallet = WalletInfo(
    id: 'watch-wallet',
    address: watchOnlyAddress,
    name: 'watching',
    walletType: WalletType.viewOnly,
    chain: 'solana',
    accountId: 'acct-watch',
  );

  setUp(() {
    mockSession = MockSessionManager();
    mockAuth = MockAuthService();
    // `ensure_signer` resolves both services through the global locator.
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    sl.registerSingleton<SessionManager>(mockSession);
    sl.registerSingleton<AuthService>(mockAuth);

    when(mockAuth.currentAddress).thenReturn(activeAddress);
    // Default: an address is NOT a session wallet. Both lookups need this —
    // `ensureSignerForAny` probes every candidate, so an unstubbed outsider
    // would raise MissingStubError instead of exercising the delegate
    // pass-through the tests below are asserting.
    when(mockSession.sessionWalletForAddress(any)).thenReturn(null);
    when(
      mockSession.sessionWalletForAddressCaseInsensitive(any),
    ).thenReturn(null);
    // `activeSignerSnapshot` resolves through this so a Profile-mode active
    // signer outside `sessionWallets` is still restorable.
    when(mockSession.resolveWalletForAddress(any)).thenReturn(null);
    when(
      mockSession.resolveWalletForAddress(signerAddress),
    ).thenReturn(holderWallet);
    when(
      mockSession.resolveWalletForAddress(activeAddress),
    ).thenReturn(activeWallet);
    when(
      mockSession.resolveWalletForAddress(watchOnlyAddress),
    ).thenReturn(watchOnlyWallet);
    when(
      mockSession.sessionWalletForAddress(signerAddress),
    ).thenReturn(holderWallet);
    when(
      mockSession.sessionWalletForAddress(activeAddress),
    ).thenReturn(activeWallet);
    when(
      mockSession.sessionWalletForAddress(watchOnlyAddress),
    ).thenReturn(watchOnlyWallet);
    // `ensureSignerForAny` resolves candidates through the case-insensitive
    // lookup; `_resolveSigner` then uses the exact one for Solana.
    when(
      mockSession.sessionWalletForAddressCaseInsensitive(signerAddress),
    ).thenReturn(holderWallet);
    when(
      mockSession.sessionWalletForAddressCaseInsensitive(watchOnlyAddress),
    ).thenReturn(watchOnlyWallet);
    when(mockSession.selectSourceWallet(any)).thenAnswer((_) async {});
  });

  tearDown(() {
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
  });

  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return ctx;
  }

  /// Advance a fixed frame budget — enough for the sheet to reveal or dismiss,
  /// without waiting on an animation that never settles.
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Runs [gate] (a signer gate expected to raise the watch-only prompt),
  /// asserts the sheet renders [expectedMessage] and not [absentMessage],
  /// dismisses it via Cancel and returns the gate's result. The gate's future is
  /// deliberately not awaited before pumping — it only completes once the sheet
  /// is dismissed. Both message assertions run while the sheet is on-screen,
  /// where `findsNothing` can still fail.
  Future<bool> runWatchOnlyPrompt(
    WidgetTester tester,
    Future<bool> Function() gate, {
    required String expectedMessage,
    String? absentMessage,
  }) async {
    final result = gate();
    // Fixed-step pumps, never `pumpAndSettle`: the confirm sheet's entrance
    // animation never reaches a steady state, so settling waits out its full
    // 10-minute timeout. Worse, the resulting failure looks like a hang rather
    // than an assertion error, because `result` only completes once the sheet
    // is dismissed below.
    await pumpFrames(tester);
    expect(find.text('Watch-only wallet'), findsOneWidget);
    expect(find.text(expectedMessage), findsOneWidget);
    if (absentMessage != null) {
      expect(find.text(absentMessage), findsNothing);
    }
    // The prompt's whole purpose: offer the import route for the key.
    expect(find.text('Import wallet'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await pumpFrames(tester);
    return result;
  }

  // The core intent of the fix: merely *reaching* a flow's precondition check
  // (opening an edit screen / a transfer or list sheet) must NOT persist an
  // active-signer switch. `ensureSignerAvailable` clears the flow to proceed
  // but defers the re-point to the confirmed-execution point.
  testWidgets('ensureSignerAvailable never re-points the active signer '
      'even when the holder is a signable non-active wallet', (tester) async {
    final ctx = await pumpContext(tester);

    final canProceed = await ensureSignerAvailable(ctx, signerAddress);

    expect(canProceed, isTrue);
    verifyNever(mockSession.selectSourceWallet(any));
  });

  // The committed path still switches — deferring must not lose the behavior
  // that lets the holder wallet sign.
  testWidgets('ensureSigner re-points the active signer to the holder wallet', (
    tester,
  ) async {
    final ctx = await pumpContext(tester);

    final canProceed = await ensureSigner(ctx, signerAddress);

    expect(canProceed, isTrue);
    verify(mockSession.selectSourceWallet(holderWallet)).called(1);
  });

  // The linked-wallet-holder scenario: the transfer flow resolves the EVM
  // holder to a signable session wallet (B) that is NOT the active signer (A).
  // ensureSigner must clear the flow to proceed WITHOUT re-pointing the active
  // (Solana-oriented) signer — the EVM transfer service signs keyed by the
  // holder's wallet id, so no `selectSourceWallet` switch applies. The holder
  // is matched case-insensitively (EIP-55 checksum) via the shared lookup.
  testWidgets('ensureSigner clears an EVM holder that is a signable non-active '
      'session wallet without re-pointing the active signer', (tester) async {
    const checksummed = '0xABCdef0000000000000000000000000000000ABC';
    const holderEth = WalletInfo(
      id: 'eth-holder',
      address: '0xabcdef0000000000000000000000000000000abc',
      name: 'holder eth',
      walletType: WalletType.hd,
      chain: 'ethereum',
      accountId: 'acct-eth',
    );
    when(
      mockSession.sessionWalletForAddressCaseInsensitive(checksummed),
    ).thenReturn(holderEth);
    final ctx = await pumpContext(tester);

    final canProceed = await ensureSigner(ctx, checksummed, evmHolder: true);

    expect(canProceed, isTrue);
    verifyNever(mockSession.selectSourceWallet(any));
  });

  // Tezos reaches the same conclusion as EVM by a different route: it has no
  // `evmHolder` flag and a `tz1…` address does not hit the `0x` short-circuit,
  // so a signable Tezos holder used to fall through and re-point the signer —
  // and with it the backend login identity that authorizes unrelated
  // `owner == req.loginAddress` writes. Tezos signs by explicit wallet id, so
  // the switch bought nothing; it is also the one flow where the transfer is
  // then refused outright by the unimplemented-cell backstop, leaving the user
  // logged in as a wallet they never chose for an action that never ran.
  testWidgets('ensureSigner clears a signable Tezos holder without re-pointing '
      'the active signer', (tester) async {
    const tezAddress = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';
    const holderTez = WalletInfo(
      id: 'tez-holder',
      address: tezAddress,
      name: 'holder tez',
      walletType: WalletType.hd,
      chain: 'tezos',
      accountId: 'acct-tez',
    );
    when(mockSession.sessionWalletForAddress(tezAddress)).thenReturn(holderTez);
    final ctx = await pumpContext(tester);

    final canProceed = await ensureSigner(ctx, tezAddress);

    expect(canProceed, isTrue);
    verifyNever(mockSession.selectSourceWallet(any));
  });

  // The control for both cases above: Solana's executor resolves its signer
  // from the global selection, so there the switch IS the mechanism and must
  // still happen. (Covered by the re-point test above; asserted here against
  // the same holder to keep the contrast in one place.)
  testWidgets('ensureSigner still re-points for a Solana holder — its executor '
      'signs with the globally selected wallet', (tester) async {
    final ctx = await pumpContext(tester);

    await ensureSigner(ctx, signerAddress);

    verify(mockSession.selectSourceWallet(holderWallet)).called(1);
  });

  test('activeSignerSnapshot resolves the current active wallet', () {
    expect(activeSignerSnapshot(), activeWallet);
  });

  // Restore is how transfer/burn/list undo an up-front switch when the user
  // abandons the flow, leaving the persisted active signer unchanged overall.
  test(
    'restoreSigner re-points back when the active wallet has moved',
    () async {
      // The flow switched the active signer to the holder; abandoning restores.
      when(mockAuth.currentAddress).thenReturn(signerAddress);

      await restoreSigner(activeWallet);

      verify(mockSession.selectSourceWallet(activeWallet)).called(1);
    },
  );

  test(
    'restoreSigner is a no-op when the snapshot is already active',
    () async {
      await restoreSigner(activeWallet);

      verifyNever(mockSession.selectSourceWallet(any));
    },
  );

  test('restoreSigner is a no-op for a null snapshot', () async {
    await restoreSigner(null);

    verifyNever(mockSession.selectSourceWallet(any));
  });

  group('ensureSignerForAny', () {
    // The reason the active-wallet scan must run over ALL candidates before the
    // ordered signable scan: settling an auction passes
    // `[seller, currentBidder]`, and when the *winner* is the active wallet a
    // candidate-order-first implementation would re-point the user's app-wide
    // wallet to the seller for a "Claim NFT" tap. That switch is both pointless
    // (the active wallet is already a valid authority) and semantically wrong —
    // settling as the seller is a different action than claiming as the winner.
    testWidgets('does not switch when the active wallet is a later candidate', (
      tester,
    ) async {
      final ctx = await pumpContext(tester);

      // Seller first (signable, non-active), winner second (active).
      final canProceed = await ensureSignerForAny(ctx, [
        signerAddress,
        activeAddress,
      ]);

      expect(canProceed, isTrue);
      verifyNever(mockSession.selectSourceWallet(any));
    });

    // Ordering still carries meaning when the active wallet is not an
    // authority: candidates are listed most-specific-first, so the first
    // signable one is the wallet the action should be performed as.
    testWidgets('switches to the first candidate when it can sign', (
      tester,
    ) async {
      final ctx = await pumpContext(tester);

      final canProceed = await ensureSignerForAny(ctx, [
        signerAddress,
        outsiderAddress,
      ]);

      expect(canProceed, isTrue);
      verify(mockSession.selectSourceWallet(holderWallet)).called(1);
    });

    // A watch-only first candidate must not dead-end the flow: the user holds
    // another authority that can actually sign (e.g. the raffle creator is
    // watch-only but the winner is a real wallet), so the action stays possible
    // instead of bouncing the user to the import screen.
    testWidgets('skips a watch-only candidate and switches to the next '
        'signable one', (tester) async {
      final ctx = await pumpContext(tester);

      final canProceed = await ensureSignerForAny(ctx, [
        watchOnlyAddress,
        signerAddress,
      ]);

      expect(canProceed, isTrue);
      verify(mockSession.selectSourceWallet(holderWallet)).called(1);
    });

    // None of the authorities is in the session, so the active wallet must be
    // acting as a delegate — the on-chain program, not this gate, decides
    // whether it may sign. Blocking here would break legitimate delegate flows.
    testWidgets('passes through without switching when no candidate is a '
        'session wallet', (tester) async {
      final ctx = await pumpContext(tester);

      final canProceed = await ensureSignerForAny(ctx, [
        outsiderAddress,
        otherOutsiderAddress,
      ]);

      expect(canProceed, isTrue);
      verifyNever(mockSession.selectSourceWallet(any));
    });

    // Every authority is a session wallet the user cannot sign for, so the
    // action is genuinely impossible: fail closed and offer the one remedy
    // (importing the key) rather than letting the flow reach a signing failure.
    testWidgets('returns false and prompts import when every candidate is '
        'watch-only', (tester) async {
      final ctx = await pumpContext(tester);

      final canProceed = await runWatchOnlyPrompt(
        tester,
        () => ensureSignerForAny(ctx, [watchOnlyAddress, watchOnlyAddress]),
        expectedMessage: defaultWatchOnlyMessage,
      );

      expect(canProceed, isFalse);
      verifyNever(mockSession.selectSourceWallet(any));
    });

    // Callers build candidate lists straight from optional model fields
    // (`auction.seller`, `auction.currentBidder`), so nulls and empty strings
    // are the norm. A blank entry must not consume the "first candidate"
    // fallback slot and mask the real authority behind it.
    testWidgets('skips null and empty candidates', (tester) async {
      final ctx = await pumpContext(tester);

      final canProceed = await ensureSignerForAny(ctx, [
        null,
        '',
        signerAddress,
      ]);

      expect(canProceed, isTrue);
      verify(mockSession.selectSourceWallet(holderWallet)).called(1);
    });

    // No authority is known at all (a model with every candidate field null):
    // there is nothing to gate on, so the flow proceeds untouched rather than
    // blocking the user on missing metadata.
    testWidgets('returns true without switching for an empty candidate list', (
      tester,
    ) async {
      final ctx = await pumpContext(tester);

      expect(await ensureSignerForAny(ctx, const []), isTrue);
      expect(await ensureSignerForAny(ctx, const [null, '']), isTrue);

      verifyNever(mockSession.selectSourceWallet(any));
    });
  });

  group('watchOnlyMessage', () {
    // The default copy claims the wallet "holds this artwork", which is a lie
    // for authorities that are not holders — cancelling an offer or claiming
    // sale proceeds. Callers must be able to name the actual reason.
    const customMessage =
        'The wallet that made this offer is watch-only. '
        'Import its private key to cancel the offer.';

    testWidgets('ensureSigner renders the caller-supplied message', (
      tester,
    ) async {
      final ctx = await pumpContext(tester);

      final canProceed = await runWatchOnlyPrompt(
        tester,
        () => ensureSigner(
          ctx,
          watchOnlyAddress,
          watchOnlyMessage: customMessage,
        ),
        expectedMessage: customMessage,
        absentMessage: defaultWatchOnlyMessage,
      );

      expect(canProceed, isFalse);
    });

    // Every existing artwork call site omits the parameter, so the default must
    // stay exactly today's copy — parameterising it must not change what the
    // untouched artwork flows say.
    testWidgets('ensureSigner keeps the artwork default when omitted', (
      tester,
    ) async {
      final ctx = await pumpContext(tester);

      final canProceed = await runWatchOnlyPrompt(
        tester,
        () => ensureSigner(ctx, watchOnlyAddress),
        expectedMessage: defaultWatchOnlyMessage,
      );

      expect(canProceed, isFalse);
    });

    // The no-side-effect variant shares `_resolveSigner`, so the copy must
    // reach the prompt identically — a screen-open precondition check explains
    // itself with the same sentence as the committed path.
    testWidgets('ensureSignerAvailable renders the caller-supplied message', (
      tester,
    ) async {
      final ctx = await pumpContext(tester);

      final canProceed = await runWatchOnlyPrompt(
        tester,
        () => ensureSignerAvailable(
          ctx,
          watchOnlyAddress,
          watchOnlyMessage: customMessage,
        ),
        expectedMessage: customMessage,
      );

      expect(canProceed, isFalse);
    });

    // The multi-candidate gate reaches the prompt through its fallback branch,
    // which is the easiest place to drop the parameter on the floor.
    testWidgets('ensureSignerForAny forwards the message to its fallback '
        'resolution', (tester) async {
      final ctx = await pumpContext(tester);

      final canProceed = await runWatchOnlyPrompt(
        tester,
        () => ensureSignerForAny(ctx, [
          watchOnlyAddress,
        ], watchOnlyMessage: customMessage),
        expectedMessage: customMessage,
        absentMessage: defaultWatchOnlyMessage,
      );

      expect(canProceed, isFalse);
    });
  });
}
