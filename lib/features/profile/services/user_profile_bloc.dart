import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;
// freezed generates an unprefixed reference to ExploreFilter's deep-copy
// helper for the `filter` field; bring just that symbol into scope so the
// generated `.freezed.dart` resolves it (the type itself stays `api.`-prefixed).
// ignore: unused_shown_name
import 'package:mallow_api/mallow_api.dart' show $ExploreFilterCopyWith;

import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/network/ledger_verify_controller.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/session/session_manager.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/user_display.dart';
import '../../../di.dart';
import '../../curations/data/curation_repository.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../artwork/services/artwork_hidden_signal.dart';
import '../../artwork/services/artwork_removal_signal.dart';
import '../../curations/services/curations_refresh_signal.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../data/user_profile_repository.dart';
import '../models/cached_profile_data.dart';
import '../models/user_profile.dart';
import '../widgets/profile_filters_sheet.dart' show activeFilterOrNull;

part 'user_profile_bloc.freezed.dart';

/// Active tab on the user profile screen.
enum ProfileTab { created, listed, collections, curations, owned }

/// True for the tabs that render a flat artwork list rather than groups. They
/// share the artwork filters sheet, the "recent" sort default, the masonry /
/// list / grid view cycle, and infinite scroll.
bool isArtworkListTab(ProfileTab tab) =>
    tab == ProfileTab.created ||
    tab == ProfileTab.listed ||
    tab == ProfileTab.owned;

/// Events for user profile screen.
@freezed
sealed class UserProfileEvent with _$UserProfileEvent {
  /// Load profile data for a given address.
  const factory UserProfileEvent.load({required String address}) =
      UserProfileLoad;

  /// Switch active tab.
  const factory UserProfileEvent.changeTab({required ProfileTab tab}) =
      UserProfileChangeTab;

  /// Cycle view mode (masonry -> detail -> grid on artwork tabs, list <-> grid
  /// on group tabs). The two are separate preferences and never overwrite
  /// each other.
  const factory UserProfileEvent.toggleViewMode() = UserProfileToggleViewMode;

  /// Change sort option.
  const factory UserProfileEvent.setSort({required PortfolioSortOption sort}) =
      UserProfileSetSort;

  /// Load profile data by username (resolves address from API).
  const factory UserProfileEvent.loadByUsername({required String username}) =
      UserProfileLoadByUsername;

  /// Toggle follow state.
  const factory UserProfileEvent.toggleFollow() = UserProfileToggleFollow;

  /// Load more artworks (next page).
  const factory UserProfileEvent.loadMoreArtworks() =
      UserProfileLoadMoreArtworks;

  /// Fetch page 0 of the Listed tab. Dispatched the first time the tab is
  /// opened (it isn't part of the initial parallel load) and again on
  /// refresh / filter change once it has been loaded.
  const factory UserProfileEvent.loadListedArtworks() =
      UserProfileLoadListedArtworks;

  /// Apply an artwork filter (listing type, price, media, categories, search).
  /// An empty filter clears all filtering.
  const factory UserProfileEvent.setFilter({
    required api.ExploreFilter filter,
  }) = UserProfileSetFilter;

  /// Apply the group-tab name search (Collections / Curations) from the
  /// filters sheet. Filters the loaded groups client-side; an empty query
  /// clears the search.
  const factory UserProfileEvent.setGroupSearch({required String query}) =
      UserProfileSetGroupSearch;

  /// Sign in with the active wallet to unlock private curations (Ledger,
  /// own profile only).
  const factory UserProfileEvent.verifyForPrivateCurations() =
      UserProfileVerifyForPrivateCurations;

  /// Refetch only the curation groups (a curation was created/edited/deleted
  /// elsewhere) — the rest of the profile is untouched.
  const factory UserProfileEvent.refreshCurations() =
      UserProfileRefreshCurations;

  /// Optimistically drop [mintAccount] from the ownership-based lists (Owned +
  /// the viewer-owned slice) the instant a transfer/burn confirms, via the
  /// app-wide [ArtworkRemovalSignal].
  const factory UserProfileEvent.artworkRemoved(String mintAccount) =
      UserProfileArtworkRemoved;

  /// Optimistically flip [mintAccount]'s hidden badge across the profile's
  /// artwork lists the instant the `/v0/hide` write returns, via the app-wide
  /// [ArtworkHiddenSignal].
  const factory UserProfileEvent.artworkHidden(
    String mintAccount, {
    required bool isHidden,
  }) = UserProfileArtworkHidden;
}

/// States for user profile screen.
@freezed
sealed class UserProfileState with _$UserProfileState {
  /// Initial state before loading.
  const factory UserProfileState.initial() = UserProfileInitial;

  /// Loading profile data.
  const factory UserProfileState.loading() = UserProfileLoading;

  /// Profile loaded successfully.
  ///
  /// Content fields are nullable to support progressive loading:
  /// - `null` = section still loading (show shimmer)
  /// - non-null (even empty list) = data arrived (show content or empty state)
  const factory UserProfileState.loaded({
    required UserProfile profile,
    List<PortfolioArtwork>? artworks,
    List<PortfolioArtwork>? ownedArtworks,

    /// Artworks listed by (or created by) the viewed profile. Lazily fetched
    /// the first time the Listed tab is opened — `null` until then.
    List<PortfolioArtwork>? listedArtworks,
    List<ArtGroup>? groups,
    List<PortfolioArtwork>? youOwnArtworks,
    @Default(ProfileTab.created) ProfileTab activeTab,
    @Default(ArtworkViewMode.masonry) ArtworkViewMode artworkViewMode,
    @Default(PortfolioViewMode.grid) PortfolioViewMode groupViewMode,
    @Default(PortfolioSortOption.recent) PortfolioSortOption activeSort,
    @Default(false) bool isFollowing,
    @Default(false) bool isRefreshing,
    @Default(false) bool isLoadingMore,
    @Default(true) bool hasMoreArtworks,
    int? nextArtworksPage,
    @Default(false) bool isLoadingMoreOwned,
    @Default(true) bool hasMoreOwned,
    int? nextOwnedPage,
    @Default(false) bool isLoadingMoreListed,
    @Default(true) bool hasMoreListed,
    int? nextListedPage,

    /// Active artwork filter (null = no filtering). Applies to the Created and
    /// Owned tabs; group tabs (collections/curations) are unaffected.
    api.ExploreFilter? filter,

    /// Active name-search query on the group tabs (null = none). Applied
    /// client-side when rendering the Collections/Curations tabs; cleared on
    /// tab change since each tab searches a different name space.
    String? groupSearch,

    /// Non-null when fetching this profile's curations failed — the Curations
    /// tab surfaces the error instead of silently showing "no curations".
    String? curationsError,

    /// True when viewing your own profile with a Ledger wallet that lacks a
    /// signed-login session, so private curations are hidden until verified.
    @Default(false) bool showVerifyPrivateCurationsCta,

    /// True while the Ledger verification flow is in-flight.
    @Default(false) bool isVerifyingCurations,
  }) = UserProfileLoaded;

