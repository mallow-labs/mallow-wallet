import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart' as api;
// freezed generates an unprefixed reference to ExploreFilter's deep-copy
// helper for the `artworkFilter` field; bring just that symbol into scope so the
// generated `.freezed.dart` resolves it (the type itself stays `api.`-prefixed).
// ignore: unused_shown_name
import 'package:mallow_api/mallow_api.dart' show $ExploreFilterCopyWith;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/network/ledger_verify_controller.dart';
import '../../../core/result/result.dart';
import '../../../core/services/wallet_change_listening.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart' show Chain;
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/user_display.dart';
import '../../artwork/services/artwork_hidden_signal.dart';
import '../../artwork/services/artwork_removal_signal.dart';
import '../../curations/data/curation_repository.dart';
import '../../curations/services/curations_refresh_signal.dart';
import '../../profile/widgets/profile_filters_sheet.dart'
    show activeFilterOrNull;
import '../data/portfolio_repository.dart';
import 'portfolio_refresh_signal.dart';

part 'portfolio_bloc.freezed.dart';

/// Persisted artwork layout (`masonry` / `detail` / `grid`). Written only by
/// the artwork toggles, and deliberately separate from [groupViewModePrefsKey]:
/// before the split a single key drove both, so re-laying-out the Collections
/// tab silently re-laid-out the Artworks tab.
const artworkViewModePrefsKey = 'artwork_view_mode';

/// Persisted art-group layout (`list` / `grid`). Written only by the group-tab
/// toggles. Keeps the original key so existing users don't lose the setting.
const groupViewModePrefsKey = 'portfolio_view_mode';

/// Pre-split masonry flag. Read once by [loadArtworkViewMode] to carry a user's
/// existing artwork layout across the split, never written again.
const _legacyPrefersMasonryKey = 'portfolio_prefers_masonry';

/// Listing types that count as "listed" for the portfolio's Listed tab.
/// Mirrors `DEFAULT_LISTING_TYPES` in the backend's listing-type helper.
const listedListingTypes = <String>[
  'auction',
  'buy-now',
  'raffle',
  'jellybean',
  'gumball',
];

/// Active tab in portfolio view
enum PortfolioTab {
  /// All artworks flat list
  allArt,

  /// Flat list of session-held artworks that are currently listed — i.e. the
  /// session wallets are the SELLER. Unlike the profile screen's Listed tab
  /// this never includes art the user merely created (updateAuth) and someone
  /// else listed: the v2 portfolio read is scoped to holdings.
  listed,

  /// Grouped by artist
  artists,

  /// Grouped by collection
  collections,

  /// User's curations
  curations,
}

/// Sort option for portfolio groups/artworks
enum PortfolioSortOption {
  /// Sort by item count (default for group tabs)
  count,

  /// Sort alphabetically by name
  name,

  /// Sort by most recent (default for allArt tab)
  recent;

  /// Display name, shown both on the sort button and in the sort sheet.
  String get label => switch (this) {
    PortfolioSortOption.count => 'Count',
    PortfolioSortOption.name => 'Name',
    PortfolioSortOption.recent => 'Recent',
  };
}

/// Type of artwork grouping
enum ArtGroupType {
  /// Artworks by a specific artist (created or collected)
  artist,

  /// Artworks in a specific collection
  collection,

  /// Artworks in a curation
  curation,
}

/// Layout for art-group tabs (artists / collections / curations).
///
/// Artworks use [ArtworkViewMode] instead — the two were one enum behind one
/// preference until they were split.
enum PortfolioViewMode {
  /// Full-width rows, one group per row
  list,

  /// Grid view with 2 columns
  grid;

  /// Toggle-button icon shown while this mode is active.
  String get iconAsset => switch (this) {
    PortfolioViewMode.list => 'assets/icons/list.svg',
    PortfolioViewMode.grid => 'assets/icons/grid.svg',
  };
}

/// Layout for artwork lists, cycled by the view toggle. Shared by every artwork
/// surface: the portfolio, the profile artwork tabs, the collection, curation
/// and group-drilldown screens, and the search drilldown.
enum ArtworkViewMode {
  /// 3-column masonry at native aspect ratio, no metadata.
  masonry,

  /// Full-width cards with edition/supply, listing status and timing, title,
  /// creator and price.
  detail,

  /// 2-column grid with title and creator.
  grid;

  static ArtworkViewMode fromName(String name) => values.firstWhere(
    (mode) => mode.name == name,
    orElse: () => ArtworkViewMode.masonry,
  );

  /// Next mode in the toggle cycle: masonry → detail → grid → masonry.
  ArtworkViewMode get next => switch (this) {
    ArtworkViewMode.masonry => ArtworkViewMode.detail,
    ArtworkViewMode.detail => ArtworkViewMode.grid,
    ArtworkViewMode.grid => ArtworkViewMode.masonry,
  };

  /// Toggle-button icon shown while this mode is active.
  String get iconAsset => switch (this) {
    ArtworkViewMode.masonry => 'assets/icons/masonry.svg',
    ArtworkViewMode.detail => 'assets/icons/float.svg',
    ArtworkViewMode.grid => 'assets/icons/grid.svg',
  };
}

/// Read the persisted artwork layout, shared by every artwork surface.
///
/// Migrates on first read: before the split the layout was two values, a
/// masonry bool plus a list/grid string under what is now
/// [groupViewModePrefsKey]. Without this an existing user's layout would reset.
Future<ArtworkViewMode> loadArtworkViewMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(artworkViewModePrefsKey);
    if (stored != null) return ArtworkViewMode.fromName(stored);

    if (prefs.getBool(_legacyPrefersMasonryKey) ?? true) {
      return ArtworkViewMode.masonry;
    }
    // The legacy "list" layout is the one the detail cards replaced.
    return prefs.getString(groupViewModePrefsKey) == 'list'
        ? ArtworkViewMode.detail
        : ArtworkViewMode.grid;
  } catch (_) {
    return ArtworkViewMode.masonry;
  }
}

/// Persist the artwork layout. Best-effort: a failed write only costs the
/// layout on next launch, so callers never wait on it.
Future<void> saveArtworkViewMode(ArtworkViewMode mode) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(artworkViewModePrefsKey, mode.name);
  } catch (_) {
    // Ignore save errors
  }
}

/// Read the persisted art-group layout. Never touches [artworkViewModePrefsKey].
Future<PortfolioViewMode> loadGroupViewMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(groupViewModePrefsKey) == 'list'
        ? PortfolioViewMode.list
        : PortfolioViewMode.grid;
  } catch (_) {
    return PortfolioViewMode.grid;
  }
}

/// Persist the art-group layout. Best-effort, as [saveArtworkViewMode].
Future<void> saveGroupViewMode(PortfolioViewMode mode) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(groupViewModePrefsKey, mode.name);
  } catch (_) {
    // Ignore save errors
  }
}

/// Model for an artwork group (artist, collection, or curation)
class ArtGroup {
  const ArtGroup({
    required this.id,
    required this.type,
    required this.name,
    required this.thumbnailUrl,
    required this.artworkCount,
    this.avatarUrl,
    this.artistAddress,
    this.artistUsername,
    this.collectionMint,
    this.creatorName,
  });

  final String id;
  final ArtGroupType type;
  final String name;
  final String? thumbnailUrl;
  final int artworkCount;

  /// The artist's profile picture, for artist groups. Deliberately separate
  /// from [thumbnailUrl], which the grouped feed fills with one of the owned
  /// artworks — the drilldown header shows the artist, not a piece by them.
  final String? avatarUrl;
  final String? artistAddress;

  /// Bare artist handle for artist groups (may differ from [name] when the
  /// backend resolved a display name); lets the Artists-tab search match
  /// username as well as display name.
  final String? artistUsername;
  final String? collectionMint;
  final String? creatorName;

