import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

// Two flags that decide whether the app shows something it should not.
//
//  * `nsfw` on feed rows — activity rows and offer/bid cards render the same
//    artwork the grids render, so they must be able to blur it. A missing or
//    misparsed flag surfaces sensitive art to a viewer who opted out.
//  * `isCreatorHidden` on the artwork models — `/v0/hide` writes the creator
//    flag when the caller minted the piece and the owner flag otherwise, so a
//    creator who has since sold their work only ever gets the creator one.
//    Reading only `isOwnerHidden` makes their hidden artwork look un-hidden.
//
// Both default to `false` when absent so an older backend degrades to today's
// behaviour instead of throwing mid-parse (which would abort the whole row).
void main() {
  group('ActivityArtwork.nsfw', () {
    test('parses the flag off the marketplace row', () {
      final artwork = ActivityArtwork.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Flagged',
        'imageUrl': 'https://example.com/a.png',
        'nsfw': true,
      });

      expect(artwork.nsfw, isTrue);
    });

    test('defaults to false when the backend omits it', () {
      final artwork = ActivityArtwork.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Unflagged',
        'imageUrl': 'https://example.com/a.png',
      });

      expect(artwork.nsfw, isFalse);
    });
  });

  group('TransferActivityData.nftNsfw', () {
    Map<String, dynamic> transferJson({bool? nsfw}) => {
      'token': {
        'mint': 'Mint111111111111111111111111111111111111111',
        'symbol': 'NFT',
        'amount': 1.0,
        'decimals': 0,
        'logoUrl': 'https://example.com/a.png',
      },
      'counterparty': {'address': 'Wallet1111111111111111111111111111111111111'},
      'isNft': true,
      'nftNsfw': ?nsfw,
    };

    test('parses the flag on an NFT transfer row', () {
      // Transfer rows render the artwork from `token.logoUrl`, so they carry
      // their own flag rather than a nested artwork object.
      expect(TransferActivityData.fromJson(transferJson(nsfw: true)).nftNsfw, isTrue);
    });

    test('defaults to false when the backend omits it', () {
      expect(TransferActivityData.fromJson(transferJson()).nftNsfw, isFalse);
    });
  });

  group('OffersInboxItem.nsfw', () {
    Map<String, dynamic> itemJson({bool? nsfw}) => {
      'kind': 'offer',
      'direction': 'received',
      'asset': 'Mint111111111111111111111111111111111111111',
      'artworkTitle': 'Flagged',
      'artworkImageUrl': 'https://example.com/a.png',
      'actorAddress': 'Wallet1111111111111111111111111111111111111',
      'viewerAddress': 'Wallet2222222222222222222222222222222222222',
      'rawAmount': '1000000000',
      'currencyMint': 'So11111111111111111111111111111111111111112',
      'nsfw': ?nsfw,
    };

    test('parses the flag on an inbox row', () {
      expect(OffersInboxItem.fromJson(itemJson(nsfw: true)).nsfw, isTrue);
    });

    test('defaults to false when the backend omits it', () {
      // Optional on the wire precisely so the inbox keeps working against a
      // deployment that has not shipped the field yet — a required field would
      // throw here and take the whole inbox down.
      expect(OffersInboxItem.fromJson(itemJson()).nsfw, isFalse);
    });
  });

  group('isCreatorHidden', () {
    test('NftDetail parses the creator flag independently of the owner flag', () {
      // The creator who sold the piece gets ONLY this flag — the app has to
      // read it or their hidden artwork reads as visible.
      final detail = NftDetail.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Hidden by its creator',
        'isCreatorHidden': true,
      });

      expect(detail.isCreatorHidden, isTrue);
      expect(detail.isOwnerHidden, isFalse);
    });

    test('NftPreview parses the creator flag independently of the owner flag', () {
      final preview = NftPreview.fromJson({
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Hidden by its creator',
        'isCreatorHidden': true,
      });

      expect(preview.isCreatorHidden, isTrue);
      expect(preview.isOwnerHidden, isFalse);
    });

    test('both default to false when the backend omits them', () {
      final json = {
        'mintAccount': 'Mint111111111111111111111111111111111111111',
        'name': 'Visible',
      };

      expect(NftDetail.fromJson(json).isCreatorHidden, isFalse);
      expect(NftPreview.fromJson(json).isCreatorHidden, isFalse);
    });
  });
}