  /// Error state.
  const factory UserProfileState.error({required String message}) =
      UserProfileError;
}

/// BLoC for the user profile screen.
@injectable
class UserProfileBloc extends Bloc<UserProfileEvent, UserProfileState> {
  UserProfileBloc(
    this._repository,
    this._curationRepository,
    this._authService,
    this._ledgerVerifyController,
  ) : super(const UserProfileState.initial()) {
    on<UserProfileLoad>(_onLoad);
    on<UserProfileLoadByUsername>(_onLoadByUsername);
    on<UserProfileChangeTab>(_onChangeTab);
    on<UserProfileToggleViewMode>(_onToggleViewMode);
    on<UserProfileSetSort>(_onSetSort);
    on<UserProfileToggleFollow>(_onToggleFollow);
    on<UserProfileLoadMoreArtworks>(_onLoadMoreArtworks);
    on<UserProfileLoadListedArtworks>(_onLoadListedArtworks);
    on<UserProfileSetFilter>(_onSetFilter);
    on<UserProfileSetGroupSearch>(_onSetGroupSearch);
    on<UserProfileVerifyForPrivateCurations>(_onVerifyForPrivateCurations);
    on<UserProfileRefreshCurations>(_onRefreshCurations);
    on<UserProfileArtworkRemoved>(_onArtworkRemoved);
    on<UserProfileArtworkHidden>(_onArtworkHidden);

    // Curation mutations (create/rename/visibility/add/remove artwork/delete)
    // fire the app-wide curations signal — refetch the curation groups so an
    // own-profile Curations tab mounted under the pushed route stays in sync.
    // Guarded so unit tests that don't bootstrap DI simply skip it.
    if (sl.isRegistered<CurationsRefreshSignal>()) {
      _curationsSignalSub = sl<CurationsRefreshSignal>().stream.listen(
        (_) => add(const UserProfileEvent.refreshCurations()),
      );
    }

    // An artwork edit (thumbnail/name/collection) lands after this profile is
    // on screen. Only the viewer's own profile hosts editable art, so refetch
    // it in place when the indexer acks — the load handler preserves the
    // active tab and skips the cache for an already-on-screen profile.
    if (sl.isRegistered<ArtworkEditedSignal>()) {
      _editedSignalSub = sl<ArtworkEditedSignal>().stream.listen((_) {
        final address = _currentAddress;
        if (address != null && address == _authService.currentAddress) {
          add(UserProfileEvent.load(address: address));
        }
      });
    }

    // A transfer/burn removes an owned artwork from the viewer's wallets — drop
    // it from the Owned / viewer-owned lists on the spot. Created art is
    // provenance-based (ownership-independent) so it's left untouched.
    if (sl.isRegistered<ArtworkRemovalSignal>()) {
      _removalSignalSub = sl<ArtworkRemovalSignal>().stream.listen(
        (mint) => add(UserProfileEvent.artworkRemoved(mint)),
      );
    }

    // Hide/unhide flips the badge across the Created / Owned lists on the spot.
    if (sl.isRegistered<ArtworkHiddenSignal>()) {
      _hiddenSignalSub = sl<ArtworkHiddenSignal>().stream.listen(
        (change) => add(
          UserProfileEvent.artworkHidden(
            change.mintAccount,
            isHidden: change.isHidden,
          ),
        ),
      );
    }
  }

  final UserProfileRepository _repository;
  final CurationRepository _curationRepository;
  final AuthService _authService;
  final LedgerVerifyController _ledgerVerifyController;

  StreamSubscription<void>? _curationsSignalSub;
  StreamSubscription<String>? _editedSignalSub;
  StreamSubscription<String>? _removalSignalSub;
  StreamSubscription<ArtworkHiddenChange>? _hiddenSignalSub;

  /// One-shot, user-facing failures that must not become part of the rendered
  /// state (a reverted follow leaves the state identical to before the tap, so
  /// there is nothing for a `BlocListener` to diff on). The screen subscribes
  /// and shows a snack bar.
  final StreamController<String> _transientErrors =
      StreamController<String>.broadcast();

  Stream<String> get transientErrors => _transientErrors.stream;

  @override
  Future<void> close() {
    _curationsSignalSub?.cancel();
    _editedSignalSub?.cancel();
    _removalSignalSub?.cancel();
    _hiddenSignalSub?.cancel();
    unawaited(_transientErrors.close());
    return super.close();
  }

  List<PortfolioArtwork> _allArtworks = [];
  List<PortfolioArtwork> _allOwnedArtworks = [];
  List<PortfolioArtwork> _allListedArtworks = [];
  List<ArtGroup> _allGroups = [];

  // Staleness guard for the Listed slice. A page-0 listed fetch bumps it; a
  // load-more captures it before its await and drops its page if it changed —
  // a replacing fetch (reopen, refresh, filter change) then owns the slice.
  int _listedGen = 0;

  String? _currentAddress;

  /// Pick the initial tab for a freshly loaded profile. Prefer Created when
  /// the user has any created artworks; otherwise fall back to Owned, matching
  /// the webapp's natural-first-tab default selection.
  ProfileTab _initialTab(UserProfile p) {
    if (p.createdArtworkCount > 0) return ProfileTab.created;
    if (p.collectedArtworkCount > 0) return ProfileTab.owned;
    return ProfileTab.created;
  }

  /// Session-wide "own profile" test, consistent with the screen's
  /// [UserProfileScreen] `_isOwnProfile`: a profile is yours when any of its
  /// addresses (its primary [ownerAddress] or a [linkedAddresses] entry) is in
  /// the current session — NOT only when it's the active signing wallet.
  /// Viewing your own profile through a secondary / linked session wallet must
  /// still fetch private (own-profile) curations and suppress the verify gate.
  ///
  /// The session set is the active wallet unioned with [SessionManager
  /// .sessionAddresses] ([sl] read guarded, matching the bloc's other
  /// service-locator usages and staying unit-testable without a DI container).
  /// The active wallet unioned with the session's wallets — the single
  /// definition of "addresses this device is logged in as", shared by
  /// [_computeIsOwnProfile] and [_profileQueryAddresses] so the two can't drift.
  Set<String> _sessionAddressSet() {
    final active = _authService.currentAddress;
    return <String>{
      if (active != null && active.isNotEmpty) active,
      if (sl.isRegistered<SessionManager>())
        ...sl<SessionManager>().sessionAddresses,
    };
  }

  bool _computeIsOwnProfile({
    required String ownerAddress,
    List<String> linkedAddresses = const [],
  }) {
    final sessionAddrs = _sessionAddressSet();
    if (sessionAddrs.isEmpty) return false;
    // Normalise both sides: the profile's addresses come back from the API with
    // EVM hex lowercased while session wallets hold the EIP-55 checksummed
    // form, so a raw compare misses for EVM — your own EVM-linked profile would
    // render as another user's (verify gate shown, private curations hidden)
    // and the session widening in [_profileQueryAddresses] would never fire.
    // Solana / Tezos are case-sensitive and pass through unchanged.
    final sessionKeys = sessionAddrs.map(apiOwnerAddress).toSet();
    if (linkedAddresses.map(apiOwnerAddress).any(sessionKeys.contains)) {
      return true;
    }
    return sessionKeys.contains(apiOwnerAddress(ownerAddress));
  }

