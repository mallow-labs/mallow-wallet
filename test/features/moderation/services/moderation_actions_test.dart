import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/moderation/data/moderation_repository.dart';
import 'package:mallow_wallet/features/moderation/services/block_store.dart';
import 'package:mallow_wallet/features/moderation/services/moderation_actions.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockSession extends Mock implements SessionManager {}

class _MockRepo extends Mock implements ModerationRepository {}

const _viewer = 'SOCIAL_VIEWER';
const _target = 'TARGET_ADDR';

void main() {
  late _MockAuth auth;
  late _MockSession session;
  late _MockRepo repo;
  late ChangeNotifier sigChanges;
  late List<String> calls;

  setUpAll(() => registerFallbackValue(const <String>[]));

  setUp(() {
    auth = _MockAuth();
    session = _MockSession();
    repo = _MockRepo();
    sigChanges = ChangeNotifier();
    calls = [];

    when(() => auth.currentAddress).thenReturn(_viewer);
    when(() => auth.walletSigChanges).thenReturn(sigChanges);
    // A social wallet with no proof yet: the shape whose key may be missing,
    // where the 401 re-sign skips the wallet and the write just fails.
    when(
      () => auth.hasValidWalletSigForAny(any()),
    ).thenAnswer((_) async => false);
    when(() => session.sessionWalletForAddress(_viewer)).thenReturn(
      const WalletInfo(
        id: 'w-social',
        address: _viewer,
        name: 'Google Wallet',
        walletType: WalletType.social,
        chain: 'solana',
      ),
    );
    when(() => repo.unblock(any())).thenAnswer((_) async {
      calls.add('unblock');
    });

    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    if (sl.isRegistered<BlockStore>()) sl.unregister<BlockStore>();
    sl.registerSingleton<AuthService>(auth);
    sl.registerSingleton<SessionManager>(session);
    sl.registerSingleton<BlockStore>(BlockStore(repo, auth));
  });

  tearDown(() {
    sl.unregister<BlockStore>();
    sl.unregister<SessionManager>();
    sl.unregister<AuthService>();
    sigChanges.dispose();
  });

  Future<bool?> tapUnblock(WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await runUnblockUserFlow(
              context,
              address: _target,
              label: '@target',
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();
    return result;
  }

  group('runUnblockUserFlow (a signed write started by a tap)', () {
    // The interceptor never re-logs a key-less social wallet in, so the write
    // must not be sent until the active wallet has proved itself here — where
    // the user tapped, and the re-login is expected.
    testWidgets('proves the active wallet before the write', (tester) async {
      when(() => auth.signAndVerifyForWallet(any(), any())).thenAnswer((
        _,
      ) async {
        calls.add('verify');
      });

      final result = await tapUnblock(tester);
      await tester.pump(const Duration(seconds: 5));

      expect(calls, ['verify', 'unblock']);
      verify(() => auth.signAndVerifyForWallet('w-social', _viewer)).called(1);
      expect(result, isTrue);
    });

    testWidgets('a cancelled re-login sends nothing and says so', (
      tester,
    ) async {
      when(() => auth.signAndVerifyForWallet(any(), any())).thenThrow(
        TransactionAuthCancelledException(
          'Sign-in was cancelled. Transaction aborted.',
        ),
      );

      final result = await tapUnblock(tester);

      expect(find.text('Sign-in was cancelled'), findsOneWidget);
      expect(
        find.textContaining('Couldn’t unblock'),
        findsNothing,
        reason: 'the generic failure is what this replaces',
      );
      expect(calls, isEmpty);
      expect(result, isFalse);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
