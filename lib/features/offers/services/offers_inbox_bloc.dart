import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
// OffersInboxItem is imported unprefixed because freezed's generated deep-copy
// code can't reference prefixed types ($OffersInboxItemCopyWith must resolve).
import 'package:mallow_api/mallow_api.dart'
    show AuctionStatus, OffersInboxItem, OffersInboxSort;

import '../../../core/result/result.dart';
import '../../../core/session/session_manager.dart';
import '../data/offers_inbox_repository.dart';

part 'offers_inbox_bloc.freezed.dart';

/// Events for the Offers screen.
@freezed
sealed class OffersInboxEvent with _$OffersInboxEvent {
  /// Initial load (resolves session wallets, fetches page 0).
  const factory OffersInboxEvent.load() = OffersInboxLoad;

  /// Pull-to-refresh / post-action refetch from page 0 (keeps the current
  /// sort and the already-rendered rows until the new page lands).
  const factory OffersInboxEvent.refresh() = OffersInboxRefresh;

  /// Append the next page.
  const factory OffersInboxEvent.loadMore() = OffersInboxLoadMore;

  /// Change sort order (refetches from page 0).
  const factory OffersInboxEvent.setSort({required OffersInboxSort sort}) =
      OffersInboxSetSort;
}

/// States for the Offers screen.
@freezed
sealed class OffersInboxState with _$OffersInboxState {
  const factory OffersInboxState.initial() = OffersInboxInitial;

  /// Loaded — [items] is the flat, recency- (or amount-) ordered feed the
  /// screen groups by artwork. [items] is null only while the very first page
  /// (or a sort change) is in flight.
  const factory OffersInboxState.loaded({
    List<OffersInboxItem>? items,
    @Default(OffersInboxSort.latest) OffersInboxSort sort,
    @Default(false) bool isLoadingMore,
    @Default(false) bool hasMore,

    /// A pull-to-refresh refetch is in flight (rows stay rendered meanwhile).
    /// This flag is what makes the refetch *observable*: without it a refresh
    /// that returns an unchanged page rebuilds an identical state, `Bloc.emit`
    /// drops it as a duplicate, and the screen — which awaits the next
    /// emission to retract the indicator — spins forever.
    @Default(false) bool isRefreshing,

    /// Offers withheld from [items] because they came from blocked accounts.
    /// Surfaced as a disclosure row — never silently dropped.
    @Default(0) int hiddenByBlockCount,
  }) = OffersInboxLoaded;

  /// Initial load failed.
  const factory OffersInboxState.error({required String message}) =
      OffersInboxError;
}

/// BLoC for the Offers screen. Aggregates every session wallet's active
/// offers + bids (received and placed) into one merged, paginated feed.
@injectable
class OffersInboxBloc extends Bloc<OffersInboxEvent, OffersInboxState> {
  OffersInboxBloc(this._repository, this._session)
    : super(const OffersInboxState.initial()) {
    on<OffersInboxLoad>(_onLoad);
    on<OffersInboxRefresh>(_onRefresh);
    on<OffersInboxLoadMore>(_onLoadMore);
    on<OffersInboxSetSort>(_onSetSort);
  }

  /// How far past `endsAt` an auction must be before [_resolveEndedAuctions]
  /// treats it as ended. Absorbs local clock skew — the check runs against the
  /// device clock, and coercing a live auction to complete is the worse error.
  static const _endedClockSkewGrace = Duration(minutes: 3);

  final OffersInboxRepository _repository;
  final SessionManager _session;

  List<OffersInboxItem> _items = [];
  OffersInboxSort _sort = OffersInboxSort.latest;

  /// Next page to fetch; null = exhausted.
  int? _cursor = 0;

  /// Offers the backend withheld because their maker is blocked. Counted
  /// across the whole merged unpaged set, so it comes off the first page and
  /// is not accumulated as further pages land.
  int _hiddenByBlockCount = 0;

  bool get _hasMore => _cursor != null;

  OffersInboxLoaded _buildLoaded() => OffersInboxLoaded(
    items: List.unmodifiable(_items),
    sort: _sort,
    hasMore: _hasMore,
    hiddenByBlockCount: _hiddenByBlockCount,
  );

