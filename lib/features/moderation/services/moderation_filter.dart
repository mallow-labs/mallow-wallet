import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart' show apiOwnerAddress;
import 'block_store.dart';
import 'moderation_hide_store.dart';

/// Drops blocked accounts' content, and content the viewer reported, from the
/// lists the app builds out of other people's content.
///
/// This is the second layer. The app does not rely on what a route returned:
/// it applies the block list and the reports itself to every list it builds,
/// whatever the session could prove to the server. Without this layer a
/// blocked artist's work could stay in the drilldowns, and a reported artwork
/// could come back with the next fetch.
///
/// **Where it runs.** The repositories filter each API shape as it arrives,
/// where the creator, owner and bidder addresses are still at hand. The lists
/// on screen (blocs, and the screens that hold their own list) listen to
/// [changes] and have what they show filtered again, so a block or a report
/// made from a route pushed on top of a list takes effect on the list
/// underneath.
///
/// **The viewer's own content is never filtered.** An address in the current
/// session is never treated as hidden, and an artwork the viewer owns stays
/// whoever made it. The viewer's own portfolio, profile, curations and placed
/// offers do not pass through here at all: their repositories and blocs do
/// not call it.
///
/// **Paged lists.** Dropping items shrinks a page, so a list must take its
/// "is there more" from the server's answer, never from the filtered length,
/// and must get past a page the filter emptied: see [fetchPastFilteredPages].
class ModerationFilter {
  /// A filter over the given stores. [isOwnAddress] says whether an address is
  /// one of the viewer's own.
  ModerationFilter({
    this.blocks,
    this.hides,
    bool Function(String address)? isOwnAddress,
  }) : _isOwnAddress = isOwnAddress ?? _never;

  /// The app's filter, over the registered stores and the current session.
  ///
  /// Hides nothing where the stores are not registered (unit tests that do
  /// not bootstrap the service locator). Asks the block list to load: that
  /// load never prompts, and until it lands the device copy is in force.
  factory ModerationFilter.current() {
    final blocks = sl.isRegistered<BlockStore>() ? sl<BlockStore>() : null;
    final hides = sl.isRegistered<ModerationHideStore>()
        ? sl<ModerationHideStore>()
        : null;
    if (blocks != null) unawaited(blocks.ensureLoaded());
    return ModerationFilter(
      blocks: blocks,
      hides: hides,
      isOwnAddress: sl.isRegistered<SessionManager>()
          ? sl<SessionManager>().ownsAddress
          : null,
    );
  }

  /// The viewer's block list, or null where there is none to consult.
  final BlockStore? blocks;

  /// What the viewer reported, or null where there is none to consult.
  final ModerationHideStore? hides;
  final bool Function(String address) _isOwnAddress;

  static bool _never(String _) => false;

  /// Fires when the block list or the reported sets change. A list on screen
  /// listens and filters itself again.
  Listenable get changes =>
      Listenable.merge([blocks?.blocked, hides?.revision]);

  /// True when [address] is blocked or was reported, and is not the viewer's.
  bool hidesAddress(String? address) {
    if (address == null || address.isEmpty) return false;
    final blocked = blocks?.isBlocked(address) ?? false;
    final reported = hides?.isUserHidden(address) ?? false;
    return (blocked || reported) && !_isOwnAddress(address);
  }

  bool hidesAnyAddress(Iterable<String?> addresses) =>
      addresses.any(hidesAddress);

  /// True when [address] is blocked and is not the viewer's. Unlike
  /// [hidesAddress] a report alone does not count: this is for the offers
  /// inbox, where what is withheld is money on the viewer's own artwork and
  /// the row that discloses it says "blocked accounts".
  bool blocksAddress(String? address) =>
      address != null &&
      address.isNotEmpty &&
      (blocks?.isBlocked(address) ?? false) &&
      !_isOwnAddress(address);

  /// True when [address] is one of the viewer's own.
  bool isViewer(String? address) =>
      address != null && address.isNotEmpty && _isOwnAddress(address);

