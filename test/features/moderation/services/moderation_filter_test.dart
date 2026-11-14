import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/moderation/services/moderation_filter.dart';
import 'package:mocktail/mocktail.dart';

import '../support/moderation_fakes.dart';

// The app does not rely on a route to leave out blocked and reported
// content. This is the client's own layer, the one every list of other
// people's content goes through.

const _blocked = 'BlockedArtist1111111111111111111111111111111';
const _other = 'SomeoneElse11111111111111111111111111111111';
const _me = 'Viewer1111111111111111111111111111111111111';
const _blockedEth = '0xAbCdEf0123456789aBcDeF0123456789AbCdEf01';

api.NftPreview _preview(
  String mint, {
  String? creator,
  List<String> creatorLinked = const [],
  String? owner,
  String? updateAuth,
}) => api.NftPreview(
  mintAccount: mint,
  name: mint,
  creator: creator == null && creatorLinked.isEmpty
      ? null
      : api.ApiUserRef(address: creator, addresses: creatorLinked),
  owner: owner == null ? null : api.ApiUserRef(address: owner),
  updateAuth: updateAuth,
);

void main() {
  setUpAll(() => registerFallbackValue(() {}));
  setUp(ModerationFilter.resetAttributions);

  group('addresses', () {
    test('a blocked address is hidden, anyone else is not', () {
      final m = moderationOver(blocked: [_blocked]).filter;
      expect(m.hidesAddress(_blocked), isTrue);
      expect(m.hidesAddress(_other), isFalse);
      expect(m.hidesAddress(null), isFalse);
      expect(m.hidesAddress(''), isFalse);
    });

    // The backend stores Ethereum addresses lowercased while the app holds
    // them checksummed. A raw compare would never match a blocked EVM account.
    test('an Ethereum address matches whatever its casing', () {
      final m = moderationOver(blocked: [_blockedEth.toLowerCase()]).filter;
      expect(m.hidesAddress(_blockedEth), isTrue);
    });

    test('a reported user is hidden like a blocked one', () {
      final m = moderationOver();
      expect(m.filter.hidesAddress(_other), isFalse);
      m.hides.hide(api.ReportTargetType.user, _other);
      expect(m.filter.hidesAddress(_other), isTrue);
    });

    test('one of the viewer\'s own addresses is never hidden', () {
      final m = moderationOver(blocked: [_me], own: [_me]);
      m.hides.hide(api.ReportTargetType.user, _me);
      expect(m.filter.hidesAddress(_me), isFalse);
      expect(m.filter.blocksAddress(_me), isFalse);
    });

    test('for offers a block counts and a report alone does not', () {
      final m = moderationOver(blocked: [_blocked]);
      m.hides.hide(api.ReportTargetType.user, _other);
      expect(m.filter.blocksAddress(_blocked), isTrue);
      expect(m.filter.blocksAddress(_other), isFalse);
    });
  });

  group('artworks', () {
    test('an artwork by a blocked creator is hidden', () {
      final m = moderationOver(blocked: [_blocked]).filter;
      expect(m.hidesPreview(_preview('a', creator: _blocked)), isTrue);
      expect(m.hidesPreview(_preview('b', creator: _other)), isFalse);
    });

    // A block names one address; the creator's profile may link several, and
    // the piece is also attributed to its update authority.
    test('any linked creator address or the update authority counts', () {
      final m = moderationOver(blocked: [_blocked]).filter;
      expect(
        m.hidesPreview(
          _preview('a', creator: _other, creatorLinked: [_blocked]),
        ),
        isTrue,
      );
      expect(
        m.hidesPreview(_preview('b', creator: _other, updateAuth: _blocked)),
        isTrue,
      );
    });

    test('a reported artwork is hidden whoever made it', () {
      final m = moderationOver();
      m.hides.hide(api.ReportTargetType.artwork, 'a');
      expect(m.filter.hidesPreview(_preview('a', creator: _other)), isTrue);
      expect(m.filter.hidesMint('a'), isTrue);
      expect(m.filter.hidesMint('b'), isFalse);
    });

    test('an artwork the viewer owns stays, whoever made it', () {
      final m = moderationOver(blocked: [_blocked], own: [_me]).filter;
      expect(
        m.hidesPreview(_preview('a', creator: _blocked, owner: _me)),
        isFalse,
      );
      // The same piece in a list that names no owner, or only its mint.
      expect(m.hidesPreview(_preview('a', creator: _blocked)), isFalse);
      expect(m.hidesMint('a'), isFalse);
      // Sold on: it is someone else's again.
      expect(
        m.hidesPreview(_preview('a', creator: _blocked, owner: _other)),
        isTrue,
      );
    });

    test('an artwork the viewer made is never hidden by its creator', () {
      final m = moderationOver(blocked: [_me], own: [_me]).filter;
      expect(m.hidesPreview(_preview('a', creator: _me)), isFalse);
    });

    // Most lists keep a mint and a display name. Blocking the creator later
    // must still be able to find their work in such a list.
    test('a list that kept only the mint is filtered after a later block', () {
      final m = moderationOver();
      expect(m.filter.hidesPreview(_preview('a', creator: _blocked)), isFalse);
      expect(m.filter.hidesMint('a'), isFalse);

      m.blocks.blocked.value = {_blocked};

      expect(m.filter.hidesMint('a'), isTrue);
      expect(m.filter.hidesMint('never-seen'), isFalse);
    });

    test('a sighting without addresses keeps what an earlier one knew', () {
      final m = moderationOver(blocked: [_blocked]).filter;
      m.hidesPreview(_preview('a', creator: _blocked));
      // As the text search returns it: no creator address at all.
      expect(m.hidesArtwork('a'), isFalse);
      expect(m.hidesMint('a'), isTrue);
    });

    // On an account's own page its work is shown: the visitor went there.
    test('the account whose page a list is on does not count there', () {
      final m = moderationOver();
      m.hides.hide(api.ReportTargetType.user, _other);
      m.hides.hide(api.ReportTargetType.artwork, 'reported');
      final theirs = _preview('a', creator: _other);

      expect(m.filter.hidesPreview(theirs), isTrue);
      expect(m.filter.hidesPreview(theirs, except: [_other]), isFalse);
      expect(m.filter.hidesMint('a', except: [_other]), isFalse);
      // A reported artwork is dropped there too.
      expect(
        m.filter.hidesPreview(
          _preview('reported', creator: _other),
          except: [_other],
        ),
        isTrue,
      );
    });
  });

  group('curations', () {
    test('a curation is hidden with its owner', () {
      final m = moderationOver(blocked: [_blocked]).filter;
      expect(m.hidesCuration(id: 'c1', owner: _blocked), isTrue);
      expect(m.hidesCuration(id: 'c1', owner: _other), isFalse);
    });

    // The report carries the slug; search, home and a profile's Curations tab
    // carry the id. Both have to match or the curation stays in those lists.
    test('a reported curation matches by slug or by id', () {
      final m = moderationOver();
      m.hides.hide(api.ReportTargetType.curation, 'the-slug', alias: 'id-1');
      expect(m.filter.hidesCuration(slug: 'the-slug'), isTrue);
      expect(m.filter.hidesCuration(id: 'id-1'), isTrue);
      expect(m.filter.hidesCuration(id: 'id-2', slug: 'another'), isFalse);
    });
  });

  test('changes fires on a block and on a report', () {
    final m = moderationOver();
    var fired = 0;
    m.filter.changes.addListener(() => fired++);

    m.blocks.blocked.value = {_blocked};
    expect(fired, 1);
    m.hides.hide(api.ReportTargetType.artwork, 'a');
    expect(fired, 2);
  });

  test('a filter with no stores hides nothing', () {
    final m = ModerationFilter();
    expect(m.hidesAddress(_blocked), isFalse);
    expect(m.hidesPreview(_preview('a', creator: _blocked)), isFalse);
    expect(m.hidesCuration(id: 'c', owner: _blocked), isFalse);
    expect(m.visible([1, 2, 3], (i) => i == 2), [1, 3]);
  });

  // Dropping items shortens a page. A list that read "is there more" off the
  // filtered length would stop early, and one that showed an emptied page as
  // "no results" would hide every page behind it.
  group('fetchPastFilteredPages', () {
    /// Pages of two items each; a page is "filtered" when listed in [emptied].
    Future<FilteredPage<String>> run({
      required int page,
      required int pages,
      Set<int> emptied = const {},
      int maxPages = kMaxFilteredOutPages,
      List<int>? asked,
    }) => fetchPastFilteredPages<String>(
      page: page,
      startOfList: page == 0,
      maxPages: maxPages,
      fetch: (p) async {
        asked?.add(p);
        final gone = emptied.contains(p);
        return FilteredPage(
          items: gone ? const [] : ['$p-a', '$p-b'],
          nextPage: p + 1 < pages ? p + 1 : null,
          filteredOut: gone ? 2 : 0,
        );
      },
    );

    test('a page with something left is returned as it is', () async {
      final asked = <int>[];
      final result = await run(page: 0, pages: 3, asked: asked);
      expect(result.items, ['0-a', '0-b']);
      expect(result.nextPage, 1);
      expect(asked, [0]);
    });

    test('a page the filter emptied is skipped, not shown as empty', () async {
      final asked = <int>[];
      final result = await run(
        page: 0,
        pages: 4,
        emptied: {0, 1},
        asked: asked,
      );
      expect(result.items, ['2-a', '2-b']);
      expect(result.nextPage, 3, reason: 'paging goes on after the last read');
      expect(result.filteredOut, 4);
      expect(asked, [0, 1, 2]);
    });

    test('the last page emptied is the end of the list', () async {
      final result = await run(page: 1, pages: 2, emptied: {1});
      expect(result.items, isEmpty);
      expect(result.nextPage, isNull);
    });

    test('a page that was empty on the server is not skipped', () async {
      final asked = <int>[];
      final result = await fetchPastFilteredPages<String>(
        page: 0,
        startOfList: true,
        fetch: (p) async {
          asked.add(p);
          return const FilteredPage(items: [], nextPage: 1);
        },
      );
      expect(result.items, isEmpty);
      expect(asked, [0], reason: 'nothing was filtered, so nothing to skip');
    });

    // A long run of one blocked account's work must not become an unbounded
    // crawl. At the top of a list there is nothing to scroll, so nothing
    // would ask again: the list ends.
    test('gives up after the cap; at the start the list ends', () async {
      final asked = <int>[];
      final result = await run(
        page: 0,
        pages: 100,
        emptied: {for (var i = 0; i < 100; i++) i},
        asked: asked,
      );
      expect(asked, [0, 1, 2, 3, 4]);
      expect(result.items, isEmpty);
      expect(result.nextPage, isNull);
    });

    // Further down, the next scroll continues from where this one stopped.
    test('gives up after the cap; further down the cursor is kept', () async {
      final asked = <int>[];
      final result = await run(
        page: 3,
        pages: 100,
        emptied: {for (var i = 0; i < 100; i++) i},
        maxPages: 2,
        asked: asked,
      );
      expect(asked, [3, 4]);
      expect(result.items, isEmpty);
      expect(result.nextPage, 5);
    });
  });
}
