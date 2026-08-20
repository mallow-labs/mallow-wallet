import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/router/nav_bar_state.dart';
import '../../../shared/widgets/bottom_nav_bar.dart';
import '../data/home_feed_repository.dart';
import '../services/home_bloc.dart';

/// Revalidates the home feed when the app returns to the foreground — or the
/// home tab becomes the active tab again — with a stale cache (older than
/// [HomeFeedRepository]'s stale TTL).
///
/// Pull-to-refresh and wallet switches already cover in-app refreshes; this
/// closes the gap where a resumed app (or a kept-alive home tab the user
/// returns to) kept showing the last-cached sections until the user pulled to
/// refresh. The skip-unchanged revalidation in [HomeBloc] means an unchanged
/// feed causes no rebuilds or scroll resets.
class HomeResumeRefreshListener extends StatefulWidget {
  const HomeResumeRefreshListener({
    required this.repository,
    required this.child,
    super.key,
  });

  final HomeFeedRepository repository;
  final Widget child;

  @override
  State<HomeResumeRefreshListener> createState() =>
      _HomeResumeRefreshListenerState();
}

class _HomeResumeRefreshListenerState extends State<HomeResumeRefreshListener>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NavBarState.activeTab.addListener(_onActiveTabChanged);
  }

  @override
  void dispose() {
    NavBarState.activeTab.removeListener(_onActiveTabChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshIfStale();
  }

  void _onActiveTabChanged() {
    if (NavBarState.activeTab.value == MallowNavTab.home) _refreshIfStale();
  }

  Future<void> _refreshIfStale() async {
    final bloc = context.read<HomeBloc>();
    // Skip while a load/refresh is already in flight — the default bloc
    // transformer is concurrent, so a second event would revalidate in
    // parallel with the first.
    final current = bloc.state;
    if (current is! HomeLoaded || current.isRefreshing) return;
    if (!await widget.repository.isCacheStale()) return;
    if (!mounted || bloc.isClosed) return;
    bloc.add(const HomeEvent.refresh());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
