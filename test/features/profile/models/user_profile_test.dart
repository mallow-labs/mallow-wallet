import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/profile/models/user_profile.dart';

void main() {
  group('UserProfile', () {
    UserProfile sample({int created = 7, int collected = 12}) => UserProfile(
      address: 'addr1',
      username: 'alice',
      handle: 'alice',
      role: 'Artist',
      bio: 'a bio',
      avatarUrl: 'https://img/a.png',
      followerCount: 100,
      followingCount: 42,
      collectorCount: 5,
      ownedArtworkCount: 3,
      createdArtworkCount: created,
      collectedArtworkCount: collected,
    );

    test('toJson/fromJson preserves the new count fields', () {
      final original = sample();
      final restored = UserProfile.fromJson(original.toJson());

      expect(restored.createdArtworkCount, 7);
      expect(restored.collectedArtworkCount, 12);
    });

    test(
      'fromJson defaults the new count fields to 0 when keys are missing',
      () {
        final legacyJson = sample().toJson()
          ..remove('createdArtworkCount')
          ..remove('collectedArtworkCount');

        final restored = UserProfile.fromJson(legacyJson);

        expect(restored.createdArtworkCount, 0);
        expect(restored.collectedArtworkCount, 0);
      },
    );

    test('followingCount survives a cache round-trip', () {
      // The profile header renders Followers *and* Following; dropping the
      // second number on the cached path would make a cache hit read
      // differently from a fresh fetch.
      expect(UserProfile.fromJson(sample().toJson()).followingCount, 42);
    });

    test('withFollowerDelta moves the count the header is showing', () {
      expect(sample().withFollowerDelta(1).followerCount, 101);
      expect(sample().withFollowerDelta(-1).followerCount, 99);
    });

    test('withFollowerDelta never renders a negative follower count', () {
      // An unfollow raced against a stale count of 0 must not produce "-1
      // Followers" while the request is in flight.
      final zero = UserProfile.fromJson(
        sample().toJson()..['followerCount'] = 0,
      );
      expect(zero.withFollowerDelta(-1).followerCount, 0);
    });

    test('withFollowerDelta carries every other field through', () {
      final shifted = sample().withFollowerDelta(1);
      expect(shifted.toJson(), {...sample().toJson(), 'followerCount': 101});
    });
  });
}
