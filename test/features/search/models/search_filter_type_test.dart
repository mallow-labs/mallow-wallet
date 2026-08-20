import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/search/models/search_models.dart';

void main() {
  group('SearchFilterType', () {
    group('categoryTag', () {
      // The explore API matches tags exactly against lowercase hyphenated
      // slugs; sending the display label returns zero results (silently).
      test('category filters return the lowercase hyphenated API slug', () {
        expect(SearchFilterType.category3D.categoryTag, '3d');
        expect(SearchFilterType.categoryAbstract.categoryTag, 'abstract');
        expect(SearchFilterType.categoryAI.categoryTag, 'ai');
        expect(SearchFilterType.categoryDigitalArt.categoryTag, 'digital-art');
        expect(SearchFilterType.categoryShortFilm.categoryTag, 'short-film');
        expect(SearchFilterType.categoryVideo.categoryTag, 'video');
      });

      test('no category tag contains uppercase or spaces', () {
        for (final c in SearchFilterType.categories) {
          final tag = c.categoryTag!;
          expect(tag, equals(tag.toLowerCase()), reason: c.name);
          expect(tag.contains(' '), isFalse, reason: c.name);
        }
      });

      test('non-category filters return null', () {
        expect(SearchFilterType.auction.categoryTag, isNull);
        expect(SearchFilterType.buyNow.categoryTag, isNull);
        expect(SearchFilterType.oneOfOne.categoryTag, isNull);
        expect(SearchFilterType.curations.categoryTag, isNull);
      });
    });

    group('static groups', () {
      test('listingTypes contains exactly auction/buyNow', () {
        expect(SearchFilterType.listingTypes, [
          SearchFilterType.auction,
          SearchFilterType.buyNow,
        ]);
      });

      test('browseTypes contains oneOfOne/editions/curations/exhibitions', () {
        expect(SearchFilterType.browseTypes, [
          SearchFilterType.oneOfOne,
          SearchFilterType.editions,
          SearchFilterType.curations,
          SearchFilterType.exhibitions,
        ]);
      });

      test('categories contains only category* values', () {
        final cats = SearchFilterType.categories;
        expect(cats, isNotEmpty);
        for (final c in cats) {
          expect(c.name, startsWith('category'));
        }
      });

      test('categories excludes listing and browse types', () {
        final cats = SearchFilterType.categories;
        expect(cats, isNot(contains(SearchFilterType.auction)));
        expect(cats, isNot(contains(SearchFilterType.oneOfOne)));
      });
    });

    group('isArtworkBrowse', () {
      // Only explore-backed drilldowns can render the artwork views and the
      // filter/sort bar. Curations and exhibitions come from their own
      // endpoints and would hand the artwork views items with no mint or
      // aspect ratio.
      test('is false for exactly curations and exhibitions', () {
        final nonArtwork = SearchFilterType.values
            .where((t) => !t.isArtworkBrowse)
            .toList();
        expect(nonArtwork, [
          SearchFilterType.curations,
          SearchFilterType.exhibitions,
        ]);
      });

      test('is true for listing types, supply types and every category', () {
        expect(SearchFilterType.auction.isArtworkBrowse, isTrue);
        expect(SearchFilterType.buyNow.isArtworkBrowse, isTrue);
        expect(SearchFilterType.oneOfOne.isArtworkBrowse, isTrue);
        expect(SearchFilterType.editions.isArtworkBrowse, isTrue);
        for (final c in SearchFilterType.categories) {
          expect(c.isArtworkBrowse, isTrue, reason: c.name);
        }
      });
    });

    group('pinTo', () {
      // The drilldown's header promises a constraint ("Auction", "3D"). It has
      // to survive whatever the user picks in the filters sheet, or the list
      // stops matching its own title.
      test('overrides a conflicting listing type from the user filter', () {
        final pinned = SearchFilterType.auction.pinTo(
          const api.ExploreFilter(listingTypes: ['buy-now']),
        );
        expect(pinned.listingTypes, ['auction']);
      });

      test('overrides a conflicting supply mode', () {
        final pinned = SearchFilterType.oneOfOne.pinTo(
          const api.ExploreFilter(mode: api.ExploreMode.editions),
        );
        expect(pinned.mode, api.ExploreMode.oneOfOne);
      });

      test('overrides conflicting category tags with its own slug', () {
        final pinned = SearchFilterType.category3D.pinTo(
          const api.ExploreFilter(tags: ['abstract']),
        );
        expect(pinned.tags, ['3d']);
      });

      test('keeps every facet it does not pin', () {
        final pinned = SearchFilterType.auction.pinTo(
          const api.ExploreFilter(
            mediaTypes: ['video'],
            tags: ['abstract'],
            search: 'sunset',
            mode: api.ExploreMode.editions,
          ),
        );
        expect(pinned.mediaTypes, ['video']);
        expect(pinned.tags, ['abstract']);
        expect(pinned.search, 'sunset');
        expect(pinned.mode, api.ExploreMode.editions);
      });
    });

    group('pinned facets', () {
      // Each pinned facet must be hidden in the filters sheet — a control the
      // fetch silently overrides reads as a broken filter.
      test('every artwork drilldown pins exactly one facet', () {
        for (final t in SearchFilterType.values.where(
          (t) => t.isArtworkBrowse,
        )) {
          final pinned = [
            t.pinsListingType,
            t.pinsSupplyType,
            t.pinsCategory,
          ].where((p) => p).length;
          expect(pinned, 1, reason: t.name);
        }
      });

      test('non-artwork drilldowns pin nothing', () {
        for (final t in [
          SearchFilterType.curations,
          SearchFilterType.exhibitions,
        ]) {
          expect(t.pinsListingType, isFalse, reason: t.name);
          expect(t.pinsSupplyType, isFalse, reason: t.name);
          expect(t.pinsCategory, isFalse, reason: t.name);
        }
      });
    });
  });
}