  /// Addresses to query this profile's content (Created / Collected / …) for.
  ///
  /// On your OWN profile the backend may not have every seed-derived wallet
  /// linked into a single account — each chain's address can be a separate
  /// stub — so widen to the local session wallets, the same set the Artwork
  /// Portfolio queries. Without this, art held on a wallet that isn't
  /// backend-linked (e.g. an imported Ethereum wallet) never appears on the
  /// profile even though it shows in the portfolio. EVM addresses are
  /// lowercased because `/v1/profile` matches owners case-sensitively against
  /// the lowercase form the backend stores. Other users' profiles are left on
  /// their linked set.
  List<String> _profileQueryAddresses(UserProfile profile) {
    final linked = profile.linkedAddresses;
    final all = <String>{
      ...(linked.isNotEmpty ? linked : [profile.address]),
    };
    if (_computeIsOwnProfile(
      ownerAddress: profile.address,
      linkedAddresses: linked,
    )) {
      all.addAll(_sessionAddressSet());
    }
    return all.where((a) => a.isNotEmpty).map(apiOwnerAddress).toSet().toList();
  }

  Future<void> _onLoad(
    UserProfileLoad event,
    Emitter<UserProfileState> emit,
  ) async {
    _currentAddress = event.address;

    final currentAddress = _authService.currentAddress;
    final isViewingOtherUser =
        currentAddress != null && currentAddress != event.address;

    final savedArtworkViewMode = await loadArtworkViewMode();
    final savedGroupViewMode = await loadGroupViewMode();

    // Phase 0: Try Drift cache for instant first paint. Skipped when this
    // profile is already on screen (pull-to-refresh / post-edit reload):
    // repainting from cache would show staler data than what's visible and
    // reset the user's active tab to the initial one.
    final alreadyOnScreen =
        state is UserProfileLoaded &&
        (state as UserProfileLoaded).profile.address == event.address;
    final cached = alreadyOnScreen
        ? null
        : await _repository.getCachedProfile(event.address);
    if (cached != null) {
      _allArtworks = cached.artworks;
      _allOwnedArtworks = cached.ownedArtworks;
      _allGroups = cached.groups;
      final isFollowing = _authService.isFollowing(event.address);
      emit(
        UserProfileState.loaded(
          profile: cached.profile,
          artworks: cached.artworks,
          ownedArtworks: cached.ownedArtworks,
          groups: cached.groups,
          youOwnArtworks: cached.youOwnArtworks,
          activeTab: _initialTab(cached.profile),
          artworkViewMode: savedArtworkViewMode,
          groupViewMode: savedGroupViewMode,
          isFollowing: isFollowing,
          isRefreshing: true,
        ),
      );
    } else if (!alreadyOnScreen) {
      emit(const UserProfileState.loading());
    }

    try {
      // Phase 1: Fast profile info (~500ms)
      final profile = await _repository.getUserProfile(event.address);
      if (isClosed) return;

      final isPrimaryLister = profile.roles.contains('primaryLister');

      // Emit with profile header immediately — content fields stay as
      // cached values or null (shimmer).
      final currentLoaded = state is UserProfileLoaded
          ? state as UserProfileLoaded
          : null;

      String? bannerUrl = profile.bannerUrl;
      // If no banner yet but we have cached artworks, use first artwork image
      if ((bannerUrl == null || bannerUrl.isEmpty) &&
          currentLoaded?.artworks != null) {
        bannerUrl = currentLoaded!.artworks!
            .map((a) => a.imageUrl)
            .where((url) => url.isNotEmpty)
            .firstOrNull;
      }

      final resolvedProfile = _buildResolvedProfile(
        profile,
        isPrimaryLister: isPrimaryLister,
        bannerUrl: bannerUrl,
        youOwnArtworks: currentLoaded?.youOwnArtworks ?? [],
        // Preserve any already-resolved count; the youOwn fetch fills it below.
        youOwnTotal: currentLoaded?.profile.ownedArtworkCount ?? 0,
      );

      final isFollowing = _authService.isFollowing(event.address);

      emit(
        UserProfileState.loaded(
          profile: resolvedProfile,
          artworks: currentLoaded?.artworks,
          ownedArtworks: currentLoaded?.ownedArtworks,
          listedArtworks: currentLoaded?.listedArtworks,
          groups: currentLoaded?.groups,
          youOwnArtworks: currentLoaded?.youOwnArtworks,
          activeTab: currentLoaded?.activeTab ?? _initialTab(resolvedProfile),
          artworkViewMode:
              currentLoaded?.artworkViewMode ?? savedArtworkViewMode,
          groupViewMode: currentLoaded?.groupViewMode ?? savedGroupViewMode,
          isFollowing: isFollowing,
          isRefreshing: true,
        ),
      );

      // Phase 2: Content calls in parallel, emit as each arrives
      final addresses = _profileQueryAddresses(profile);

      // The Listed tab is lazily fetched, so it only refreshes here when the
      // user has already opened it (pull-to-refresh while on the tab).
      if (currentLoaded?.listedArtworks != null) {
        add(const UserProfileEvent.loadListedArtworks());
      }

      List<PortfolioArtwork>? freshArtworks;
      List<PortfolioArtwork>? freshOwned;
      List<ArtGroup>? freshGroups;
      List<PortfolioArtwork>? freshYouOwn;

      final artworksFuture = _repository.getUserArtworks(addresses).then((
        result,
      ) {
        if (isClosed) return;
        freshArtworks = result.artworks;
        _allArtworks = result.artworks;

        // Update banner if still missing
        final currentState = state;
        if (currentState is UserProfileLoaded) {
          var updatedProfile = currentState.profile;
          if ((updatedProfile.bannerUrl == null ||
                  updatedProfile.bannerUrl!.isEmpty) &&
              result.artworks.isNotEmpty) {
            final artBanner = result.artworks
                .map((a) => a.imageUrl)
                .where((url) => url.isNotEmpty)
                .firstOrNull;
            if (artBanner != null) {
              updatedProfile = _buildResolvedProfile(
                profile,
                isPrimaryLister: isPrimaryLister,
                bannerUrl: artBanner,
                youOwnArtworks: currentState.youOwnArtworks ?? [],
                // This rebuild only refreshes the banner — keep the resolved
                // count intact (the youOwn fetch owns it).
                youOwnTotal: currentState.profile.ownedArtworkCount,
              );
            }
          }
          emit(
            currentState.copyWith(
              profile: updatedProfile,
              artworks: result.artworks,
              hasMoreArtworks: result.nextPage != null,
              nextArtworksPage: result.nextPage,
            ),
          );
        }
      });

      final ownedFuture = _repository
          .getUserArtworks(addresses, tab: api.ApiProfileTab.collected)
          .then((result) {
            if (isClosed) return;
            freshOwned = result.artworks;
            _allOwnedArtworks = result.artworks;

            final currentState = state;
            if (currentState is UserProfileLoaded) {
              emit(
                currentState.copyWith(
                  ownedArtworks: result.artworks,
                  hasMoreOwned: result.nextPage != null,
                  nextOwnedPage: result.nextPage,
                ),
              );
            }
          });

      // Curations: own profile lists the profile's curations (private included
      // once ANY session wallet is verified); other profiles list that user's
      // public curations by address. Own-profile is session-wide (any session
      // wallet, incl. a non-active linked one), matching the screen's gate.
      final isOwnProfile = _computeIsOwnProfile(
        ownerAddress: event.address,
        linkedAddresses: profile.linkedAddresses,
      );
      final collectionsF = _repository.getUserCollections(addresses);
      // Resolve the own-profile private-curation gate first: it silently
      // verifies a locally-signable session wallet when none is verified yet,
      // so the curation fetch below authorizes via the freshly-attached cookie
      // on this same load. Returns whether to show the manual "verify" CTA
      // (only Ledger / watch-only session wallets remain). No active switch.
      final needsVerifyF = isOwnProfile
          ? _resolvePrivateCurationsGate(
              ownerAddress: event.address,
              linkedAddresses: profile.linkedAddresses,
            )
          : Future.value(false);
      final curationsF = Future(() async {
        await needsVerifyF;
        return _fetchCurationGroups(
          isOwnProfile: isOwnProfile,
          ownerAddress: event.address,
          creatorName: formatUsernameOrAddress(
            username: profile.handle,
            address: profile.address,
          ),
        );
      });
      final groupsFuture = Future(() async {
        final collections = await collectionsF;
        final curationResult = await curationsF;
        final needsVerify = await needsVerifyF;
        if (isClosed) return;
        final result = [...collections, ...curationResult.groups];
        freshGroups = result;
        _allGroups = result;

        final currentState = state;
        if (currentState is UserProfileLoaded) {
          emit(
            currentState.copyWith(
              groups: result,
              curationsError: curationResult.error,
              showVerifyPrivateCurationsCta: needsVerify,
            ),
          );
        }
      });

      final youOwnFuture = isViewingOtherUser
          ? _repository.getYouOwnArtworks(event.address).then((result) {
              if (isClosed) return;
              freshYouOwn = result.artworks;

              final currentState = state;
              if (currentState is UserProfileLoaded) {
                // Update profile with youOwn data. The count is the group's
                // server `total`, not the fetched page length.
                final updatedProfile = _buildResolvedProfile(
                  profile,
                  isPrimaryLister: isPrimaryLister,
                  bannerUrl: currentState.profile.bannerUrl,
                  youOwnArtworks: result.artworks,
                  youOwnTotal: result.total,
                );
                emit(
                  currentState.copyWith(
                    profile: updatedProfile,
                    youOwnArtworks: result.artworks,
                  ),
                );
              }
            })
          : Future<void>.value();

      await Future.wait([
        artworksFuture,
        ownedFuture,
        groupsFuture,
        youOwnFuture,
      ]);
      if (isClosed) return;

      // Phase 3: Done — set isRefreshing false
      final finalState = state;
      if (finalState is UserProfileLoaded) {
        emit(finalState.copyWith(isRefreshing: false));
      }

      // Cache the full result (fire-and-forget)
      unawaited(
        _repository.cacheProfile(
          event.address,
          CachedProfileData(
            profile: (state as UserProfileLoaded).profile,
            artworks: freshArtworks ?? _allArtworks,
            groups: freshGroups ?? _allGroups,
            youOwnArtworks: freshYouOwn ?? <PortfolioArtwork>[],
            ownedArtworks: freshOwned ?? _allOwnedArtworks,
          ),
        ),
      );
    } catch (e) {
      final failure = AppFailure.from(e);
      debugPrint('[UserProfileBloc] Load failed: ${failure.message}');
      if (isClosed) return;
      // If we already have cached data showing, just stop refreshing
      if (state is UserProfileLoaded) {
        emit((state as UserProfileLoaded).copyWith(isRefreshing: false));
      } else {
        emit(
          UserProfileState.error(
            message: 'Failed to load profile: ${failure.message}',
          ),
        );
      }
    }
  }

