import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/profile/widgets/profile_bio.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';

/// The webapp header carries Followers **and** Following, both linking into
/// the follow lists on their own tab. Mobile showed Followers + Collectors, so
/// the second number under a user's name meant something different on the two
/// clients and the Following list was unreachable from the profile.
void main() {
  Future<void> pumpBio(
    WidgetTester tester, {
    int followers = 12,
    int following = 34,
    int collectors = 5,
    VoidCallback? onFollowersTap,
    VoidCallback? onFollowingTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: ProfileBio(
            bio: 'a bio',
            followerCount: followers,
            followingCount: following,
            collectorCount: collectors,
            onFollowersTap: onFollowersTap,
            onFollowingTap: onFollowingTap,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('all three counts are shown', (tester) async {
    await pumpBio(tester);

    expect(find.text('12 Followers'), findsOneWidget);
    expect(find.text('34 Following'), findsOneWidget);
    expect(find.text('5 Collectors'), findsOneWidget);
  });

  testWidgets('Followers and Collectors singularise, Following does not', (
    tester,
  ) async {
    // "1 Following" is correct English for the count; "1 Followings" is not.
    await pumpBio(tester, followers: 1, following: 1, collectors: 1);

    expect(find.text('1 Follower'), findsOneWidget);
    expect(find.text('1 Following'), findsOneWidget);
    expect(find.text('1 Collector'), findsOneWidget);
  });

  testWidgets('each follow count opens its own list', (tester) async {
    var followersTaps = 0;
    var followingTaps = 0;
    await pumpBio(
      tester,
      onFollowersTap: () => followersTaps++,
      onFollowingTap: () => followingTaps++,
    );

    await tester.tap(find.text('12 Followers'));
    await tester.tap(find.text('34 Following'));

    // Wiring both to the same handler would make one of the two numbers lie
    // about where it goes.
    expect(followersTaps, 1);
    expect(followingTaps, 1);
  });

  testWidgets('Collectors is not tappable — there is no such list', (
    tester,
  ) async {
    await pumpBio(tester);

    expect(tester.widget<Text>(find.text('5 Collectors')), isNotNull);
    expect(
      find.ancestor(
        of: find.text('5 Collectors'),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
  });
}
