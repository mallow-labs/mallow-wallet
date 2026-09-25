import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/result/result.dart';
import '../data/notifications_repository.dart';

part 'notifications_bloc.freezed.dart';

@freezed
sealed class NotificationsEvent with _$NotificationsEvent {
  /// Load notifications from API.
  const factory NotificationsEvent.load() = NotificationsLoad;

  /// Refresh notifications (pull-to-refresh).
  const factory NotificationsEvent.refresh() = NotificationsRefresh;

  /// Mark all as read (fires acknowledge API call).
  const factory NotificationsEvent.markAllRead() = NotificationsMarkAllRead;

  /// Dismiss the push notification banner.
  const factory NotificationsEvent.dismissPushBanner() =
      NotificationsDismissPushBanner;

  /// Show the push notification banner (called after permission check).
  const factory NotificationsEvent.showPushBanner() =
      NotificationsShowPushBanner;
}

@freezed
sealed class NotificationsState with _$NotificationsState {
  const factory NotificationsState.initial() = NotificationsInitial;
  const factory NotificationsState.loading() = NotificationsLoading;
  const factory NotificationsState.loaded({
    required List<api.NotificationItem> notifications,
    @Default(false) bool showPushBanner,
    @Default(false) bool isRefreshing,
  }) = NotificationsLoaded;
  const factory NotificationsState.error({required String message}) =
      NotificationsError;
}

@injectable
class NotificationsBloc extends Bloc<NotificationsEvent, NotificationsState> {
  NotificationsBloc(this._repository)
    : super(const NotificationsState.initial()) {
    on<NotificationsLoad>(_onLoad);
    on<NotificationsRefresh>(_onRefresh);
    on<NotificationsMarkAllRead>(_onMarkAllRead);
    on<NotificationsDismissPushBanner>(_onDismissPushBanner);
    on<NotificationsShowPushBanner>(_onShowPushBanner);
  }

  final NotificationsRepository _repository;

  Future<void> _onLoad(
    NotificationsLoad event,
    Emitter<NotificationsState> emit,
  ) async {
    emit(const NotificationsState.loading());
    final result = await Result.guard(_repository.getNotifications);
    switch (result) {
      case ResultSuccess(:final value):
        // showPushBanner defaults to false — the screen flips it on after
        // checking notification permissions.
        emit(NotificationsState.loaded(notifications: _displayable(value)));
        // Acknowledge from the RAW list, not the filtered one. An unread row
        // this build cannot render still counts toward the server's unread
        // flag, so acknowledging only what is on screen would strand the
        // drawer's bell dot above a list that looks empty.
        _acknowledgeOnOpen(value);
      case ResultFailure(:final error):
        debugPrint('[NotificationsBloc] Load failed: ${error.message}');
        emit(
          const NotificationsState.error(
            message: 'Failed to load notifications',
          ),
        );
    }
  }

  /// Drop rows this build has no renderer for.
  ///
  /// `NotificationItem.type` decodes an unrecognised wire value to
  /// [api.NotificationType.unknown], which is how a client survives the backend
  /// shipping a new type. Showing those rows means an older build renders a
  /// placeholder that says nothing and links nowhere; hiding them means the
  /// feed only ever contains rows it can actually render.
  ///
  /// The trade-off, deliberately taken: a build that predates a new
  /// notification type shows no trace of it at all, so a new feature is
  /// invisible until the user updates. Acknowledgement is kept on the raw list
  /// so the unread badge still clears (see [_acknowledgeOnOpen]).
  static List<api.NotificationItem> _displayable(
    List<api.NotificationItem> notifications,
  ) => notifications
      .where((n) => n.type != api.NotificationType.unknown)
      .toList();

  /// Mark the feed read as soon as it is opened, matching the webapp: fetching
  /// `/v1/notifications` fires `POST /acknowledge` and invalidates the unread
  /// badge.
  ///
  /// Deliberately does NOT restamp the rows on screen — the webapp keeps the
  /// unread highlight for the list you are currently looking at, and greying
  /// every row the instant it renders would erase the only cue for what is new.
  /// Fire-and-forget: a failed acknowledge must not fail the load, it just
  /// leaves the badge up until the next visit.
  void _acknowledgeOnOpen(List<api.NotificationItem> notifications) {
    if (notifications.every((n) => n.acknowledgedAt != null)) return;
    unawaited(
      Future<void>.sync(_repository.acknowledgeAll).catchError((Object e) {
        debugPrint('[NotificationsBloc] Acknowledge on open failed: $e');
      }),
    );
  }

  Future<void> _onRefresh(
    NotificationsRefresh event,
    Emitter<NotificationsState> emit,
  ) async {
    final current = state;
    if (current is NotificationsLoaded) {
      emit(current.copyWith(isRefreshing: true));
    }
    final result = await Result.guard(_repository.getNotifications);
    switch (result) {
      case ResultSuccess(:final value):
        final showBanner = current is NotificationsLoaded
            ? current.showPushBanner
            : false;
        emit(
          NotificationsState.loaded(
            notifications: _displayable(value),
            showPushBanner: showBanner,
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[NotificationsBloc] Refresh failed: ${error.message}');
        // A failed pull-to-refresh must not blow away the displayed list —
        // just stop the spinner. Only surface an error when there's nothing
        // on screen yet.
        if (current is NotificationsLoaded) {
          emit(current.copyWith(isRefreshing: false));
        } else {
          emit(
            const NotificationsState.error(
              message: 'Failed to refresh notifications',
            ),
          );
        }
    }
  }

  Future<void> _onMarkAllRead(
    NotificationsMarkAllRead event,
    Emitter<NotificationsState> emit,
  ) async {
    final current = state;
    if (current is! NotificationsLoaded) return;

    // Optimistically mark all as read in the UI
    final now = DateTime.now();
    final updated = current.notifications
        .map(
          (n) => n.acknowledgedAt == null ? n.copyWith(acknowledgedAt: now) : n,
        )
        .toList();
    emit(current.copyWith(notifications: updated));

    try {
      await _repository.acknowledgeAll();
    } catch (_) {
      // Revert on error
      emit(current);
    }
  }

  void _onDismissPushBanner(
    NotificationsDismissPushBanner event,
    Emitter<NotificationsState> emit,
  ) {
    final current = state;
    if (current is NotificationsLoaded) {
      emit(current.copyWith(showPushBanner: false));
    }
  }

  void _onShowPushBanner(
    NotificationsShowPushBanner event,
    Emitter<NotificationsState> emit,
  ) {
    final current = state;
    if (current is NotificationsLoaded) {
      emit(current.copyWith(showPushBanner: true));
    }
  }
}
