import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show ListingType;
import 'package:mallow_wallet/features/market/services/can_accept_offer.dart';

/// Port of the webapp's `canAcceptOffer` spec (`canAcceptOffer.test`) plus
/// the click-time invariants its only caller pairs it with
/// (`useAcceptOffer`).
///
/// Accepting an offer is irreversible and costs a signature: every case below
/// is a state where the transaction would either be refused on-chain or hand
/// the artwork away under a listing the seller still believes is live. The
/// Exchange-Art cases from the webapp's suite are deliberately absent — those
/// branches are dead code there (the sole caller never passes
/// `exchangeArtMetadata`), so porting them would have made an EA auction *with*
/// bids acceptable.
void main() {
  /// Every input at its most permissive; each test flips only what it is about.
  AcceptOfferRefusal? refusal({
    bool isUserOwner = true,
    bool isOwnOffer = false,
    String? auctionCurrentBidder,
    ListingType listingType = ListingType.unlisted,
    bool isFrozen = false,
    bool hasMallowListing = false,
  }) => acceptOfferRefusal(
    isUserOwner: isUserOwner,
    isOwnOffer: isOwnOffer,
    auctionCurrentBidder: auctionCurrentBidder,
    listingType: listingType,
    isFrozen: isFrozen,
    hasMallowListing: hasMallowListing,
  );

  group('owner checks', () {
    // Only the holder can hand the artwork over. Ported from the webapp's
    // `it.each` over every listing type.
    for (final listingType in ListingType.values) {
      test('refuses a non-owner on a $listingType listing', () {
        expect(
          refusal(isUserOwner: false, listingType: listingType),
          AcceptOfferRefusal.notOwner,
        );
      });
    }

    test('allows the owner of an unlisted artwork', () {
      expect(refusal(), isNull);
    });

    test('allows the owner of a buy-now listing', () {
      expect(refusal(listingType: ListingType.buyNow), isNull);
    });

    test('refuses the owner of an auction listing', () {
      expect(
        refusal(listingType: ListingType.auction),
        AcceptOfferRefusal.listingNotAcceptable,
      );
    });

    test('refuses the owner of a raffle listing', () {
      expect(
        refusal(listingType: ListingType.raffle),
        AcceptOfferRefusal.listingNotAcceptable,
      );
    });
  });

  group('mallow auction checks', () {
    // Accepting while a bid is escrowed would sell the artwork out from under
    // the bidder; the auction has to be cancelled first.
    test('refuses when the auction has a current bidder', () {
      expect(
        refusal(
          auctionCurrentBidder: 'someBidder',
          listingType: ListingType.auction,
        ),
        AcceptOfferRefusal.auctionHasBids,
      );
    });

    test('still refuses an auction with no bidder — on the listing type', () {
      expect(
        refusal(listingType: ListingType.auction),
        AcceptOfferRefusal.listingNotAcceptable,
      );
    });

    // `null` is the only "no bidder" sentinel. An empty-string bidder is
    // malformed input, and treating it as "no bidder" would open exactly the
    // case the check exists to close.
    test('an empty-string bidder counts as a real bidder', () {
      expect(
        refusal(auctionCurrentBidder: ''),
        AcceptOfferRefusal.auctionHasBids,
      );
    });

    test('an unlisted artwork with no bidder is acceptable', () {
      expect(refusal(), isNull);
    });
  });

  group('listing types with no accept path', () {
    // The webapp's fallthrough: only unlisted and buy-now are acceptable.
    // Jellybean is the one the mobile sheet currently reaches, so it is
    // named rather than folded into a loop.
    test('refuses a jellybean listing', () {
      expect(
        refusal(listingType: ListingType.jellybean),
        AcceptOfferRefusal.listingNotAcceptable,
      );
    });

    for (final listingType in [
      ListingType.store,
      ListingType.gumball,
      ListingType.airdrop,
    ]) {
      test('refuses a $listingType listing', () {
        expect(
          refusal(listingType: listingType),
          AcceptOfferRefusal.listingNotAcceptable,
        );
      });
    }
  });

  group('own-offer check (backend does not enforce this)', () {
    // The backend validates DAS ownership and that the offer's buyer matches,
    // but never that buyer != seller — so without this the user pays a
    // signature to buy their own artwork from themselves.
    test('refuses accepting your own offer', () {
      expect(refusal(isOwnOffer: true), AcceptOfferRefusal.ownOffer);
    });

    test('own-offer is refused ahead of any listing-state reason', () {
      expect(
        refusal(isOwnOffer: true, listingType: ListingType.buyNow),
        AcceptOfferRefusal.ownOffer,
      );
    });

    test('a non-owner is reported as non-owner, not as own-offer', () {
      expect(
        refusal(isUserOwner: false, isOwnOffer: true),
        AcceptOfferRefusal.notOwner,
      );
    });
  });

  group('frozen check (backend does not enforce this)', () {
    // A frozen token with no mallow listing to delist cannot move — the accept
    // instruction fails on-chain after the user has already signed.
    test('refuses a frozen artwork with no mallow listing', () {
      expect(refusal(isFrozen: true), AcceptOfferRefusal.frozen);
    });

    // The common legitimate case: a mallow buy-now listing freezes the token
    // in the seller's wallet and the accept tx delists in the same sequence.
    // Refusing here would break accepting an offer on a listed artwork.
    test('allows a frozen artwork that carries a mallow listing', () {
      expect(
        refusal(
          isFrozen: true,
          hasMallowListing: true,
          listingType: ListingType.buyNow,
        ),
        isNull,
      );
    });

    test('an unfrozen artwork with no listing is acceptable', () {
      expect(refusal(), isNull);
    });
  });

  group('refusal copy', () {
    // The reason has to reach the user — every Tier-B refusal that falls
    // through to the generic failure path reads as "the app is broken".
    test('every refusal carries distinct, non-empty copy', () {
      final messages = AcceptOfferRefusal.values
          .map((r) => r.message)
          .toList(growable: false);
      expect(messages.any((m) => m.isEmpty), isFalse);
      expect(messages.toSet().length, AcceptOfferRefusal.values.length);
    });
  });
}
