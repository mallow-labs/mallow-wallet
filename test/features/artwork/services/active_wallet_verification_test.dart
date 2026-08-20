import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/active_wallet_verification.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockSession extends Mock implements SessionManager {}

WalletInfo _wallet(String address, WalletType type) => WalletInfo(
  id: 'id-$address',
  address: address,
  name: address,
  walletType: type,
  chain: 'solana',
);

void main() {
  late _MockAuth auth;
  late _MockSession session;

  const active = 'ACTIVE_ADDR';

  setUpAll(() => registerFallbackValue(const <String>[]));

  setUp(() {
    auth = _MockAuth();
    session = _MockSession();
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    sl.registerSingleton<AuthService>(auth);
    sl.registerSingleton<SessionManager>(session);
  });

  tearDown(() {
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
  });

  // Stubs the common "active wallet is [type] and carries no valid sig" state.
  // Each test then decides how signAndVerifyForWallet behaves.
  void stubUnverifiedActive(WalletType type) {
    when(() => auth.currentAddress).thenReturn(active);
    when(
      () => auth.hasValidWalletSigForAny(any()),
    ).thenAnswer((_) async => false);
    when(
      () => session.sessionWalletForAddress(active),
    ).thenReturn(_wallet(active, type));
  }

  group('ensureActiveWalletVerified', () {
    // The active wallet already carries a valid sig — the interceptor attaches
    // it and the backend authorizes the write. No re-sign, no prompt.
    test('active wallet already verified → null, never re-signs', () async {
      when(() => auth.currentAddress).thenReturn(active);
      when(
        () => auth.hasValidWalletSigForAny(any()),
      ).thenAnswer((_) async => true);

      expect(await ensureActiveWalletVerified(), isNull);
      verifyNever(() => auth.signAndVerifyForWallet(any(), any()));
    });

    // Active wallet is HD (silently signable) and unverified → sign it silently.
    // Crucially it signs the ACTIVE wallet, since /v0/hide honors only that
    // wallet's cookie — not some other verified session wallet.
    test(
      'active HD wallet unverified → silently signs the active wallet',
      () async {
        stubUnverifiedActive(WalletType.hd);
        when(
          () => auth.signAndVerifyForWallet(any(), any()),
        ).thenAnswer((_) async {});

        expect(await ensureActiveWalletVerified(), isNull);
        verify(
          () => auth.signAndVerifyForWallet('id-$active', active),
        ).called(1);
      },
    );

    // A hide/download tap is user-initiated, so the interactive Ledger
    // connect+verify sheet is the correct response — the gate must hand off to
    // signAndVerifyForWallet (which routes hardware to LedgerVerifyController)
    // rather than dead-ending on a "verify first" message. The BLE sheet is
    // suppressed for *background* paths only, and that guard lives in
    // AuthService._verifySignatureIfPossible, not here.
    test('active Ledger wallet unverified → pops the verify flow', () async {
      stubUnverifiedActive(WalletType.ledger);
      when(
        () => auth.signAndVerifyForWallet(any(), any()),
      ).thenAnswer((_) async {});

      expect(await ensureActiveWalletVerified(), isNull);
      verify(() => auth.signAndVerifyForWallet('id-$active', active)).called(1);
    });

    // A dismissed or failed verify sheet means the write is unauthorized, so
    // the gate must block — with copy the user can read, not an exception dump.
    // The sheet has already named the underlying reason on screen.
    test('cancelled Ledger sheet → blocks with readable copy', () async {
      stubUnverifiedActive(WalletType.ledger);
      when(
        () => auth.signAndVerifyForWallet(any(), any()),
      ).thenThrow(LedgerVerificationCancelledException());

      final error = await ensureActiveWalletVerified();
      expect(error, 'Hardware wallet not verified');
      expect(error, isNot(contains('Exception')));
    });

    // The gate keys the "not verified" copy off the TYPED cancellation, not off
    // walletType — so a storage/database failure on a Ledger keeps its own
    // diagnostic instead of being mislabelled as a dismissed sheet.
    test('non-cancellation failure on Ledger → keeps the real error', () async {
      stubUnverifiedActive(WalletType.ledger);
      when(
        () => auth.signAndVerifyForWallet(any(), any()),
      ).thenThrow(Exception('keychain unavailable'));

      expect(
        await ensureActiveWalletVerified(),
        contains('keychain unavailable'),
      );
    });

    // A verified NON-active wallet must NOT satisfy the gate: /v0/hide ignores
    // its cookie, so the active wallet is the one that has to sign. The stub is
    // argument-aware on purpose — widening the gate's query to every session
    // address (the regression this guards) then returns true and fails here.
    test(
      'verified non-active wallet does not authorize the active write',
      () async {
        when(() => auth.currentAddress).thenReturn(active);
        when(() => auth.hasValidWalletSigForAny(any())).thenAnswer(
          (i) async => (i.positionalArguments.first as List<String>).contains(
            'WALLET_B',
          ),
        );
        when(
          () => session.sessionWalletForAddress(active),
        ).thenReturn(_wallet(active, WalletType.hd));
        when(
          () => session.sessionWalletForAddress('WALLET_B'),
        ).thenReturn(_wallet('WALLET_B', WalletType.hd));
        when(
          () => auth.signAndVerifyForWallet(any(), any()),
        ).thenAnswer((_) async {});

        expect(await ensureActiveWalletVerified(), isNull);
        // The ACTIVE wallet signs — never WALLET_B, whose cookie the backend
        // would ignore.
        verify(
          () => auth.signAndVerifyForWallet('id-$active', active),
        ).called(1);
        verifyNever(
          () => auth.signAndVerifyForWallet('id-WALLET_B', 'WALLET_B'),
        );
      },
    );

    // No active wallet at all → a can't-sign message, no crash.
    test('no active wallet → message', () async {
      when(() => auth.currentAddress).thenReturn(null);

      expect(await ensureActiveWalletVerified(), isNotNull);
    });

    // Watch-only active wallet → can't sign message, no silent sign attempt.
    test('view-only active wallet → message, never signs', () async {
      stubUnverifiedActive(WalletType.viewOnly);

      expect(await ensureActiveWalletVerified(), isNotNull);
      verifyNever(() => auth.signAndVerifyForWallet(any(), any()));
    });
  });
}
