import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/sell/services/listing_eligibility.dart';

/// The webapp only lets a wallet list an artwork when one of two things is
/// true: the artwork is demonstrably secondary (a verified sale, or a verified
/// on-chain creator who is a vetted mallow creator), or the lister is a vetted
/// creator with a complete profile — and never when the artwork or its creator
/// has been flagged (`ListArtwork`). Listing
/// is the surface primary-sale abuse happens on, so mobile has to agree with
/// the webapp branch for branch: a mobile-only "yes" is a bypass, and a
/// mobile-only "no" locks legitimate sellers out of their own artwork.
void main() {
  const creatorAddress = 'creator-address';

  User user({
    List<String> roles = const [],
    String? username = 'artist',
    String? imageUrl = 'https://img',
    bool isTwitterVerified = true,
    bool isFlagged = false,
  }) => User(
    roles: roles,
    username: username,
    imageUrl: imageUrl,
    isTwitterVerified: isTwitterVerified,
    isFlagged: isFlagged,
  );

  ArtworkListingFacts facts({
    bool isFlagged = false,
    bool creatorIsFlagged = false,
    bool hasVerifiedSale = false,
    bool hasOnChainAsset = true,
    bool hasVerifiedCreator = false,
  }) => ArtworkListingFacts(
    isFlagged: isFlagged,
    creatorIsFlagged: creatorIsFlagged,
    hasVerifiedSale: hasVerifiedSale,
    hasOnChainAsset: hasOnChainAsset,
    hasVerifiedCreator: hasVerifiedCreator,
  );

  DigitalAsset asset({
    TokenStandard standard = TokenStandard.nft,
    String? updateAuthority,
    List<OnChainCreator> creators = const [],
  }) => DigitalAsset(
    id: 'mint',
    tokenStandard: standard,
    isMutable: true,
    frozen: false,
    supply: 0,
    freezeDelegateFrozen: false,
    permanentFreezeDelegateFrozen: false,
    hasMasterEditionPlugin: false,
    updateAuthority: updateAuthority,
    tokenMetadataCreators: creators,
  );

  group('evaluateListingEligibility', () {
    test(
      'approved creator with a complete profile may list a primary sale',
      () {
        // The whole point of the primaryLister role: no secondary-market
        // evidence needed, the creator is vetted.
        expect(
          evaluateListingEligibility(
            user: user(roles: const ['primaryLister']),
            artwork: facts(),
          ),
          isNull,
        );
      },
    );

    test('admin counts as an approved creator', () {
      // isApprovedCreator falls through to isAdmin on the shared user type.
      expect(
        evaluateListingEligibility(
          user: user(roles: const ['admin']),
          artwork: facts(),
        ),
        isNull,
      );
    });

    test('approved creator without a verified twitter cannot list', () {
      // hasCompleteProfile requires the twitter link — it is the only identity
      // check standing between a granted role and a primary sale.
      expect(
        evaluateListingEligibility(
          user: user(roles: const ['primaryLister'], isTwitterVerified: false),
          artwork: facts(),
        ),
        ListingBlockReason.incompleteProfile,
      );
    });

    test('approved creator without a username or avatar cannot list', () {
      expect(
        evaluateListingEligibility(
          user: user(roles: const ['primaryLister'], username: ''),
          artwork: facts(),
        ),
        ListingBlockReason.incompleteProfile,
      );
      expect(
        evaluateListingEligibility(
          user: user(roles: const ['primaryLister'], imageUrl: null),
          artwork: facts(),
        ),
        ListingBlockReason.incompleteProfile,
      );
    });

    test('a flagged creator blocks the listing even with a verified sale', () {
      // Moderation outranks every other signal: the flag check runs before the
      // secondary-market disjunct is even considered.
      expect(
        evaluateListingEligibility(
          user: user(roles: const ['primaryLister']),
          artwork: facts(creatorIsFlagged: true, hasVerifiedSale: true),
        ),
        ListingBlockReason.flagged,
      );
    });

    test('a flagged artwork blocks the listing even for an admin', () {
      expect(
        evaluateListingEligibility(
          user: user(roles: const ['admin']),
          artwork: facts(isFlagged: true),
        ),
        ListingBlockReason.flagged,
      );
    });

    test('a verified on-chain creator may list without being an approved '
        'creator', () {
      // The secondary path: the collector holding a verified artist's work can
      // resell it even though they will never hold primaryLister themselves.
      expect(
        evaluateListingEligibility(
          user: user(),
          artwork: facts(hasVerifiedCreator: true),
        ),
        isNull,
      );
    });

    test('a verified sale may be relisted by anyone signed in', () {
      expect(
        evaluateListingEligibility(
          user: user(username: null, imageUrl: null, isTwitterVerified: false),
          artwork: facts(hasVerifiedSale: true),
        ),
        isNull,
      );
    });

    test('secondary-market evidence is ignored when the on-chain asset failed '
        'to load', () {
      // Webapp requires `onChainAsset != null` before honouring either signal —
      // an unreadable asset is not proof of anything.
      expect(
        evaluateListingEligibility(
          user: user(),
          artwork: facts(hasVerifiedSale: true, hasOnChainAsset: false),
        ),
        ListingBlockReason.notApprovedCreator,
      );
    });

    test('an unvetted user with no secondary evidence is sent to the '
        'application form', () {
      expect(
        evaluateListingEligibility(user: user(), artwork: facts()),
        ListingBlockReason.notApprovedCreator,
      );
    });

    test('a signed-out session is blocked', () {
      expect(
        evaluateListingEligibility(
          user: null,
          artwork: facts(hasVerifiedSale: true),
        ),
        ListingBlockReason.notApprovedCreator,
      );
    });

    group('entered without an artwork (the action menu Sell shortcut)', () {
      test('only the vetted-creator path can open the flow', () {
        // No mint means no artwork facts to prove a secondary listing with, so
        // the artwork-less shortcut has to fall back on the user-side disjunct.
        expect(
          evaluateListingEligibility(
            user: user(roles: const ['primaryLister']),
          ),
          isNull,
        );
        expect(
          evaluateListingEligibility(user: user()),
          ListingBlockReason.notApprovedCreator,
        );
      });

      test('a flagged user is blocked', () {
        expect(
          evaluateListingEligibility(
            user: user(roles: const ['primaryLister'], isFlagged: true),
          ),
          ListingBlockReason.flagged,
        );
      });
    });
  });

  group('computeHasVerifiedCreator', () {
    ApiUserRef creator({
      List<String> roles = const ['primaryLister'],
      bool? isTwitterVerified = true,
      List<String> addresses = const [creatorAddress],
    }) => ApiUserRef(
      roles: roles,
      isTwitterVerified: isTwitterVerified,
      addresses: addresses,
    );

    test('matches the update authority of a token-metadata asset', () {
      expect(
        computeHasVerifiedCreator(
          creator: creator(),
          asset: asset(updateAuthority: creatorAddress),
        ),
        isTrue,
      );
    });

    test('matches a verified creator entry, but not an unverified one', () {
      // The `verified` flag is the whole signal — an unverified entry is
      // self-asserted and forgeable, so it must not open the listing flow.
      expect(
        computeHasVerifiedCreator(
          creator: creator(),
          asset: asset(
            updateAuthority: 'someone-else',
            creators: const [
              OnChainCreator(
                address: creatorAddress,
                share: 100,
                verified: true,
              ),
            ],
          ),
        ),
        isTrue,
      );
      expect(
        computeHasVerifiedCreator(
          creator: creator(),
          asset: asset(
            updateAuthority: 'someone-else',
            creators: const [
              OnChainCreator(
                address: creatorAddress,
                share: 100,
                verified: false,
              ),
            ],
          ),
        ),
        isFalse,
      );
    });

    test('a Core asset defers to its collection when one was loaded', () {
      // Core assets carry the artist on the collection, not the asset — this
      // is the fallback the webapp's asset model uses.
      expect(
        computeHasVerifiedCreator(
          creator: creator(),
          asset: asset(standard: TokenStandard.core, updateAuthority: 'escrow'),
          collectionAsset: asset(
            standard: TokenStandard.coreCollection,
            updateAuthority: creatorAddress,
          ),
        ),
        isTrue,
      );
      expect(
        computeHasVerifiedCreator(
          creator: creator(),
          asset: asset(standard: TokenStandard.core, updateAuthority: 'escrow'),
        ),
        isFalse,
      );
    });

    test('an on-chain match alone is not enough — the creator must be vetted '
        'and twitter-verified', () {
      // Otherwise anyone could mint an asset with themselves as the update
      // authority and list it as a "verified creator" primary sale.
      expect(
        computeHasVerifiedCreator(
          creator: creator(roles: const []),
          asset: asset(updateAuthority: creatorAddress),
        ),
        isFalse,
      );
      expect(
        computeHasVerifiedCreator(
          creator: creator(isTwitterVerified: false),
          asset: asset(updateAuthority: creatorAddress),
        ),
        isFalse,
      );
    });

    test(
      'no mallow creator, or no on-chain asset, means no verified creator',
      () {
        expect(
          computeHasVerifiedCreator(
            creator: null,
            asset: asset(updateAuthority: creatorAddress),
          ),
          isFalse,
        );
        expect(
          computeHasVerifiedCreator(creator: creator(), asset: null),
          isFalse,
        );
      },
    );
  });
}