  /// [addresses] without the ones in [except], compared the way blocks are.
  static Iterable<String?> _without(
    Iterable<String?> addresses,
    Iterable<String> except,
  ) {
    if (except.isEmpty) return addresses;
    final skipped = {for (final a in except) apiOwnerAddress(a)};
    return addresses.where(
      (a) => a == null || !skipped.contains(apiOwnerAddress(a)),
    );
  }

  /// True when the artwork [mint] should be dropped: it was reported, or one
  /// of the addresses it is attributed to ([by]: its creators and its update
  /// authority, the same set the server filters on) is hidden.
  ///
  /// Never true for an artwork one of [ownedBy] makes the viewer's own. A
  /// shape that names no owner keeps what an earlier sighting of the same
  /// mint established.
  ///
  /// [except] names addresses that do not count in this list: the account
  /// whose page the list is on. Someone who opens the profile of an account
  /// they reported gets that account's work there; a blocked account's page
  /// is behind its own gate. A reported mint is dropped all the same.
  ///
  /// Also remembers who [mint] is attributed to, so a list that kept only the
  /// mint can be filtered again later with [hidesMint].
  bool hidesArtwork(
    String mint, {
    Iterable<String?> by = const [],
    Iterable<String?> ownedBy = const [],
    Iterable<String> except = const [],
  }) {
    final owners = [
      for (final a in ownedBy)
        if (a != null && a.isNotEmpty) a,
    ];
    final own = owners.isEmpty
        ? _attributions.isOwn(mint)
        : owners.any(_isOwnAddress);
    _attributions.record(mint, by, own: own);
    if (own) return false;
    return (hides?.isArtworkHidden(mint) ?? false) ||
        hidesAnyAddress(_without(by, except));
  }

  /// [hidesArtwork] for an artwork preview as the API returns it.
  bool hidesPreview(
    api.NftPreview preview, {
    Iterable<String> except = const [],
  }) => hidesArtwork(
    preview.mintAccount,
    by: [...userRefAddresses(preview.creator), preview.updateAuth],
    ownedBy: userRefAddresses(preview.owner),
    except: except,
  );

  /// True when the artwork [mint] should be dropped from a list that holds
  /// only mints: it was reported, or an earlier [hidesArtwork] call attributed
  /// it to an address that is hidden now.
  ///
  /// A mint this filter has never seen with its addresses is only matched
  /// against the reported set. [except] is as in [hidesArtwork].
  bool hidesMint(String mint, {Iterable<String> except = const []}) {
    if (mint.isEmpty) return false;
    if (_attributions.isOwn(mint)) return false;
    return (hides?.isArtworkHidden(mint) ?? false) ||
        hidesAnyAddress(_without(_attributions.of(mint), except));
  }

  /// True when a curation should be dropped: it was reported (matched by
  /// [id] or [slug], whichever the list has), or its [owner] is hidden.
  bool hidesCuration({String? id, String? slug, String? owner}) {
    final hides = this.hides;
    final reported =
        hides != null &&
        ((id != null && id.isNotEmpty && hides.isCurationHidden(id)) ||
            (slug != null && slug.isNotEmpty && hides.isCurationHidden(slug)));
    if (!reported) return hidesAddress(owner);
    return owner == null || owner.isEmpty || !_isOwnAddress(owner);
  }

  /// [items] without the ones [hides] is true for.
  List<T> visible<T>(Iterable<T> items, bool Function(T item) hides) => [
    for (final item in items)
      if (!hides(item)) item,
  ];

  /// Forgets every recorded attribution. Attributions are facts about content,
  /// not about the viewer, so only tests need a clean slate.
  @visibleForTesting
  static void resetAttributions() => _attributions.clear();
}

/// Every address a user reference from the API carries. A profile can link
/// several wallets, and a block names one address, so all of them are checked.
Iterable<String> userRefAddresses(api.ApiUserRef? ref) sync* {
  if (ref == null) return;
  final address = ref.address;
  if (address != null && address.isNotEmpty) yield address;
  final primary = ref.primaryAddress;
  if (primary != null && primary.isNotEmpty) yield primary;
  yield* ref.addresses.where((a) => a.isNotEmpty);
}