  Future<void> _onLoadByUsername(
    UserProfileLoadByUsername event,
    Emitter<UserProfileState> emit,
  ) async {
    emit(const UserProfileState.loading());

    final result = await Result.guard(
      () => _repository.getUserProfileByUsername(event.username),
    );
    if (isClosed) return;

    switch (result) {
      case ResultSuccess(:final value):
        if (value.address.isEmpty) {
          emit(const UserProfileState.error(message: 'User not found'));
          return;
        }
        // Delegate to the address-based load flow
        add(UserProfileEvent.load(address: value.address));
      case ResultFailure(:final error):
        debugPrint(
          '[UserProfileBloc] Username lookup failed: ${error.message}',
        );
        emit(
          UserProfileState.error(
            message: 'Failed to load profile: ${error.message}',
          ),
        );
    }
  }

  /// Resolve the own-profile private-curation auth gate WITHOUT switching the
  /// active signing wallet.
  ///
  /// Private curations of the VIEWED profile are readable only when one of that
  /// profile's own wallets presents a valid `wallet-sig` — the backend binds
  /// the private-read gate to the viewed profile's wallet set, so a session
  /// wallet belonging to a *different* profile (e.g. the active login wallet
  /// when the profile is reached through a linked secondary wallet) proves
  /// nothing here. Every check below is therefore scoped to the session wallets
  /// that belong to the viewed profile ([ownerAddress] + [linkedAddresses]):
  /// - a scoped wallet is already verified → its cookie rides along; no CTA;
  /// - else silently sign the first locally-signable (HD / imported) scoped
  ///   wallet so the fetch authorizes via its freshly-attached cookie — but the
  ///   silent sign can fail non-fatally (offline / keystore / 5xx), so re-check
  ///   whether a valid sig actually landed and surface the CTA if it didn't;
  /// - else, no locally-signable scoped wallet remains: surface the manual
  ///   verify CTA only when a Ledger scoped wallet is present (it can verify via
  ///   the BLE sheet); with only social / watch-only wallets nothing can satisfy
  ///   the gate, so don't show a dead-end CTA.
  ///
  /// Returns true when the CTA should show. [SessionManager] is read via [sl]
  /// (guarded) to match the bloc's other service-locator usages and stay
  /// unit-testable without a DI container.
  Future<bool> _resolvePrivateCurationsGate({
    required String ownerAddress,
    List<String> linkedAddresses = const [],
  }) async {
    if (!sl.isRegistered<SessionManager>()) return false;
    final session = sl<SessionManager>();

    // Scope to the session wallets that are part of the VIEWED profile — only
    // those can unlock its private curations (the backend requires the proof to
    // be for one of the viewed profile's wallets, not any session wallet).
    final profileAddrs = <String>{ownerAddress, ...linkedAddresses};
    final scopedWallets = session.sessionWallets
        .where((w) => profileAddrs.contains(w.address))
        .toList();
    final scopedAddrs = scopedWallets.map((w) => w.address).toSet();
    if (scopedAddrs.isEmpty) return false;

    // Any scoped wallet already verified → its cookie rides the fetch; no
    // prompt. Uses the disk-hydrating check so a valid sig that lives only on
    // disk (e.g. a non-active session wallet after a cold start, before login
    // hydrates it) is honoured and attached — the memory-only check would miss
    // it and wrongly show the CTA / send the fetch cookieless.
    if (await _authService.hasValidWalletSigForAny(scopedAddrs)) return false;

    // Auto-verify the first locally-signable (HD / imported) scoped wallet.
    final localSigner = scopedWallets
        .where(
          (w) =>
              w.walletType == WalletType.hd ||
              w.walletType == WalletType.importedKey,
        )
        .firstOrNull;
    if (localSigner != null) {
      await _authService.verifySessionWallet(localSigner.address);
      // verifySessionWallet swallows every failure (offline / keystore / 5xx),
      // so a silent-sign miss leaves NO attached sig. Re-check what's actually
      // in the in-memory cache: if a valid scoped sig now exists the private
      // fetch authorizes and no CTA is needed; if it didn't land, surface the
      // CTA so private curations don't vanish with no way for the user to retry.
      return !_authService.hasAnyVerifiedSession(scopedAddrs);
    }

    // No locally-signable scoped wallet remains. A Ledger scoped wallet can
    // still verify through the manual BLE sheet, so surface the CTA. But if only
    // social / watch-only wallets remain, nothing can satisfy the gate — the
    // CTA would pop a Ledger sheet that can never succeed — so don't show it.
    return scopedWallets.any((w) => w.walletType == WalletType.ledger);
  }

