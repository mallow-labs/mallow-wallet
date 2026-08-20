import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show FollowUser;
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/features/profile/data/user_profile_repository.dart';
import 'package:mallow_wallet/features/profile/services/followers_bloc.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'followers_bloc_test.mocks.dart';

@GenerateMocks([UserProfileRepository, AuthService])
void main() {
  late MockUserProfileRepository mockRepository;
  late MockAuthService mockAuthService;

  const profileAddresses = ['PROFILE_ADDR'];
  const myAddress = 'MY_ADDR';

  FollowUser user(String address, {bool isFollowing = false}) => FollowUser(
    addresses: [address],
    username: address.toLowerCase(),
    isFollowing: isFollowing,
  );

  void stubLists({
    List<FollowUser> followers = const [],
    List<FollowUser> following = const [],
  }) {
    when(mockRepository.getFollowers(any, page: anyNamed('page'))).thenAnswer(
      (_) async => FollowListResult(users: followers, total: followers.length),
    );
    when(mockRepository.getFollowing(any, page: anyNamed('page'))).thenAnswer(
      (_) async => FollowListResult(users: following, total: following.length),
    );
  }

  setUp(() {
    mockRepository = MockUserProfileRepository();
    mockAuthService = MockAuthService();
    when(mockAuthService.currentAddress).thenReturn(myAddress);
  });

  FollowersBloc buildBloc() => FollowersBloc(mockRepository, mockAuthService);

  group('load + All tab merge', () {
    blocTest<FollowersBloc, FollowersState>(
      'All tab is the union of followers and following, deduped by '
      'address so mutuals appear once',
      build: () {
        stubLists(
          followers: [user('A'), user('B')],
          following: [user('B', isFollowing: true), user('C')],
        );
        return buildBloc();
      },
      act: (bloc) =>
          bloc.add(const FollowersEvent.load(addresses: profileAddresses)),
      verify: (bloc) {
        final state = bloc.state as FollowersLoaded;
        final visible = visibleFollowUsers(state);
        expect(visible.map((u) => u.addresses.first), ['A', 'B', 'C']);
        // Per-tab lists stay intact.
        expect(state.followers!.length, 2);
        expect(state.following!.length, 2);
      },
    );
  });

  group('toggleFollow', () {
    blocTest<FollowersBloc, FollowersState>(
      'optimistically marks the user followed in BOTH lists (a mutual '
      'appears in each) and calls the follow endpoint once',
      build: () {
        stubLists(followers: [user('B')], following: [user('B')]);
        when(mockRepository.followUser(any)).thenAnswer((_) async {});
        return buildBloc();
      },
      act: (bloc) async {
        bloc.add(const FollowersEvent.load(addresses: profileAddresses));
        await Future<void>.delayed(Duration.zero);
        bloc.add(FollowersEvent.toggleFollow(user: user('B')));
      },
      verify: (bloc) {
        final state = bloc.state as FollowersLoaded;
        expect(state.followers!.single.isFollowing, isTrue);
        expect(state.following!.single.isFollowing, isTrue);
        verify(mockRepository.followUser('B')).called(1);
      },
    );

    blocTest<FollowersBloc, FollowersState>(
      'reverts the optimistic flag when the API call fails so the UI '
      'never shows a follow that did not happen',
      build: () {
        stubLists(followers: [user('B')]);
        when(mockRepository.followUser(any)).thenThrow(Exception('rate'));
        return buildBloc();
      },
      act: (bloc) async {
        bloc.add(const FollowersEvent.load(addresses: profileAddresses));
        await Future<void>.delayed(Duration.zero);
        bloc.add(FollowersEvent.toggleFollow(user: user('B')));
      },
      verify: (bloc) {
        final state = bloc.state as FollowersLoaded;
        expect(state.followers!.single.isFollowing, isFalse);
      },
    );
  });

  group('followAll', () {
    blocTest<FollowersBloc, FollowersState>(
      'sends ONE bulk request containing only users not already followed, '
      'and never the current user (the backend rejects self-follows)',
      build: () {
        stubLists(
          followers: [
            user('A'),
            user('B', isFollowing: true),
            user(myAddress),
            user('C'),
          ],
        );
        when(mockRepository.followAllUsers(any)).thenAnswer((_) async {});
        return buildBloc();
      },
      act: (bloc) async {
        bloc.add(const FollowersEvent.load(addresses: profileAddresses));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const FollowersEvent.followAll());
      },
      verify: (bloc) {
        verify(mockRepository.followAllUsers(['A', 'C'])).called(1);
        verifyNever(mockRepository.followUser(any));
        final state = bloc.state as FollowersLoaded;
        expect(state.isFollowingAll, isFalse);
        expect(
          state.followers!.where((u) => u.isFollowing).length,
          3, // A, B (already), C — never the current user
        );
      },
    );

    blocTest<FollowersBloc, FollowersState>(
      'reverts every optimistic flag when the bulk call fails',
      build: () {
        stubLists(followers: [user('A'), user('C')]);
        when(
          mockRepository.followAllUsers(any),
        ).thenThrow(Exception('network'));
        return buildBloc();
      },
      act: (bloc) async {
        bloc.add(const FollowersEvent.load(addresses: profileAddresses));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const FollowersEvent.followAll());
      },
      verify: (bloc) {
        final state = bloc.state as FollowersLoaded;
        expect(state.followers!.any((u) => u.isFollowing), isFalse);
        expect(state.isFollowingAll, isFalse);
      },
    );
  });

  group('error handling', () {
    blocTest<FollowersBloc, FollowersState>(
      'emits error state when the initial load fails',
      build: () {
        when(
          mockRepository.getFollowers(any, page: anyNamed('page')),
        ).thenThrow(Exception('network'));
        when(
          mockRepository.getFollowing(any, page: anyNamed('page')),
        ).thenThrow(Exception('network'));
        return buildBloc();
      },
      act: (bloc) =>
          bloc.add(const FollowersEvent.load(addresses: profileAddresses)),
      verify: (bloc) => expect(bloc.state, isA<FollowersError>()),
    );
  });
}
