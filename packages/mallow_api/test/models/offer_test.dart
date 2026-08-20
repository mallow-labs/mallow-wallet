import 'dart:convert';

import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  group('OffersPage', () {
    test('preserves buyer profile fields from a live /v1/offers payload', () {
      // Captured from production. The highest-offer panels render
      // buyer.username + buyer.imageUrl — if the parse drops them the UI
      // silently falls back to a truncated address and blank avatar.
      const raw =
          '{"result":[{"offerType":0,"buyer":{"addresses":["FW2RJCknSCjkqHY6FigmnwpmnpPQF8X59M947eKAEnC8"],"listingTokenMints":[],"displayName":"Hutch3","imageUrl":"https://cdn.example.com/images/pfp/FW2RJCknSCjkqHY6FigmnwpmnpPQF8X59M947eKAEnC8/1773806645331","username":"hutch3","followerCount":1,"followingCount":8,"postsCount":0,"postLikesCount":0,"postCommentsCount":0,"channelsMuted":[],"channelsLeft":[],"roles":[],"isTwitterVerified":false},"buyerAddress":"FW2RJCknSCjkqHY6FigmnwpmnpPQF8X59M947eKAEnC8","asset":"95ttS7cjo2NrGGfmeeswiAcJWrUqr5VUhoAxMf9Tp95h","currencyMint":"So11111111111111111111111111111111111111112","price":150000000,"oneOfOneOnly":true,"date":"2026-05-27T19:39:10.000Z"}],"nextPage":null,"total":1}';

      final page = OffersPage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final offer = page.result.single;

      expect(offer.buyer?.username, 'hutch3');
      expect(offer.buyer?.displayName, 'Hutch3');
      expect(
        offer.buyer?.avatarUrl,
        'https://cdn.example.com/images/pfp/FW2RJCknSCjkqHY6FigmnwpmnpPQF8X59M947eKAEnC8/1773806645331',
      );
      expect(offer.price, 150000000);
    });

    test('buyer without a profile parses to addresses-only ref', () {
      const raw =
          '{"result":[{"offerType":0,"buyer":{"addresses":["CcG6fHnHzoW127xbsDMDSmXT4rqQXDSLZ5fmBFTnH7QG"],"listingTokenMints":[],"roles":[],"isTwitterVerified":false},"buyerAddress":"CcG6fHnHzoW127xbsDMDSmXT4rqQXDSLZ5fmBFTnH7QG","asset":"5va2mQtwvrpbXQqUDqxVQzyqjhmGxUFQqtvF6w3HuPKL","currencyMint":"So11111111111111111111111111111111111111112","price":400000000,"oneOfOneOnly":true,"date":"2026-06-10T05:25:19.000Z"}],"nextPage":null,"total":1}';

      final page = OffersPage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final offer = page.result.single;

      expect(offer.buyer?.username, isNull);
      expect(offer.buyer?.avatarUrl, isNull);
      expect(offer.buyer?.effectiveAddress, 'CcG6fHnHzoW127xbsDMDSmXT4rqQXDSLZ5fmBFTnH7QG');
    });
  });
}