  /// Fetch a profile's curations mapped to curation [ArtGroup]s so they slot
  /// into the same groups list as collections. The curation id goes into
  /// [ArtGroup.id], which [CurationScreen] uses to fetch the artwork list.
  ///
  /// Own profile → the signed-in user's curations (private included once the
  /// wallet has a signed-login session). Other profile → that user's public
  /// curations by [ownerAddress].
  ///
  /// On error: own-profile degrades to an empty list (never blocks the rest of
  /// the profile); other-profile surfaces the error so the Curations tab can
  /// fail loud rather than silently look empty.
  Future<({List<ArtGroup> groups, String? error})> _fetchCurationGroups({
    required bool isOwnProfile,
    required String ownerAddress,
    required String creatorName,
  }) async {
    try {
      final curations = await _curationRepository.getCurations(
        // Always scope the fetch to the VIEWED profile's owner — never null.
        // The backend resolves the private-read gate against THIS profile and
        // returns its private curations only when the login+sig actually proves
        // ownership of it. Passing null let the backend fall back to the active
        // *login* wallet, so viewing a different profile reached through a
        // linked session wallet silently returned the login user's curations
        // (private included) under the viewed profile.
        ownerAddress: ownerAddress,
      );
      return (
        groups: CurationRepository.curationsToGroups(
          curations,
          creatorName: creatorName,
        ),
        error: null,
      );
    } catch (e) {
      debugPrint('[UserProfileBloc] Curations fetch failed: $e');
      return (
        groups: const <ArtGroup>[],
        error: isOwnProfile ? null : 'Couldn\'t load curations',
      );
    }
  }

  /// Run the wallet verification flow (Ledger sign-in) on your own profile
  /// and, on success, refetch curations so private ones appear.
  Future<void> _onVerifyForPrivateCurations(
    UserProfileVerifyForPrivateCurations event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;
    if (currentState.isVerifyingCurations) return;

    final ownerAddress = _currentAddress;
    if (ownerAddress == null) return;

    emit(currentState.copyWith(isVerifyingCurations: true));

    // Verify a Ledger wallet that BELONGS to the viewed profile (not
    // necessarily the active signer): only such a wallet's sig unlocks this
    // profile's private curations, and the CTA only shows when Ledger wallets
    // are all that remain. No active switch.
    final profileAddrs = <String>{
      currentState.profile.address,
      ...currentState.profile.linkedAddresses,
    };
    final ledgerAddress = sl.isRegistered<SessionManager>()
        ? sl<SessionManager>().sessionWallets
              .where(
                (w) =>
                    w.walletType == WalletType.ledger &&
                    profileAddrs.contains(w.address),
              )
              .firstOrNull
              ?.address
        : null;
    // Only a Ledger wallet can complete the BLE sign sheet. With no Ledger
    // session wallet there is nothing the sheet could verify — popping it for a
    // social / watch-only address is a dead end that can never succeed — so
    // bail out without prompting rather than firing an impossible flow.
    if (ledgerAddress == null) {
      final s = state;
      if (s is UserProfileLoaded) {
        emit(s.copyWith(isVerifyingCurations: false));
      }
      return;
    }
    var verified = false;
    try {
      verified = await _ledgerVerifyController.requestVerification(
        ledgerAddress,
      );
    } catch (e) {
      debugPrint('[UserProfileBloc] Ledger verification failed: $e');
    }
    if (isClosed) return;

    if (!verified) {
      final s = state;
      if (s is UserProfileLoaded) {
        emit(s.copyWith(isVerifyingCurations: false));
      }
      return;
    }

    final curationResult = await _fetchCurationGroups(
      isOwnProfile: true,
      ownerAddress: ownerAddress,
      creatorName: formatUsernameOrAddress(
        username: currentState.profile.handle,
        address: currentState.profile.address,
      ),
    );
    if (isClosed) return;
    _allGroups = [
      ..._allGroups.where((g) => g.type != ArtGroupType.curation),
      ...curationResult.groups,
    ];

    final s = state;
    if (s is! UserProfileLoaded) return;
    emit(
      s.copyWith(
        groups: _allGroups,
        isVerifyingCurations: false,
        showVerifyPrivateCurationsCta: false,
        curationsError: curationResult.error,
      ),
    );
  }

  /// Refetch only the curation groups and splice them into the cached groups
  /// list, leaving artworks and collection groups untouched. Fired via the
  /// app-wide curations signal after any curation mutation.
  Future<void> _onRefreshCurations(
    UserProfileRefreshCurations event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;

    final ownerAddress = _currentAddress;
    if (ownerAddress == null) return;
    final isOwnProfile = _computeIsOwnProfile(
      ownerAddress: ownerAddress,
      linkedAddresses: currentState.profile.linkedAddresses,
    );

    final curationResult = await _fetchCurationGroups(
      isOwnProfile: isOwnProfile,
      ownerAddress: ownerAddress,
      creatorName: formatUsernameOrAddress(
        username: currentState.profile.handle,
        address: currentState.profile.address,
      ),
    );
    if (isClosed) return;
    _allGroups = [
      ..._allGroups.where((g) => g.type != ArtGroupType.curation),
      ...curationResult.groups,
    ];

    final s = state;
    if (s is! UserProfileLoaded) return;
    emit(s.copyWith(groups: _allGroups, curationsError: curationResult.error));
  }

