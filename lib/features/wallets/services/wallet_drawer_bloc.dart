import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/models/account.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/services/active_networks.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/wallet_change_listening.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../shared/utils/chain.dart';
import '../../portfolio/data/token_repository.dart';
import '../../portfolio/data/wallet_balance_totals.dart';
import 'profile_lookup_service.dart';
import 'wallet_link_service.dart';

part 'wallet_drawer_bloc.freezed.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

@freezed
abstract class WalletDrawerEvent with _$WalletDrawerEvent {
  /// Load wallets + bulk lookup + build profile groups.
  const factory WalletDrawerEvent.load() = _Load;

  /// Switch active wallet and re-login.
  const factory WalletDrawerEvent.switchWallet(String walletId) = _SwitchWallet;

  /// Toggle expand/collapse of a profile group.
  ///
  /// [groupId] is the userId for profile groups or 'anon' for the anon group.
  const factory WalletDrawerEvent.toggleGroupExpanded(String groupId) =
      _ToggleGroupExpanded;

  /// Pull-to-refresh: re-run bulk lookup to rebuild profile groups.
  const factory WalletDrawerEvent.refreshProfiles() = _RefreshProfiles;

  /// Link [walletId] into the profile that owns [targetProfileUserId].
  ///
  /// [targetGroupOrder] is the full ordered list of wallet IDs for the target
  /// group after the drop. If provided, persists sort indices before the API
  /// call so that `_silentReload` sees the correct order.
  const factory WalletDrawerEvent.linkWallet(
    String walletId,
    String targetProfileUserId, {
    List<String>? targetGroupOrder,
  }) = _LinkWallet;

  /// Unlink [walletId] from its current profile.
  ///
  /// [targetGroupOrder] is the full ordered list of wallet IDs for the anon
  /// group after the drop. If provided, persists sort indices before the API
  /// call so that `_silentReload` sees the correct order.
  const factory WalletDrawerEvent.unlinkWallet(
    String walletId, {
    List<String>? targetGroupOrder,
  }) = _UnlinkWallet;

  /// Reorder wallets within a group.
  ///
  /// [orderedWalletIds] is the full ordered list of wallet IDs for the group
  /// after the drag. Persists new sortIndex values to the DB.
  const factory WalletDrawerEvent.reorderWallets(
    List<String> orderedWalletIds,
  ) = _ReorderWallets;

  /// Reorder profile groups (drag-and-drop on group headers).
  ///
  /// [orderedGroupIds] is the full ordered list of non-anon group userIds
  /// in the new order. Persists to SharedPreferences.
  const factory WalletDrawerEvent.reorderProfileGroups(
    List<String> orderedGroupIds,
  ) = _ReorderProfileGroups;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@freezed
abstract class WalletDrawerState with _$WalletDrawerState {
  const factory WalletDrawerState.initial() = _Initial;
  const factory WalletDrawerState.loading() = _Loading;
  const factory WalletDrawerState.loaded({
    required List<ProfileGroup> profileGroups,
    required ProfileGroup anonGroup,
    required String? activeWalletId,
    @Default({}) Set<String> expandedGroupIds,

    /// Wallet ID currently being linked (shows a loading indicator in the UI).
    String? linkingWalletId,

    /// Account-grouped view (one per Accounts-table row) backing the Wallets
    /// tab. Independent of the profile grouping above.
    @Default([]) List<Account> accounts,
  }) = WalletDrawerLoaded;

  /// Loaded in offline mode — profile groups unavailable, wallets shown flat.
  const factory WalletDrawerState.offline({
    required List<WalletInfo> wallets,
    required String? activeWalletId,
    @Default([]) List<Account> accounts,
  }) = WalletDrawerOffline;

