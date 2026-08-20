import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  // The listing-eligibility gate refuses to open the sell flow on these three
  // fields, so a silent parse miss (a renamed key, a nested creator shipped as
  // a bare address) would either lock every seller out or wave everyone
  // through. Wire shape:
  // `listingData`.
  test('ListingData parses the fields the listing gate reads', () {
    final data = ListingData.fromJson(<String, dynamic>{
      'hasVerifiedSale': true,
      'nftPreview': <String, dynamic>{
        'mintAccount': '9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin',
        'name': 'Artwork',
        'isFlagged': true,
        'creator': <String, dynamic>{
          'addresses': ['9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin'],
          'roles': ['primaryLister'],
          'isTwitterVerified': true,
          'isFlagged': true,
        },
      },
    });

    expect(data.hasVerifiedSale, isTrue);
    expect(data.nftPreview!.isFlagged, isTrue);
    expect(data.nftPreview!.creator!.isFlagged, isTrue);
    expect(data.nftPreview!.creator!.roles, ['primaryLister']);
    expect(data.nftPreview!.creator!.isTwitterVerified, isTrue);
  });

  test('absent flags default to not-flagged, no verified sale', () {
    final data = ListingData.fromJson(<String, dynamic>{
      'nftPreview': <String, dynamic>{'mintAccount': 'mint', 'name': 'Artwork'},
    });

    expect(data.hasVerifiedSale, isFalse);
    expect(data.nftPreview!.isFlagged, isFalse);
    expect(data.nftPreview!.creator, isNull);
  });
}
