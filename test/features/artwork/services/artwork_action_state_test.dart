import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show RaffleUserState;
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/security/secure_storage.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/core/services/token_metadata_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_action_state.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mallow_wallet/features/wallets/services/profile_lookup_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockWalletRepository extends Mock implements WalletRepository {}

class _MockWalletManager extends Mock implements WalletManager {}

class _MockSecureWalletStorage extends Mock implements SecureWalletStorage {}

class _MockPreferencesService extends Mock implements PreferencesService {}

class _MockProfileLookupService extends Mock implements ProfileLookupService {}

// `resolveArtworkActionState` is the central decision tree that decides
// which bottom-sheet variant the artwork detail screen pins to the bottom
// of the page. It mirrors the matrix in `docs/artwork_state.md` and the
// webapp's per-listing dispatchers. Getting any branch wrong silently
// breaks a checkout/bid/claim flow for a specific wallet relationship —
// the kind of bug that's easy to ship and impossible to spot from logs.

ArtworkDetails artwork({
  String mint = 'mint1',
  ListingType listingType = ListingType.unlisted,
  SupplyType supplyType = SupplyType.oneOfOne,
  bool? isMasterEdition,
  String artistAddress = 'artist1',
  List<String> artistAddresses = const [],
  String? ownerAddress,
  List<String> ownerAddresses = const [],
  String? updateAuthority,
  List<ArtworkRoyaltySplit> royaltySplits = const [],
  AuctionMetadata? auctionMetadata,
  RaffleMetadata? raffleMetadata,
  List<RaffleMetadata> unclaimedRaffles = const [],
  bool isFlagged = false,
  bool creatorIsFlagged = false,
  MarketSource? lastSource,
  ListingState? listingState,
  String? chain,
  BuyNowMetadata? buyNowMetadata,
  String? currency,
  int? supply,
  int? maxSupply,
}) => ArtworkDetails(
  mintAccount: mint,
  chain: chain,
  title: 'T',
  imageUrl: '',
  description: null,
  artistName: 'A',
  artistAddress: artistAddress,
  artistAddresses: artistAddresses,
  ownerAddress: ownerAddress,
  ownerAddresses: ownerAddresses,
  updateAuthority: updateAuthority,
  royaltySplits: royaltySplits,
  listingType: listingType,
  listingState: listingState,
  supplyType: supplyType,
  isMasterEdition: isMasterEdition,
  auctionMetadata: auctionMetadata,
  raffleMetadata: raffleMetadata,
  unclaimedRaffles: unclaimedRaffles,
  isFlagged: isFlagged,
  creatorIsFlagged: creatorIsFlagged,
  lastSource: lastSource,
  buyNowMetadata: buyNowMetadata,
  currency: currency,
  supply: supply,
  maxSupply: maxSupply,
);

/// USDC — a non-native listing currency.
const usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const solMintAddr = 'So11111111111111111111111111111111111111112';

const owner = 'owner-addr';
const other = 'other-addr';
const artist = 'artist-addr';

