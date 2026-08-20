import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/cast/widgets/cast_error_toast.dart';
import 'package:mallow_wallet/features/cast/widgets/cast_error_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/app_snack_bar.dart';

class _MockCastBloc extends MockBloc<CastEvent, CastState>
    implements CastBloc {}

/// A cast session can die while the user is somewhere else entirely — the
/// receiver sleeps, drops off Wi-Fi, or another sender takes it. The inline
/// [CastErrorView] only exists inside the cast sheets and Now Playing, so that
/// case used to render nothing at all: the now-casting bar vanished and the
/// user was left to infer that casting had stopped. These tests pin the two
/// halves of the fix — the failure is announced when nothing else is showing
/// it, and it is announced exactly once when something is.
void main() {
  const message = 'Cast connection lost. The screen may have gone to sleep.';

  late StreamController<CastState> states;
  late _MockCastBloc bloc;

  setUp(() {
    states = StreamController<CastState>.broadcast();
    bloc = _MockCastBloc();
    whenListen(bloc, states.stream, initialState: const CastState.idle());
  });

  tearDown(() async {
    AppSnackBar.dismiss();
    await states.close();
  });

  /// [inlineSurface] mirrors what a cast sheet does: rebuild on [CastError]
  /// and render [CastErrorView] in place of its normal content.
  Future<void> pumpHost(
    WidgetTester tester, {
    required bool inlineSurface,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => BlocProvider<CastBloc>.value(
              value: bloc,
              child: CastErrorToastListener(
                // The app wires this to the root navigator's top route; the
                // test supplies a context inside the same (root) overlay.
                overlayContext: () => context,
                child: inlineSurface
                    ? BlocBuilder<CastBloc, CastState>(
                        builder: (context, state) => state is CastError
                            ? CastErrorView(message: state.message)
                            : const SizedBox.shrink(),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> dropSession(WidgetTester tester) async {
    states.add(const CastState.error(message: message));
    // First pump delivers the state and runs the post-frame suppression
    // check; the second lets the toast's entry build and animate in.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('announces the failure when no cast surface is showing it', (
    tester,
  ) async {
    await pumpHost(tester, inlineSurface: false);
    await dropSession(tester);

    // The mapped sentence from cast_failure.dart, not a generic string — it is
    // the only thing that tells the user what to do next.
    expect(find.text(message), findsOneWidget);

    // Retire the toast (and its auto-dismiss timer) inside the test.
    AppSnackBar.dismiss();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(message), findsNothing);
  });

  testWidgets('does not double-report when a sheet shows the error inline', (
    tester,
  ) async {
    await pumpHost(tester, inlineSurface: true);
    await dropSession(tester);

    expect(find.byType(CastErrorView), findsOneWidget);
    // Exactly one rendering of the message: the inline view. A toast stacked
    // on top of an error view that already carries "Try again" would make two.
    expect(find.text(message), findsOneWidget);
  });

  testWidgets(
    'castToastOverlayContext resolves an overlay the navigator context cannot',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: AppRoutes.rootNavigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      // Why the helper exists: the root navigator's own context has no
      // Overlay *ancestor* (the overlay is its descendant), so handing it to
      // AppSnackBar throws instead of showing anything.
      final navigatorContext = AppRoutes.rootNavigatorKey.currentContext!;
      expect(Overlay.maybeOf(navigatorContext, rootOverlay: true), isNull);

      final resolved = castToastOverlayContext();
      expect(resolved, isNotNull);
      expect(Overlay.maybeOf(resolved!, rootOverlay: true), isNotNull);
    },
  );
}