  /// True when [query] (already lowercased) matches this group's name — or,
  /// for artist groups, the artist's username or address. Drives the
  /// group-tab search from the filters sheet.
  bool matchesSearch(String query) {
    bool has(String? s) => s != null && s.toLowerCase().contains(query);
    return has(name) || has(artistUsername) || has(artistAddress);
  }
}

/// Model for a single artwork in the portfolio
class PortfolioArtwork {
  PortfolioArtwork({
    required this.mintAccount,
    required this.title,
    required this.imageUrl,
    required this.artistName,
    this.artistUsername,
    this.isVerified = false,
    this.isAdmin = false,
    this.collectionName,
    this.lastPrice,
    double aspectRatio = 1.0,
    this.listingType,
    this.supply,
    this.maxSupply,
    this.editionNumber,
    this.parentEdition,
    this.auctionMetadata,
    this.buyNowMetadata,
    this.raffleMetadata,
    this.animationUrl,
    this.updateAuth,
    this.playbackId,
    this.clipPlaybackId,
    this.nsfw = false,
    this.chain,
    this.tokenStandard,
    this.isHidden = false,
  }) : aspectRatio = aspectRatio > 0 ? aspectRatio : 1.0;

  final String mintAccount;
  final String title;
  final String imageUrl;
  final String artistName;

  /// Bare handle (no leading `@`), when the API returned a structured user.
  final String? artistUsername;

  /// Whether the artist has a verified badge.
  final bool isVerified;

  /// Whether the artist has the `admin` role — tints the verified badge.
  final bool isAdmin;
  final String? collectionName;
  final double? lastPrice;

  /// Original animation/video URL for animated or video NFTs.
  final String? animationUrl;

  /// Mux playback ids for inline video preview. Present on renderer-backed
  /// surfaces (curation, exhibition, explore, home, search); null on portfolio
  /// (the mobile portfolio endpoints don't hydrate Mux metadata) — those tiles
  /// fall back to the still image.
  final String? playbackId;
  final String? clipPlaybackId;

  /// Moderation flag: artwork marked not-safe-for-work. Tiles blur it unless
  /// the viewer's show-NSFW setting is on. False on surfaces whose endpoint
  /// doesn't return the flag (the mobile portfolio routes, like [playbackId]).
  final bool nsfw;

  /// Aspect ratio (width / height) for masonry layout
  final double aspectRatio;

  final api.ListingType? listingType;
  final int? supply;
  final int? maxSupply;
  final int? editionNumber;
  final String? parentEdition;
  final api.AuctionMetadata? auctionMetadata;
  final api.BuyNowMetadata? buyNowMetadata;

  /// Raffle lifecycle for a `listingType == raffle` tile. Only `endsAt` and
  /// `sold` are populated on list surfaces — enough to badge live vs
  /// draw-pending vs expired. Null when the endpoint didn't hydrate it, which
  /// the badge treats as "unknown lifecycle" rather than "expired".
  final api.RaffleMetadata? raffleMetadata;

  /// On-chain update authority address. When this matches the active wallet,
  /// the UI can optimistically show update-auth-gated actions (Edit / Burn)
  /// as disabled placeholders before the full permission check resolves.
  final String? updateAuth;

  /// Chain the asset lives on (`solana` / `ethereum` / …), when the source
  /// endpoint carries it. Drives EVM vs Solana transfer routing.
  final String? chain;

  /// Token standard wire value (`erc721` / `erc1155` / Solana standards), when
  /// known — lets the transfer flow branch without a Solana-only DAS lookup.
  final String? tokenStandard;

  /// True when the requesting owner has hidden this artwork from their profile.
  /// Only meaningful when the viewer owns the artwork — drives the corner
  /// "hidden" badge and the hide/unhide menu row's state.
  final bool isHidden;

  /// Copy with [collectionName] filled from the surrounding screen's context.
  /// Collection drilldowns know which collection they're showing, but their
  /// wire rows don't carry the name — this backfills it without overriding a
  /// name the API did provide.
  PortfolioArtwork withCollectionName(String name) {
    if (collectionName != null || name.isEmpty) return this;
    return PortfolioArtwork(
      mintAccount: mintAccount,
      title: title,
      imageUrl: imageUrl,
      artistName: artistName,
      artistUsername: artistUsername,
      isVerified: isVerified,
      isAdmin: isAdmin,
      collectionName: name,
      lastPrice: lastPrice,
      aspectRatio: aspectRatio,
      listingType: listingType,
      supply: supply,
      maxSupply: maxSupply,
      editionNumber: editionNumber,
      parentEdition: parentEdition,
      auctionMetadata: auctionMetadata,
      buyNowMetadata: buyNowMetadata,
      raffleMetadata: raffleMetadata,
      animationUrl: animationUrl,
      updateAuth: updateAuth,
      playbackId: playbackId,
      clipPlaybackId: clipPlaybackId,
      nsfw: nsfw,
      chain: chain,
      tokenStandard: tokenStandard,
      isHidden: isHidden,
    );
  }

  /// Targeted copy flipping only [isHidden] — used for the optimistic
  /// hide/unhide update fired via [ArtworkHiddenSignal].
  PortfolioArtwork copyWithHidden(bool isHidden) {
    if (isHidden == this.isHidden) return this;
    return PortfolioArtwork(
      mintAccount: mintAccount,
      title: title,
      imageUrl: imageUrl,
      artistName: artistName,
      artistUsername: artistUsername,
      isVerified: isVerified,
      isAdmin: isAdmin,
      collectionName: collectionName,
      lastPrice: lastPrice,
      aspectRatio: aspectRatio,
      listingType: listingType,
      supply: supply,
      maxSupply: maxSupply,
      editionNumber: editionNumber,
      parentEdition: parentEdition,
      auctionMetadata: auctionMetadata,
      buyNowMetadata: buyNowMetadata,
      raffleMetadata: raffleMetadata,
      animationUrl: animationUrl,
      updateAuth: updateAuth,
      playbackId: playbackId,
      clipPlaybackId: clipPlaybackId,
      nsfw: nsfw,
      chain: chain,
      tokenStandard: tokenStandard,
      isHidden: isHidden,
    );
  }

  /// Supply label matching the reference web client getSupplyTypeTitle logic.
  String get supplyLabel {
    if (parentEdition != null) {
      return editionNumber != null
          ? 'Edition print #$editionNumber'
          : 'Edition print';
    }
    if (maxSupply == null) return 'Open edition';
    if (maxSupply! <= 1) return '1/1 artwork';
    return 'Limited edition of $maxSupply';
  }

  /// True for open/limited editions that can have prints (not 1/1, not edition prints).
  bool get isPrintable =>
      parentEdition == null && (maxSupply == null || maxSupply! > 1);

  /// True when this is a limited edition (maxSupply > 1).
  bool get isLimitedEdition => maxSupply != null && maxSupply! > 1;

  /// Prints still available on a limited edition — what separates
  /// "N / M sold" from "Sold out".
  ///
  /// `maxSupply - supply` is a **Solana-only** derivation: it reads the
  /// Metaplex master-edition supply counter, which off-Solana is either absent
  /// or a mirror of total minted rather than of this listing. The webapp
  /// refuses to trust it off-chain-of-Solana and reads the listing's own
  /// `quantityLeft` instead; mobile applied
  /// the Solana arm everywhere, so an ETH edition with prints left read
  /// "Sold out" (or vice versa).
  ///
  /// An absent [chain] is treated as Solana — every mobile surface that
  /// renders this is Solana unless the endpoint says otherwise, and the
  /// webapp's own `!== Chain.Solana` test never sees a null in practice.
  int get _editionsAvailable {
    final isSolana = chain == null || Chain.tryParse(chain) == Chain.solana;
    if (!isSolana) return buyNowMetadata?.quantityLeft ?? 0;
    return (maxSupply ?? 0) - (supply ?? 0);
  }

