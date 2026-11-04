import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/cast/models/cast_queue.dart';
import 'package:mallow_wallet/features/cast/services/cast_actions.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockSession extends Mock implements SessionManager {}

class _MockCastBloc extends Mock implements CastBloc {}

/// Casting from a hardware wallet first needs a wallet-sig. Seed Vault's and
/// Keystone's verify sheets collect consent and sign nothing, so the pre-flight
/// must run the device's whole handshake rather than stop at consent.
void main() {
  const address = 'HardwareAddr';
  const item = CastQueueItem(mintAccount: 'mint', title: 't', imageUrl: 'u');

  late _MockAuth auth;
  late _MockSession session;
  late _MockCastBloc castBloc;

  setUpAll(() {
    registerFallbackValue(const CastEvent.castArtwork(item));
    registerFallbackValue(<String>[]);
  });

  setUp(() async {
    await sl.reset();
    auth = _MockAuth();
    session = _MockSession();
    castBloc = _MockCastBloc();
    sl
      ..registerSingleton<AuthService>(auth)
      ..registerSingleton<SessionManager>(session)
      ..registerSingleton<CastBloc>(castBloc);
    when(() => auth.currentAddress).thenReturn(address);
    when(
      auth.currentWalletNeedsHardwareVerification,
    ).thenAnswer((_) async => true);
    when(() => auth.hasValidWalletSigForAny(any())).thenAnswer((_) async {
      return false;
    });
  });

  tearDown(sl.reset);

  for (final type in [
    WalletType.seedVault,
    WalletType.keystone,
    WalletType.ledger,
  ]) {
    test('a ${type.name} wallet signs a wallet-sig, then casts', () async {
      when(() => session.sessionWalletForAddress(address)).thenReturn(
        WalletInfo(
          id: 'wallet-1',
          address: address,
          name: 'hw',
          walletType: type,
          chain: 'solana',
        ),
      );
      when(
        () => auth.signAndVerifyForWallet(any(), any()),
      ).thenAnswer((_) async {});

      await castArtworkWithVerify(item);

      verify(() => auth.signAndVerifyForWallet('wallet-1', address)).called(1);
      verify(() => castBloc.add(any())).called(1);
    });
  }

  test('a cancelled device does not cast', () async {
    when(() => session.sessionWalletForAddress(address)).thenReturn(
      const WalletInfo(
        id: 'wallet-1',
        address: address,
        name: 'hw',
        walletType: WalletType.keystone,
        chain: 'solana',
      ),
    );
    when(
      () => auth.signAndVerifyForWallet(any(), any()),
    ).thenThrow(HardwareVerificationCancelledException());

    await castArtworkWithVerify(item);

    verifyNever(() => castBloc.add(any()));
  });

  test('a cached wallet-sig casts without signing', () async {
    when(
      auth.currentWalletNeedsHardwareVerification,
    ).thenAnswer((_) async => false);

    await castArtworkWithVerify(item);

    verifyNever(() => auth.signAndVerifyForWallet(any(), any()));
    verify(() => castBloc.add(any())).called(1);
  });
}