  Future<void> _fetchFirstPage(Emitter<OffersInboxState> emit) async {
    final result = await Result.guard(() async {
      final owners = _session.apiOwnerAddresses;
      final page = await _repository.getInbox(owners: owners, sort: _sort);
      _items = _resolveEndedAuctions(page.result);
      _cursor = page.nextPage;
      _hiddenByBlockCount = page.hiddenByBlockCount;
    });

    if (result.isFailure) {
      emit(
        OffersInboxState.error(
          message: result.errorOrNull?.message ?? 'Failed to load offers',
        ),
      );
      return;
    }
    emit(_buildLoaded());
  }

  /// Re-derive auction liveness from `endsAt` instead of trusting the
  /// server-sent `status`. The indexer DELETES an auction's row the instant it
  /// settles or is cancelled (there is no `settled` column), so a row that
  /// still exists with `endsAt <= now` is *ended but unsettled* — it must not
  /// render as live/bid-able, since tapping bid builds a doomed transaction.
  /// The backend derives `status` from its own clock, so skew or a cached page
  /// can hand us a past-`endsAt` row still tagged `live`; this guard closes
  /// that gap client-side.
  ///
  /// The comparison uses the *device* clock, which can run minutes fast, so it
  /// only fires once `endsAt` is [_endedClockSkewGrace] in the past — otherwise
  /// a skewed clock mislabels a genuinely live auction during its closing
  /// window (premature "complete" card, win/claim chips on an unfinished sale).
  List<OffersInboxItem> _resolveEndedAuctions(List<OffersInboxItem> items) {
    final cutoff = DateTime.now().subtract(_endedClockSkewGrace);
    return items.map((item) {
      final auction = item.auction;
      final endsAt = auction?.endTime;
      if (auction == null || endsAt == null || endsAt.isAfter(cutoff)) {
        return item;
      }
      return item.copyWith(
        auction: auction.copyWith(status: AuctionStatus.complete),
      );
    }).toList();
  }

  Future<void> _onLoad(OffersInboxLoad event, Emitter<OffersInboxState> emit) {
    return _fetchFirstPage(emit);
  }

  Future<void> _onRefresh(
    OffersInboxRefresh event,
    Emitter<OffersInboxState> emit,
  ) async {
    // Keep the existing rows visible (no spinner flash) while refetching, but
    // mark the state as refreshing so the terminal emission always differs
    // from this one — see [OffersInboxLoaded.isRefreshing].
    final current = state;
    if (current is OffersInboxLoaded) {
      emit(current.copyWith(isRefreshing: true));
    }
    await _fetchFirstPage(emit);
  }

  Future<void> _onSetSort(
    OffersInboxSetSort event,
    Emitter<OffersInboxState> emit,
  ) async {
    if (event.sort == _sort) return;
    _sort = event.sort;
    _items = [];
    _cursor = 0;
    // Clear rows (items defaults to null) so the screen shows the first-page
    // spinner under the new sort.
    emit(OffersInboxLoaded(sort: _sort));
    await _fetchFirstPage(emit);
  }

  Future<void> _onLoadMore(
    OffersInboxLoadMore event,
    Emitter<OffersInboxState> emit,
  ) async {
    final current = state;
    if (current is! OffersInboxLoaded || current.isLoadingMore) return;
    final page = _cursor;
    if (page == null) return;

    emit(current.copyWith(isLoadingMore: true));

    final result = await Result.guard(() async {
      final owners = _session.apiOwnerAddresses;
      final next = await _repository.getInbox(
        owners: owners,
        sort: _sort,
        page: page,
      );
      _items = [..._items, ..._resolveEndedAuctions(next.result)];
      _cursor = next.nextPage;
    });

    if (result.isFailure) {
      debugPrint(
        '[OffersInboxBloc] loadMore failed: ${result.errorOrNull?.message}',
      );
      emit(current.copyWith(isLoadingMore: false));
      return;
    }
    emit(_buildLoaded());
  }
}