/// Who each artwork the filter has seen is attributed to, newest last.
///
/// The UI models most lists hold carry a mint and a display name, not the
/// creator's address. Filtering such a list again after a block needs the
/// address, and this is where it is kept from the moment the API shape passed
/// through. Bounded: the oldest entries go first.
final _attributions = _Attributions(capacity: 5000);

class _Attributions {
  _Attributions({required this.capacity});

  final int capacity;

  /// Mint → the addresses it is attributed to.
  final LinkedHashMap<String, List<String>> _byMint = LinkedHashMap();

  /// Mints last seen as the viewer's own, which are never filtered.
  final LinkedHashSet<String> _own = LinkedHashSet();

  void record(String mint, Iterable<String?> addresses, {required bool own}) {
    if (mint.isEmpty) return;
    if (own) {
      _byMint.remove(mint);
      _own
        ..remove(mint)
        ..add(mint);
      if (_own.length > capacity) _own.remove(_own.first);
      return;
    }
    _own.remove(mint);
    final known = [
      for (final a in addresses)
        if (a != null && a.isNotEmpty) a,
    ];
    // A sighting that came without addresses says nothing new: what an
    // earlier one recorded stays.
    if (known.isEmpty) return;
    // Removed first so an artwork seen again counts as recent.
    _byMint
      ..remove(mint)
      ..[mint] = known;
    if (_byMint.length > capacity) _byMint.remove(_byMint.keys.first);
  }

  List<String> of(String mint) => _byMint[mint] ?? const [];

  bool isOwn(String mint) => _own.contains(mint);

  void clear() {
    _byMint.clear();
    _own.clear();
  }
}

/// How many pages in a row may come back with every item filtered out before
/// one fetch stops asking for the next.
const kMaxFilteredOutPages = 5;

/// One page of a list after filtering.
class FilteredPage<T> {
  const FilteredPage({
    required this.items,
    required this.nextPage,
    this.filteredOut = 0,
  });

  /// What is left of the page.
  final List<T> items;

  /// The page to ask for next, or null when the server has no more. Taken
  /// from the server's answer, not from how many [items] survived.
  final int? nextPage;

  /// How many items the filter dropped.
  final int filteredOut;
}

/// Fetches [page] with [fetch] and, while the filter empties a page that has a
/// successor, goes on to the next one, so the caller gets something to show.
///
/// A page the filter emptied is not the end of the list: the next page may be
/// full of other people's work. Reporting it as "no results", or as the end,
/// would hide everything behind it. Reporting it as an empty page with more to
/// come would leave a list that cannot scroll, so nothing would ever ask for
/// the next page.
///
/// It gives up after [maxPages] such pages in a row, so a long run of one
/// blocked account's work cannot turn into an unbounded crawl. What happens
/// then depends on where the list is:
/// - [startOfList] (nothing on screen yet): the list ends there, empty. With
///   nothing to scroll, nothing would ever ask again.
/// - further down: the cursor is handed back, and the next scroll to the end
///   continues from it. Every further batch is one the user asked for.
Future<FilteredPage<T>> fetchPastFilteredPages<T>({
  required int page,
  required bool startOfList,
  required Future<FilteredPage<T>> Function(int page) fetch,
  int maxPages = kMaxFilteredOutPages,
}) async {
  var current = page;
  var filteredOut = 0;
  for (var fetched = 1; ; fetched++) {
    final result = await fetch(current);
    filteredOut += result.filteredOut;
    final next = result.nextPage;
    final emptied = result.items.isEmpty && result.filteredOut > 0;
    if (!emptied || next == null) {
      return FilteredPage(
        items: result.items,
        nextPage: next,
        filteredOut: filteredOut,
      );
    }
    if (fetched >= maxPages) {
      return FilteredPage(
        items: const [],
        nextPage: startOfList ? null : next,
        filteredOut: filteredOut,
      );
    }
    current = next;
  }
}