  /// Sold count label matching React ArtworkCard logic.
  /// Returns null when no count should be shown.
  String? get soldCountLabel {
    if (!isPrintable) return null;
    if (listingType == null || listingType == api.ListingType.unlisted) {
      return null;
    }
    final now = DateTime.now().toUtc();
    // Hide count while listing is pending start
    if (buyNowMetadata?.startsAt != null &&
        buyNowMetadata!.startsAt!.isAfter(now)) {
      return null;
    }
    if (auctionMetadata?.startsAt != null &&
        auctionMetadata!.startsAt!.isAfter(now)) {
      return null;
    }
    // Counts are thousands-grouped, matching the webapp's `.toLocaleString()`
    // (`ArtworkCardMetadata`) — an open edition with 1234 prints
    // reads "1,234 sold".
    if (!isLimitedEdition) {
      return '${formatCount(supply ?? 0)} sold';
    }
    final editionsAvailable = _editionsAvailable;
    if (editionsAvailable > 0) {
      return '${formatCount(supply ?? 0)} / ${formatCount(maxSupply ?? 0)} sold';
    }
    return 'Sold out';
  }

  /// Formatted active-listing price for display. Returns the live auction or
  /// buy-now price; empty string when the artwork is not actively listed.
  /// Does NOT fall back to last sale price — an unlisted artwork shows nothing.
  ///
  /// A listed artwork's price slot always carries a word where the number
  /// would mislead, matching the webapp's `PriceDisplay` under `fullSYOP`
  /// (`ArtworkCardMetadata`): a "set your own price" listing has
  /// an on-chain price of 0 and a free mint really is free, so neither may
  /// render as "0 SOL".
  String get displayPrice {
    if (listingType == api.ListingType.auction && auctionMetadata != null) {
      final amount =
          auctionMetadata!.currentBidAmount ?? auctionMetadata!.reservePrice;
      return PriceFormatter.formatRawAmountWithSymbol(
        amount,
        auctionMetadata!.bidMint,
        chain: chain,
      );
    }
    if (listingType == api.ListingType.buyNow && buyNowMetadata != null) {
      return PriceFormatter.formatListingPrice(
        // Webapp `listingStateDerivation` reads a missing amount as 0
        // ("Free"), not as "no listing".
        buyNowMetadata!.amount ?? 0,
        buyNowMetadata!.currencyMint,
        chain: chain,
        buyerSetsPrice: buyNowMetadata!.buyerSetsPrice,
      );
    }
    return '';
  }
}

/// Events for portfolio screen
@freezed
sealed class PortfolioEvent with _$PortfolioEvent {
  /// Load portfolio data
  const factory PortfolioEvent.load() = PortfolioLoad;

  /// Refresh portfolio data
  const factory PortfolioEvent.refresh() = PortfolioRefresh;

  /// Apply the artwork filters sheet ([api.ExploreFilter]) to the owned-artwork
  /// list — refetches the flat "Artworks" list server-side.
  const factory PortfolioEvent.setArtworkFilter({
    required api.ExploreFilter filter,
  }) = PortfolioSetArtworkFilter;

  /// Apply the group-tab name search (Artists / Collections / Curations) from
  /// the filters sheet. Filters the loaded groups client-side; an empty query
  /// clears the search.
  const factory PortfolioEvent.setGroupSearch({required String query}) =
      PortfolioSetGroupSearch;

  /// Load next page of artworks for the "All art" flat list (infinite scroll)
  const factory PortfolioEvent.loadMoreAllArtworks() =
      PortfolioLoadMoreAllArtworks;

  /// Fetch page 0 of the Listed tab. Dispatched the first time the tab is
  /// opened (it isn't part of the initial parallel load) and again on refresh
  /// / filter change once it has been loaded.
  const factory PortfolioEvent.loadListedArtworks() =
      PortfolioLoadListedArtworks;

  /// Load next page of the Listed tab (infinite scroll)
  const factory PortfolioEvent.loadMoreListedArtworks() =
      PortfolioLoadMoreListedArtworks;

  /// Change active tab (null = deselect, show all groups)
  const factory PortfolioEvent.changeTab({PortfolioTab? tab}) =
      PortfolioChangeTab;

  /// Toggle between list and grid view
  const factory PortfolioEvent.toggleViewMode() = PortfolioToggleViewMode;

  /// Set sort option
  const factory PortfolioEvent.setSort({required PortfolioSortOption sort}) =
      PortfolioSetSort;

  /// Sign in with the active wallet to unlock private curations (Ledger).
  const factory PortfolioEvent.verifyForPrivateCurations() =
      PortfolioVerifyForPrivateCurations;

  /// Refetch only the curation groups (curations changed or the auth
  /// session switched) — the rest of the portfolio is untouched.
  const factory PortfolioEvent.refreshCurations() = PortfolioRefreshCurations;

  /// Optimistically drop [mintAccount] from the flat owned-art list the instant
  /// a transfer/burn confirms (via the app-wide [ArtworkRemovalSignal]), before
  /// the reindex refetch lands.
  const factory PortfolioEvent.artworkRemoved(String mintAccount) =
      PortfolioArtworkRemoved;

  /// Optimistically flip [mintAccount]'s hidden badge the instant the
  /// `/v0/hide` write returns (via the app-wide [ArtworkHiddenSignal]).
  const factory PortfolioEvent.artworkHidden(
    String mintAccount, {
    required bool isHidden,
  }) = PortfolioArtworkHidden;
}

/// States for portfolio screen
@freezed
sealed class PortfolioState with _$PortfolioState {
  /// Initial state
  const factory PortfolioState.initial({
    @Default(ArtworkViewMode.masonry) ArtworkViewMode artworkViewMode,
    @Default(PortfolioViewMode.grid) PortfolioViewMode groupViewMode,
  }) = PortfolioInitial;

  /// Loading state
  const factory PortfolioState.loading({
    @Default(ArtworkViewMode.masonry) ArtworkViewMode artworkViewMode,
    @Default(PortfolioViewMode.grid) PortfolioViewMode groupViewMode,
  }) = PortfolioLoading;

  /// Loaded state with grouped artworks
  const factory PortfolioState.loaded({
    required List<ArtGroup> groups,
    required int totalArtworks,

    /// Active artwork filters (the profile-style filters sheet) applied to the
    /// flat "Artworks" list. Null when no filtering is active.
    api.ExploreFilter? artworkFilter,

    /// Active name-search query on the group tabs (null = none). Applied
    /// client-side to [groups]; cleared on tab change since each tab searches
    /// a different name space.
    String? groupSearch,
    PortfolioTab? activeTab,
    @Default(ArtworkViewMode.masonry) ArtworkViewMode artworkViewMode,
    @Default(PortfolioViewMode.grid) PortfolioViewMode groupViewMode,
    @Default(PortfolioSortOption.recent) PortfolioSortOption activeSort,
    @Default([]) List<PortfolioArtwork> allArtworks,
    @Default(false) bool isLoadingMoreAllArt,
    @Default(true) bool hasMoreAllArt,
    int? nextAllArtPage,

    /// Session-held artworks that are currently listed. Lazily fetched the
    /// first time the Listed tab is opened — `null` until then (shimmer).
    List<PortfolioArtwork>? listedArtworks,
    @Default(false) bool isLoadingMoreListed,
    @Default(true) bool hasMoreListed,
    int? nextListedPage,

    /// True while a refresh refetch (pull-to-refresh or the global refresh
    /// signal) is in flight.
    @Default(false) bool isRefreshing,

    /// True when the active wallet is a Ledger without a valid signed-login
    /// session, so private curations are hidden until the user verifies.
    @Default(false) bool showVerifyPrivateCurationsCta,

    /// True while the Ledger verification flow is in-flight.
    @Default(false) bool isVerifyingCurations,
  }) = PortfolioLoaded;

  /// Error state
  const factory PortfolioState.error({required String message}) =
      PortfolioError;
}

