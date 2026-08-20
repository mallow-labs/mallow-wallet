import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
// FollowUser is imported unprefixed because freezed's generated deep-copy
// code can't reference prefixed types ($FollowUserCopyWith must resolve).
import 'package:mallow_api/mallow_api.dart'
    show FollowUser, $FollowUserCopyWith;

import '../../../core/network/auth_service.dart';
import '../../../core/result/result.dart';
import '../data/user_profile_repository.dart';

part 'followers_bloc.freezed.dart';

/// Active tab on the followers screen.
enum FollowersTab { all, followers, following }

/// Events for the followers screen.
@freezed
sealed class FollowersEvent with _$FollowersEvent {
  /// Load followers + following for a profile's linked addresses.
  const factory FollowersEvent.load({required List<String> addresses}) =
      FollowersLoad;

  /// Switch active tab.
  const factory FollowersEvent.changeTab({required FollowersTab tab}) =
      FollowersChangeTab;

  /// Toggle Latest <-> Oldest ordering (reloads both lists).
  const factory FollowersEvent.toggleSort() = FollowersToggleSort;

  /// Load the next page for the active tab.
  const factory FollowersEvent.loadMore() = FollowersLoadMore;

  /// Follow/unfollow a single listed user.
  const factory FollowersEvent.toggleFollow({required FollowUser user}) =
      FollowersToggleFollow;

  /// Follow every loaded user on the active tab not yet followed.
  const factory FollowersEvent.followAll() = FollowersFollowAll;
}

/// States for the followers screen.
@freezed
sealed class FollowersState with _$FollowersState {
  /// Initial state before loading.
  const factory FollowersState.initial() = FollowersInitial;

  /// Loaded (lists are `null` while their first page is in flight).
  const factory FollowersState.loaded({
    List<FollowUser>? followers,
    List<FollowUser>? following,
    @Default(FollowersTab.all) FollowersTab activeTab,
    @Default(true) bool latestFirst,
    @Default(false) bool isLoadingMore,
    @Default(false) bool isFollowingAll,
    @Default(false) bool hasMore,
  }) = FollowersLoaded;

  /// Error state (initial load failed).
  const factory FollowersState.error({required String message}) =
      FollowersError;
}

/// Users visible on a given tab. The All tab is the union of followers and
/// following, deduped by primary address (followers first, matching load
/// order).
List<FollowUser> visibleFollowUsers(FollowersLoaded state) {
  switch (state.activeTab) {
    case FollowersTab.followers:
      return state.followers ?? const [];
    case FollowersTab.following:
      return state.following ?? const [];
    case FollowersTab.all:
      final followers = state.followers ?? const <FollowUser>[];
      final following = state.following ?? const <FollowUser>[];
      final seen = followers
          .map((u) => u.addresses.firstOrNull)
          .whereType<String>()
          .toSet();
      return [
        ...followers,
        ...following.where((u) => !seen.contains(u.addresses.firstOrNull)),
      ];
  }
}

/// BLoC for the followers screen.
@injectable
class FollowersBloc extends Bloc<FollowersEvent, FollowersState> {
  FollowersBloc(this._repository, this._authService)
    : super(const FollowersState.initial()) {
    on<FollowersLoad>(_onLoad);
    on<FollowersChangeTab>(_onChangeTab);
    on<FollowersToggleSort>(_onToggleSort);
    on<FollowersLoadMore>(_onLoadMore);
    on<FollowersToggleFollow>(_onToggleFollow);
    on<FollowersFollowAll>(_onFollowAll);
  }

  final UserProfileRepository _repository;
  final AuthService _authService;

  /// Backend page size for /v1/followers and /v1/following (mirrors the
  /// webapp). Needed to locate the last page for oldest-first ordering.
  static const _pageSize = 50;

  List<String> _addresses = [];
  List<FollowUser> _followers = [];
  List<FollowUser> _following = [];
  int _followersTotal = 0;
  int _followingTotal = 0;