  const factory WalletDrawerState.error(String message) = _Error;
}

// ---------------------------------------------------------------------------
// BLoC
// ---------------------------------------------------------------------------

@injectable
class WalletDrawerBloc extends Bloc<WalletDrawerEvent, WalletDrawerState>
    with WalletChangeListening<WalletDrawerEvent, WalletDrawerState> {
  WalletDrawerBloc(
    this._walletRepo,
    this._walletManager,
    this._profileLookup,
    this._walletLink,
    this._tokenRepo,
    this._prefs,
    this._activeNetworks,
  ) : super(const WalletDrawerState.initial()) {
    on<_Load>(_onLoad);
    on<_SwitchWallet>(_onSwitchWallet);
    on<_ToggleGroupExpanded>(_onToggleGroupExpanded);
    on<_RefreshProfiles>(_onRefreshProfiles);
    on<_LinkWallet>(_onLinkWallet);
    on<_UnlinkWallet>(_onUnlinkWallet);
    on<_ReorderWallets>(_onReorderWallets);
    on<_ReorderProfileGroups>(_onReorderProfileGroups);

    startWalletChangeListening();

    // Switching a network off has to take its wallets out of the drawer the
    // user backs out to — the drawer only reloads on a wallet change, so the
    // rows would otherwise sit there until the next switch.
    _networksSub = _activeNetworks.changes.listen((_) {
      if (isClosed) return;
      add(const WalletDrawerEvent.load());
    });
  }

  final WalletRepository _walletRepo;
  final WalletManager _walletManager;
  final ProfileLookupService _profileLookup;
  final WalletLinkService _walletLink;
  final TokenRepository _tokenRepo;
  final PreferencesService _prefs;
  final ActiveNetworks _activeNetworks;
  StreamSubscription<void>? _networksSub;

  @override
  Future<void> close() async {
    await _networksSub?.cancel();
    return super.close();
  }

  /// Max wallets refreshed concurrently in [_fetchFreshBalances]. A switch
  /// fans out over every wallet the user owns; bounding the fan-out keeps the
  /// Helius/Jupiter burst from tripping rate limits while still letting the
  /// per-mint Jupiter coalescer merge the in-flight requests.
  static const _maxConcurrentBalanceFetches = 5;

  @override
  WalletManager get walletManager => _walletManager;

  /// When true, the next `onWalletChanged` event is suppressed (we already
  /// did a `_silentReload` in the link/unlink handler).
  bool _suppressNextLoad = false;

  // Reload when wallet changes externally (e.g. wallet removal). After
  // link/unlink we already did a _silentReload, so suppress the redundant
  // full load triggered by notifyWalletDataChanged().
  @override
  void onWalletChanged() {
    if (_suppressNextLoad) {
      _suppressNextLoad = false;
      return;
    }
    add(const WalletDrawerEvent.load());
  }

  // ---------------------------------------------------------------------------
  // Handlers
  // ---------------------------------------------------------------------------

  Future<void> _onLoad(_Load event, Emitter<WalletDrawerState> emit) async {
    emit(const WalletDrawerState.loading());
    final walletsResult = await Result.guard(() async {
      final all = await _walletRepo.getAllWallets();
      final active = await _walletRepo.getActiveWallet();
      final accounts = await _walletRepo.getAccountViews();
      // Wallets on a switched-off network drop out of every list below — the
      // flat/offline one as well as the profile groups.
      final disabled = await _disabledChains();
      return (
        walletsOnActiveNetworks(
          all,
          disabled: disabled,
          activeWalletId: active?.id,
        ),
        active?.id,
        accounts,
        disabled,
      );
    });
    if (walletsResult case ResultFailure(:final error)) {
      emit(WalletDrawerState.error(error.message));
      return;
    }
    final (wallets, activeWalletId, accounts, disabledChains) =
        walletsResult.valueOrNull!;
    debugPrint(
      '[SocialImport][DrawerBloc] _onLoad: ${accounts.length} accounts '
      '${accounts.map((a) => '${a.name}(${a.kind.name},'
          '${a.wallets.length}w)').toList()} activeWalletId=$activeWalletId',
    );
    try {
      if (wallets.isEmpty) {
        emit(
          WalletDrawerState.loaded(
            profileGroups: const [],
            anonGroup: const ProfileGroup(wallets: [], isAnon: true),
            activeWalletId: activeWalletId,
            accounts: accounts,
          ),
        );
        return;
      }

      // Bulk lookup to build profile groups
      try {
        final addresses = wallets.map((w) => w.address).toList();
        await _profileLookup.bulkLookup(addresses);
        final response = _profileLookup.lastResponse!;
        var (profileGroups, anonGroup) = _profileLookup.buildProfileGroups(
          wallets,
          response,
        );

        // A profile's linked-but-unimported addresses arrive here as synthetic
        // placeholders rather than local wallets, so the network filter is
        // applied to the built groups as well as to `wallets` above.
        profileGroups = groupsOnActiveNetworks(
          profileGroups,
          disabled: disabledChains,
          activeWalletId: activeWalletId,
        );
        anonGroup = anonGroup.copyWith(
          wallets: walletsOnActiveNetworks(
            anonGroup.wallets,
            disabled: disabledChains,
            activeWalletId: activeWalletId,
          ),
        );

        // Apply persisted profile group order.
        profileGroups = _applyPersistedGroupOrder(profileGroups);

        // Default: expand all groups
        final expandedIds = _allGroupIds(profileGroups, anonGroup);

        // Balances cover local wallets plus a profile's synthetic (unheld)
        // linked wallets, so the per-profile total matches the home aggregate.
        final balanceAddresses = _balanceAddresses(addresses, profileGroups);

        // Emit with cached balances immediately
        final cachedBalances = await _loadCachedBalances(balanceAddresses);
        emit(
          WalletDrawerState.loaded(
            profileGroups: _enrichGroups(profileGroups, cachedBalances),
            anonGroup: _enrichGroup(anonGroup, cachedBalances),
            activeWalletId: activeWalletId,
            expandedGroupIds: expandedIds,
            accounts: accounts,
          ),
        );

        // Refresh balances from API in background. The active wallet — the one
        // you just switched to — always refreshes; the rest ride their cache.
        final activeAddress = wallets
            .where((w) => w.id == activeWalletId)
            .map((w) => w.address)
            .firstOrNull;
        final freshBalances = await _fetchFreshBalances(
          balanceAddresses,
          activeAddress: activeAddress,
        );
        if (freshBalances.isNotEmpty) {
          final current = state;
          if (current is WalletDrawerLoaded) {
            emit(
              current.copyWith(
                profileGroups: _enrichGroups(
                  current.profileGroups,
                  freshBalances,
                ),
                anonGroup: _enrichGroup(current.anonGroup, freshBalances),
              ),
            );
          }
        }
      } catch (e) {
        // Offline or lookup failed — show flat list
        debugPrint('[WalletDrawerBloc] bulkLookup failed (offline?): $e');
        emit(
          WalletDrawerState.offline(
            wallets: wallets,
            activeWalletId: activeWalletId,
            accounts: accounts,
          ),
        );
      }
    } catch (e) {
      emit(WalletDrawerState.error(AppFailure.from(e).message));
    }
  }