void main() {
  group('disconnected (currentAddress == null)', () {
    test('buyNow → "Sign in to buy"', () {
      final s = resolveArtworkActionState(
        artwork: artwork(listingType: ListingType.buyNow),
        currentAddress: null,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkConnectWalletAction>());
      expect((s as ArtworkConnectWalletAction).label, 'Sign in to buy');
    });

    test('raffle → "Sign in to buy tickets"', () {
      final s = resolveArtworkActionState(
        artwork: artwork(listingType: ListingType.raffle),
        currentAddress: null,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect((s as ArtworkConnectWalletAction).label, 'Sign in to buy tickets');
    });

    test('live auction → "Sign in to place bid"', () {
      final now = DateTime.utc(2026);
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          auctionMetadata: AuctionMetadata(
            endsAt: now.add(const Duration(hours: 1)),
          ),
        ),
        currentAddress: null,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkConnectWalletAction).label, 'Sign in to place bid');
    });

    test('ended auction → "Sign in to view"', () {
      final now = DateTime.utc(2026);
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          auctionMetadata: AuctionMetadata(
            endsAt: now.subtract(const Duration(hours: 1)),
          ),
        ),
        currentAddress: null,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkConnectWalletAction).label, 'Sign in to view');
    });

    test('unlisted → "Sign in to make offer"', () {
      final s = resolveArtworkActionState(
        artwork: artwork(),
        currentAddress: null,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect((s as ArtworkConnectWalletAction).label, 'Sign in to make offer');
    });

    test('external listing types → "Sign in to participate"', () {
      for (final lt in const [
        ListingType.gumball,
        ListingType.airdrop,
        ListingType.store,
        ListingType.jellybean,
      ]) {
        final s = resolveArtworkActionState(
          artwork: artwork(listingType: lt),
          currentAddress: null,
          creatorLinkedAddresses: const {},
          permissions: null,
        );
        expect(
          (s as ArtworkConnectWalletAction).label,
          'Sign in to participate',
        );
      }
    });
  });

  group('precedence', () {
    // `/v1/artwork/byMint` returns EVERY unclaimed raffle for the mint with no
    // user scoping — the query is `{isInitialized, mintAccount, isClaimed:
    // {\$ne: true}}`, Redis-cached for 300 s
    // (`raffleMetadataHelper`). So
    // the presence of a row says nothing about whether *this* wallet can claim
    // anything; only the webapp's user/role filter
    // (`ArtworkContent`) does.
    RaffleMetadata unclaimed({
      String creator = 'c',
      String account = 'r',
      String? winner,
      bool isPrizeClaimed = false,
      bool isClaimed = false,
      int? sold,
    }) => RaffleMetadata(
      mintAccount: 'm',
      creator: creator,
      raffleAccount: account,
      entrantsAccount: 'e',
      winner: winner,
      isPrizeClaimed: isPrizeClaimed,
      isClaimed: isClaimed,
      sold: sold,
    );

    test('an unclaimed raffle this wallet has no role in does NOT displace '
        'the listing sheet', () {
      // The regression: `unclaimedRaffles.isNotEmpty` ran ahead of every other
      // branch, so a live buy-now listing showed "Claim proceeds" to every
      // signed-in visitor who happened to load an artwork carrying somebody
      // else's unsettled raffle.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          unclaimedRaffles: [unclaimed(winner: other, sold: 5)],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkBuyAction>());
    });

    test('a live raffle still shows Buy tickets to a visitor carrying an '
        "unrelated wallet's unclaimed raffle", () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: const [other],
          raffleMetadata: RaffleMetadata(
            mintAccount: 'm',
            creator: other,
            raffleAccount: 'live',
            entrantsAccount: 'e',
            endsAt: DateTime.utc(2026).add(const Duration(hours: 1)),
            supply: 50,
            sold: 3,
          ),
          unclaimedRaffles: [unclaimed(account: 'old', winner: other, sold: 9)],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: DateTime.utc(2026),
      );
      expect(s, isA<ArtworkRaffleAction>());
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.selling);
      expect(s.role, RaffleRole.buyer);
      expect(s.gate.canBuyTickets, isTrue);
    });

    test("the winner's own unclaimed prize does take precedence", () {
      final raffle = unclaimed(winner: owner, sold: 9);
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          unclaimedRaffles: [raffle],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkUnclaimedRaffleAction>());
      expect((s as ArtworkUnclaimedRaffleAction).raffle, raffle);
      expect(s.claim, UnclaimedRaffleClaim.prize);
    });

    test("the creator's undrawn proceeds take precedence", () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          unclaimedRaffles: [unclaimed(creator: owner, winner: other, sold: 9)],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(
        (s as ArtworkUnclaimedRaffleAction).claim,
        UnclaimedRaffleClaim.proceeds,
      );
    });

    test('an expired-unsold raffle offers the creator a reclaim', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          unclaimedRaffles: [unclaimed(creator: owner, sold: 0)],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(
        (s as ArtworkUnclaimedRaffleAction).claim,
        UnclaimedRaffleClaim.reclaim,
      );
    });

    test('the raffle the main sheet is already showing is excluded', () {
      // Webapp `ArtworkContent` — otherwise the unclaimed box would
      // shadow the very listing it describes.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: const [owner],
          raffleMetadata: RaffleMetadata(
            mintAccount: 'm',
            creator: owner,
            raffleAccount: 'r',
            entrantsAccount: 'e',
            endsAt: DateTime.utc(2026).subtract(const Duration(hours: 1)),
            winner: other,
            sold: 9,
          ),
          unclaimedRaffles: [unclaimed(creator: owner, winner: other, sold: 9)],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: DateTime.utc(2026),
      );
      expect(s, isA<ArtworkRaffleAction>());
      expect((s as ArtworkRaffleAction).role, RaffleRole.owner);
      expect(s.subState, RaffleSubState.drawnUnclaimed);
    });

    test('external listings short-circuit before relationship resolution', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.gumball,
          ownerAddresses: [owner],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkExternalLinkAction>());
      expect((s as ArtworkExternalLinkAction).listingType, ListingType.gumball);
    });

    test('jellybean links out instead of offering owner / offer actions', () {
      // Jellybean sales run on the web app and the webapp refuses accept-offer
      // on them outright (`canAcceptOffer`). Missing from this branch,
      // a Jellybean artwork fell through to the owner arm and rendered
      // "List artwork" + "Accept offer" — actions with no working backend.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.jellybean,
          ownerAddresses: [owner],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: true,
          canBurn: true,
          canList: true,
        ),
      );
      expect(s, isA<ArtworkExternalLinkAction>());
      expect(
        (s as ArtworkExternalLinkAction).listingType,
        ListingType.jellybean,
      );
    });
  });

  group('buyNow', () {
    test('owner sees owner-listed sheet', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          ownerAddresses: [owner],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkOwnerListedAction>());
    });

    test('viewer of a 1/1 buyNow gets ArtworkBuyAction', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          ownerAddresses: [other],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        userOwnOffer: true,
      );
      expect(s, isA<ArtworkBuyAction>());
      expect((s as ArtworkBuyAction).userOwnOffer, isTrue);
      expect(s.block, isNull);
    });

    test('limitedEdition supplyType routes to BuyEdition sheet', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          supplyType: SupplyType.limitedEdition,
          ownerAddresses: [other],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkBuyEditionAction>());
    });

    test(
      'editionState.isPrintableMasterEdition overrides supplyType proxy',
      () {
        final s = resolveArtworkActionState(
          // SupplyType says 1/1 but live DAS state says it's a master edition.
          artwork: artwork(
            listingType: ListingType.buyNow,
            ownerAddresses: [other],
          ),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
          editionState: const EditionLiveState(
            tokenStandard: 'nft',
            isPrintableMasterEdition: true,
            supplyInfo: EditionSupplyInfo(),
          ),
        );
        expect(s, isA<ArtworkBuyEditionAction>());
      },
    );

    test(
      'editionState present but not master overrides supplyType=editions',
      () {
        // Reverse case: proxy would route to edition sheet, live state
        // disagrees and we must trust the live signal.
        final s = resolveArtworkActionState(
          artwork: artwork(
            listingType: ListingType.buyNow,
            supplyType: SupplyType.limitedEdition,
            ownerAddresses: [other],
          ),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
          editionState: const EditionLiveState(
            tokenStandard: 'nft',
            isPrintableMasterEdition: false,
            supplyInfo: EditionSupplyInfo(),
          ),
        );
        expect(s, isA<ArtworkBuyAction>());
      },
    );

    test('API isMasterEdition=true overrides supplyType=oneOfOne proxy', () {
      // Server field says master edition, proxy would say 1/1 — server wins.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          isMasterEdition: true,
          ownerAddresses: [other],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkBuyEditionAction>());
    });

    test(
      'API isMasterEdition=false overrides supplyType=limitedEdition proxy',
      () {
        // Server field says NOT a master, proxy would route to edition sheet.
        final s = resolveArtworkActionState(
          artwork: artwork(
            listingType: ListingType.buyNow,
            supplyType: SupplyType.limitedEdition,
            isMasterEdition: false,
            ownerAddresses: [other],
          ),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
        );
        expect(s, isA<ArtworkBuyAction>());
      },
    );

    test('editionState wins over API isMasterEdition when both present', () {
      // API says master, but DAS live state disagrees — DAS wins.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          isMasterEdition: true,
          ownerAddresses: [other],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        editionState: const EditionLiveState(
          tokenStandard: 'nft',
          isPrintableMasterEdition: false,
          supplyInfo: EditionSupplyInfo(),
        ),
      );
      expect(s, isA<ArtworkBuyAction>());
    });
  });

  // A buy-now listing carries an optional sale window. Neither the v1 nor the
  // v2 builder validates it, so an enabled Buy outside the window costs the
  // user a signing prompt and a fee for a transaction the program reverts.
  // The webapp hard-disables via `deriveCanBuyNow`'s `isActive` term
  // (`listingStateDerivation` ← `useListingState` ←
  // `listing` `hasItemStarted` / `hasItemEnded`).
  group('buyNow sale window', () {
    final now = DateTime.utc(2026, 6, 1, 12);

    ArtworkActionState resolve({
      DateTime? startsAt,
      DateTime? endsAt,
      SupplyType supplyType = SupplyType.oneOfOne,
      bool? isMasterEdition,
    }) => resolveArtworkActionState(
      artwork: artwork(
        listingType: ListingType.buyNow,
        supplyType: supplyType,
        isMasterEdition: isMasterEdition,
        ownerAddresses: [other],
        buyNowMetadata: BuyNowMetadata(startsAt: startsAt, endsAt: endsAt),
      ),
      currentAddress: owner,
      creatorLinkedAddresses: const {},
      permissions: null,
      now: now,
    );

    test('a 1/1 whose sale has not started cannot be bought', () {
      final s = resolve(startsAt: now.add(const Duration(hours: 2)));
      expect((s as ArtworkBuyAction).block, ArtworkBuyBlock.notStarted);
    });

    test('a 1/1 whose sale has ended cannot be bought', () {
      final s = resolve(endsAt: now.subtract(const Duration(minutes: 1)));
      expect((s as ArtworkBuyAction).block, ArtworkBuyBlock.ended);
    });

    test('a 1/1 inside its window is buyable', () {
      final s = resolve(
        startsAt: now.subtract(const Duration(hours: 1)),
        endsAt: now.add(const Duration(hours: 1)),
      );
      expect((s as ArtworkBuyAction).block, isNull);
    });

    test('no schedule means the sale is open (webapp hasItemStarted)', () {
      expect((resolve() as ArtworkBuyAction).block, isNull);
    });

    test('endsAt exactly at now counts as ended', () {
      expect(
        (resolve(endsAt: now) as ArtworkBuyAction).block,
        ArtworkBuyBlock.ended,
      );
    });

    test('startsAt exactly at now counts as started', () {
      expect((resolve(startsAt: now) as ArtworkBuyAction).block, isNull);
    });

    test('the same gate applies to the edition sheet', () {
      final s = resolve(
        supplyType: SupplyType.limitedEdition,
        startsAt: now.add(const Duration(days: 1)),
      );
      expect(s, isA<ArtworkBuyEditionAction>());
      expect((s as ArtworkBuyEditionAction).block, ArtworkBuyBlock.notStarted);
    });
  });

  // Both v2 buy builders settle in the listing's own currency — an SPL-priced
  // listing is bought by spending the buyer's balance of that token, with no
  // `swapQuote` and no extra setup (`swapQuote` is only for paying with a
  // *different* token, which mobile never does). So no buy path may be
  // currency-gated. This group is the regression pin for the gate that used to
  // live here: it hard-disabled the CTA as "Unavailable in app" for every
  // SPL-denominated listing reaching the single-tx builder, which now hides
  // purchases the backend can fill.
  group('buyNow non-native currency', () {
    ArtworkActionState resolve({
      required SupplyType supplyType,
      String? currency,
      EditionLiveState? editionState,
    }) => resolveArtworkActionState(
      artwork: artwork(
        listingType: ListingType.buyNow,
        supplyType: supplyType,
        currency: currency,
        ownerAddresses: [other],
      ),
      currentAddress: owner,
      creatorLinkedAddresses: const {},
      permissions: null,
      editionState: editionState,
    );

    test('a USDC-priced 1/1 is buyable — the builder spends the '
        'buyer\'s USDC', () {
      final s = resolve(supplyType: SupplyType.oneOfOne, currency: usdcMint);
      expect((s as ArtworkBuyAction).block, isNull);
    });

    test('a SOL-priced 1/1 is unaffected', () {
      final s = resolve(
        supplyType: SupplyType.oneOfOne,
        currency: 'So11111111111111111111111111111111111111112',
      );
      expect((s as ArtworkBuyAction).block, isNull);
    });

    test('an absent currency means SOL', () {
      final s = resolve(supplyType: SupplyType.oneOfOne);
      expect((s as ArtworkBuyAction).block, isNull);
    });

    test('a USDC-priced edition still buys — the builder supports SPL', () {
      final s = resolve(
        supplyType: SupplyType.limitedEdition,
        currency: usdcMint,
      );
      expect(s, isA<ArtworkBuyEditionAction>());
      expect((s as ArtworkBuyEditionAction).block, isNull);
    });

    test('a USDC-priced secondary edition print buys too', () {
      // `editionPrint` is not a printable master, so `MarketBloc._onBuy` sends
      // it to `buyFixedPriceTx`. That is the resale path the old gate caught
      // most often — it is a normal SPL purchase.
      final s = resolve(
        supplyType: SupplyType.editionPrint,
        currency: usdcMint,
      );
      expect((s as ArtworkBuyAction).block, isNull);
    });

    test('a USDC-priced master whose live state says "not printable" buys '
        'through the fixed-price builder', () {
      // The live DAS signal is what the builder routes on, so a master the
      // index still calls `limited-edition` but DAS reports as non-printable
      // takes the fixed-price builder — which handles SPL the same way.
      final s = resolve(
        supplyType: SupplyType.limitedEdition,
        currency: usdcMint,
        editionState: const EditionLiveState(
          tokenStandard: 'nft',
          isPrintableMasterEdition: false,
          supplyInfo: EditionSupplyInfo(),
        ),
      );
      expect((s as ArtworkBuyAction).block, isNull);
    });
  });

  // Seven memecoin currencies were dropped from the static registry, so an
  // artwork listed in one of them now prices through an async DAS lookup
  // (`TokenMetadataService`). Until that lands the sheet is showing a shimmer
  // or "Unknown token" — and the invariant this group pins is that the CTA
  // follows the figure: **never signable for an amount that was never
  // displayed.** This is the only currency-driven block left, and unlike the
  // removed `unsupportedCurrency` gate it covers every buy path — 1/1, edition
  // and auction alike.
  group('unresolved listing currency', () {
    ArtworkActionState resolve({
      required SupplyType supplyType,
      required TokenMetadataStatus currencyStatus,
    }) => resolveArtworkActionState(
      artwork: artwork(
        listingType: ListingType.buyNow,
        supplyType: supplyType,
        ownerAddresses: [other],
      ),
      currentAddress: owner,
      creatorLinkedAddresses: const {},
      permissions: null,
      currencyStatus: currencyStatus,
    );

    test('a 1/1 is blocked while the lookup is in flight', () {
      final s = resolve(
        supplyType: SupplyType.oneOfOne,
        currencyStatus: TokenMetadataStatus.resolving,
      );
      expect((s as ArtworkBuyAction).block, ArtworkBuyBlock.unknownCurrency);
    });

    test('a 1/1 stays blocked when the lookup failed', () {
      final s = resolve(
        supplyType: SupplyType.oneOfOne,
        currencyStatus: TokenMetadataStatus.unresolved,
      );
      expect((s as ArtworkBuyAction).block, ArtworkBuyBlock.unknownCurrency);
    });

    test('an edition is blocked too — the gap the old guard left open', () {
      final s = resolve(
        supplyType: SupplyType.limitedEdition,
        currencyStatus: TokenMetadataStatus.resolving,
      );
      expect(s, isA<ArtworkBuyEditionAction>());
      expect(
        (s as ArtworkBuyEditionAction).block,
        ArtworkBuyBlock.unknownCurrency,
      );
    });

    test('a resolved currency unblocks the moment metadata lands', () {
      final s = resolve(
        supplyType: SupplyType.limitedEdition,
        currencyStatus: TokenMetadataStatus.resolved,
      );
      expect((s as ArtworkBuyEditionAction).block, isNull);
    });

    test('an auction bid is blocked until the bidMint resolves', () {
      final now = DateTime.utc(2026);
      ArtworkActionState bid(TokenMetadataStatus status) =>
          resolveArtworkActionState(
            artwork: artwork(
              listingType: ListingType.auction,
              ownerAddresses: [other],
              auctionMetadata: AuctionMetadata(
                endsAt: now.add(const Duration(hours: 1)),
              ),
            ),
            currentAddress: owner,
            creatorLinkedAddresses: const {},
            permissions: null,
            currencyStatus: status,
            now: now,
          );

      expect(
        (bid(TokenMetadataStatus.resolving) as ArtworkAuctionBidAction)
            .unknownCurrency,
        isTrue,
      );
      expect(
        (bid(TokenMetadataStatus.unresolved) as ArtworkAuctionBidAction)
            .unknownCurrency,
        isTrue,
      );
      expect(
        (bid(TokenMetadataStatus.resolved) as ArtworkAuctionBidAction)
            .unknownCurrency,
        isFalse,
      );
    });

    test(
      'the sale-window gates still win — they are permanent, this is not',
      () {
        final now = DateTime.utc(2026);
        final s = resolveArtworkActionState(
          artwork: artwork(
            listingType: ListingType.buyNow,
            ownerAddresses: [other],
            buyNowMetadata: BuyNowMetadata(
              startsAt: now.add(const Duration(days: 1)),
            ),
          ),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
          currencyStatus: TokenMetadataStatus.resolving,
          now: now,
        );
        expect((s as ArtworkBuyAction).block, ArtworkBuyBlock.notStarted);
      },
    );
  });

  group('auction', () {
    final now = DateTime.utc(2026);

    test('live auction + viewer → bid action', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [other],
          auctionMetadata: AuctionMetadata(
            endsAt: now.add(const Duration(hours: 1)),
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(s, isA<ArtworkAuctionBidAction>());
    });

    test('live auction + owner → owner action', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [owner],
          auctionMetadata: AuctionMetadata(
            endsAt: now.add(const Duration(hours: 1)),
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(s, isA<ArtworkAuctionOwnerAction>());
    });

    test('ended auction + seller role', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [owner],
          auctionMetadata: AuctionMetadata(
            endsAt: now.subtract(const Duration(hours: 1)),
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(s, isA<ArtworkAuctionClaimAction>());
      expect((s as ArtworkAuctionClaimAction).role, AuctionEndedRole.seller);
    });

    test('ended auction + current bidder → winner', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [other],
          auctionMetadata: AuctionMetadata(
            endsAt: now.subtract(const Duration(hours: 1)),
            currentBidder: owner,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkAuctionClaimAction).role, AuctionEndedRole.winner);
    });

    test('ended auction + neither owner nor bidder → observer', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [other],
          auctionMetadata: AuctionMetadata(
            endsAt: now.subtract(const Duration(hours: 1)),
            currentBidder: 'someone-else',
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkAuctionClaimAction).role, AuctionEndedRole.observer);
    });

    test('auction with no endsAt is treated as live', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [other],
          auctionMetadata: const AuctionMetadata(),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(s, isA<ArtworkAuctionBidAction>());
    });

    test('auctionMetadata.seller can mark caller as owner', () {
      // Indexer hasn't caught up: ownerAddresses points at escrow, but the
      // auctionMetadata.seller is the real owner.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: ['escrow'],
          auctionMetadata: AuctionMetadata(
            endsAt: now.add(const Duration(hours: 1)),
            seller: owner,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(s, isA<ArtworkAuctionOwnerAction>());
    });
  });

  // Auction-ended is a PURELY time-based check against `endsAt`. Nothing
  // changes on-chain at the end instant, so the server-derived `listingState`
  // never flips to `ended` on its own — it can sit on `active` indefinitely
  // past `endsAt`. The clock is therefore authoritative, and `listingState`
  // is ignored. Mirrors the reference web client's time-only `hasItemEnded`.
  group('auction-ended is time-based, listingState ignored', () {
    final now = DateTime.utc(2026);

    test('endsAt in the future stays live even if listingState says ended', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [owner],
          listingState: ListingState.ended,
          auctionMetadata: AuctionMetadata(
            endsAt: now.add(const Duration(hours: 1)),
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(s, isA<ArtworkAuctionOwnerAction>());
    });

    // The core fix: a stale `active` state must NOT keep the auction live once
    // the clock has passed `endsAt`.
    test('endsAt in the past ends even if listingState still says active', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [owner],
          listingState: ListingState.active,
          auctionMetadata: AuctionMetadata(
            endsAt: now.subtract(const Duration(hours: 1)),
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(s, isA<ArtworkAuctionClaimAction>());
      expect((s as ArtworkAuctionClaimAction).role, AuctionEndedRole.seller);
    });

    test('null listingState still uses the endsAt comparison', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          ownerAddresses: [owner],
          auctionMetadata: AuctionMetadata(
            endsAt: now.subtract(const Duration(hours: 1)),
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(s, isA<ArtworkAuctionClaimAction>());
    });

    test('disconnected, endsAt in the future → "Sign in to place bid"', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          listingState: ListingState.ended,
          auctionMetadata: AuctionMetadata(
            endsAt: now.add(const Duration(hours: 1)),
          ),
        ),
        currentAddress: null,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkConnectWalletAction).label, 'Sign in to place bid');
    });
  });

  group('raffle', () {
    final now = DateTime.utc(2026);
    RaffleMetadata raffle({
      DateTime? endsAt,
      String? winner,
      bool? isPrizeClaimed,
      bool? isClaimed,
      bool? isExpired,
      int? supply,
      int? sold,
      int? ticketLimit,
      Map<String, int>? countByEntrant,
      String creator = 'c',
      RaffleUserState? raffleUserState,
    }) => RaffleMetadata(
      mintAccount: 'm',
      creator: creator,
      raffleAccount: 'r',
      entrantsAccount: 'e',
      endsAt: endsAt,
      winner: winner,
      isPrizeClaimed: isPrizeClaimed,
      isClaimed: isClaimed,
      isExpired: isExpired,
      supply: supply,
      sold: sold,
      ticketLimit: ticketLimit,
      countByEntrant: countByEntrant,
      raffleUserState: raffleUserState,
    );

    test('owner role beats winner role when both apply', () {
      // Owner address matches AND raffle.winner matches → owner wins.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [owner],
          raffleMetadata: raffle(winner: owner),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).role, RaffleRole.owner);
    });

    test('winner role when caller is raffle.winner and not owner', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(winner: owner),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).role, RaffleRole.winner);
    });

    test('buyer role for everyone else', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).role, RaffleRole.buyer);
    });

    test(
      'raffleUserState.isUserOwner overrides address-matching owner check',
      () {
        // Address not in ownerAddresses, but server says this wallet is owner.
        final s = resolveArtworkActionState(
          artwork: artwork(
            listingType: ListingType.raffle,
            ownerAddresses: [other],
            raffleMetadata: raffle(
              raffleUserState: const RaffleUserState(isUserOwner: true),
            ),
          ),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
          now: now,
        );
        expect((s as ArtworkRaffleAction).role, RaffleRole.owner);
      },
    );

    test(
      'raffleUserState.isUserWinner overrides address-matching winner check',
      () {
        // winner field doesn't match address, but server says this wallet won.
        final s = resolveArtworkActionState(
          artwork: artwork(
            listingType: ListingType.raffle,
            ownerAddresses: [other],
            raffleMetadata: raffle(
              winner: other,
              raffleUserState: const RaffleUserState(isUserWinner: true),
            ),
          ),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
          now: now,
        );
        expect((s as ArtworkRaffleAction).role, RaffleRole.winner);
      },
    );

    test('subState — winner set + prize unclaimed → drawn-unclaimed', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(winner: owner, isPrizeClaimed: false),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(
        (s as ArtworkRaffleAction).subState,
        RaffleSubState.drawnUnclaimed,
      );
    });

    test('subState — sale window closed + tickets sold + no winner → '
        'awaiting-draw', () {
      // `sold > 0` is what separates "the draw hasn't run" from "expired with
      // nothing sold" (webapp `raffleStateDerivation` vs `isRaffleExpired`).
      // Without it this case used to be reached by the server's `isExpired`
      // flag alone.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(
            endsAt: now.subtract(const Duration(minutes: 1)),
            supply: 50,
            sold: 7,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.awaitingDraw);
    });

    test('subState — sale window closed + sold unknown (null) + no winner → '
        'awaiting-draw, never ended-cancelled', () {
      // `sold` is nullable on the wire and the indexed row lags exactly in this
      // window, before the async live-PDA overlay resolves. Reading null as 0
      // would classify a closed, tickets-sold, not-yet-drawn raffle as
      // cancelled: the creator gets a "Reclaim NFT" CTA whose `claimPrize`
      // reverts on-chain ("Creator can only reclaim the prize after a no-bid
      // expiry") and buyers are told the raffle was
      // cancelled. The webapp gates the same arm on strict
      // `(numberSold ?? sold) === 0` (`raffleStateDerivation`), which
      // does not fire on null — only a concrete zero is cancelled-eligible.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: const ['raffle-escrow'],
          raffleMetadata: raffle(
            creator: owner,
            endsAt: now.subtract(const Duration(hours: 1)),
            supply: 50,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.awaitingDraw);
    });

    test('subState — the live PDA overlay settles an unknown sold count into '
        'ended-cancelled', () {
      // The unknown-sold fallback above is a holding state, not a permanent
      // one: once the PDA snapshot lands with a concrete `sold: 0`, the raffle
      // classifies as cancelled and the creator's reclaim CTA appears.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: const ['raffle-escrow'],
          raffleMetadata: raffle(
            creator: owner,
            endsAt: now.subtract(const Duration(hours: 1)),
            supply: 50,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        raffleState: const RaffleLiveState(
          raffleAccount: 'r',
          creator: owner,
          prizeMint: 'm',
          currencyMint: solMintAddr,
          supply: 50,
        ),
        now: now,
      );
      expect(
        (s as ArtworkRaffleAction).subState,
        RaffleSubState.endedCancelled,
      );
      expect(s.role, RaffleRole.owner);
    });

    test('subState — ended + isExpired=true → ended-cancelled', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(
            endsAt: now.subtract(const Duration(minutes: 1)),
            isExpired: true,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(
        (s as ArtworkRaffleAction).subState,
        RaffleSubState.endedCancelled,
      );
    });

    test('subState — endsAt in the future → selling', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(endsAt: now.add(const Duration(hours: 1))),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.selling);
    });

    test('null raffleMetadata → selling', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.selling);
    });

    test('subState — winner set + prize already claimed → drawn-claimed, '
        'never back to selling', () {
      // This is the state that used to fall through to `selling`, which put a
      // live "Buy tickets" CTA on a raffle that had already been drawn AND
      // collected. The creator's proceeds survive the prize claim — webapp
      // `isProceedsClaimable` (`raffleStateDerivation`) does not
      // consult `isPrizeClaimed` — so the phase needs its own value.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(
            endsAt: now.subtract(const Duration(days: 2)),
            winner: other,
            isPrizeClaimed: true,
            supply: 50,
            sold: 50,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.drawnClaimed);
      expect(s.gate.canBuyTickets, isFalse);
    });

    test('an expired-unsold raffle gives its creator the owner role so the '
        'reclaim CTA is reachable', () {
      // The prize is in raffle escrow, so the indexed NFT owner is the escrow,
      // not the creator — resolving the role off ownership alone classified
      // the creator as a buyer and left an empty sheet, with no way to get the
      // NFT back from the app. Webapp resolves the creator off
      // `raffleMetadata.creator` (`raffleStateDerivation`)
      // and the reclaim tx exists both client-side (`claimPrize`) and in the
      // server's raffle builders.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: const ['raffle-escrow'],
          raffleMetadata: raffle(
            creator: owner,
            endsAt: now.subtract(const Duration(hours: 1)),
            supply: 50,
            sold: 0,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect(
        (s as ArtworkRaffleAction).subState,
        RaffleSubState.endedCancelled,
      );
      expect(s.role, RaffleRole.owner);
    });

    test('a sold-out raffle offers no live Buy CTA', () {
      // Webapp `isSoldOut` → `canBuyTicket` false
      // (`raffleStateDerivation`); the modal disables the same
      // way (`BuyTicketsModal`). Mobile had no supply gate at all,
      // so a sold-out raffle still took the user into a purchase that could
      // only fail.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(
            endsAt: now.add(const Duration(hours: 1)),
            supply: 50,
            sold: 50,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.selling);
      expect(s.gate.isSoldOut, isTrue);
      expect(s.gate.canBuyTickets, isFalse);
      expect(s.gate.ticketsRemaining, 0);
    });

    test(
      'the wallet limit caps at 40% of supply and blocks a maxed wallet',
      () {
        // `raffleWalletLimit` (`nft`)
        // — the program caps any one wallet at 40% of supply; a configured
        // `ticketLimit` narrows but never widens it.
        final s = resolveArtworkActionState(
          artwork: artwork(
            listingType: ListingType.raffle,
            ownerAddresses: [other],
            raffleMetadata: raffle(
              endsAt: now.add(const Duration(hours: 1)),
              supply: 50,
              sold: 20,
              ticketLimit: 100,
              countByEntrant: const {owner: 20},
            ),
          ),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
          now: now,
        );
        expect((s as ArtworkRaffleAction).gate.walletLimit, 20);
        expect(s.gate.userTickets, 20);
        expect(s.gate.canBuyTickets, isFalse);
        expect(s.gate.ticketsRemaining, 30);
      },
    );

    test('a buyer under the wallet limit on a live raffle can buy', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(
            endsAt: now.add(const Duration(hours: 1)),
            supply: 50,
            sold: 20,
            countByEntrant: const {owner: 3},
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).gate.canBuyTickets, isTrue);
      expect(s.gate.userTickets, 3);
    });

    test('the live raffle snapshot overrides a lagging indexed sold count', () {
      // `RaffleRepository.getState` was dead code. It matters precisely here:
      // the indexer still reports 0 sold while the PDA knows tickets went out,
      // and `sold` is what separates "expired, creator reclaims" from
      // "awaiting draw". Reclaiming a raffle that actually sold tickets is
      // rejected on-chain, so the stale read points the creator at a
      // guaranteed failure.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: const ['raffle-escrow'],
          raffleMetadata: raffle(
            creator: owner,
            endsAt: now.subtract(const Duration(hours: 1)),
            supply: 50,
            sold: 0,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        raffleState: const RaffleLiveState(
          raffleAccount: 'r',
          creator: owner,
          prizeMint: 'm',
          currencyMint: solMintAddr,
          supply: 50,
          sold: 12,
        ),
        now: now,
      );
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.awaitingDraw);
      expect(s.raffle?.sold, 12);
    });

    test('the live snapshot treats the default pubkey as "no winner"', () {
      // The rafffle program stores the all-ones system-program key before the
      // draw; the webapp screens for it at `raffleStateDerivation`.
      // Taken literally it would read as a drawn winner and hide the
      // awaiting-draw state.
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(
            endsAt: now.subtract(const Duration(hours: 1)),
            supply: 50,
            sold: 12,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        raffleState: const RaffleLiveState(
          raffleAccount: 'r',
          creator: 'c',
          prizeMint: 'm',
          currencyMint: solMintAddr,
          supply: 50,
          sold: 12,
          winner: '11111111111111111111111111111111',
        ),
        now: now,
      );
      expect((s as ArtworkRaffleAction).subState, RaffleSubState.awaitingDraw);
      expect(s.raffle?.winner, isNull);
    });

    test('a snapshot for a different raffle account is ignored', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: [other],
          raffleMetadata: raffle(
            endsAt: now.add(const Duration(hours: 1)),
            supply: 50,
            sold: 1,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        raffleState: const RaffleLiveState(
          raffleAccount: 'some-other-raffle',
          creator: 'c',
          prizeMint: 'm',
          currencyMint: solMintAddr,
          supply: 50,
          sold: 50,
        ),
        now: now,
      );
      expect((s as ArtworkRaffleAction).gate.isSoldOut, isFalse);
      expect(s.raffle?.sold, 1);
    });

    test('the raffle creator is never offered tickets on their own raffle', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.raffle,
          ownerAddresses: const ['raffle-escrow'],
          raffleMetadata: raffle(
            creator: owner,
            endsAt: now.add(const Duration(hours: 1)),
            supply: 50,
            sold: 2,
          ),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: now,
      );
      expect((s as ArtworkRaffleAction).role, RaffleRole.owner);
      expect(s.gate.canBuyTickets, isFalse);
    });
  });

  group('market source', () {
    // Every CTA the dispatcher can produce is built against a mallow program.
    // The webapp refuses foreign sources outright ("Unsupported market source",
    // `useCancelListing`) and defaults a missing value to mallow
    // (`UpdateListingModal`).
    test('an objkt-sourced listing yields no CTA at all', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          lastSource: MarketSource.objkt,
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkNoAction>());
    });

    test("a foreign source suppresses the owner's listing management too", () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.buyNow,
          ownerAddresses: const [owner],
          lastSource: MarketSource.exchangeArt,
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      // Not ArtworkOwnerListedAction — Update / Cancel listing would build a
      // mallow_market instruction against an Exchange Art listing PDA.
      expect(s, isA<ArtworkNoAction>());
    });

    test('a null lastSource still yields the normal CTA', () {
      // The field is sparsely populated. Defaulting a missing value to
      // "foreign" would kill every legitimate CTA in the app.
      final s = resolveArtworkActionState(
        artwork: artwork(listingType: ListingType.buyNow),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkBuyAction>());
    });

    test('mallow and unknown are both treated as mallow', () {
      for (final source in const [MarketSource.mallow, MarketSource.unknown]) {
        final s = resolveArtworkActionState(
          artwork: artwork(listingType: ListingType.buyNow, lastSource: source),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
        );
        expect(s, isA<ArtworkBuyAction>(), reason: '$source');
      }
    });

    test('an unlisted artwork with foreign trade history keeps its CTAs', () {
      // `lastSource` records the last marketplace the piece TRADED on, not
      // where it currently lives. An owner holding an unlisted piece that once
      // sold on magic-eden can still list it on mallow — a mallow_market
      // listing built for it is perfectly valid, and the webapp's
      // `deriveCanList` never consults `lastSource`. Suppressing here would
      // strip the List CTA from artwork its owner holds outright.
      final s = resolveArtworkActionState(
        artwork: artwork(
          ownerAddresses: const [owner],
          lastSource: MarketSource.magicEden,
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: true,
          canBurn: true,
          canList: true,
        ),
      );
      expect(s, isA<ArtworkOwnerUnlistedAction>());
      expect((s as ArtworkOwnerUnlistedAction).canList, isTrue);
    });

    test('the suppression also covers the disconnected connect-wallet CTA', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          lastSource: MarketSource.opensea,
        ),
        currentAddress: null,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkNoAction>());
    });
  });

  group('unlisted', () {
    test('collection supplyType → no action', () {
      final s = resolveArtworkActionState(
        artwork: artwork(supplyType: SupplyType.collection),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkNoAction>());
    });

    test('owner + canList=true → owner-unlisted sheet', () {
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [owner]),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: true,
          canBurn: true,
          canList: true,
        ),
      );
      expect(s, isA<ArtworkOwnerUnlistedAction>());
      expect((s as ArtworkOwnerUnlistedAction).canList, isTrue);
      expect(s.canSend, isTrue);
    });

    test('owner + no permissions at all → no action (frozen / delegated)', () {
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [owner]),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: ArtworkPermissions.none,
      );
      expect(s, isA<ArtworkNoAction>());
    });

    test('owner + canList=false but canTransfer=true keeps Send', () {
      // Send used to be gated on `canList`, so a listing-blocked artwork lost
      // its only in-app way out of the wallet. `canTransfer` is the predicate
      // the context-menu Transfer row uses; Send must not be stricter.
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [owner]),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: false,
          canBurn: false,
          canList: false,
        ),
      );
      expect(s, isA<ArtworkOwnerUnlistedAction>());
      expect((s as ArtworkOwnerUnlistedAction).canSend, isTrue);
      expect(s.canList, isFalse);
    });

    test('owner + flagged NFT can still send, but not list', () {
      // The webapp gates only the "List for sale" CTA on `isFlagged`
      // (`ActionBox`); Transfer sits outside that condition. Removing
      // the whole sheet stranded the owner's own flagged artwork in the app.
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [owner], isFlagged: true),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: true,
          canBurn: true,
          canList: true,
        ),
      );
      expect(s, isA<ArtworkOwnerUnlistedAction>());
      expect((s as ArtworkOwnerUnlistedAction).canList, isFalse);
      expect(s.canSend, isTrue);
    });

    test('owner + flagged CREATOR can still send, but not list', () {
      // Second half of the webapp's `!creator?.isFlagged && !isFlagged` guard
      // (`ActionBox`), which mobile never modelled — the List CTA
      // rendered and only explained itself after the tap. It must gate List
      // and nothing else: letting it reach `canSend` would rebuild the exact
      // inversion that stranded an owner's flagged artwork.
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [owner], creatorIsFlagged: true),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: true,
          canBurn: true,
          canList: true,
        ),
      );
      expect(s, isA<ArtworkOwnerUnlistedAction>());
      expect((s as ArtworkOwnerUnlistedAction).canList, isFalse);
      expect(s.canSend, isTrue);
    });

    test('owner + flagged + untransferable → no sheet', () {
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [owner], isFlagged: true),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: false,
          canEdit: false,
          canBurn: false,
          canList: true,
        ),
      );
      expect(s, isA<ArtworkNoAction>());
    });

    test('sold-out master edition cannot be listed', () {
      // `deriveCanList` returns false on `isSoldOut`
      // (`listingStateDerivation`, pinned by its own test). Mobile
      // sent the listing tx: `_canList` never read supply, and the default
      // `editionsLimit: 0` skips the backend check that would have caught it.
      final s = resolveArtworkActionState(
        artwork: artwork(
          ownerAddresses: [owner],
          supplyType: SupplyType.limitedEdition,
          supply: 10,
          maxSupply: 10,
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: true,
          canBurn: true,
          canList: true,
        ),
      );
      expect(s, isA<ArtworkOwnerUnlistedAction>());
      expect((s as ArtworkOwnerUnlistedAction).canList, isFalse);
      // Sold out only blocks listing — the master itself can still be sent.
      expect(s.canSend, isTrue);
    });

    test('master edition with prints remaining can still be listed', () {
      final s = resolveArtworkActionState(
        artwork: artwork(
          ownerAddresses: [owner],
          supplyType: SupplyType.limitedEdition,
          supply: 9,
          maxSupply: 10,
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: true,
          canBurn: true,
          canList: true,
        ),
      );
      expect((s as ArtworkOwnerUnlistedAction).canList, isTrue);
    });

    test('open edition (no maxSupply) is never sold out', () {
      // The webapp's raw `supply === maxSupply` reports sold-out when both are
      // absent; mobile requires both present, so an uncapped open edition stays
      // listable.
      final s = resolveArtworkActionState(
        artwork: artwork(
          ownerAddresses: [owner],
          supplyType: SupplyType.openEdition,
          supply: 100,
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: true,
          canEdit: true,
          canBurn: true,
          canList: true,
        ),
      );
      expect((s as ArtworkOwnerUnlistedAction).canList, isTrue);
    });

    test('viewer of unlisted → make-offer action', () {
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [other]),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        userOwnOffer: true,
      );
      expect(s, isA<ArtworkUnlistedViewerAction>());
      expect((s as ArtworkUnlistedViewerAction).userOwnOffer, isTrue);
    });

    test('viewer of unlisted master edition → no action (offers not live)', () {
      // Edition offers aren't supported yet, so master editions must not
      // surface the make-offer sheet until they are.
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [other], isMasterEdition: true),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkNoAction>());
    });
  });

  group('relationship resolution', () {
    test(
      'artistAddresses, royaltySplits and linked addresses mark creator',
      () {
        // Creator role doesn't change unlisted dispatcher output (still
        // make-offer), but the helper still must classify them as not-owner.
        final s = resolveArtworkActionState(
          artwork: artwork(artistAddresses: [owner], ownerAddresses: [other]),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
        );
        expect(s, isA<ArtworkUnlistedViewerAction>());

        final s2 = resolveArtworkActionState(
          artwork: artwork(
            royaltySplits: const [
              ArtworkRoyaltySplit(address: owner, sharePercent: 100),
            ],
            ownerAddresses: [other],
          ),
          currentAddress: owner,
          creatorLinkedAddresses: const {},
          permissions: null,
        );
        expect(s2, isA<ArtworkUnlistedViewerAction>());

        final s3 = resolveArtworkActionState(
          artwork: artwork(ownerAddresses: [other]),
          currentAddress: owner,
          creatorLinkedAddresses: const {owner},
          permissions: null,
        );
        expect(s3, isA<ArtworkUnlistedViewerAction>());
      },
    );

    test('ownerAddress (legacy single field) marks owner', () {
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddress: owner),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: const ArtworkPermissions(
          canTransfer: false,
          canEdit: false,
          canBurn: false,
          canList: true,
        ),
      );
      expect(s, isA<ArtworkOwnerUnlistedAction>());
    });

    test(
      'auction.seller empty-string + empty currentAddress does not match',
      () {
        // Defensive: an empty currentAddress + empty seller must not be treated
        // as owner. (currentAddress can't actually be empty here because the
        // disconnected branch handles null — but the helper guards against
        // it.)
        final s = resolveArtworkActionState(
          artwork: artwork(
            listingType: ListingType.auction,
            ownerAddresses: [other],
            auctionMetadata: const AuctionMetadata(seller: ''),
          ),
          currentAddress: '',
          creatorLinkedAddresses: const {},
          permissions: null,
          now: DateTime.utc(2026),
        );
        expect(s, isA<ArtworkAuctionBidAction>());
      },
    );
  });

  // An account can hold several Solana wallets; only one is the active
  // signing wallet. Ownership must be judged against EVERY address the
  // session controls (`ownedAddresses`) — an artwork held by a non-active
  // wallet is still owned, and must show the owner view, not "Make offer".
  group('ownership across all session wallets (ownedAddresses)', () {
    const activeWallet = 'active-addr';
    const otherWallet = 'other-owned-addr';
    const ownerPerms = ArtworkPermissions(
      canTransfer: true,
      canEdit: true,
      canBurn: true,
      canList: true,
    );

    test(
      'artwork held by a non-active owned wallet → owner sheet, not make-offer',
      () {
        // The active wallet is NOT the owner; a different wallet in the same
        // account is. Before threading `ownedAddresses`, this fell through to
        // the viewer make-offer sheet (the reported bug).
        final s = resolveArtworkActionState(
          artwork: artwork(ownerAddresses: [otherWallet]),
          currentAddress: activeWallet,
          sessionAddresses: const {activeWallet, otherWallet},
          creatorLinkedAddresses: const {},
          permissions: ownerPerms,
        );
        expect(s, isA<ArtworkOwnerUnlistedAction>());
      },
    );

    test('non-active owned wallet matches legacy single ownerAddress', () {
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddress: otherWallet),
        currentAddress: activeWallet,
        sessionAddresses: const {activeWallet, otherWallet},
        creatorLinkedAddresses: const {},
        permissions: ownerPerms,
      );
      expect(s, isA<ArtworkOwnerUnlistedAction>());
    });

    test('non-active owned wallet is the auction seller → owner sheet', () {
      final now = DateTime.utc(2026);
      final s = resolveArtworkActionState(
        artwork: artwork(
          listingType: ListingType.auction,
          auctionMetadata: const AuctionMetadata(seller: otherWallet),
        ),
        currentAddress: activeWallet,
        sessionAddresses: const {activeWallet, otherWallet},
        creatorLinkedAddresses: const {},
        permissions: ownerPerms,
        now: now.add(const Duration(hours: 1)),
      );
      expect(s, isA<ArtworkAuctionOwnerAction>());
    });

    test('artwork owned by no session wallet stays a viewer', () {
      // Guard against over-broadening: a wallet the session does NOT control
      // must still resolve to the make-offer viewer sheet.
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddresses: [owner]),
        currentAddress: activeWallet,
        sessionAddresses: const {activeWallet, otherWallet},
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkUnlistedViewerAction>());
    });

    test('empty owned wallet entries never false-match an empty owner', () {
      // Defensive: blank addresses on both sides must not read as ownership.
      final s = resolveArtworkActionState(
        artwork: artwork(ownerAddress: '', ownerAddresses: const ['']),
        currentAddress: activeWallet,
        sessionAddresses: const {activeWallet, ''},
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkUnlistedViewerAction>());
    });

    // The API stores and returns EVM owner addresses lowercased, but local
    // wallets hold (and pass in) the EIP-55 checksummed form. A raw string
    // compare therefore never matches for Ethereum: the holder of their own
    // ETH artwork was classified as a viewer and shown "Make offer" instead of
    // the list / transfer / hide owner sheet. Both sides must be normalised.
    group('EVM address casing', () {
      const evmLower = '0xabcdef0123456789abcdef0123456789abcdef01';
      const evmChecksummed = '0xAbCdEf0123456789aBcDeF0123456789AbCdEf01';

      test('lowercased API owner matches the checksummed active wallet', () {
        final s = resolveArtworkActionState(
          artwork: artwork(ownerAddresses: const [evmLower]),
          currentAddress: evmChecksummed,
          sessionAddresses: const {evmChecksummed},
          creatorLinkedAddresses: const {},
          permissions: ownerPerms,
        );
        expect(s, isA<ArtworkOwnerUnlistedAction>());
      });

      test('lowercased API owner matches a checksummed session wallet', () {
        // Non-active session wallet holds it — same widening as above, but the
        // casing mismatch is what used to break it.
        final s = resolveArtworkActionState(
          artwork: artwork(ownerAddress: evmLower),
          currentAddress: activeWallet,
          sessionAddresses: const {activeWallet, evmChecksummed},
          creatorLinkedAddresses: const {},
          permissions: ownerPerms,
        );
        expect(s, isA<ArtworkOwnerUnlistedAction>());
      });

      test('a different EVM address is still a viewer', () {
        // Guard against normalisation over-matching: lowercasing must not make
        // unrelated hex addresses equal.
        final s = resolveArtworkActionState(
          artwork: artwork(
            ownerAddresses: const [
              '0x1111111111111111111111111111111111111111',
            ],
          ),
          currentAddress: evmChecksummed,
          sessionAddresses: const {evmChecksummed},
          creatorLinkedAddresses: const {},
          permissions: null,
        );
        expect(s, isA<ArtworkUnlistedViewerAction>());
      });
    });
  });

  // The creator half of the relationship resolver compared every field against
  // the active signing wallet alone while the owner half above had already been
  // widened to the whole session. A session spans several wallets, so a piece
  // minted from — or paying royalties to — a non-active session wallet was
  // classified as a plain viewer: the user is not recognised as the creator of
  // their own work whenever they happen to be signing with another wallet.
  //
  // The session here is a REAL [SessionManager] over mocked stores and the set
  // handed to the resolver is its own `sessionAddresses` — the exact value
  // `artwork_detail_screen.dart` passes in production. A hand-written literal
  // (or a stubbed ownership predicate) would assert nothing about that wiring,
  // nor about the EIP-55 normalisation the EVM case below pins.
  //
  // Each field is checked twice: once for an address held by a NON-ACTIVE
  // session wallet (must resolve creator) and once for an unrelated address
  // (must stay viewer), so the widening cannot silently become "everyone is a
  // creator".
  group('creator across all session wallets', () {
    const activeWallet = 'SOL_ACTIVE_A';
    const linkedWallet = 'SOL_LINKED_B';
    const outsider = 'SOL_OUTSIDER_X';
    // The session stores the EIP-55 checksummed form; the API echoes it
    // lowercased on every creator/authority/royalty field.
    const evmChecksummed = '0xAbC0000000000000000000000000000000000001';
    const evmLowercased = '0xabc0000000000000000000000000000000000001';

    late SessionManager session;

    WalletInfo wallet(String id, String address, String chain) => WalletInfo(
      id: id,
      address: address,
      name: id,
      walletType: WalletType.hd,
      chain: chain,
      accountId: 'acc-1',
    );

    /// A real session spanning the active wallet, a second Solana wallet and a
    /// checksummed EVM wallet.
    Future<SessionManager> buildSession() async {
      final repo = _MockWalletRepository();
      final walletManager = _MockWalletManager();
      final storage = _MockSecureWalletStorage();
      final prefs = _MockPreferencesService();
      final profileLookup = _MockProfileLookupService();

      final wallets = [
        wallet('w-a', activeWallet, 'solana'),
        wallet('w-b', linkedWallet, 'solana'),
        wallet('w-eth', evmChecksummed, 'ethereum'),
      ];
      when(() => repo.getAccountViews()).thenAnswer(
        (_) async => [
          Account(id: 'acc-1', name: 'Account 01', wallets: wallets),
        ],
      );
      when(() => storage.storeLoginMode(any())).thenAnswer((_) async {});
      when(
        () => storage.storeSelectedAccountId(any()),
      ).thenAnswer((_) async {});
      when(() => storage.deleteActiveProfileId()).thenAnswer((_) async {});
      when(
        () => walletManager.switchWalletById(any()),
      ).thenAnswer((_) async {});
      when(() => prefs.lastSolanaWalletId(any())).thenReturn(null);

      final manager = SessionManager(
        repo,
        walletManager,
        storage,
        prefs,
        profileLookup,
      );
      await manager.switchToAccount('acc-1');
      return manager;
    }

    setUp(() async {
      session = await buildSession();
    });

    /// Resolve with [activeWallet] signing and the real session set. The
    /// artwork is always held by [outsider] so the (already widened) owner
    /// branch never short-circuits the creator checks under test.
    ArtworkRelationship relationshipFor(
      ArtworkDetails details, {
      Set<String> creatorLinkedAddresses = const {},
    }) => artworkRelationshipOf(
      currentAddress: activeWallet,
      sessionAddresses: session.sessionAddresses,
      artwork: details,
      creatorLinkedAddresses: creatorLinkedAddresses,
    );

    test('artistAddresses: non-active session wallet is the creator', () {
      expect(
        relationshipFor(
          artwork(
            artistAddress: outsider,
            artistAddresses: const [linkedWallet],
            ownerAddresses: const [outsider],
          ),
        ),
        ArtworkRelationship.creator,
      );
      expect(
        relationshipFor(
          artwork(
            artistAddress: outsider,
            artistAddresses: const [outsider],
            ownerAddresses: const [outsider],
          ),
        ),
        ArtworkRelationship.viewer,
      );
    });

    test('artistAddress: non-active session wallet is the creator', () {
      expect(
        relationshipFor(
          artwork(
            artistAddress: linkedWallet,
            ownerAddresses: const [outsider],
          ),
        ),
        ArtworkRelationship.creator,
      );
      expect(
        relationshipFor(
          artwork(artistAddress: outsider, ownerAddresses: const [outsider]),
        ),
        ArtworkRelationship.viewer,
      );
    });

    test('updateAuthority: non-active session wallet is the creator', () {
      expect(
        relationshipFor(
          artwork(
            artistAddress: outsider,
            updateAuthority: linkedWallet,
            ownerAddresses: const [outsider],
          ),
        ),
        ArtworkRelationship.creator,
      );
      expect(
        relationshipFor(
          artwork(
            artistAddress: outsider,
            updateAuthority: outsider,
            ownerAddresses: const [outsider],
          ),
        ),
        ArtworkRelationship.viewer,
      );
    });

    test('royaltySplits: non-active session wallet is the creator', () {
      expect(
        relationshipFor(
          artwork(
            artistAddress: outsider,
            royaltySplits: const [
              ArtworkRoyaltySplit(address: linkedWallet, sharePercent: 100),
            ],
            ownerAddresses: const [outsider],
          ),
        ),
        ArtworkRelationship.creator,
      );
      expect(
        relationshipFor(
          artwork(
            artistAddress: outsider,
            royaltySplits: const [
              ArtworkRoyaltySplit(address: outsider, sharePercent: 100),
            ],
            ownerAddresses: const [outsider],
          ),
        ),
        ArtworkRelationship.viewer,
      );
    });

    test(
      'creatorLinkedAddresses: non-active session wallet is the creator',
      () {
        expect(
          relationshipFor(
            artwork(artistAddress: outsider, ownerAddresses: const [outsider]),
            creatorLinkedAddresses: const {linkedWallet},
          ),
          ArtworkRelationship.creator,
        );
        expect(
          relationshipFor(
            artwork(artistAddress: outsider, ownerAddresses: const [outsider]),
            creatorLinkedAddresses: const {outsider},
          ),
          ArtworkRelationship.viewer,
        );
      },
    );

    // The bug class `apiOwnerAddress` exists to prevent: the API returns EVM
    // addresses lowercased while the session holds the EIP-55 checksummed form,
    // so a raw compare never matches and the creator of their own Ethereum
    // piece is classified as a viewer.
    test(
      'EVM: lowercased API artist matches the checksummed session wallet',
      () {
        expect(
          relationshipFor(
            artwork(
              artistAddress: evmLowercased,
              ownerAddresses: const [outsider],
            ),
          ),
          ArtworkRelationship.creator,
        );
        expect(
          relationshipFor(
            artwork(
              artistAddress: outsider,
              updateAuthority: evmLowercased,
              ownerAddresses: const [outsider],
            ),
          ),
          ArtworkRelationship.creator,
        );
        // Normalisation must not make unrelated hex addresses equal.
        expect(
          relationshipFor(
            artwork(
              artistAddress: '0x1111111111111111111111111111111111111111',
              ownerAddresses: const [outsider],
            ),
          ),
          ArtworkRelationship.viewer,
        );
      },
    );
  });

  // Every CTA this dispatcher can return builds a Solana marketplace tx. A
  // non-Solana artwork reaching a Buy / Bid / Cancel / Settle arm would sign
  // against a mint account that isn't a Solana mint — so the chain gate has to
  // win over *every* listing type, including the arms that fire before the
  // relationship is even computed.
  group('non-Solana artworks get no action sheet', () {
    const evmMint = '0x1111111111111111111111111111111111111111-42';
    const tezosMint = 'KT1abcdefghijklmnopqrstuvwxyz012345-7';

    // The mint shape alone must be enough (the wire `chain` is often absent),
    // and so must the wire `chain` alone (a Solana-shaped mint on an EVM
    // artwork). The disconnected case is here too: the gate has to beat the
    // connect-wallet arm, which fires before any relationship is computed.
    test('detected by mint shape or wire chain, connected or not', () {
      for (final (name, mint, chain, address) in [
        ('EVM mint shape', evmMint, null, owner),
        ('Tezos mint shape', tezosMint, null, other),
        ('wire chain ethereum', 'mint1', 'ethereum', other),
        ('wire chain tezos', 'mint1', 'tezos', other),
        ('EVM mint shape, disconnected', evmMint, null, null),
      ]) {
        final s = resolveArtworkActionState(
          artwork: artwork(
            mint: mint,
            listingType: ListingType.buyNow,
            chain: chain,
          ),
          currentAddress: address,
          creatorLinkedAddresses: const {},
          permissions: null,
        );
        expect(s, isA<ArtworkNoAction>(), reason: name);
      }
    });

    test('gate beats the owner-listed / auction-owner arms', () {
      final listed = resolveArtworkActionState(
        artwork: artwork(
          mint: evmMint,
          listingType: ListingType.buyNow,
          ownerAddress: owner,
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(listed, isA<ArtworkNoAction>());

      final auction = resolveArtworkActionState(
        artwork: artwork(
          mint: evmMint,
          listingType: ListingType.auction,
          ownerAddress: owner,
          auctionMetadata: AuctionMetadata(endsAt: DateTime.utc(2027)),
        ),
        currentAddress: owner,
        creatorLinkedAddresses: const {},
        permissions: null,
        now: DateTime.utc(2026),
      );
      expect(auction, isA<ArtworkNoAction>());
    });

    test('Solana artworks are untouched by the gate', () {
      final s = resolveArtworkActionState(
        artwork: artwork(listingType: ListingType.buyNow, chain: 'solana'),
        currentAddress: other,
        creatorLinkedAddresses: const {},
        permissions: null,
      );
      expect(s, isA<ArtworkBuyAction>());
    });
  });
}
