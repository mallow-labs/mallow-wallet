import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/notifications/data/notifications_repository.dart';
import 'package:mallow_wallet/features/notifications/services/notifications_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements NotificationsRepository {}

api.NotificationItem _item({required int id, DateTime? acknowledgedAt}) {
  return api.NotificationItem(
    id: id,
    type: api.NotificationType.test,
    data: const {},
    createdAt: DateTime.utc(2026),
    acknowledgedAt: acknowledgedAt,
  );
}

void main() {
  late _MockRepo repo;

  setUp(() {
    repo = _MockRepo();
    // Opening the feed acknowledges it (see 'acknowledges the feed on open').
    when(repo.acknowledgeAll).thenAnswer((_) async {});
  });

  NotificationsBloc buildBloc() => NotificationsBloc(repo);

  group('NotificationsBloc.load', () {
    blocTest<NotificationsBloc, NotificationsState>(
      'emits loading then loaded with the fetched notifications',
      setUp: () {
        when(repo.getNotifications).thenAnswer((_) async => [_item(id: 1)]);
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const NotificationsEvent.load()),
      expect: () => [
        const NotificationsState.loading(),
        isA<NotificationsLoaded>()
            .having((s) => s.notifications.length, 'count', 1)
            .having((s) => s.showPushBanner, 'showPushBanner', false)
            .having((s) => s.isRefreshing, 'isRefreshing', false),
      ],
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'emits error state with stable copy when the repository throws',
      setUp: () {
        when(repo.getNotifications).thenThrow(Exception('boom'));
      },
      build: buildBloc,
      act: (bloc) => bloc.add(const NotificationsEvent.load()),
      // Fixed user-facing copy: the raw exception text ('boom') must never
      // reach the error state — it goes to debugPrint only.
      expect: () => [
        const NotificationsState.loading(),
        isA<NotificationsError>()
            .having((s) => s.message, 'message', 'Failed to load notifications')
            .having((s) => s.message, 'no raw detail', isNot(contains('boom'))),
      ],
    );
  });

  group('NotificationsBloc.load marks the feed read', () {
    test('acknowledges the feed on open, matching the webapp', () async {
      // The webapp fires POST /acknowledge as soon as the list is fetched, so
      // the unread badge clears by looking at notifications. Without this the
      // badge only ever cleared via the explicit "Mark all as read" link.
      when(repo.getNotifications).thenAnswer((_) async => [_item(id: 1)]);
      final bloc = buildBloc()..add(const NotificationsEvent.load());
      await bloc.stream.firstWhere((s) => s is NotificationsLoaded);
      await Future<void>.delayed(Duration.zero);
      verify(repo.acknowledgeAll).called(1);
      await bloc.close();
    });

    test('leaves the displayed rows unread so "new" stays visible', () async {
      // Deliberately unlike markAllRead: the webapp keeps the unread highlight
      // on the list you are currently reading. Greying every row on arrival
      // would erase the only cue for what is new.
      when(repo.getNotifications).thenAnswer((_) async => [_item(id: 1)]);
      final bloc = buildBloc()..add(const NotificationsEvent.load());
      final loaded =
          await bloc.stream.firstWhere((s) => s is NotificationsLoaded)
              as NotificationsLoaded;
      expect(loaded.notifications.single.acknowledgedAt, isNull);
      await bloc.close();
    });

    test('does not acknowledge when every row is already read', () async {
      when(repo.getNotifications).thenAnswer(
        (_) async => [_item(id: 1, acknowledgedAt: DateTime.utc(2026))],
      );
      final bloc = buildBloc()..add(const NotificationsEvent.load());
      await bloc.stream.firstWhere((s) => s is NotificationsLoaded);
      await Future<void>.delayed(Duration.zero);
      verifyNever(repo.acknowledgeAll);
      await bloc.close();
    });

    test('a failed acknowledge still leaves the list loaded', () async {
      // Fire-and-forget: the feed is readable even when marking it read fails.
      when(repo.getNotifications).thenAnswer((_) async => [_item(id: 1)]);
      when(repo.acknowledgeAll).thenThrow(Exception('offline'));
      final bloc = buildBloc()..add(const NotificationsEvent.load());
      final loaded = await bloc.stream.firstWhere(
        (s) => s is NotificationsLoaded,
      );
      await Future<void>.delayed(Duration.zero);
      expect(loaded, isA<NotificationsLoaded>());
      await bloc.close();
    });
  });

  group('NotificationsBloc.refresh', () {
    blocTest<NotificationsBloc, NotificationsState>(
      'flips isRefreshing on then off, preserving the existing push banner flag',
      setUp: () {
        when(repo.getNotifications).thenAnswer((_) async => [_item(id: 2)]);
      },
      build: buildBloc,
      // Seed a loaded state with showPushBanner=true so we can verify it
      // survives the refresh.
      seed: () => NotificationsState.loaded(
        notifications: [_item(id: 1)],
        showPushBanner: true,
      ),
      act: (bloc) => bloc.add(const NotificationsEvent.refresh()),
      expect: () => [
        isA<NotificationsLoaded>()
            .having((s) => s.isRefreshing, 'isRefreshing', true)
            .having((s) => s.showPushBanner, 'showPushBanner', true),
        isA<NotificationsLoaded>()
            .having(
              (s) => s.notifications.single.id,
              'first notification id',
              2,
            )
            .having((s) => s.showPushBanner, 'showPushBanner', true)
            .having((s) => s.isRefreshing, 'isRefreshing', false),
      ],
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'on refresh failure from a loaded state, clears isRefreshing without surfacing an error',
      setUp: () {
        when(repo.getNotifications).thenThrow(Exception('network'));
      },
      build: buildBloc,
      seed: () => NotificationsState.loaded(notifications: [_item(id: 1)]),
      act: (bloc) => bloc.add(const NotificationsEvent.refresh()),
      // A failed pull-to-refresh must not blow away the currently displayed
      // list with an error screen. The spinner just stops.
      expect: () => [
        isA<NotificationsLoaded>().having(
          (s) => s.isRefreshing,
          'isRefreshing',
          true,
        ),
        isA<NotificationsLoaded>()
            .having((s) => s.isRefreshing, 'isRefreshing', false)
            .having((s) => s.notifications.single.id, 'id', 1),
      ],
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'on refresh failure from a non-loaded state, surfaces stable error copy',
      setUp: () {
        when(repo.getNotifications).thenThrow(Exception('network'));
      },
      build: buildBloc,
      // No seed — bloc starts in initial.
      act: (bloc) => bloc.add(const NotificationsEvent.refresh()),
      // Fixed copy only; the interpolated exception text must not leak through.
      expect: () => [
        isA<NotificationsError>()
            .having(
              (s) => s.message,
              'message',
              'Failed to refresh notifications',
            )
            .having(
              (s) => s.message,
              'no raw detail',
              isNot(contains('network')),
            ),
      ],
    );
  });

  group('NotificationsBloc.markAllRead', () {
    blocTest<NotificationsBloc, NotificationsState>(
      'optimistically stamps acknowledgedAt on every unread item',
      setUp: () {
        when(repo.acknowledgeAll).thenAnswer((_) async {});
      },
      build: buildBloc,
      seed: () => NotificationsState.loaded(
        notifications: [
          _item(id: 1),
          _item(id: 2, acknowledgedAt: DateTime.utc(2025)),
          _item(id: 3),
        ],
      ),
      act: (bloc) => bloc.add(const NotificationsEvent.markAllRead()),
      verify: (_) {
        verify(repo.acknowledgeAll).called(1);
      },
      expect: () => [
        isA<NotificationsLoaded>().having(
          (s) => s.notifications.every((n) => n.acknowledgedAt != null),
          'all acknowledged',
          isTrue,
        ),
      ],
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'preserves the original acknowledgedAt timestamp for already-read items',
      setUp: () {
        when(repo.acknowledgeAll).thenAnswer((_) async {});
      },
      build: buildBloc,
      seed: () {
        final earlier = DateTime.utc(2025);
        return NotificationsState.loaded(
          notifications: [_item(id: 2, acknowledgedAt: earlier)],
        );
      },
      act: (bloc) => bloc.add(const NotificationsEvent.markAllRead()),
      // The optimistic update only stamps items whose acknowledgedAt is null.
      // With a single already-acknowledged item, the resulting state equals
      // the seed, so Bloc's distinct filter swallows the emit. Verify two
      // things: no state change, and the acknowledge API still fires.
      expect: () => const <NotificationsState>[],
      verify: (bloc) {
        verify(repo.acknowledgeAll).called(1);
        expect(
          (bloc.state as NotificationsLoaded)
              .notifications
              .single
              .acknowledgedAt,
          DateTime.utc(2025),
        );
      },
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'reverts the optimistic update if acknowledgeAll throws',
      setUp: () {
        when(repo.acknowledgeAll).thenThrow(Exception('500'));
      },
      build: buildBloc,
      seed: () => NotificationsState.loaded(notifications: [_item(id: 1)]),
      act: (bloc) => bloc.add(const NotificationsEvent.markAllRead()),
      expect: () => [
        // Optimistic write
        isA<NotificationsLoaded>().having(
          (s) => s.notifications.single.acknowledgedAt,
          'optimistic ack',
          isNotNull,
        ),
        // Reverted to the pre-event snapshot
        isA<NotificationsLoaded>().having(
          (s) => s.notifications.single.acknowledgedAt,
          'reverted ack',
          isNull,
        ),
      ],
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'does nothing when state is not loaded',
      build: buildBloc,
      // Not seeded — bloc is in initial state.
      act: (bloc) => bloc.add(const NotificationsEvent.markAllRead()),
      verify: (_) {
        verifyNever(repo.acknowledgeAll);
      },
      expect: () => const <NotificationsState>[],
    );
  });

  group('push banner toggles', () {
    blocTest<NotificationsBloc, NotificationsState>(
      'showPushBanner only flips the flag inside a loaded state',
      build: buildBloc,
      seed: () => NotificationsState.loaded(notifications: [_item(id: 1)]),
      act: (bloc) => bloc.add(const NotificationsEvent.showPushBanner()),
      expect: () => [
        isA<NotificationsLoaded>().having(
          (s) => s.showPushBanner,
          'showPushBanner',
          true,
        ),
      ],
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'dismissPushBanner clears the flag inside a loaded state',
      build: buildBloc,
      seed: () => NotificationsState.loaded(
        notifications: [_item(id: 1)],
        showPushBanner: true,
      ),
      act: (bloc) => bloc.add(const NotificationsEvent.dismissPushBanner()),
      expect: () => [
        isA<NotificationsLoaded>().having(
          (s) => s.showPushBanner,
          'showPushBanner',
          false,
        ),
      ],
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'showPushBanner is a no-op when not in a loaded state',
      build: buildBloc,
      act: (bloc) => bloc.add(const NotificationsEvent.showPushBanner()),
      expect: () => const <NotificationsState>[],
    );

    blocTest<NotificationsBloc, NotificationsState>(
      'dismissPushBanner is a no-op when not in a loaded state',
      build: buildBloc,
      act: (bloc) => bloc.add(const NotificationsEvent.dismissPushBanner()),
      expect: () => const <NotificationsState>[],
    );
  });
}