  Future<void> _onSwitchWallet(
    _SwitchWallet event,
    Emitter<WalletDrawerState> emit,
  ) async {
    // Optimistically flip the active wallet id so anything reading it (e.g. the
    // header address) updates immediately. The new wallet's address is already
    // present in the current state, so we don't need to wait for the async
    // persist + reload below to finish.
    final current = state;
    if (current is WalletDrawerLoaded) {
      emit(current.copyWith(activeWalletId: event.walletId));
    } else if (current is WalletDrawerOffline) {
      emit(current.copyWith(activeWalletId: event.walletId));
    }

    try {
      // switchWalletById fires onWalletChanged which triggers:
      //  - app.dart listener → authService.switchWallet() (re-login)
      //  - our stream listener → load() (refresh drawer state)
      await _walletManager.switchWalletById(event.walletId);
    } catch (e) {
      debugPrint('[WalletDrawerBloc] switchWallet error: $e');
      add(const WalletDrawerEvent.load());
    }
  }

  void _onToggleGroupExpanded(
    _ToggleGroupExpanded event,
    Emitter<WalletDrawerState> emit,
  ) {
    final current = state;
    if (current is WalletDrawerLoaded) {
      final expanded = Set<String>.from(current.expandedGroupIds);
      if (expanded.contains(event.groupId)) {
        expanded.remove(event.groupId);
      } else {
        expanded.add(event.groupId);
      }
      emit(current.copyWith(expandedGroupIds: expanded));
    }
  }

