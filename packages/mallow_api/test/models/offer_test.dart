import 'dart:convert';

import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  group('OffersPage', () {
    test('preserves buyer profile fields from a live /v1/offers payload', () {
      // The shape of a live payload. The highest-offer panels render
      // buyer.username + buyer.imageUrl — if the parse drops them the UI
      // silently falls back to a truncated address and blank avatar.
      const raw =
          '{"result":[{"offerType":0,"buyer":{"addresses":["4Ss5JMkXAD9Z7cktFEdrqeMuT6jGMF1pVozTyPHZ6zT4"],"listingTokenMints":[],"displayName":"Alice","imageUrl":"https://cdn.example.com/images/pfp/4Ss5JMkXAD9Z7cktFEdrqeMuT6jGMF1pVozTyPHZ6zT4/1700000000000","username":"alice","followerCount":2,"followingCount":3,"postsCount":0,"postLikesCount":0,"postCommentsCount":0,"channelsMuted":[],"channelsLeft":[],"roles":[],"isTwitterVerified":false},"buyerAddress":"4Ss5JMkXAD9Z7cktFEdrqeMuT6jGMF1pVozTyPHZ6zT4","asset":"29d2S7vB453rNYFdR5Ycwt7y9haRT5fwVwL9zTmBhfV2","currencyMint":"So11111111111111111111111111111111111111112","price":150000000,"oneOfOneOnly":true,"date":"2026-01-01T00:00:00.000Z"}],"nextPage":null,"total":1}';

      final page = OffersPage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final offer = page.result.single;

      expect(offer.buyer?.username, 'alice');
      expect(offer.buyer?.displayName, 'Alice');
      expect(
        offer.buyer?.avatarUrl,
        'https://cdn.example.com/images/pfp/4Ss5JMkXAD9Z7cktFEdrqeMuT6jGMF1pVozTyPHZ6zT4/1700000000000',
      );
      expect(offer.price, 150000000);
    });

    test('buyer without a profile parses to addresses-only ref', () {
      const raw =
          '{"result":[{"offerType":0,"buyer":{"addresses":["3JF3sEqM796hk5WFqA6EtmEwJQ9quALszsfJyvXNQKy3"],"listingTokenMints":[],"roles":[],"isTwitterVerified":false},"buyerAddress":"3JF3sEqM796hk5WFqA6EtmEwJQ9quALszsfJyvXNQKy3","asset":"5bV6jUfhDHCQVA1WfKBUnXUsboJgoKgkzkKcxr3joew5","currencyMint":"So11111111111111111111111111111111111111112","price":400000000,"oneOfOneOnly":true,"date":"2026-01-02T00:00:00.000Z"}],"nextPage":null,"total":1}';

      final page = OffersPage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final offer = page.result.single;

      expect(offer.buyer?.username, isNull);
      expect(offer.buyer?.avatarUrl, isNull);
      expect(offer.buyer?.effectiveAddress, '3JF3sEqM796hk5WFqA6EtmEwJQ9quALszsfJyvXNQKy3');
    });
  });
}
