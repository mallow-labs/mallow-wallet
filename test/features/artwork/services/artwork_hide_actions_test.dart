import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_hidden_signal.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_hide_actions.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

class _MockSession extends Mock implements SessionManager {}

class _MockUserProfileRepo extends Mock implements UserProfileRepository {}

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

  // The backend now 403s an unauthorized hide/unhide instead of the old silent
  // 200 no-op. The client must therefore treat a throw as "the write did not
  // happen": surface an error and NEVER broadcast the optimistic flip (which
  // would flip badges/menu rows for a write that never landed). Only a genuine
  // success broadcasts [notifyArtworkHidden] and shows the confirmation.
  group('toggleArtworkHidden', () {
    const mint = 'MINT_1';

    late _MockUserProfileRepo repo;
    late ArtworkHiddenSignal signal;
    late List<ArtworkHiddenChange> emitted;
    late StreamSubscription<ArtworkHiddenChange> sub;

    setUp(() {
      repo = _MockUserProfileRepo();
      signal = ArtworkHiddenSignal();
      emitted = [];
      sub = signal.stream.listen(emitted.add);

      if (sl.isRegistered<UserProfileRepository>()) {
        sl.unregister<UserProfileRepository>();
      }
      if (sl.isRegistered<ArtworkHiddenSignal>()) {
        sl.unregister<ArtworkHiddenSignal>();
      }
      sl.registerSingleton<UserProfileRepository>(repo);
      sl.registerSingleton<ArtworkHiddenSignal>(signal);

      // Active wallet already carries a valid sig, so the verify gate passes
      // without signing — isolating the hide/unhide write behaviour under test.
      when(() => auth.currentAddress).thenReturn(active);
      when(
        () => auth.hasValidWalletSigForAny(any()),
      ).thenAnswer((_) async => true);
    });

    tearDown(() async {
      await sub.cancel();
      if (sl.isRegistered<UserProfileRepository>()) {
        sl.unregister<UserProfileRepository>();
      }
      if (sl.isRegistered<ArtworkHiddenSignal>()) {
        sl.unregister<ArtworkHiddenSignal>();
      }
    });

    Future<BuildContext> pumpContext(WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return ctx;
    }

    // Let the top-anchored snackbar's 4s auto-dismiss timer fire and its exit
    // animation finish, so no timers/animations linger past the test.
    Future<void> drainSnackBar(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'unauthorized hide (403) → no signal, error snackbar, no flip',
      (tester) async {
        when(() => repo.hideMint(any())).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: '/v0/hide'),
            response: Response(
              requestOptions: RequestOptions(path: '/v0/hide'),
              statusCode: 403,
            ),
          ),
        );
        final ctx = await pumpContext(tester);

        final result = await toggleArtworkHidden(
          ctx,
          mintAccount: mint,
          currentlyHidden: false,
        );
        await tester.pump();

        expect(result, isNull);
        // The optimistic flip must NOT be broadcast for a write that 403'd.
        expect(emitted, isEmpty);
        expect(find.text('Failed to hide artwork'), findsOneWidget);

        await drainSnackBar(tester);
      },
    );

    testWidgets('authorized hide → signal + confirmation, returns new state', (
      tester,
    ) async {
      when(() => repo.hideMint(any())).thenAnswer((_) async {});
      final ctx = await pumpContext(tester);

      final result = await toggleArtworkHidden(
        ctx,
        mintAccount: mint,
        currentlyHidden: false,
      );
      await tester.pump();

      expect(result, isTrue);
      expect(emitted, [(mintAccount: mint, isHidden: true)]);
      expect(find.text('Hidden from profile'), findsOneWidget);
      verify(() => repo.hideMint(mint)).called(1);

      await drainSnackBar(tester);
    });

    testWidgets('authorized unhide → signal(false) + confirmation', (
      tester,
    ) async {
      when(() => repo.unhideMint(any())).thenAnswer((_) async {});
      final ctx = await pumpContext(tester);

      final result = await toggleArtworkHidden(
        ctx,
        mintAccount: mint,
        currentlyHidden: true,
      );
      await tester.pump();

      expect(result, isFalse);
      expect(emitted, [(mintAccount: mint, isHidden: false)]);
      expect(find.text('Unhidden'), findsOneWidget);
      verify(() => repo.unhideMint(mint)).called(1);

      await drainSnackBar(tester);
    });
  });
}