  /// Build the resolved UserProfile with role, banner, and youOwn data.
  UserProfile _buildResolvedProfile(
    UserProfile profile, {
    required bool isPrimaryLister,
    required String? bannerUrl,
    required List<PortfolioArtwork> youOwnArtworks,
    required int youOwnTotal,
  }) {
    return UserProfile(
      address: profile.address,
      username: profile.username,
      handle: profile.handle,
      displayName: profile.displayName,
      role: isPrimaryLister
          ? 'Artist'
          : youOwnArtworks.isNotEmpty
          ? 'Collector'
          : '',
      roles: profile.roles,
      bio: profile.bio,
      avatarUrl: profile.avatarUrl,
      followerCount: profile.followerCount,
      followingCount: profile.followingCount,
      collectorCount: profile.collectorCount,
      ownedArtworkCount: youOwnTotal,
      createdArtworkCount: profile.createdArtworkCount,
      collectedArtworkCount: profile.collectedArtworkCount,
      bannerUrl: bannerUrl,
      isVerified: isPrimaryLister,
      ownedArtworkThumbnailUrl: profile.ownedArtworkThumbnailUrl,
      ownedArtworkThumbnailUrls: youOwnArtworks
          .take(4)
          .map((a) => a.imageUrl)
          .where((url) => url.isNotEmpty)
          .toList(),
      twitterUrl: profile.twitterUrl,
      instagramUrl: profile.instagramUrl,
      websiteUrl: profile.websiteUrl,
      youtubeUrl: profile.youtubeUrl,
      linkedAddresses: profile.linkedAddresses,
    );
  }

  Future<void> _onChangeTab(
    UserProfileChangeTab event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;

    final defaultSort = isArtworkListTab(event.tab)
        ? PortfolioSortOption.recent
        : PortfolioSortOption.count;

    // The group name search is tab-specific (collection names vs curation
    // names) — drop it rather than carrying it into a tab it wasn't typed for.
    emit(
      currentState.copyWith(
        activeTab: event.tab,
        activeSort: defaultSort,
        groupSearch: null,
      ),
    );

    // Listed is fetched on demand the first time it's opened — every other tab
    // is already populated by the initial parallel load.
    if (event.tab == ProfileTab.listed && currentState.listedArtworks == null) {
      add(const UserProfileEvent.loadListedArtworks());
    }
  }

  /// Fetch page 0 of the Listed tab (artworks the profile has listed, or
  /// created and someone else listed — the `listed` profile tab's server-side
  /// definition, matching the reference web client).
  Future<void> _onLoadListedArtworks(
    UserProfileLoadListedArtworks event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;

    final addresses = _profileQueryAddresses(currentState.profile);

    // Bump the generation: this fetch replaces the slice, so a listed load-more
    // issued against the pre-fetch list (an older cursor) must be discarded when
    // it lands rather than spliced onto the replacement.
    final gen = ++_listedGen;
    try {
      final result = await _repository.getUserArtworks(
        addresses,
        tab: api.ApiProfileTab.listed,
        filter: activeFilterOrNull(currentState.filter),
      );
      // Superseded by a newer listed fetch (tab reopen, refresh, filter change).
      if (isClosed || gen != _listedGen) return;
      _allListedArtworks = result.artworks;

      final latest = state;
      if (latest is! UserProfileLoaded) return;
      emit(
        latest.copyWith(
          listedArtworks: result.artworks,
          isLoadingMoreListed: false,
          hasMoreListed: result.nextPage != null,
          nextListedPage: result.nextPage,
        ),
      );
    } catch (e) {
      debugPrint('[UserProfileBloc] Load listed artworks failed: $e');
      if (isClosed || gen != _listedGen) return;
      final latest = state;
      if (latest is! UserProfileLoaded) return;
      // Fail loud rather than leaving the tab on an endless shimmer: an empty
      // list renders the tab's empty state. Sync the backing list to exactly
      // what's emitted — otherwise it keeps its stale pre-fetch contents and a
      // later sort re-emits `sortArtworks(_allListedArtworks)` (because
      // `listedArtworks != null`), resurrecting items the filter dropped.
      final restored = latest.listedArtworks ?? const <PortfolioArtwork>[];
      _allListedArtworks = restored;
      emit(
        latest.copyWith(
          listedArtworks: restored,
          isLoadingMoreListed: false,
          hasMoreListed: false,
        ),
      );
    }
  }

  /// Optimistically drop a transferred/burnt artwork from the ownership-based
  /// lists (Owned + the viewer-owned slice) so it disappears immediately. The
  /// Created list is provenance-based (an artist's minted works, independent of
  /// current ownership) so it's deliberately left alone.
  void _onArtworkRemoved(
    UserProfileArtworkRemoved event,
    Emitter<UserProfileState> emit,
  ) {
    final current = state;
    if (current is! UserProfileLoaded) return;
    final mint = event.mintAccount;
    bool keep(PortfolioArtwork a) => a.mintAccount != mint;

    final owned = current.ownedArtworks;
    final youOwn = current.youOwnArtworks;
    final inOwned = owned?.any((a) => a.mintAccount == mint) ?? false;
    final inYouOwn = youOwn?.any((a) => a.mintAccount == mint) ?? false;
    final inBacking = _allOwnedArtworks.any((a) => a.mintAccount == mint);
    if (!inOwned && !inYouOwn && !inBacking) return;

    _allOwnedArtworks = _allOwnedArtworks.where(keep).toList();

    final newYouOwn = youOwn?.where(keep).toList();
    // Decrement the "You own N" banner count when the removed artwork belonged
    // to this artist's owned set. The signal only fires for burns and transfers
    // to a *non-session* wallet (a move between the viewer's own wallets keeps
    // the asset owned and never signals — see [ArtworkRemovalSignal]), so any
    // removal reaching here is a genuine loss. We gate on `inYouOwn` — the mint
    // being present in the loaded page confirms it's one of this artist's works
    // (an off-page removal we can't attribute is left to the next full reload).
    final ownedCount = current.profile.ownedArtworkCount;
    final updatedProfile = inYouOwn && ownedCount > 0
        ? _buildResolvedProfile(
            current.profile,
            isPrimaryLister: current.profile.role == 'Artist',
            bannerUrl: current.profile.bannerUrl,
            youOwnArtworks: newYouOwn ?? const [],
            youOwnTotal: ownedCount - 1,
          )
        : current.profile;
    emit(
      current.copyWith(
        profile: updatedProfile,
        ownedArtworks: owned?.where(keep).toList(),
        youOwnArtworks: newYouOwn,
      ),
    );
  }

