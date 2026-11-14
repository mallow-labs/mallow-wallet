import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/features/profile/widgets/email_otp_sheet.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockSession extends Mock implements SessionManager {}

class _MockRepo extends Mock implements UserProfileRepository {}

const _viewer = 'SOCIAL_VIEWER';

void main() {
  late _MockAuth auth;
  late _MockSession session;
  late _MockRepo repo;
  late List<String> calls;

  setUpAll(() => registerFallbackValue(const <String>[]));

  setUp(() {
    auth = _MockAuth();
    session = _MockSession();
    repo = _MockRepo();
    calls = [];
    when(() => auth.currentAddress).thenReturn(_viewer);
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
    when(() => repo.sendEmailOtp(any())).thenAnswer((_) async {
      calls.add('send');
    });
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    if (sl.isRegistered<UserProfileRepository>()) {
      sl.unregister<UserProfileRepository>();
    }
    sl.registerSingleton<AuthService>(auth);
    sl.registerSingleton<SessionManager>(session);
    sl.registerSingleton<UserProfileRepository>(repo);
  });

  tearDown(() {
    sl.unregister<UserProfileRepository>();
    sl.unregister<SessionManager>();
    sl.unregister<AuthService>();
  });

  Future<void> sendCode(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showEmailOtpSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'ada@example.com');
    await tester.tap(find.widgetWithText(MallowButton, 'Send code'));
    await tester.pump();
    await tester.pump();
  }

  // `POST /v1/otp` takes a signed login. A social wallet whose key is missing
  // is skipped by the 401 re-sign, so the send only failed. The tap proves
  // the wallet first, and that is where the wallet gets its re-login.
  testWidgets('proves the active wallet before sending the code', (
    tester,
  ) async {
    when(() => auth.signAndVerifyForWallet(any(), any())).thenAnswer((_) async {
      calls.add('verify');
    });

    await sendCode(tester);

    expect(calls, ['verify', 'send']);
    verify(() => auth.signAndVerifyForWallet('w-social', _viewer)).called(1);
  });

  testWidgets('a cancelled re-login sends no code and says so', (tester) async {
    when(() => auth.signAndVerifyForWallet(any(), any())).thenThrow(
      TransactionAuthCancelledException(
        'Sign-in was cancelled. Transaction aborted.',
      ),
    );

    await sendCode(tester);

    expect(calls, isEmpty);
    expect(find.text('Sign-in was cancelled'), findsOneWidget);
  });

  // The backend says why it refused, and that is what the user needs to
  // read, not a generic "Something went wrong".
  for (final (status, message) in [
    (429, 'Too many codes requested. Try again later.'),
    (400, 'Email is already taken'),
    (400, 'Please wait before requesting a new code'),
  ]) {
    testWidgets('a $status refusal shows "$message"', (tester) async {
      when(
        () => auth.hasValidWalletSigForAny(any()),
      ).thenAnswer((_) async => true);
      when(() => repo.sendEmailOtp(any())).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/v1/otp'),
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: '/v1/otp'),
            statusCode: status,
            data: {
              'error': {'message': message},
            },
          ),
        ),
      );

      await sendCode(tester);

      expect(find.text(message), findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsNothing);
    });
  }
}