  Future<void> _onRefreshProfiles(
    _RefreshProfiles event,
    Emitter<WalletDrawerState> emit,
  ) async {
    _profileLookup.clearCache();
    add(const WalletDrawerEvent.load());
  }

  Future<void> _onLinkWallet(
    _LinkWallet event,
    Emitter<WalletDrawerState> emit,
  ) async {
    final current = state;
    if (current is! WalletDrawerLoaded) return;

    // Find the wallet being linked
    final walletInfo = _findWalletById(
      current.profileGroups,
      current.anonGroup,
      event.walletId,
    );
    if (walletInfo == null) {
      debugPrint('[WalletDrawerBloc] linkWallet: wallet not found');
      return;
    }

    // Find the target profile group and a signable wallet address in it
    final targetGroup = current.profileGroups.firstWhere(
      (g) => g.userId == event.targetProfileUserId,
      orElse: () => const ProfileGroup(wallets: [], isAnon: false),
    );
    final signable = targetGroup.wallets.firstWhere(
      (w) => w.canSign,
      orElse: () => throw StateError('No signable wallet in target profile'),
    );

    // Detect cross-profile move: wallet is in a non-anon profile != target
    final sourceGroupId = _findGroupIdForWallet(
      current.profileGroups,
      current.anonGroup,
      event.walletId,
    );
    final isCrossProfile =
        sourceGroupId != null &&
        sourceGroupId != 'anon' &&
        sourceGroupId != event.targetProfileUserId;

    // Persist the drop-position sort order BEFORE the API call so that
    // _silentReload (which reads from DB) sees the correct order.
    if (event.targetGroupOrder != null) {
      await _walletRepo.reorderWalletsInGroup(event.targetGroupOrder!);
    }

    // Emit optimistic state — move wallet to target group immediately
    emit(
      _optimisticMoveWallet(
        current,
        event.walletId,
        event.targetProfileUserId,
        targetGroupOrder: event.targetGroupOrder,
      ),
    );

    try {
      // Cross-profile: unlink the single wallet first to avoid full user merge
      if (isCrossProfile) {
        await _walletLink.unlinkWallet(walletInfo.address);
      }
      await _walletLink.linkWallet(walletInfo.address, signable.address);
    } catch (e) {
      debugPrint('[WalletDrawerBloc] linkWallet error: $e');
    }

    // Always sync from server to reflect the true state
    _profileLookup.clearCache();
    await _silentReload(emit);

    // Suppress the redundant full load that notifyWalletDataChanged() will
    // trigger on THIS bloc instance (we already did _silentReload above).
    _suppressNextLoad = true;
    // Notify other BLoC instances (home screen, drawer) to reload profile data
    await _walletManager.notifyWalletDataChanged();
  }

