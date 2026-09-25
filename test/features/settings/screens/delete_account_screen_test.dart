import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/settings/screens/delete_account_screen.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends Mock implements AuthService {}

// The Delete profile row is always shown (App Store 5.1.1(v) discoverability),
// so the screen owns every state the row can open into. The load-bearing one:
// every `/v0/login` upserts a `users` document for the signed-in address, so a
// signed-in user with no username still has a server record — addresses,
// sign-in history, push registrations — and the delete must run for real. The
// screen once told those users there was "nothing to delete on our servers",
// which is the 5.1.1(v) gap this suite guards.

void main() {
  late _MockAuth auth;

  setUp(() {
    auth = _MockAuth();
    if (sl.isRegistered<AuthService>()) sl.unregister<AuthService>();
    sl.registerSingleton<AuthService>(auth);
  });
  tearDown(() => sl.unregister<AuthService>());

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: DeleteAccountScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('signed in with a username names the profile it deletes', (
    tester,
  ) async {
    when(() => auth.currentUser).thenReturn(const api.User(username: 'ada'));

    await pumpScreen(tester);

    expect(find.text('Delete @ada'), findsOneWidget);
    expect(find.widgetWithText(MallowButton, 'Delete profile'), findsOneWidget);
  });

  // A missing username is not a missing record, so this is the same real
  // delete — only the heading changes.
  testWidgets('signed in without a username still offers the real delete', (
    tester,
  ) async {
    when(() => auth.currentUser).thenReturn(const api.User());

    await pumpScreen(tester);

    expect(find.text('Delete your mallow profile'), findsOneWidget);
    expect(find.widgetWithText(MallowButton, 'Delete profile'), findsOneWidget);
    // The itemised copy is what tells the user what a delete costs; it must
    // not be dropped just because there is no username to print. "What stays"
    // sits below the fold in the test viewport, so scroll to it.
    expect(find.text('What gets removed'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('What stays'), 200);
    expect(find.text('What stays'), findsOneWidget);
    // The old, false variant.
    expect(find.text('No mallow profile to delete'), findsNothing);
    expect(
      find.textContaining('nothing to delete on our servers'),
      findsNothing,
    );
    expect(find.widgetWithText(MallowButton, 'Reset app'), findsNothing);
  });

  // Signed out there is no `login-token`, so the call would 401 and leave the
  // profile in place. Ask for a sign-in rather than offering a delete that
  // cannot run — and never claim the server holds nothing.
  testWidgets('signed out asks for a sign-in instead of deleting', (
    tester,
  ) async {
    when(() => auth.currentUser).thenReturn(null);

    await pumpScreen(tester);

    expect(find.text('Sign in to delete your profile'), findsOneWidget);
    expect(find.widgetWithText(MallowButton, 'Delete profile'), findsNothing);
    expect(find.textContaining('nothing to delete'), findsNothing);
    // Reset app wipes the wallets and touches no server record: it is never
    // presented as the way to delete the profile.
    expect(find.widgetWithText(MallowButton, 'Reset app'), findsNothing);
    expect(find.byType(MallowButton), findsNothing);
  });
}