/// Bloc for portfolio screen.
///
/// Fetches portfolio data from the API via [PortfolioRepository].
///
/// Concurrency rules (bloc's default event transformer runs handlers
/// concurrently, so fetches overlap with each other and with synchronous
/// selection events like [PortfolioChangeTab]):
///
/// 1. No emit after an `await` may be based on a state snapshot captured
///    before it — always re-read [state] and write only the fields the
///    handler owns, so a chip/tab/sort/view change made mid-fetch survives.
/// 2. Server data lives in per-fetch slices guarded by generation counters:
///    a fetch bumps its slice's counter when it starts and discards its
///    response if the counter moved, so the newest *issued* fetch always
///    wins regardless of network completion order.
@injectable
class PortfolioBloc extends Bloc<PortfolioEvent, PortfolioState>
    with WalletChangeListening<PortfolioEvent, PortfolioState> {
  PortfolioBloc(
    this._repository,
    this._curationRepository,
    this._authService,
    this._ledgerVerifyController,
    this.walletManager,
  ) : super(const PortfolioState.initial()) {
    on<PortfolioLoad>(_onLoad);
    on<PortfolioRefresh>(_onRefresh);
    on<PortfolioSetArtworkFilter>(_onSetArtworkFilter);
    on<PortfolioSetGroupSearch>(_onSetGroupSearch);
    on<PortfolioLoadMoreAllArtworks>(_onLoadMoreAllArtworks);
    on<PortfolioLoadListedArtworks>(_onLoadListedArtworks);
    on<PortfolioLoadMoreListedArtworks>(_onLoadMoreListedArtworks);
    on<PortfolioChangeTab>(_onChangeTab);
    on<PortfolioToggleViewMode>(_onToggleViewMode);
    on<PortfolioSetSort>(_onSetSort);
    on<PortfolioVerifyForPrivateCurations>(_onVerifyForPrivateCurations);
    on<PortfolioRefreshCurations>(_onRefreshCurations);
    on<PortfolioArtworkRemoved>(_onArtworkRemoved);
    on<PortfolioArtworkHidden>(_onArtworkHidden);

    startWalletChangeListening();

    // Refetch when an add/edit/remove action elsewhere (buy, mint, edit,
    // list, transfer, burn, sale) reports its indexer ack — the My Art tab
    // stays mounted under the pushed detail/flow route, so this keeps it in
    // sync without the user manually pulling to refresh. Guarded so unit
    // tests that don't bootstrap DI simply skip the subscription.
    if (sl.isRegistered<PortfolioRefreshSignal>()) {
      _refreshSignalSub = sl<PortfolioRefreshSignal>().stream.listen(
        (_) => add(const PortfolioEvent.refresh()),
      );
    }

    // A transfer/burn removes an owned artwork from the session immediately —
    // drop it from the flat list on the spot instead of waiting for the
    // reindex refetch the refresh signal above fires seconds later.
    if (sl.isRegistered<ArtworkRemovalSignal>()) {
      _removalSignalSub = sl<ArtworkRemovalSignal>().stream.listen(
        (mint) => add(PortfolioEvent.artworkRemoved(mint)),
      );
    }

    // Hide/unhide flips the flat list's badge on the spot; the delayed reindex
    // refetch reconciles the server's `isOwnerHidden` afterwards.
    if (sl.isRegistered<ArtworkHiddenSignal>()) {
      _hiddenSignalSub = sl<ArtworkHiddenSignal>().stream.listen(
        (change) => add(
          PortfolioEvent.artworkHidden(
            change.mintAccount,
            isHidden: change.isHidden,
          ),
        ),
      );
    }

    // Curation mutations (create/rename/visibility/add/remove artwork) only
    // invalidate the curation groups — refetch those alone instead of the
    // whole portfolio.
    if (sl.isRegistered<CurationsRefreshSignal>()) {
      _curationsSignalSub = sl<CurationsRefreshSignal>().stream.listen(
        (_) => add(const PortfolioEvent.refreshCurations()),
      );
    }

    // getCurations() is authenticated by the login-token cookie, and the
    // full reload fired by onWalletChanged races the app-level re-login —
    // so it can fetch the *previous* user's curations. Refetch curations
    // once the new session actually lands (AuthService notifies after a
    // successful login with the session address updated); the generation
    // counter makes that later-issued fetch win over the load's raced one.
    _lastSessionAddress = _authService.currentAddress;
    _authService.addListener(_onAuthSessionChanged);
  }

  final PortfolioRepository _repository;
  final CurationRepository _curationRepository;
  final AuthService _authService;
  final LedgerVerifyController _ledgerVerifyController;

  StreamSubscription<void>? _refreshSignalSub;
  StreamSubscription<void>? _curationsSignalSub;
  StreamSubscription<String>? _removalSignalSub;
  StreamSubscription<ArtworkHiddenChange>? _hiddenSignalSub;
  String? _lastSessionAddress;

  @override
  final WalletManager walletManager;

  @override
  void onWalletChanged() => add(const PortfolioEvent.load());

  void _onAuthSessionChanged() {
    final address = _authService.currentAddress;
    // Only react to a completed login for a different user — AuthService
    // also notifies on loading/error/logout, where address is unchanged or
    // null (logout is followed by a wallet change that reloads everything).
    if (address == null || address == _lastSessionAddress) return;
    _lastSessionAddress = address;
    add(const PortfolioEvent.refreshCurations());
  }

  @override
  Future<void> close() {
    _refreshSignalSub?.cancel();
    _curationsSignalSub?.cancel();
    _removalSignalSub?.cancel();
    _hiddenSignalSub?.cancel();
    _authService.removeListener(_onAuthSessionChanged);
    return super.close();
  }

  // Server data, split into slices by fetch ownership so concurrent fetches
  // can never clobber each other: the portfolio fetches (load / refresh /
  // filter) own the artworks and artist/collection groups; the curation
  // fetches (load / refresh / refreshCurations / verify) own the curation
  // groups.
  List<PortfolioArtwork> _allArtworks = [];
  List<PortfolioArtwork> _listedArtworks = [];
  List<ArtGroup> _portfolioGroups = [];
  List<ArtGroup> _curationGroups = [];

  List<ArtGroup> get _allGroups => [..._portfolioGroups, ..._curationGroups];

  /// The active server-side artwork filter, threaded into every owned-artwork
  /// fetch (initial load, refresh, pagination) so they stay consistent. Null
  /// means unfiltered. `PortfolioLoaded.artworkFilter` mirrors it for the UI.
  api.ExploreFilter? _artworkFilter;

  /// The ordering the artwork slices were fetched with, threaded into every
  /// owned-artwork fetch alongside [_artworkFilter] — a page fetched under a
  /// different ordering would splice into a list it was never ranked against.
  ///
  /// Distinct from `PortfolioLoaded.activeSort`, which also drives the group
  /// tabs: the artwork route serves `recent`/`name`, `count` is a group-only
  /// option, and the group tabs re-sort in memory rather than refetching. The
  /// two agree whenever an artwork tab is on screen — [_onSetSort] reloads on a
  /// pick made there, and [_onChangeTab] reloads on the way back in.
  PortfolioSortOption _artworkSort = PortfolioSortOption.recent;

  /// The active group-tab name search, applied inside [_filterGroups] so every
  /// recompute of the groups list (sort, tab, curation refresh) preserves it.
  /// Null means no search. `PortfolioLoaded.groupSearch` mirrors it.
  String? _groupSearch;

  // Stale-response guards (see the class doc). Bumped when a fetch that
  // REPLACES the slice starts; compared after its await.
  int _artworksGen = 0;
  int _curationsGen = 0;
  int _listedGen = 0;

  /// The filter for the Listed slice: the active artwork filter narrowed to
  /// listed artworks. The filter object is shared across tabs and the filters
  /// sheet offers an 'unlisted' option, so a listing-type selection made on
  /// another tab can contain 'unlisted' (or any non-listed type). Intersect the
  /// user's picks with [listedListingTypes] so the Listed tab can never fetch
  /// unlisted artworks; when nothing the user picked is a listed type (or they
  /// picked none), fall back to the full listed set.
  api.ExploreFilter _listedFilter() {
    final base = _artworkFilter ?? const api.ExploreFilter();
    final picked = base.listingTypes
        .where(listedListingTypes.contains)
        .toList();
    return base.copyWith(
      listingTypes: picked.isEmpty ? listedListingTypes : picked,
    );
  }

  /// The single constructor for a full-data loaded emit. It rebases on the
  /// CURRENT state at emit time — never a pre-await snapshot — so tab/sort/
  /// view selection changed while the fetch was in flight is preserved. The
  /// fallbacks only apply when no loaded state is on screen yet.
  PortfolioState _freshLoadedState(
    PortfolioArtworksResult artworks, {
    ArtworkViewMode fallbackArtworkViewMode = ArtworkViewMode.masonry,
    PortfolioViewMode fallbackGroupViewMode = PortfolioViewMode.grid,
    bool isRefreshing = false,
    bool showVerifyPrivateCurationsCta = false,
    bool resetListed = false,
  }) {
    final current = state;
    final loaded = current is PortfolioLoaded ? current : null;
    final activeTab = loaded?.activeTab;
    final activeSort = loaded?.activeSort ?? PortfolioSortOption.count;

    return PortfolioState.loaded(
      groups: _filterGroups(_allGroups, _tabToFilter(activeTab), activeSort),
      totalArtworks: artworks.total,
      artworkViewMode: loaded?.artworkViewMode ?? fallbackArtworkViewMode,
      groupViewMode: loaded?.groupViewMode ?? fallbackGroupViewMode,
      artworkFilter: _artworkFilter,
      groupSearch: _groupSearch,
      activeTab: activeTab,
      activeSort: activeSort,
      allArtworks: _allArtworks,
      hasMoreAllArt: artworks.nextPage != null,
      nextAllArtPage: artworks.nextPage,
      // The Listed slice is fetched by its own handler — carry whatever it has
      // (including "never opened" = null) across a full-data emit.
      listedArtworks: resetListed ? null : loaded?.listedArtworks,
      hasMoreListed: resetListed ? true : (loaded?.hasMoreListed ?? true),
      nextListedPage: resetListed ? null : loaded?.nextListedPage,
      isRefreshing: isRefreshing,
      showVerifyPrivateCurationsCta: showVerifyPrivateCurationsCta,
    );
  }

  Future<void> _onLoad(
    PortfolioLoad event,
    Emitter<PortfolioState> emit,
  ) async {
    final artworkViewMode = await loadArtworkViewMode();
    final groupViewMode = await loadGroupViewMode();

    // A full load can follow a wallet/session change, so the previous
    // session's Listed slice must not survive it — drop it and let the tab
    // refetch (below) if it's the one on screen.
    _listedArtworks = const [];
    ++_listedGen;

    // 1. Serve this session's cached snapshot immediately for an instant
    //    paint; fall back to the skeleton only when no cache exists yet.
    //    Cache failures are non-fatal — skip straight to the fresh fetch.
    //    Curations aren't cached; they splice in when a curation fetch lands.
    PortfolioSnapshot? cached;
    try {
      cached = await _repository.getCachedSnapshot();
    } catch (e) {
      debugPrint('[PortfolioBloc] Portfolio cache read failed: $e');
    }
    if (isClosed) return;

    if (cached != null) {
      _allArtworks = cached.artworks.artworks;
      _portfolioGroups = [
        for (final g in cached.groups.groups)
          if (g.type != ArtGroupType.curation) g,
      ];
      _curationGroups = [
        for (final g in cached.groups.groups)
          if (g.type == ArtGroupType.curation) g,
      ];
      emit(
        _freshLoadedState(
          cached.artworks,
          fallbackArtworkViewMode: artworkViewMode,
          fallbackGroupViewMode: groupViewMode,
          isRefreshing: true,
          resetListed: true,
        ),
      );
    } else {
      emit(
        PortfolioState.loading(
          artworkViewMode: artworkViewMode,
          groupViewMode: groupViewMode,
        ),
      );
    }

    // 2. Fresh fetch. The repository persists the raw responses as a side
    //    effect for the next load's instant paint.
    await _fetchAndEmitAll(
      emit,
      fallbackArtworkViewMode: artworkViewMode,
      fallbackGroupViewMode: groupViewMode,
      failureLabel: 'Failed to load portfolio',
      resetListed: true,
    );

    // Refetch the (just-cleared) Listed slice when it's the tab on screen.
    final loaded = state;
    if (loaded is PortfolioLoaded && loaded.activeTab == PortfolioTab.listed) {
      add(const PortfolioEvent.loadListedArtworks());
    }
  }

  Future<void> _onRefresh(
    PortfolioRefresh event,
    Emitter<PortfolioState> emit,
  ) async {
    final currentState = state;
    if (currentState is PortfolioLoaded) {
      emit(currentState.copyWith(isRefreshing: true));
    }
    await _fetchAndEmitAll(emit, failureLabel: 'Failed to refresh');

    // The Listed slice has its own fetch — refresh it too, but only once the
    // user has opened the tab (it's lazily loaded).
    final loaded = state;
    if (loaded is PortfolioLoaded && loaded.listedArtworks != null) {
      _resetListedCursorAndRefetch(loaded, emit);
    }
  }

  /// Zero the Listed slice's pagination cursor, then dispatch a page-0 refetch.
  /// A listed refetch ([_onLoadListedArtworks]) bumps `_listedGen`, so a
  /// load-more that fires between this dispatch and the page-0 replacement would
  /// otherwise capture the already-bumped generation, fetch the stale cursor
  /// with the new filter, and splice its result onto the freshly replaced list.
  /// Zeroing `hasMoreListed`/`nextListedPage` first makes any such load-more
  /// bail — the same guard the allArt slice applies before its refetch (see the
  /// pagination reset in `_onSetArtworkFilter`). The page-0 fetch restores the
  /// real cursor when it lands.
  void _resetListedCursorAndRefetch(
    PortfolioLoaded current,
    Emitter<PortfolioState> emit,
  ) {
    emit(current.copyWith(hasMoreListed: false, nextListedPage: null));
    add(const PortfolioEvent.loadListedArtworks());
  }

  /// Fetch artworks, artist/collection groups, curations, and the Ledger
  /// verify CTA in parallel, store whatever wasn't superseded by a newer
  /// fetch, and emit one fresh loaded state. Shared by load and refresh so
  /// the two paths cannot drift.
  Future<void> _fetchAndEmitAll(
    Emitter<PortfolioState> emit, {
    required String failureLabel,
    ArtworkViewMode fallbackArtworkViewMode = ArtworkViewMode.masonry,
    PortfolioViewMode fallbackGroupViewMode = PortfolioViewMode.grid,
    bool resetListed = false,
  }) async {
    final artworksGen = ++_artworksGen;
    final curationsGen = ++_curationsGen;

    final result = await Result.guard(
      () => Future.wait<Object>([
        _repository.getOwnedArtworks(
          filter: _artworkFilter,
          sort: _artworkSort,
        ),
        _repository.getGroupedPortfolio(),
        _fetchCurationGroups(),
        // Ledger wallets without a signed-login session only get public
        // curations from the backend — surface the "verify" CTA so the user
        // can unlock private ones.
        _needsCurationVerification(),
      ]),
    );
    if (isClosed) return;

    switch (result) {
      case ResultSuccess(:final value):
        // A curation-only fetch issued mid-flight (e.g. the post-switch
        // re-login) owns the curation slice now — keep its result.
        if (curationsGen == _curationsGen) {
          _curationGroups = value[2] as List<ArtGroup>;
        }
        // A newer full/filter fetch supersedes this one entirely; it emits.
        if (artworksGen != _artworksGen) return;
        final artworksResult = value[0] as PortfolioArtworksResult;
        _allArtworks = artworksResult.artworks;
        _portfolioGroups = (value[1] as PortfolioGroupsResult).groups;
        emit(
          _freshLoadedState(
            artworksResult,
            fallbackArtworkViewMode: fallbackArtworkViewMode,
            fallbackGroupViewMode: fallbackGroupViewMode,
            showVerifyPrivateCurationsCta: value[3] as bool,
            resetListed: resetListed,
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[PortfolioBloc] $failureLabel: ${error.message}');
        if (artworksGen != _artworksGen) return;
        final current = state;
        if (current is PortfolioLoaded) {
          // Keep what's on screen (cached paint or previous data); just stop
          // the refresh indicator.
          emit(current.copyWith(isRefreshing: false));
        } else {
          emit(
            PortfolioState.error(message: '$failureLabel: ${error.message}'),
          );
        }
    }
  }

  /// Apply the artwork filters sheet to the flat "Artworks" list. Refetches
  /// page 0 with the filter server-side; on failure the pre-filter list and
  /// filter are restored so the tab isn't left blank.
  Future<void> _onSetArtworkFilter(
    PortfolioSetArtworkFilter event,
    Emitter<PortfolioState> emit,
  ) =>
      // Normalize an all-empty filter to null so caching/badge treat it as
      // "cleared" and page-0 caching resumes for the default portfolio.
      _reloadArtworks(activeFilterOrNull(event.filter), _artworkSort, emit);

  /// Refetch page 0 of both artwork slices under a new [filter] / [sort].
  ///
  /// Shared by the filters sheet and the sort sheet because the two are the
  /// same operation: the query changed server-side, so every page the client
  /// holds is stale. On failure the previous query AND its results are restored
  /// together — a list left under a label it wasn't fetched for is worse than
  /// the error.
  Future<void> _reloadArtworks(
    api.ExploreFilter? filter,
    PortfolioSortOption sort,
    Emitter<PortfolioState> emit,
  ) async {
    final currentState = state;
    if (currentState is! PortfolioLoaded) return;

    final previousArtworks = _allArtworks;
    final previousFilter = _artworkFilter;
    final previousSort = _artworkSort;
    // Snapshot pagination too — the shimmer emit resets it, so the failure
    // rollback must restore the cursor or the pre-filter list comes back with
    // infinite scroll dead until a full refresh.
    final previousHasMore = currentState.hasMoreAllArt;
    final previousNextPage = currentState.nextAllArtPage;
    _artworkFilter = filter;
    _artworkSort = sort;
    final gen = ++_artworksGen;

    // Show the shimmer while the filtered page loads. Reset pagination to the
    // fresh-load baseline and clear the backing list: the collapsed list fires
    // the scroll listener, and leaving the stale cursor/`hasMoreAllArt` in
    // place would let a concurrent load-more fetch the pre-filter page with the
    // new filter and splice it onto the never-cleared `_allArtworks`.
    _allArtworks = const [];
    emit(
      currentState.copyWith(
        allArtworks: const [],
        artworkFilter: filter,
        isRefreshing: true,
        hasMoreAllArt: false,
        nextAllArtPage: null,
      ),
    );

    final result = await Result.guard(
      () => _repository.getOwnedArtworks(filter: filter, sort: sort),
    );
    // Superseded by a newer fetch (another filter, a reload, a refresh) —
    // that fetch owns the list and the emit.
    if (isClosed || gen != _artworksGen) return;
    final latest = state;
    if (latest is! PortfolioLoaded) return;

    switch (result) {
      case ResultSuccess(:final value):
        _allArtworks = value.artworks;
        emit(
          latest.copyWith(
            allArtworks: _allArtworks,
            artworkFilter: filter,
            totalArtworks: value.total,
            hasMoreAllArt: value.nextPage != null,
            nextAllArtPage: value.nextPage,
            isLoadingMoreAllArt: false,
            isRefreshing: false,
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[PortfolioBloc] Reload artworks failed: ${error.message}');
        // Restore the pre-filter list, filter, and pagination snapshot so the
        // tab isn't left blank and its infinite scroll still works.
        _artworkFilter = previousFilter;
        _artworkSort = previousSort;
        _allArtworks = previousArtworks;
        emit(
          latest.copyWith(
            allArtworks: previousArtworks,
            artworkFilter: previousFilter,
            // The sort sheet's label has already flipped to the ordering that
            // failed to load; put it back so it names the list on screen.
            activeSort: previousSort,
            groups: _filterGroups(
              _allGroups,
              _tabToFilter(latest.activeTab),
              previousSort,
            ),
            hasMoreAllArt: previousHasMore,
            nextAllArtPage: previousNextPage,
            isRefreshing: false,
            // The shimmer emit above may have collapsed the list and fired a
            // load-more whose own cleanup bails on the generation bump — clear
            // the flag here so pagination isn't wedged after a filter failure.
            isLoadingMoreAllArt: false,
          ),
        );
    }

    // The Listed slice narrows the same filter — refetch it (with whichever
    // filter ended up applied above) once the user has opened the tab. The
    // previous page stays on screen until it lands rather than flashing empty.
    final settled = state;
    if (settled is PortfolioLoaded && settled.listedArtworks != null) {
      _resetListedCursorAndRefetch(settled, emit);
    }
  }

  /// Fetch page 0 of the Listed tab: the session's held artworks narrowed to
  /// the listed listing types, so the session wallet is the seller. Failures
  /// settle on an empty list rather than an endless shimmer.
  Future<void> _onLoadListedArtworks(
    PortfolioLoadListedArtworks event,
    Emitter<PortfolioState> emit,
  ) async {
    final gen = ++_listedGen;
    final result = await Result.guard(
      () => _repository.getOwnedArtworks(
        filter: _listedFilter(),
        sort: _artworkSort,
      ),
    );
    // Superseded by a newer listed fetch (tab reopen, refresh, filter change).
    if (isClosed || gen != _listedGen) return;
    final latest = state;
    if (latest is! PortfolioLoaded) return;

    switch (result) {
      case ResultSuccess(:final value):
        _listedArtworks = value.artworks;
        emit(
          latest.copyWith(
            listedArtworks: _listedArtworks,
            isLoadingMoreListed: false,
            hasMoreListed: value.nextPage != null,
            nextListedPage: value.nextPage,
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[PortfolioBloc] Load listed failed: ${error.message}');
        // Keep whatever is already on screen (a previously loaded page, or the
        // empty list on a first-open failure) and just stop the loading
        // indicator — mirroring the allArt refresh failure, which leaves the
        // list and its pagination cursor untouched. Critically the mirror must
        // track the emitted list: a later hidden/removal signal emits
        // `_listedArtworks`, so a desync here would silently wipe the visible
        // Listed tab. Leave hasMoreListed/nextListedPage as-is so the
        // still-displayed list keeps its pagination.
        final kept = latest.listedArtworks ?? const <PortfolioArtwork>[];
        _listedArtworks = kept;
        emit(latest.copyWith(listedArtworks: kept, isLoadingMoreListed: false));
    }
  }

  Future<void> _onLoadMoreListedArtworks(
    PortfolioLoadMoreListedArtworks event,
    Emitter<PortfolioState> emit,
  ) async {
    final currentState = state;
    if (currentState is! PortfolioLoaded) return;
    if (currentState.activeTab != PortfolioTab.listed) return;
    if (currentState.listedArtworks == null) return;
    if (currentState.isLoadingMoreListed || !currentState.hasMoreListed) return;
    final nextPage = currentState.nextListedPage;
    if (nextPage == null) return;

    // Captured, not bumped: a page append doesn't replace the slice, so a
    // replacing fetch issued mid-flight must drop this page.
    final gen = _listedGen;
    emit(currentState.copyWith(isLoadingMoreListed: true));

    final result = await Result.guard(
      () => _repository.getOwnedArtworks(
        page: nextPage,
        filter: _listedFilter(),
        sort: _artworkSort,
      ),
    );
    if (isClosed || gen != _listedGen) return;
    final latest = state;
    if (latest is! PortfolioLoaded) return;

    switch (result) {
      case ResultSuccess(:final value):
        _listedArtworks = [..._listedArtworks, ...value.artworks];
        emit(
          latest.copyWith(
            listedArtworks: _listedArtworks,
            isLoadingMoreListed: false,
            hasMoreListed: value.nextPage != null,
            nextListedPage: value.nextPage,
          ),
        );
      case ResultFailure(:final error):
        debugPrint('[PortfolioBloc] Load more listed failed: ${error.message}');
        emit(latest.copyWith(isLoadingMoreListed: false));
    }
  }

  Future<void> _onLoadMoreAllArtworks(
    PortfolioLoadMoreAllArtworks event,
    Emitter<PortfolioState> emit,
  ) async {
    final currentState = state;
    if (currentState is! PortfolioLoaded) return;
    // Pagination only applies to the flat Artworks tab.
    if (currentState.activeTab != PortfolioTab.allArt) return;
    // A filter refetch in flight has collapsed the list and reset pagination —
    // don't page against the stale/pre-filter cursor while it lands.
    if (currentState.isRefreshing) return;
    if (currentState.isLoadingMoreAllArt || !currentState.hasMoreAllArt) return;
    final nextPage = currentState.nextAllArtPage;
    if (nextPage == null) return;

    // Captured, not bumped: a page append doesn't replace the list, but the
    // page belongs to the list as of now — if a filter/reload replaces it
    // mid-flight, drop the page instead of splicing it into the new list.
    final gen = _artworksGen;
    emit(currentState.copyWith(isLoadingMoreAllArt: true));

    try {
      final result = await _repository.getOwnedArtworks(
        page: nextPage,
        filter: _artworkFilter,
        sort: _artworkSort,
      );
      if (isClosed || gen != _artworksGen) return;
      final latest = state;
      if (latest is! PortfolioLoaded) return;

      _allArtworks = [..._allArtworks, ...result.artworks];
      emit(
        latest.copyWith(
          allArtworks: _allArtworks,
          isLoadingMoreAllArt: false,
          hasMoreAllArt: result.nextPage != null,
          nextAllArtPage: result.nextPage,
        ),
      );
    } catch (e) {
      debugPrint('[PortfolioBloc] Load more all artworks failed: $e');
      if (isClosed || gen != _artworksGen) return;
      final latest = state;
      if (latest is PortfolioLoaded) {
        emit(latest.copyWith(isLoadingMoreAllArt: false));
      }
    }
  }

  void _onChangeTab(PortfolioChangeTab event, Emitter<PortfolioState> emit) {
    final currentState = state;
    if (currentState is! PortfolioLoaded) return;

    final tab = event.tab;

    // Reset sort to tab-appropriate default
    final defaultSort = tab == PortfolioTab.allArt || tab == PortfolioTab.listed
        ? PortfolioSortOption.recent
        : PortfolioSortOption.count;

    // The name search is tab-specific (collection names vs artist names) —
    // drop it rather than carrying it into a tab it wasn't typed for.
    _groupSearch = null;

    emit(
      currentState.copyWith(
        groups: _filterGroups(_allGroups, _tabToFilter(tab), defaultSort),
        activeTab: tab,
        activeSort: defaultSort,
        groupSearch: null,
      ),
    );

    // Entering an artwork tab resets the sort to its default, but the slices
    // still hold whatever ordering they were last fetched with — a Name sort
    // picked before a detour through the group tabs. Re-sync through the sort
    // handler, which owns the refetch.
    if (_isArtworkTab(tab) && _artworkSort != defaultSort) {
      add(PortfolioEvent.setSort(sort: defaultSort));
    }

    // Listed is fetched on demand the first time it's opened.
    if (tab == PortfolioTab.listed && currentState.listedArtworks == null) {
      add(const PortfolioEvent.loadListedArtworks());
    }
  }

  /// Apply the group-tab name search client-side — the groups are already
  /// fully loaded, so no refetch is involved (unlike the artwork filter).
  void _onSetGroupSearch(
    PortfolioSetGroupSearch event,
    Emitter<PortfolioState> emit,
  ) {
    final currentState = state;
    if (currentState is! PortfolioLoaded) return;

    final query = event.query.trim();
    _groupSearch = query.isEmpty ? null : query;
    emit(
      currentState.copyWith(
        groupSearch: _groupSearch,
        groups: _filterGroups(
          _allGroups,
          _tabToFilter(currentState.activeTab),
          currentState.activeSort,
        ),
      ),
    );
  }

  /// Apply a sort option.
  ///
  /// The group tabs hold every group in memory, so they re-sort in place. The
  /// artwork tabs hold only the pages scrolled so far, so their ordering is the
  /// server's: a new sort refetches from page 0, exactly like a new filter.
  Future<void> _onSetSort(
    PortfolioSetSort event,
    Emitter<PortfolioState> emit,
  ) async {
    final currentState = state;
    if (currentState is! PortfolioLoaded) return;

    emit(
      currentState.copyWith(
        activeSort: event.sort,
        groups: _filterGroups(
          _allGroups,
          _tabToFilter(currentState.activeTab),
          event.sort,
        ),
      ),
    );

    // Only while an artwork tab is on screen: a sort picked on a group tab is a
    // group ordering, and refetching the artwork slices for it would spend a
    // round trip on a list nobody is looking at. Returning to an artwork tab
    // re-syncs them — see [_onChangeTab].
    if (_isArtworkTab(currentState.activeTab) && _artworkSort != event.sort) {
      await _reloadArtworks(_artworkFilter, event.sort, emit);
    }
  }

  /// True when [tab] renders a flat artwork list rather than groups.
  static bool _isArtworkTab(PortfolioTab? tab) =>
      tab == PortfolioTab.allArt || tab == PortfolioTab.listed;

  // Synchronous emit-then-persist: the toggle must not open an await window
  // between reading and re-emitting the state, and the UI shouldn't wait on
  // a best-effort preference write.
  void _onToggleViewMode(
    PortfolioToggleViewMode event,
    Emitter<PortfolioState> emit,
  ) {
    final currentState = state;
    if (currentState is! PortfolioLoaded) return;

    // Both flat tabs render artworks. The screen's own `_isArtworkTab` has
    // always said so; this branch used to check `allArt` alone, which sent the
    // Listed tab's toggle down the group path.
    final isArtworkTab =
        currentState.activeTab == PortfolioTab.allArt ||
        currentState.activeTab == PortfolioTab.listed;

    if (isArtworkTab) {
      final next = currentState.artworkViewMode.next;
      emit(currentState.copyWith(artworkViewMode: next));
      unawaited(saveArtworkViewMode(next));
    } else {
      final next = currentState.groupViewMode == PortfolioViewMode.list
          ? PortfolioViewMode.grid
          : PortfolioViewMode.list;
      emit(currentState.copyWith(groupViewMode: next));
      unawaited(saveGroupViewMode(next));
    }
  }

  /// Fetch the signed-in user's created curations, mapped to curation
  /// [ArtGroup]s. Private curations are included only when the wallet has a
  /// valid signed-login session (handled server-side). Failures degrade to an
  /// empty list so a curations error never blocks the rest of the portfolio.
  Future<List<ArtGroup>> _fetchCurationGroups() async {
    try {
      final address = await walletManager.getAddress();
      final curations = await _curationRepository.getCurations();
      return CurationRepository.curationsToGroups(
        curations,
        creatorName: formatUsernameOrAddress(
          username: _authService.currentUser?.username,
          address: address,
        ),
      );
    } catch (e) {
      debugPrint('[PortfolioBloc] Curations fetch failed: $e');
      return const [];
    }
  }

  /// Whether the "verify wallet to see private curations" CTA should show.
  ///
  /// The backend's gate is profile-wide, not per-wallet: `GET /v1/curations`
  /// lists across every wallet on the login profile and includes the private
  /// ones when ANY of those wallets presents a valid `wallet-sig`. The auth
  /// interceptor attaches every cached wallet-sig cookie on every request, so a
  /// verified linked wallet already unlocks the whole profile's private
  /// curations — including ones created by an unverified Ledger.
  ///
  /// Asking only whether the *active* wallet needs verification therefore
  /// showed the CTA while the private curations it offers to unlock were
  /// already on screen. Keep the cheap active-wallet check first (it short-
  /// circuits the common non-Ledger case), then widen to the profile's wallets.
  ///
  /// `currentUser.addresses` is the login profile's wallet set from `/v0/login`
  /// — exactly the `ownerWallets` the backend resolves the gate against. Before
  /// login lands it is null, and the empty set holds no valid sig, so the CTA
  /// falls back to the active-wallet answer rather than being suppressed.
  ///
  /// NOTE: `UserProfileBloc._resolvePrivateCurationsGate` answers the same
  /// question for the profile screen and does strictly more (it silently signs
  /// an eligible HD wallet first). The two can disagree — see the follow-up to
  /// hoist one shared gate.
  Future<bool> _needsCurationVerification() async {
    if (!await _authService.currentWalletNeedsLedgerVerification()) {
      return false;
    }
    return !await _authService.hasValidWalletSigForAny(
      _authService.currentUser?.addresses ?? const [],
    );
  }

  /// Run the wallet verification flow (Ledger sign-in) and, on success,
  /// refetch curations so private ones appear, clearing the CTA.
  Future<void> _onVerifyForPrivateCurations(
    PortfolioVerifyForPrivateCurations event,
    Emitter<PortfolioState> emit,
  ) async {
    final currentState = state;
    if (currentState is! PortfolioLoaded) return;
    if (currentState.isVerifyingCurations) return;

    emit(currentState.copyWith(isVerifyingCurations: true));

    final address =
        _authService.currentAddress ?? await walletManager.getAddress();

    var verified = false;
    try {
      verified = await _ledgerVerifyController.requestVerification(address);
    } catch (e) {
      debugPrint('[PortfolioBloc] Ledger verification failed: $e');
    }
    if (isClosed) return;

    if (!verified) {
      final s = state;
      if (s is PortfolioLoaded) {
        emit(s.copyWith(isVerifyingCurations: false));
      }
      return;
    }

    // Re-fetch curations now that the wallet-sig session is established.
    final gen = ++_curationsGen;
    final curationGroups = await _fetchCurationGroups();
    if (isClosed) return;
    if (gen == _curationsGen) {
      _curationGroups = curationGroups;
    }

    final s = state;
    if (s is! PortfolioLoaded) return;
    emit(
      s.copyWith(
        isVerifyingCurations: false,
        showVerifyPrivateCurationsCta: false,
        groups: _filterGroups(
          _allGroups,
          _tabToFilter(s.activeTab),
          s.activeSort,
        ),
      ),
    );
  }

  /// Refetch only the curation groups; artworks and artist/collection groups
  /// live in their own slices and are untouched. Also recomputes the
  /// Ledger-verify CTA since it shares the same auth-session dependency.
  Future<void> _onRefreshCurations(
    PortfolioRefreshCurations event,
    Emitter<PortfolioState> emit,
  ) async {
    final gen = ++_curationsGen;
    final results = await Future.wait<Object>([
      _fetchCurationGroups(),
      _needsCurationVerification(),
    ]);
    // Superseded by a newer curation fetch (a reload or another refresh).
    if (isClosed || gen != _curationsGen) return;
    _curationGroups = results[0] as List<ArtGroup>;

    final s = state;
    // Not loaded yet (initial load in flight): the slice is stored; the
    // load's emit composes it — and the load's own raced curation fetch is
    // discarded by the generation check above.
    if (s is! PortfolioLoaded) return;
    emit(
      s.copyWith(
        showVerifyPrivateCurationsCta: results[1] as bool,
        groups: _filterGroups(
          _allGroups,
          _tabToFilter(s.activeTab),
          s.activeSort,
        ),
      ),
    );
  }

  /// Optimistically drop a transferred/burnt artwork from the flat owned-art
  /// list so it disappears immediately, rather than lingering until the reindex
  /// refetch (fired from the same [ArtworkRemovalSignal]) lands. The artist/
  /// collection group counts are intentionally left to that refetch — mapping a
  /// mint back to its group client-side isn't reliable, and a briefly off-by-one
  /// count self-corrects on the refetch.
  void _onArtworkRemoved(
    PortfolioArtworkRemoved event,
    Emitter<PortfolioState> emit,
  ) {
    final current = state;
    if (current is! PortfolioLoaded) return;
    final inAll = _allArtworks.any((a) => a.mintAccount == event.mintAccount);
    final inListed = _listedArtworks.any(
      (a) => a.mintAccount == event.mintAccount,
    );
    if (!inAll && !inListed) return;

    _allArtworks = [
      for (final a in _allArtworks)
        if (a.mintAccount != event.mintAccount) a,
    ];
    // A transferred/burnt artwork leaves the Listed tab too — the session no
    // longer holds it, so it can't be the seller.
    _listedArtworks = [
      for (final a in _listedArtworks)
        if (a.mintAccount != event.mintAccount) a,
    ];
    emit(
      current.copyWith(
        allArtworks: _allArtworks,
        listedArtworks: current.listedArtworks == null ? null : _listedArtworks,
        totalArtworks: inAll && current.totalArtworks > 0
            ? current.totalArtworks - 1
            : current.totalArtworks,
      ),
    );
  }

  /// Optimistic hide/unhide: flip the matching artwork's [PortfolioArtwork.isHidden]
  /// in the flat list so its corner badge appears/disappears immediately. The
  /// item stays in the portfolio either way (the owner still owns it); only the
  /// badge changes. A later refetch reconciles the server's `isOwnerHidden`.
  void _onArtworkHidden(
    PortfolioArtworkHidden event,
    Emitter<PortfolioState> emit,
  ) {
    final current = state;
    if (current is! PortfolioLoaded) return;
    var changed = false;
    _allArtworks = [
      for (final a in _allArtworks)
        if (a.mintAccount == event.mintAccount && a.isHidden != event.isHidden)
          () {
            changed = true;
            return a.copyWithHidden(event.isHidden);
          }()
        else
          a,
    ];
    _listedArtworks = [
      for (final a in _listedArtworks)
        if (a.mintAccount == event.mintAccount && a.isHidden != event.isHidden)
          () {
            changed = true;
            return a.copyWithHidden(event.isHidden);
          }()
        else
          a,
    ];
    if (!changed) return;
    emit(
      current.copyWith(
        allArtworks: _allArtworks,
        listedArtworks: current.listedArtworks == null ? null : _listedArtworks,
      ),
    );
  }

  /// Map tab to the appropriate ArtGroupType filter
  ArtGroupType? _tabToFilter(PortfolioTab? tab) {
    switch (tab) {
      case null:
      case PortfolioTab.allArt:
      case PortfolioTab.listed:
        return null; // No filter, show all groups/artworks
      case PortfolioTab.artists:
        return ArtGroupType.artist;
      case PortfolioTab.collections:
        return ArtGroupType.collection;
      case PortfolioTab.curations:
        return ArtGroupType.curation;
    }
  }

  List<ArtGroup> _filterGroups(
    List<ArtGroup> groups,
    ArtGroupType? filter,
    PortfolioSortOption sort,
  ) {
    var filtered = groups;

    // Apply type filter
    if (filter != null) {
      filtered = filtered.where((g) => g.type == filter).toList();
    }

    // Apply the group-tab name search
    final search = _groupSearch?.toLowerCase();
    if (search != null) {
      filtered = filtered.where((g) => g.matchesSearch(search)).toList();
    }

    // Apply sorting
    switch (sort) {
      case PortfolioSortOption.count:
        filtered = List.of(filtered)
          ..sort((a, b) => b.artworkCount.compareTo(a.artworkCount));
      case PortfolioSortOption.name:
        filtered = List.of(
          filtered,
        )..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case PortfolioSortOption.recent:
        // Keep API order (sorted by recency on server)
        break;
    }

    return filtered;
  }
}
