import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/cast/services/cast_bloc.dart';
import 'package:mallow_wallet/features/cast/widgets/cast_error_view.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';

class _MockCastBloc extends MockBloc<CastEvent, CastState>
    implements CastBloc {}

/// [CastError] used to be a state nothing displayed, which is why a failed
/// cast presented as a permanent hang. These tests pin the two properties that
/// make the state useful: the message reaches the screen, and the retry
/// actually re-enters discovery (the only path back to a session).
void main() {
  late _MockCastBloc bloc;

  setUp(() {
    bloc = _MockCastBloc();
    whenListen(
      bloc,
      const Stream<CastState>.empty(),
      initialState: const CastState.error(message: 'Cast connection lost.'),
    );
  });

  Future<void> pumpView(WidgetTester tester, {VoidCallback? onDismiss}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: BlocProvider<CastBloc>.value(
            value: bloc,
            child: CastErrorView(
              message: 'Cast connection lost.',
              onDismiss: onDismiss,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the failure message rather than a blank surface', (
    tester,
  ) async {
    await pumpView(tester);
    expect(find.text('Cast connection lost.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('Try again re-enters discovery', (tester) async {
    await pumpView(tester);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    // refreshDiscovery is what restarts the scan AND restores the queue the
    // failed session was carrying — a retry that dispatched nothing would
    // leave the user exactly as stuck as before.
    verify(() => bloc.add(const CastEvent.refreshDiscovery())).called(1);
  });

  testWidgets('Dismiss is only offered when the host supplies it', (
    tester,
  ) async {
    await pumpView(tester);
    expect(find.text('Dismiss'), findsNothing);

    var dismissed = false;
    await pumpView(tester, onDismiss: () => dismissed = true);
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(dismissed, isTrue);
  });
}