  /// Next page index to fetch per list; `null` = exhausted. When sorting
  /// oldest-first pages are walked backwards from the last page (the API
  /// only serves newest-first), with each page's items reversed.
  int? _followersCursor = 0;
  int? _followingCursor = 0;
  bool _latestFirst = true;

  bool get _hasMore => _followersCursor != null || _followingCursor != null;

  bool _isSelf(FollowUser user) {
    final current = _authService.currentAddress;
    return current != null && user.addresses.contains(current);
  }

  FollowersLoaded _buildLoaded({FollowersLoaded? from}) {
    return (from ?? const FollowersLoaded()).copyWith(
      followers: List.unmodifiable(_followers),
      following: List.unmodifiable(_following),
      latestFirst: _latestFirst,
      hasMore: _hasMore,
      isLoadingMore: false,
    );
  }

  Future<void> _onLoad(
    FollowersLoad event,
    Emitter<FollowersState> emit,
  ) async {
    _addresses = event.addresses;
    final result = await Result.guard(() async {
      final pages = await Future.wait([
        _repository.getFollowers(_addresses),
        _repository.getFollowing(_addresses),
      ]);
      final followersPage = pages[0];
      final followingPage = pages[1];
      _followers = followersPage.users;
      _following = followingPage.users;
      _followersTotal = followersPage.total;
      _followingTotal = followingPage.total;
      _followersCursor = followersPage.nextPage;
      _followingCursor = followingPage.nextPage;
    });

    if (result.isFailure) {
      emit(
        FollowersState.error(
          message: result.errorOrNull?.message ?? 'Failed to load followers',
        ),
      );
      return;
    }
    emit(_buildLoaded());
  }

  void _onChangeTab(FollowersChangeTab event, Emitter<FollowersState> emit) {
    final current = state;
    if (current is! FollowersLoaded) return;
    emit(current.copyWith(activeTab: event.tab));
  }

  /// Fetch the next window for one list, honoring the sort direction.
  Future<int?> _fetchInto({required bool intoFollowers}) async {
    final cursor = intoFollowers ? _followersCursor : _followingCursor;
    if (cursor == null) return null;

    final page = intoFollowers
        ? await _repository.getFollowers(_addresses, page: cursor)
        : await _repository.getFollowing(_addresses, page: cursor);

    final users = _latestFirst ? page.users : page.users.reversed.toList();
    if (intoFollowers) {
      _followers = [..._followers, ...users];
      _followersTotal = page.total;
    } else {
      _following = [..._following, ...users];
      _followingTotal = page.total;
    }
    return _latestFirst ? page.nextPage : (cursor > 0 ? cursor - 1 : null);
  }

  Future<void> _onToggleSort(
    FollowersToggleSort event,
    Emitter<FollowersState> emit,
  ) async {
    final current = state;
    if (current is! FollowersLoaded || current.isLoadingMore) return;

    _latestFirst = !_latestFirst;
    _followers = [];
    _following = [];
    // Latest starts at page 0; oldest starts at the last page (totals are
    // known from the previous load) and walks backwards.
    int? startCursor(int total) =>
        _latestFirst ? 0 : (total == 0 ? null : (total - 1) ~/ _pageSize);
    _followersCursor = startCursor(_followersTotal);
    _followingCursor = startCursor(_followingTotal);

    emit(
      current.copyWith(
        followers: null,
        following: null,
        latestFirst: _latestFirst,
        isLoadingMore: false,
        hasMore: false,
      ),
    );

    final result = await Result.guard(() async {
      await Future.wait([
        () async {
          _followersCursor = await _fetchInto(intoFollowers: true);
        }(),
        () async {
          _followingCursor = await _fetchInto(intoFollowers: false);
        }(),
      ]);
    });

    if (result.isFailure) {
      emit(
        FollowersState.error(
          message: result.errorOrNull?.message ?? 'Failed to load followers',
        ),
      );
      return;
    }
    emit(_buildLoaded(from: current));
  }