  Future<void> _onUnlinkWallet(
    _UnlinkWallet event,
    Emitter<WalletDrawerState> emit,
  ) async {
    final current = state;
    if (current is! WalletDrawerLoaded) return;

    final walletInfo = _findWalletById(
      current.profileGroups,
      current.anonGroup,
      event.walletId,
    );
    if (walletInfo == null) {
      debugPrint('[WalletDrawerBloc] unlinkWallet: wallet not found');
      return;
    }

    // Persist the drop-position sort order BEFORE the API call so that
    // _silentReload (which reads from DB) sees the correct order.
    if (event.targetGroupOrder != null) {
      await _walletRepo.reorderWalletsInGroup(event.targetGroupOrder!);
    }

    // Emit optimistic state — move wallet to anon group immediately
    emit(
      _optimisticMoveWallet(
        current,
        event.walletId,
        'anon',
        targetGroupOrder: event.targetGroupOrder,
      ),
    );

    try {
      await _walletLink.unlinkWallet(walletInfo.address);
    } catch (e) {
      debugPrint('[WalletDrawerBloc] unlinkWallet error: $e');
    }

    // Always sync from server to reflect the true state
    _profileLookup.clearCache();
    await _silentReload(emit);

    // Suppress the redundant full load that notifyWalletDataChanged() will
    // trigger on THIS bloc instance (we already did _silentReload above).
    _suppressNextLoad = true;
    // Notify other BLoC instances (home screen, drawer) to reload profile data
    await _walletManager.notifyWalletDataChanged();
  }

  Future<void> _onReorderWallets(
    _ReorderWallets event,
    Emitter<WalletDrawerState> emit,
  ) async {
    final current = state;
    if (current is! WalletDrawerLoaded) return;

    // Optimistically reorder the wallets in state so the UI updates immediately.
    final newOrder = event.orderedWalletIds;

    ProfileGroup reordered(ProfileGroup group) {
      final map = {for (final w in group.wallets) w.id: w};
      final ordered = newOrder
          .where(map.containsKey)
          .map((id) => map[id]!)
          .toList();
      // Append any wallets not in newOrder (shouldn't happen, but be safe).
      for (final w in group.wallets) {
        if (!newOrder.contains(w.id)) ordered.add(w);
      }
      return group.copyWith(wallets: ordered);
    }

    final updatedGroups = current.profileGroups.map(reordered).toList();
    final updatedAnon = reordered(current.anonGroup);

    emit(
      current.copyWith(profileGroups: updatedGroups, anonGroup: updatedAnon),
    );

    // Persist to DB.
    try {
      await _walletRepo.reorderWalletsInGroup(newOrder);
    } catch (e) {
      debugPrint('[WalletDrawerBloc] reorderWallets error: $e');
    }
  }

  Future<void> _onReorderProfileGroups(
    _ReorderProfileGroups event,
    Emitter<WalletDrawerState> emit,
  ) async {
    final current = state;
    if (current is! WalletDrawerLoaded) return;

    // Reorder profileGroups to match the event's order.
    final orderMap = {
      for (var i = 0; i < event.orderedGroupIds.length; i++)
        event.orderedGroupIds[i]: i,
    };
    final reordered = List<ProfileGroup>.from(current.profileGroups)
      ..sort((a, b) {
        final ai = orderMap[a.userId] ?? orderMap.length;
        final bi = orderMap[b.userId] ?? orderMap.length;
        return ai.compareTo(bi);
      });

    emit(current.copyWith(profileGroups: reordered));

    // Fire-and-forget persistence.
    unawaited(_prefs.setProfileGroupOrder(event.orderedGroupIds));
  }

