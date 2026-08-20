import 'package:flutter/widgets.dart';

import '../../core/observability/app_logger.dart';
import '../widgets/app_snack_bar.dart';
import 'pagination_bloc.dart';

const String _tag = 'DrainPages';

/// Hard stop on the walk. 200 pages is ~4,000 artworks at the usual page size —
/// far past any real group, and low enough that a feed whose `hasMore` never
/// goes false cannot spin forever.
const int _maxPages = 200;

/// Walks [fetchPage] from page 0 to the end of the feed and returns every item.
///
/// List screens hold only the pages the user has scrolled past — a
/// [PaginationBloc]'s `state.items` is a *prefix*, not the collection. Any bulk
/// action that means "all of them" (download, export) must walk the feed
/// itself; reading `state.items` silently operates on the first page or two and
/// reports success, which is indistinguishable from having done the whole job.
///
/// Pages are fetched sequentially: the caller is about to download every item
/// anyway, and firing N page requests at once to save a second of latency is
/// not a trade worth making. [shouldStop] is polled between pages so a user
/// cancelling the batch doesn't have to wait out the rest of the walk.
Future<List<T>> drainPages<T>(
  Future<PaginatedPage<T>> Function(int page) fetchPage, {
  bool Function()? shouldStop,
}) async {
  final all = <T>[];
  for (var page = 0; page < _maxPages; page++) {
    if (shouldStop?.call() ?? false) return all;
    final result = await fetchPage(page);
    all.addAll(result.items);
    if (!result.hasMore) return all;
  }
  // Never silently truncate: an incomplete list that looks complete is the
  // exact failure this function exists to fix.
  AppLogger.warn(
    _tag,
    'stopped at the $_maxPages-page cap with more pages still claimed — '
    '${all.length} items collected',
  );
  return all;
}

/// [drainPages] behind a "Preparing…" snackbar — the shape a bulk action on a
/// paged screen needs when it has no progress sheet of its own.
///
/// Returns `null` when the walk failed or the screen went away, in which case
/// the caller must do nothing at all: acting on a partial list is what this
/// whole mechanism exists to prevent. A failure is reported rather than
/// silently degraded to a short list.
Future<List<T>?> drainPagesWhilePreparing<T>(
  BuildContext context,
  Future<PaginatedPage<T>> Function(int page) fetchPage, {
  String errorMessage = 'Could not load the full list',
}) async {
  // Long enough to cover a multi-page walk; dismissed explicitly either way.
  AppSnackBar.show(
    context,
    'Preparing…',
    duration: const Duration(seconds: 30),
  );
  try {
    final items = await drainPages(fetchPage);
    AppSnackBar.dismiss();
    return context.mounted ? items : null;
  } catch (e) {
    AppSnackBar.dismiss();
    AppLogger.error(_tag, 'could not walk the feed', e);
    if (context.mounted) AppSnackBar.show(context, errorMessage);
    return null;
  }
}