  Future<void> _onLoadMore(
    FollowersLoadMore event,
    Emitter<FollowersState> emit,
  ) async {
    final current = state;
    if (current is! FollowersLoaded || current.isLoadingMore) return;
    if (!_hasMore) return;

    // Advance only the list(s) the active tab renders.
    final wantFollowers =
        current.activeTab != FollowersTab.following && _followersCursor != null;
    final wantFollowing =
        current.activeTab != FollowersTab.followers && _followingCursor != null;
    if (!wantFollowers && !wantFollowing) return;

    emit(current.copyWith(isLoadingMore: true));

    final result = await Result.guard(() async {
      await Future.wait([
        if (wantFollowers)
          () async {
            _followersCursor = await _fetchInto(intoFollowers: true);
          }(),
        if (wantFollowing)
          () async {
            _followingCursor = await _fetchInto(intoFollowers: false);
          }(),
      ]);
    });

    if (result.isFailure) {
      debugPrint(
        '[FollowersBloc] loadMore failed: ${result.errorOrNull?.message}',
      );
      emit(current.copyWith(isLoadingMore: false));
      return;
    }
    emit(_buildLoaded(from: current));
  }

  /// Rewrite [user]'s follow flag in both lists (a user can appear in each).
  void _setFollowing(FollowUser user, bool isFollowing) {
    final key = user.addresses.firstOrNull;
    List<FollowUser> update(List<FollowUser> list) => [
      for (final u in list)
        if (u.addresses.firstOrNull == key)
          u.copyWith(isFollowing: isFollowing)
        else
          u,
    ];
    _followers = update(_followers);
    _following = update(_following);
  }

  Future<void> _onToggleFollow(
    FollowersToggleFollow event,
    Emitter<FollowersState> emit,
  ) async {
    final current = state;
    if (current is! FollowersLoaded) return;
    final address = event.user.addresses.firstOrNull;
    if (address == null || _isSelf(event.user)) return;

    final wasFollowing = event.user.isFollowing;

    // Optimistic update, revert on failure.
    _setFollowing(event.user, !wasFollowing);
    emit(_buildLoaded(from: current));

    final result = await Result.guard(() async {
      if (wasFollowing) {
        await _repository.unfollowUser(address);
      } else {
        await _repository.followUser(address);
      }
    });

    if (result.isFailure) {
      debugPrint(
        '[FollowersBloc] Follow toggle failed, reverting: '
        '${result.errorOrNull?.message}',
      );
      _setFollowing(event.user, wasFollowing);
      final latest = state;
      emit(_buildLoaded(from: latest is FollowersLoaded ? latest : current));
    }
  }

  Future<void> _onFollowAll(
    FollowersFollowAll event,
    Emitter<FollowersState> emit,
  ) async {
    final current = state;
    if (current is! FollowersLoaded || current.isFollowingAll) return;

    final targets = visibleFollowUsers(
      current,
    ).where((u) => !u.isFollowing && !_isSelf(u)).toList();
    final addresses = targets
        .map((u) => u.addresses.firstOrNull)
        .whereType<String>()
        .toList();
    if (addresses.isEmpty) return;

    // Optimistic update, revert all on failure (the bulk endpoint is
    // idempotent per target, so a retry is safe).
    for (final user in targets) {
      _setFollowing(user, true);
    }
    emit(_buildLoaded(from: current).copyWith(isFollowingAll: true));

    final result = await Result.guard(
      () => _repository.followAllUsers(addresses),
    );

    if (result.isFailure) {
      debugPrint(
        '[FollowersBloc] Follow all failed, reverting: '
        '${result.errorOrNull?.message}',
      );
      for (final user in targets) {
        _setFollowing(user, false);
      }
    }

    final latest = state;
    emit(
      _buildLoaded(
        from: latest is FollowersLoaded ? latest : current,
      ).copyWith(isFollowingAll: false),
    );
  }
}