  /// Sort [profileGroups] according to the persisted order in SharedPreferences.
  /// Groups not in the saved order are appended at the end.
  List<ProfileGroup> _applyPersistedGroupOrder(
    List<ProfileGroup> profileGroups,
  ) {
    final saved = _prefs.profileGroupOrder;
    if (saved == null || saved.isEmpty) return profileGroups;

    final orderMap = {for (var i = 0; i < saved.length; i++) saved[i]: i};
    return List<ProfileGroup>.from(profileGroups)..sort((a, b) {
      final ai = orderMap[a.userId] ?? orderMap.length;
      final bi = orderMap[b.userId] ?? orderMap.length;
      return ai.compareTo(bi);
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Set<String> _allGroupIds(
    List<ProfileGroup> profileGroups,
    ProfileGroup anonGroup,
  ) {
    return {
      for (final group in profileGroups) group.userId ?? 'anon',
      if (anonGroup.wallets.isNotEmpty) 'anon',
    };
  }

  WalletInfo? _findWalletById(
    List<ProfileGroup> profileGroups,
    ProfileGroup anonGroup,
    String walletId,
  ) {
    for (final group in profileGroups) {
      for (final w in group.wallets) {
        if (w.id == walletId) return w;
      }
    }
    for (final w in anonGroup.wallets) {
      if (w.id == walletId) return w;
    }
    return null;
  }

  /// Find which group currently contains [walletId].
  /// Returns the group's userId, or `'anon'` for the anon group, or null.
  String? _findGroupIdForWallet(
    List<ProfileGroup> profileGroups,
    ProfileGroup anonGroup,
    String walletId,
  ) {
    for (final group in profileGroups) {
      for (final w in group.wallets) {
        if (w.id == walletId) return group.userId ?? 'anon';
      }
    }
    for (final w in anonGroup.wallets) {
      if (w.id == walletId) return 'anon';
    }
    return null;
  }

  /// Build a new loaded state with [walletId] moved to [targetGroupId].
  ///
  /// [targetGroupId] is a userId for profile groups or `'anon'`.
  /// If [targetGroupOrder] is provided the target group's wallets are sorted
  /// to match that order (preserving the drop position).
  /// Sets [linkingWalletId] on the result.
  WalletDrawerLoaded _optimisticMoveWallet(
    WalletDrawerLoaded current,
    String walletId,
    String targetGroupId, {
    List<String>? targetGroupOrder,
  }) {
    // Find the wallet object
    final wallet = _findWalletById(
      current.profileGroups,
      current.anonGroup,
      walletId,
    );
    if (wallet == null) return current;

    // Remove wallet from all groups
    ProfileGroup removeWallet(ProfileGroup g) =>
        g.copyWith(wallets: g.wallets.where((w) => w.id != walletId).toList());

    final strippedGroups = current.profileGroups.map(removeWallet).toList();
    final strippedAnon = removeWallet(current.anonGroup);

    // Add wallet to the target group
    List<ProfileGroup> newGroups;
    ProfileGroup newAnon;

    if (targetGroupId == 'anon') {
      newGroups = strippedGroups;
      final wallets = [...strippedAnon.wallets, wallet];
      newAnon = strippedAnon.copyWith(
        wallets: _applyWalletOrder(wallets, targetGroupOrder),
      );
    } else {
      newGroups = strippedGroups.map((g) {
        if ((g.userId ?? 'anon') == targetGroupId) {
          final wallets = [...g.wallets, wallet];
          return g.copyWith(
            wallets: _applyWalletOrder(wallets, targetGroupOrder),
          );
        }
        return g;
      }).toList();
      newAnon = strippedAnon;
    }

    return current.copyWith(
      profileGroups: newGroups,
      anonGroup: newAnon,
      linkingWalletId: walletId,
    );
  }

  /// Reorder [wallets] to match [order] (a list of wallet IDs).
  /// Wallets not in [order] are appended at the end.
  /// If [order] is null, returns [wallets] unchanged.
  List<WalletInfo> _applyWalletOrder(
    List<WalletInfo> wallets,
    List<String>? order,
  ) {
    if (order == null || order.isEmpty) return wallets;
    final map = {for (final w in wallets) w.id: w};
    final result = <WalletInfo>[];
    for (final id in order) {
      final w = map.remove(id);
      if (w != null) result.add(w);
    }
    // Append any remaining wallets not in the order list.
    result.addAll(map.values);
    return result;
  }

  /// Reload profile groups from the server without emitting a loading state.
  ///
  /// Preserves [expandedGroupIds] from the current state. Falls back to
  /// clearing [linkingWalletId] if the reload fails.
  Future<void> _silentReload(Emitter<WalletDrawerState> emit) async {
    final current = state;
    if (current is! WalletDrawerLoaded) return;

    try {
      final all = await _walletRepo.getAllWallets();
      final activeWallet = await _walletRepo.getActiveWallet();
      final accounts = await _walletRepo.getAccountViews();
      final disabledChains = await _disabledChains();
      final wallets = walletsOnActiveNetworks(
        all,
        disabled: disabledChains,
        activeWalletId: activeWallet?.id,
      );

      final addresses = wallets.map((w) => w.address).toList();
      await _profileLookup.bulkLookup(addresses);
      final response = _profileLookup.lastResponse!;
      var (profileGroups, anonGroup) = _profileLookup.buildProfileGroups(
        wallets,
        response,
      );

      profileGroups = groupsOnActiveNetworks(
        profileGroups,
        disabled: disabledChains,
        activeWalletId: activeWallet?.id,
      );
      anonGroup = anonGroup.copyWith(
        wallets: walletsOnActiveNetworks(
          anonGroup.wallets,
          disabled: disabledChains,
          activeWalletId: activeWallet?.id,
        ),
      );

      // Apply persisted profile group order (covers both user reordering and
      // preserving order across link/unlink reloads).
      profileGroups = _applyPersistedGroupOrder(profileGroups);

      final cachedBalances = await _loadCachedBalances(
        _balanceAddresses(addresses, profileGroups),
      );

      emit(
        WalletDrawerState.loaded(
          profileGroups: _enrichGroups(profileGroups, cachedBalances),
          anonGroup: _enrichGroup(anonGroup, cachedBalances),
          activeWalletId: activeWallet?.id,
          expandedGroupIds: current.expandedGroupIds,
          accounts: accounts,
        ),
      );
    } catch (e) {
      debugPrint('[WalletDrawerBloc] silentReload failed: $e');
      // Clear the linking indicator so the UI isn't stuck
      emit(current.copyWith(linkingWalletId: null));
    }
  }

  // ---------------------------------------------------------------------------
  // Balance helpers
  // ---------------------------------------------------------------------------

  /// Local wallet addresses plus every address surfaced in [groups] — i.e. a
  /// profile's synthetic (unheld) linked wallets — so per-profile balances
  /// include those and match the home portfolio aggregate. Deduped.
  /// The chains switched off for the current session scope. A read failure
  /// degrades to "nothing disabled" so a storage hiccup shows the user's whole
  /// wallet list rather than hiding wallets they own.
  Future<Set<Chain>> _disabledChains() async {
    try {
      return await _activeNetworks.disabled();
    } catch (_) {
      return const {};
    }
  }

  /// [wallets] minus every wallet on a chain the user switched off in Active
  /// Networks — the drawer's half of the same rule the tokens tab and the
  /// import picker apply. Covers a profile's synthetic view-only placeholders
  /// too: their chain is derived from the linked address.
  ///
  /// 🛑 [activeWalletId] always survives the filter. It is the wallet the
  /// session signs with, and the header renders it whether or not the drawer
  /// lists it — hiding it would leave the user looking at an address with no
  /// row to switch away from. Turning a network off must never be able to
  /// strand a session on an unreachable wallet.
  @visibleForTesting
  static List<WalletInfo> walletsOnActiveNetworks(
    List<WalletInfo> wallets, {
    required Set<Chain> disabled,
    required String? activeWalletId,
  }) {
    if (disabled.isEmpty) return wallets;
    return [
      for (final w in wallets)
        if (w.id == activeWalletId || !disabled.contains(w.chainEnum)) w,
    ];
  }

  /// [groups] with [walletsOnActiveNetworks] applied to each. A group left with
  /// nothing to show is dropped rather than rendered empty — its wallets all
  /// sit on networks the user switched off. The active wallet's own group can
  /// never empty out, so the session's profile stays in the list.
  @visibleForTesting
  static List<ProfileGroup> groupsOnActiveNetworks(
    List<ProfileGroup> groups, {
    required Set<Chain> disabled,
    required String? activeWalletId,
  }) {
    if (disabled.isEmpty) return groups;
    final filtered = <ProfileGroup>[];
    for (final group in groups) {
      final wallets = walletsOnActiveNetworks(
        group.wallets,
        disabled: disabled,
        activeWalletId: activeWalletId,
      );
      if (wallets.isEmpty) continue;
      filtered.add(group.copyWith(wallets: wallets));
    }
    return filtered;
  }

  List<String> _balanceAddresses(
    List<String> localAddresses,
    List<ProfileGroup> groups,
  ) => <String>{
    ...localAddresses,
    for (final g in groups)
      for (final w in g.wallets) w.address,
  }.toList();

  /// Load cached balances for all addresses. Returns address → totalUsd map.
  Future<Map<String, double>> _loadCachedBalances(
    List<String> addresses,
  ) async {
    final balances = <String, double>{};
    for (final address in addresses) {
      try {
        // Ethereum and Tezos wallets are cached under their own providers, not
        // the Solana TokenRepository, so every chain in a profile counts toward
        // its aggregate. See [cachedWalletTotalUsd].
        final total = await cachedWalletTotalUsd(address);
        if (total != null) {
          balances[address] = total;
        }
      } catch (e) {
        debugPrint('[WalletDrawerBloc] cached balance error for $address: $e');
      }
    }
    return balances;
  }

  /// Refresh balances from the API, returning address → totalUsd for the
  /// wallets actually re-fetched (wallets left out keep the cached totals the
  /// drawer already painted).
  ///
  /// A switch reloads the drawer for *every* wallet the user owns, so two
  /// guards stop it from stampeding Helius/Jupiter:
  ///   * Skip any wallet whose 30s balance cache is still fresh — re-fetching
  ///     it would just reproduce the totals already on screen. [activeAddress]
  ///     (the wallet you switched to) is always refreshed so the screen you
  ///     land on is authoritative.
  ///   * Fetch the survivors in bounded-concurrency chunks instead of one
  ///     sequential round-trip per wallet.
  Future<Map<String, double>> _fetchFreshBalances(
    List<String> addresses, {
    String? activeAddress,
  }) async {
    final stale = <String>[];
    for (final address in addresses) {
      if (address == activeAddress || await _tokenRepo.isCacheStale(address)) {
        stale.add(address);
      }
    }

    final balances = <String, double>{};
    for (var i = 0; i < stale.length; i += _maxConcurrentBalanceFetches) {
      final chunk = stale.skip(i).take(_maxConcurrentBalanceFetches);
      await Future.wait(
        chunk.map((address) async {
          try {
            // Routed per chain — a `0x…`/`tz1…` address sent down the Solana
            // path returns nothing and wipes that wallet's cached rows. See
            // [fetchWalletTotalUsd].
            balances[address] = await fetchWalletTotalUsd(address);
          } catch (e) {
            debugPrint(
              '[WalletDrawerBloc] fresh balance error for $address: $e',
            );
          }
        }),
      );
    }
    return balances;
  }

  /// Copy a ProfileGroup with enriched wallet balances.
  ProfileGroup _enrichGroup(ProfileGroup group, Map<String, double> balances) {
    return group.copyWith(
      wallets: group.wallets
          .map(
            (w) => balances.containsKey(w.address)
                ? w.copyWith(balanceUsd: balances[w.address])
                : w,
          )
          .toList(),
    );
  }

  /// Enrich all profile groups with balances.
  List<ProfileGroup> _enrichGroups(
    List<ProfileGroup> groups,
    Map<String, double> balances,
  ) {
    return groups.map((g) => _enrichGroup(g, balances)).toList();
  }
}
