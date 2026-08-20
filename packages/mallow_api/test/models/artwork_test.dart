import 'package:test/test.dart';
import 'package:mallow_api/mallow_api.dart';

// Covers the server-derived listing fields `listingState`, `isMasterEdition`
// and `listingFees`. The wallet now trusts these backend fields instead of
// computing them client-side, so parsing correctness — and the null fallback
// when the backend omits them — is the contract the rest of the app relies on.
void main() {
  group('ListingState', () {
    test('parses all JSON values correctly', () {
      expect(ListingState.values.length, 5);
      expect(ListingState.unknown, isNotNull);
      expect(ListingState.none, isNotNull);
      expect(ListingState.pending, isNotNull);
      expect(ListingState.active, isNotNull);
      expect(ListingState.ended, isNotNull);
    });
  });

  // `listingState` is a server-owned vocabulary expected to grow. A
  // present-but-unrecognized value must NOT throw:
  // decoding happens inside `NftPreview`/`NftDetail.fromJson`, so a throw would
  // abort parsing of the ENTIRE artwork — breaking grids and the detail screen,
  // not just this one field. The `@JsonKey(unknownEnumValue: ...)` fallback
  // maps any unknown value to `ListingState.unknown` ("no authoritative
  // state"), which `_auctionEnded` treats like `none`/null. These tests pin
  // that contract.
  group('listingState unknown-value fallback', () {
    test('NftPreview keeps parsing and falls back to unknown', () {
      final preview = NftPreview.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Future NFT',
        'listingState': 'cancelled', // not in the known vocabulary
      });

      // Whole object still parsed — the unknown state did not abort it.
      expect(preview.mintAccount, 'Mint111111111111111111111111111111111111111');
      expect(preview.name, 'Future NFT');
      expect(preview.listingState, ListingState.unknown);
    });

    test('NftDetail keeps parsing and falls back to unknown', () {
      final detail = NftDetail.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Future NFT',
        'listingState': 'sold', // not in the known vocabulary
      });

      expect(detail.mintAccount, 'Mint111111111111111111111111111111111111111');
      expect(detail.name, 'Future NFT');
      expect(detail.listingState, ListingState.unknown);
    });
  });

  group('ListingFees', () {
    test('fromJson parses all fields', () {
      final fees = ListingFees.fromJson({
        'feeBps': 250,
        'royaltyBps': 500,
        'estimatedFeeAmount': 12345.0,
        'estimatedRoyaltyAmount': 6789.0,
      });

      expect(fees.feeBps, 250);
      expect(fees.royaltyBps, 500);
      expect(fees.estimatedFeeAmount, 12345.0);
      expect(fees.estimatedRoyaltyAmount, 6789.0);
    });

    test('fromJson tolerates an empty object (all fields null)', () {
      final fees = ListingFees.fromJson({});
      expect(fees.feeBps, isNull);
      expect(fees.royaltyBps, isNull);
      expect(fees.estimatedFeeAmount, isNull);
      expect(fees.estimatedRoyaltyAmount, isNull);
    });
  });

  group('NftPreview server-derived fields', () {
    test('fromJson parses listingState, isMasterEdition and listingFees', () {
      final preview = NftPreview.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Test NFT',
        'listingState': 'active',
        'isMasterEdition': true,
        'listingFees': {'feeBps': 200, 'royaltyBps': 750},
      });

      expect(preview.listingState, ListingState.active);
      expect(preview.isMasterEdition, isTrue);
      expect(preview.listingFees?.feeBps, 200);
      expect(preview.listingFees?.royaltyBps, 750);
    });

    test('fromJson leaves new fields null when the backend omits them', () {
      final preview = NftPreview.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Legacy NFT',
      });

      expect(preview.listingState, isNull);
      expect(preview.isMasterEdition, isNull);
      expect(preview.listingFees, isNull);
    });
  });

  group('NftDetail server-derived fields', () {
    test('fromJson parses listingState, isMasterEdition and listingFees', () {
      final detail = NftDetail.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Test NFT',
        'listingState': 'ended',
        'isMasterEdition': false,
        'listingFees': {'feeBps': 100, 'estimatedFeeAmount': 999.0},
      });

      expect(detail.listingState, ListingState.ended);
      expect(detail.isMasterEdition, isFalse);
      expect(detail.listingFees?.feeBps, 100);
      expect(detail.listingFees?.estimatedFeeAmount, 999.0);
    });

    test('fromJson leaves new fields null when the backend omits them', () {
      final detail = NftDetail.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Legacy NFT',
      });

      expect(detail.listingState, isNull);
      expect(detail.isMasterEdition, isNull);
      expect(detail.listingFees, isNull);
    });
  });

  // Metaplex leaves `attributes[].value` free-form and the API relays the
  // off-chain metadata verbatim, so generative collections send numbers and
  // bools (mint HEATe2qp… ships `{"trait_type": "Circles", "value": 6}`).
  // A raw `as String?` cast threw mid-`NftDetail.fromJson`, which aborts the
  // ENTIRE artwork parse — the detail screen showed only the type-cast error.
  // Coercion keeps every other field readable.
  group('NftAttribute non-string values', () {
    test('coerces numeric and bool values to String', () {
      expect(NftAttribute.fromJson({'trait_type': 'Circles', 'value': 6}).value, '6');
      expect(NftAttribute.fromJson({'trait_type': 'Ink Gain', 'value': 1.5}).value, '1.5');
      expect(NftAttribute.fromJson({'trait_type': 'Animated', 'value': true}).value, 'true');
    });

    test('leaves strings untouched and a missing value null', () {
      expect(NftAttribute.fromJson({'trait_type': 'Word', 'value': 'ghost'}).value, 'ghost');
      expect(NftAttribute.fromJson({'trait_type': 'Word'}).value, isNull);
    });

    // `trait_type` is the same free-form JSON, one key over, and is
    // non-nullable — so a numeric OR absent trait aborts the parse just as
    // hard. `EditPrefill._parseAttributes` already treats it as untrusted.
    test('coerces a numeric trait_type and tolerates an absent one', () {
      expect(NftAttribute.fromJson({'trait_type': 6, 'value': 'x'}).traitType, '6');
      expect(NftAttribute.fromJson({'value': 'x'}).traitType, '');
    });

    test('a numeric attribute no longer aborts the whole NftDetail', () {
      final detail = NftDetail.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Ghost - mesmerizing',
        'attributes': [
          {'trait_type': 'Word', 'value': 'mesmerizing'},
          {'trait_type': 'Circles', 'value': 6},
        ],
      });

      expect(detail.name, 'Ghost - mesmerizing');
      expect(detail.attributes.map((a) => a.value), ['mesmerizing', '6']);
    });
  });
}
