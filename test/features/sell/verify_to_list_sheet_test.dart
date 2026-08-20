import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/sell/services/listing_eligibility.dart';
import 'package:mallow_wallet/features/sell/widgets/verify_to_list_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// Each block reason has to land the user on the one thing that can actually
/// unblock them — the application form when they are not a vetted creator, the
/// profile editor when their profile is incomplete, and nothing at all when the
/// block is a moderation flag (a CTA there would promise a self-service fix
/// that does not exist). The copy is the webapp's verbatim, so a flagged
/// creator reading it on mobile is told the same thing as on the web
/// (`VerifyToList`).
void main() {
  Future<void> pumpSheet(WidgetTester tester, ListingBlockReason reason) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(body: VerifyToListSheet(reason: reason)),
      ),
    );
    await tester.pump();
  }

  testWidgets('every branch keeps the webapp headline', (tester) async {
    for (final reason in ListingBlockReason.values) {
      await pumpSheet(tester, reason);
      expect(find.text('Verify to list'), findsOneWidget);
      expect(find.text('Sorry, this item cannot be listed.'), findsOneWidget);
    }
  });

  testWidgets('a flagged artwork explains itself and offers no CTA', (
    tester,
  ) async {
    await pumpSheet(tester, ListingBlockReason.flagged);
    expect(
      find.text(
        'The creator of this artwork has been flagged for suspicious activity. '
        'Please let us know in our discord if you think a mistake has been made.',
      ),
      findsOneWidget,
    );
    expect(find.text('Open application form'), findsNothing);
    expect(find.text('Edit profile'), findsNothing);
  });

  testWidgets('an unvetted creator is pointed at the application form', (
    tester,
  ) async {
    await pumpSheet(tester, ListingBlockReason.notApprovedCreator);
    expect(
      find.text(
        'There is an application process to go through before you can list '
        'primary sales - please fill out the form below.',
      ),
      findsOneWidget,
    );
    expect(find.text('Open application form'), findsOneWidget);
    expect(find.text('Edit profile'), findsNothing);
  });

  testWidgets('an incomplete profile is pointed at the profile editor', (
    tester,
  ) async {
    await pumpSheet(tester, ListingBlockReason.incompleteProfile);
    expect(
      find.text(
        'Please complete your profile with a username, profile picture, and '
        'twitter account.',
      ),
      findsOneWidget,
    );
    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Open application form'), findsNothing);
  });

  testWidgets('the twitter-only branch asks for twitter and offers no CTA', (
    tester,
  ) async {
    await pumpSheet(tester, ListingBlockReason.twitterNotVerified);
    expect(
      find.text(
        'Please connect a twitter account to your profile before listing '
        'primary sales.',
      ),
      findsOneWidget,
    );
    expect(find.text('Open application form'), findsNothing);
    expect(find.text('Edit profile'), findsNothing);
  });

  testWidgets('the edit-profile CTA hands the navigation back to the caller', (
    tester,
  ) async {
    // The chooser behind the sheet still has to unwind itself; if the sheet
    // pushed the editor directly that unwind would pop the editor straight
    // back off. So the sheet only reports the choice.
    VerifyToListAction? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showVerifyToListSheet(
                    context,
                    ListingBlockReason.incompleteProfile,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    // `showMallowSheet` arms a 100ms settle barrier that swallows taps landing
    // as the sheet arrives (mallow_sheet.dart), and it schedules no frames —
    // pump past it or the tap below is silently eaten.
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
    expect(result, VerifyToListAction.editProfile);
  });
}