  /// Optimistic hide/unhide: flip the matching artwork's badge across every
  /// profile list it may appear in (Created / Owned / the viewer-owned slice)
  /// plus the backing slices, so the corner badge updates immediately. The item
  /// stays in place; only [PortfolioArtwork.isHidden] changes.
  void _onArtworkHidden(
    UserProfileArtworkHidden event,
    Emitter<UserProfileState> emit,
  ) {
    final current = state;
    if (current is! UserProfileLoaded) return;
    final mint = event.mintAccount;
    final hidden = event.isHidden;
    List<PortfolioArtwork>? flip(List<PortfolioArtwork>? list) {
      if (list == null) return null;
      return [
        for (final a in list)
          if (a.mintAccount == mint) a.copyWithHidden(hidden) else a,
      ];
    }

    _allArtworks = flip(_allArtworks) ?? _allArtworks;
    _allOwnedArtworks = flip(_allOwnedArtworks) ?? _allOwnedArtworks;
    _allListedArtworks = flip(_allListedArtworks) ?? _allListedArtworks;
    emit(
      current.copyWith(
        artworks: flip(current.artworks),
        ownedArtworks: flip(current.ownedArtworks),
        listedArtworks: flip(current.listedArtworks),
        youOwnArtworks: flip(current.youOwnArtworks),
      ),
    );
  }

  /// Apply the group-tab name search. Purely client-side: the groups are
  /// already fully loaded, and rendering filters them by [UserProfileLoaded
  /// .groupSearch] — no refetch (unlike the artwork filter).
  void _onSetGroupSearch(
    UserProfileSetGroupSearch event,
    Emitter<UserProfileState> emit,
  ) {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;

    final query = event.query.trim();
    emit(currentState.copyWith(groupSearch: query.isEmpty ? null : query));
  }

  Future<void> _onToggleViewMode(
    UserProfileToggleViewMode event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;

    if (isArtworkListTab(currentState.activeTab)) {
      final next = currentState.artworkViewMode.next;
      await saveArtworkViewMode(next);
      emit(currentState.copyWith(artworkViewMode: next));
    } else {
      final next = currentState.groupViewMode == PortfolioViewMode.list
          ? PortfolioViewMode.grid
          : PortfolioViewMode.list;
      await saveGroupViewMode(next);
      emit(currentState.copyWith(groupViewMode: next));
    }
  }

  Future<void> _onSetSort(
    UserProfileSetSort event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;

    // Guard: content hasn't arrived yet
    if (_allArtworks.isEmpty &&
        _allOwnedArtworks.isEmpty &&
        _allListedArtworks.isEmpty &&
        _allGroups.isEmpty) {
      emit(currentState.copyWith(activeSort: event.sort));
      return;
    }

    List<PortfolioArtwork> sortArtworks(List<PortfolioArtwork> source) {
      final sorted = List<PortfolioArtwork>.of(source);
      switch (event.sort) {
        case PortfolioSortOption.name:
          sorted.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
        case PortfolioSortOption.recent:
        case PortfolioSortOption.count:
          // Keep original order from API
          break;
      }
      return sorted;
    }

    final sortedArtworks = sortArtworks(_allArtworks);
    final sortedOwned = sortArtworks(_allOwnedArtworks);
    // Untouched while the tab has never been opened, so it stays `null`
    // (shimmer) rather than becoming an empty list.
    final sortedListed = currentState.listedArtworks == null
        ? null
        : sortArtworks(_allListedArtworks);

    // Re-sort groups
    final sortedGroups = List<ArtGroup>.of(_allGroups);
    switch (event.sort) {
      case PortfolioSortOption.count:
        sortedGroups.sort((a, b) => b.artworkCount.compareTo(a.artworkCount));
      case PortfolioSortOption.name:
        sortedGroups.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case PortfolioSortOption.recent:
        break;
    }

    emit(
      currentState.copyWith(
        activeSort: event.sort,
        artworks: sortedArtworks,
        ownedArtworks: sortedOwned,
        listedArtworks: sortedListed,
        groups: sortedGroups,
      ),
    );
  }

  Future<void> _onLoadMoreArtworks(
    UserProfileLoadMoreArtworks event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;

    final addresses = _profileQueryAddresses(currentState.profile);

    if (currentState.activeTab == ProfileTab.owned) {
      if (currentState.isLoadingMoreOwned || !currentState.hasMoreOwned) return;
      if (currentState.nextOwnedPage == null) return;

      emit(currentState.copyWith(isLoadingMoreOwned: true));

      try {
        final result = await _repository.getUserArtworks(
          addresses,
          page: currentState.nextOwnedPage!,
          tab: api.ApiProfileTab.collected,
          filter: activeFilterOrNull(currentState.filter),
        );

        _allOwnedArtworks = [..._allOwnedArtworks, ...result.artworks];

        final latestState = state;
        if (latestState is! UserProfileLoaded) return;

        emit(
          latestState.copyWith(
            ownedArtworks: _allOwnedArtworks,
            isLoadingMoreOwned: false,
            hasMoreOwned: result.nextPage != null,
            nextOwnedPage: result.nextPage,
          ),
        );
      } catch (e) {
        debugPrint('[UserProfileBloc] Load more owned failed: $e');
        final latestState = state;
        if (latestState is UserProfileLoaded) {
          emit(latestState.copyWith(isLoadingMoreOwned: false));
        }
      }
      return;
    }

    if (currentState.activeTab == ProfileTab.listed) {
      // A null slice means a page-0 listed fetch is in flight (shimmer): don't
      // append a page onto a list that's about to be replaced.
      if (currentState.listedArtworks == null) return;
      if (currentState.isLoadingMoreListed || !currentState.hasMoreListed) {
        return;
      }
      if (currentState.nextListedPage == null) return;

      // Capture the generation BEFORE the await — a listed refetch bumps it.
      // A page append doesn't replace the slice, so a replacing fetch issued
      // mid-flight must drop this stale old-cursor page instead of splicing it.
      final gen = _listedGen;
      emit(currentState.copyWith(isLoadingMoreListed: true));

      try {
        final result = await _repository.getUserArtworks(
          addresses,
          page: currentState.nextListedPage!,
          tab: api.ApiProfileTab.listed,
          filter: activeFilterOrNull(currentState.filter),
        );
        if (isClosed || gen != _listedGen) return;

        _allListedArtworks = [..._allListedArtworks, ...result.artworks];

        final latestState = state;
        if (latestState is! UserProfileLoaded) return;

        emit(
          latestState.copyWith(
            listedArtworks: _allListedArtworks,
            isLoadingMoreListed: false,
            hasMoreListed: result.nextPage != null,
            nextListedPage: result.nextPage,
          ),
        );
      } catch (e) {
        debugPrint('[UserProfileBloc] Load more listed failed: $e');
        if (isClosed || gen != _listedGen) return;
        final latestState = state;
        if (latestState is UserProfileLoaded) {
          emit(latestState.copyWith(isLoadingMoreListed: false));
        }
      }
      return;
    }

    if (currentState.activeTab != ProfileTab.created) return;
    if (currentState.isLoadingMore || !currentState.hasMoreArtworks) return;
    if (currentState.nextArtworksPage == null) return;

    emit(currentState.copyWith(isLoadingMore: true));

    try {
      final result = await _repository.getUserArtworks(
        addresses,
        page: currentState.nextArtworksPage!,
        filter: activeFilterOrNull(currentState.filter),
      );

      _allArtworks = [..._allArtworks, ...result.artworks];

      final latestState = state;
      if (latestState is! UserProfileLoaded) return;

      emit(
        latestState.copyWith(
          artworks: _allArtworks,
          isLoadingMore: false,
          hasMoreArtworks: result.nextPage != null,
          nextArtworksPage: result.nextPage,
        ),
      );
    } catch (e) {
      debugPrint('[UserProfileBloc] Load more artworks failed: $e');
      final latestState = state;
      if (latestState is UserProfileLoaded) {
        emit(latestState.copyWith(isLoadingMore: false));
      }
    }
  }

