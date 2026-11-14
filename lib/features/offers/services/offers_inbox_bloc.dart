import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
// OffersInboxItem is imported unprefixed because freezed's generated deep-copy
// code can't reference prefixed types ($OffersInboxItemCopyWith must resolve).
import 'package:mallow_api/mallow_api.dart'
    show AuctionStatus, OffersInboxDirection, OffersInboxItem, OffersInboxSort;

import '../../../core/result/result.dart';
import '../../../core/session/session_manager.dart';
import '../../../shared/utils/chain.dart';
import '../../moderation/services/moderation_filter.dart';
import '../data/offers_inbox_repository.dart';
import '../models/bid_refund_balance.dart';

part 'offers_inbox_bloc.freezed.dart';

/// Events for the Offers screen.
@freezed
sealed class OffersInboxEvent with _$OffersInboxEvent {
  /// Initial load (resolves session wallets, fetches page 0).
  const factory OffersInboxEvent.load() = OffersInboxLoad;

  /// Pull-to-refresh / post-action refetch from page 0 (keeps the current
  /// sort and the already-rendered rows until the new page lands).
  const factory OffersInboxEvent.refresh({@Default(true) bool refreshRefunds}) =
      OffersInboxRefresh;

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
  /// screen groups by artwork. [items] is null while the very first page
  /// is in flight.
  const factory OffersInboxState.loaded({
    List<OffersInboxItem>? items,
    @Default([]) List<BidRefundBalance> bidRefunds,
    String? bidRefundError,
    String? inboxError,
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
  OffersInboxBloc(
    this._repository,
    this._session, {
    // Tests pass a filter over fake stores. Kept out of the generated
    // construction, which uses the app's.
    @ignoreParam ModerationFilter Function()? moderation,
  }) : _moderation = moderation ?? ModerationFilter.current,
       super(const OffersInboxState.initial()) {
    on<OffersInboxLoad>(_onLoad);
    on<OffersInboxRefresh>(_onRefresh);
    on<OffersInboxLoadMore>(_onLoadMore);
    on<OffersInboxSetSort>(_onSetSort);

    // A block made while the inbox is on screen (from a bidder's profile,
    // pushed on top of it) withholds that account's rows.
    _moderationChanges = _moderation().changes..addListener(_onBlocksChanged);
  }

  final ModerationFilter Function() _moderation;
  late final Listenable _moderationChanges;

  /// Refetches the inbox when a row on screen is from an account the viewer
  /// has just blocked. The refetch runs through [_withholdBlocked] and brings
  /// back the backend's own count, so the disclosure row is right as well.
  /// The rows stay up until it lands, as on any refresh.
  void _onBlocksChanged() {
    if (isClosed || state is! OffersInboxLoaded) return;
    final moderation = _moderation();
    final affected = _items.any(
      (item) =>
          item.direction == OffersInboxDirection.received &&
          moderation.blocksAddress(item.actorAddress),
    );
    if (affected) add(const OffersInboxEvent.refresh(refreshRefunds: false));
  }

  @override
  Future<void> close() {
    _moderationChanges.removeListener(_onBlocksChanged);
    return super.close();
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

  /// Rows this bloc withheld itself ([_withholdBlocked]), across the pages
  /// loaded so far. Added to the backend's count for the disclosure row.
  int _withheldHere = 0;
  List<BidRefundBalance> _bidRefunds = [];
  String? _bidRefundError;
  String? _inboxError;
  int _firstPageGeneration = 0;
  int _refundGeneration = 0;

  bool get _hasMore => _cursor != null;

  OffersInboxLoaded _buildLoaded() => OffersInboxLoaded(
    items: List.unmodifiable(_items),
    bidRefunds: List.unmodifiable(_bidRefunds),
    bidRefundError: _bidRefundError,
    inboxError: _inboxError,
    sort: _sort,
    hasMore: _hasMore,
    hiddenByBlockCount: _hiddenByBlockCount + _withheldHere,
  );

  /// Drops received rows whose counterparty the viewer blocked, counting them
  /// into [_withheldHere] so the disclosure row still owns up to them.
  ///
  /// The backend does the same when the session has proven its wallet. A
  /// hardware or Seed Vault session often has not, so this applies the block
  /// list the device holds to whatever arrives.
  ///
  /// Same rule as the backend: the counterparty of a received row only. On a
  /// placed row the actor is the viewer's own wallet, and their own offers
  /// and bids are never withheld. A report alone withholds nothing here.
  List<OffersInboxItem> _withholdBlocked(List<OffersInboxItem> items) {
    final moderation = _moderation();
    final kept = [
      for (final item in items)
        if (item.direction != OffersInboxDirection.received ||
            !moderation.blocksAddress(item.actorAddress))
          item,
    ];
    _withheldHere += items.length - kept.length;
    return kept;
  }

  OffersInboxState _settledState() => _inboxError != null && _bidRefunds.isEmpty
      ? OffersInboxState.error(message: _inboxError!)
      : _buildLoaded();

  Future<void> _fetchBidRefunds(
    Emitter<OffersInboxState> emit,
    int generation,
  ) async {
    final refunds = await Result.guard(
      () => _repository.getBidRefunds(
        _session.sessionWallets
            .where((wallet) => wallet.chainEnum == Chain.solana)
            .map((wallet) => wallet.address),
      ),
    );
    if (generation != _refundGeneration || emit.isDone) return;
    // Keep a known claim reachable through a temporary read failure.
    _bidRefunds = refunds.valueOrNull ?? _bidRefunds;
    _bidRefundError = refunds.errorOrNull?.message;
    final current = state;
    if (_inboxError != null) {
      emit(_settledState());
    } else if (current is OffersInboxLoaded) {
      emit(
        current.copyWith(
          bidRefunds: List.unmodifiable(_bidRefunds),
          bidRefundError: _bidRefundError,
        ),
      );
    }
  }

  Future<void> _fetchFirstPage(
    Emitter<OffersInboxState> emit, {
    bool refreshRefunds = true,
  }) async {
    final generation = ++_firstPageGeneration;
    final sort = _sort;
    _inboxError = null;
    // Refunds are independent of feed ordering. Start both reads together and
    // render the inbox as soon as it lands, even if a refund scan is slow.
    final refunds = refreshRefunds
        ? _fetchBidRefunds(emit, ++_refundGeneration)
        : Future<void>.value();
    final inbox = () async {
      final result = await Result.guard(
        () => _repository.getInbox(
          owners: _session.apiOwnerAddresses,
          sort: sort,
        ),
      );
      if (generation != _firstPageGeneration || emit.isDone) return;
      final page = result.valueOrNull;
      if (page == null) {
        _items = [];
        _cursor = null;
        _hiddenByBlockCount = 0;
        _withheldHere = 0;
        _inboxError = result.errorOrNull?.message ?? 'Failed to load offers';
      } else {
        _withheldHere = 0;
        _items = _withholdBlocked(_resolveEndedAuctions(page.result));
        _cursor = page.nextPage;
        _hiddenByBlockCount = page.hiddenByBlockCount;
      }
      emit(_settledState());
    }();
    await Future.wait([inbox, refunds]);
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
    await _fetchFirstPage(emit, refreshRefunds: event.refreshRefunds);
  }

  Future<void> _onSetSort(
    OffersInboxSetSort event,
    Emitter<OffersInboxState> emit,
  ) async {
    if (event.sort == _sort) return;
    _sort = event.sort;
    // Keep refund cards mounted so their destination fields survive sorting.
    emit(_buildLoaded().copyWith(isRefreshing: true));
    await _fetchFirstPage(emit, refreshRefunds: false);
  }

  Future<void> _onLoadMore(
    OffersInboxLoadMore event,
    Emitter<OffersInboxState> emit,
  ) async {
    final current = state;
    if (current is! OffersInboxLoaded || current.isLoadingMore) return;
    final page = _cursor;
    if (page == null || current.isRefreshing || _inboxError != null) return;
    final generation = _firstPageGeneration;

    emit(current.copyWith(isLoadingMore: true));

    final result = await Result.guard(() async {
      final owners = _session.apiOwnerAddresses;
      final next = await _repository.getInbox(
        owners: owners,
        sort: _sort,
        page: page,
      );
      if (generation != _firstPageGeneration) return;
      _items = [
        ..._items,
        ..._withholdBlocked(_resolveEndedAuctions(next.result)),
      ];
      _cursor = next.nextPage;
    });

    if (generation != _firstPageGeneration || emit.isDone) return;
    if (result.isFailure) {
      debugPrint(
        '[OffersInboxBloc] loadMore failed: ${result.errorOrNull?.message}',
      );
      final now = state;
      if (now is OffersInboxLoaded) {
        emit(now.copyWith(isLoadingMore: false));
      }
      return;
    }
    emit(_buildLoaded());
  }
}