  /// Apply an artwork filter. Refetches the artwork tabs (Created + Owned, and
  /// Listed once it has been opened) from page 0 so whichever is active
  /// reflects the new filter; group tabs (collections/curations) are untouched.
  Future<void> _onSetFilter(
    UserProfileSetFilter event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;

    final filterArg = activeFilterOrNull(event.filter);
    final addresses = _profileQueryAddresses(currentState.profile);

    // Only refetch Listed when the user has opened it — it's lazily loaded, so
    // an untouched tab must stay `null` and fetch with the filter on first open.
    final refetchListed = currentState.listedArtworks != null;

    // Null the artwork lists so the tabs show shimmer while refetching.
    emit(
      currentState.copyWith(
        filter: event.filter,
        artworks: null,
        ownedArtworks: null,
        listedArtworks: refetchListed ? null : currentState.listedArtworks,
        isRefreshing: true,
      ),
    );

    try {
      final results = await Future.wait([
        _repository.getUserArtworks(addresses, filter: filterArg),
        _repository.getUserArtworks(
          addresses,
          tab: api.ApiProfileTab.collected,
          filter: filterArg,
        ),
      ]);
      if (isClosed) return;

      final created = results[0];
      final owned = results[1];
      _allArtworks = created.artworks;
      _allOwnedArtworks = owned.artworks;

      final latest = state;
      if (latest is! UserProfileLoaded) return;
      emit(
        latest.copyWith(
          artworks: created.artworks,
          hasMoreArtworks: created.nextPage != null,
          nextArtworksPage: created.nextPage,
          ownedArtworks: owned.artworks,
          hasMoreOwned: owned.nextPage != null,
          nextOwnedPage: owned.nextPage,
          isRefreshing: false,
        ),
      );
      if (refetchListed) add(const UserProfileEvent.loadListedArtworks());
    } catch (e) {
      debugPrint('[UserProfileBloc] Apply filter failed: $e');
      if (isClosed) return;
      final latest = state;
      if (latest is UserProfileLoaded) {
        // Restore the pre-filter lists AND the pre-filter filter so the tabs
        // don't get stuck on shimmer and the sliders badge doesn't advertise a
        // filter the displayed (unfiltered) results don't reflect.
        emit(
          latest.copyWith(
            filter: currentState.filter,
            artworks: _allArtworks,
            ownedArtworks: _allOwnedArtworks,
            listedArtworks: refetchListed
                ? _allListedArtworks
                : latest.listedArtworks,
            isRefreshing: false,
          ),
        );
      }
    }
  }

  /// Fetch every artwork the user is about to cast, paginating beyond
  /// what's currently in state (which is only what the UI lazy-loads on
  /// scroll). Capped at [max] so we don't blow up memory or the cast
  /// queue for users with very large collections.
  ///
  /// Falls back to created artworks for the group tabs (collections /
  /// curations), mirroring [_castActiveTabArtworks] in the screen since
  /// those tabs surface groups rather than individual artworks.
  ///
  /// Side-effect: extra pages fetched here are folded into the bloc's
  /// internal `_allArtworks` / `_allOwnedArtworks` so the next on-scroll
  /// pagination tick doesn't re-fetch what we already have.
  Future<List<PortfolioArtwork>> fetchAllArtworksForActiveTab({
    int max = 1000,
  }) async {
    final s = state;
    if (s is! UserProfileLoaded) return const [];

    final tab = s.activeTab;
    final apiTab = switch (tab) {
      ProfileTab.owned => api.ApiProfileTab.collected,
      ProfileTab.listed => api.ApiProfileTab.listed,
      _ => api.ApiProfileTab.created,
    };

    final addresses = _profileQueryAddresses(s.profile);

    final accumulated = List<PortfolioArtwork>.of(switch (tab) {
      ProfileTab.owned => _allOwnedArtworks,
      ProfileTab.listed => _allListedArtworks,
      _ => _allArtworks,
    });
    int? nextPage = switch (tab) {
      ProfileTab.owned => s.nextOwnedPage,
      ProfileTab.listed => s.nextListedPage,
      _ => s.nextArtworksPage,
    };

    while (accumulated.length < max && nextPage != null) {
      try {
        final result = await _repository.getUserArtworks(
          addresses,
          page: nextPage,
          tab: apiTab,
          filter: activeFilterOrNull(s.filter),
        );
        if (result.artworks.isEmpty) break;
        accumulated.addAll(result.artworks);
        nextPage = result.nextPage;
      } catch (e) {
        debugPrint('[UserProfileBloc] Cast prefetch failed: $e');
        break;
      }
    }

    final capped = accumulated.length > max
        ? accumulated.sublist(0, max)
        : accumulated;

    switch (tab) {
      case ProfileTab.owned:
        _allOwnedArtworks = capped;
      case ProfileTab.listed:
        _allListedArtworks = capped;
      case _:
        _allArtworks = capped;
    }

    return capped;
  }

  Future<void> _onToggleFollow(
    UserProfileToggleFollow event,
    Emitter<UserProfileState> emit,
  ) async {
    final currentState = state;
    if (currentState is! UserProfileLoaded) return;
    if (_currentAddress == null) return;

    final wasFollowing = currentState.isFollowing;

    // Optimistic update — the button label *and* the follower count the
    // header is showing, matching the webapp's `useFollowUser`. Leaving the
    // count alone made a successful follow look like it did nothing.
    emit(
      currentState.copyWith(
        isFollowing: !wasFollowing,
        profile: currentState.profile.withFollowerDelta(wasFollowing ? -1 : 1),
      ),
    );

    final result = await Result.guard(() async {
      if (wasFollowing) {
        await _repository.unfollowUser(_currentAddress!);
      } else {
        await _repository.followUser(_currentAddress!);
      }
    });

    // The screen can be popped mid-request: `close` has then already closed
    // `_transientErrors`, and adding to it throws a StateError that escapes as
    // an unhandled zone error.
    if (isClosed) return;

    if (result.isFailure) {
      debugPrint(
        '[UserProfileBloc] Follow toggle failed, reverting: '
        '${result.errorOrNull?.message}',
      );
      // Revert on error — both halves of the optimistic update.
      emit(
        currentState.copyWith(
          isFollowing: wasFollowing,
          profile: currentState.profile,
        ),
      );
      // A silently reverted button is indistinguishable from a tap that never
      // registered; the webapp raises "Failed to follow" / "Failed to
      // unfollow" here and so do we.
      _transientErrors.add(
        wasFollowing ? 'Failed to unfollow' : 'Failed to follow',
      );
    }
  }
}
