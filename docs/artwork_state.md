# Artwork Detail Bottom-Sheet State Spec

This document enumerates every bottom-sheet layout the artwork detail screen
(`lib/features/artwork/screens/artwork_detail_screen.dart`) renders, indexed by
the user's relationship to the artwork × the artwork's listing state × supply
type. It is the canonical reference for the dispatcher in
`lib/features/artwork/services/artwork_action_state.dart`. It mirrors the web
client's own action-box logic, which is not part of this repository — the
parity notes below record *what* that behaviour is and why this app matches it.

**Stub status — the convention is gone; the tables below have been de-stubbed.**
The helper this document used to describe, `showArtworkSheetComingSoon`, has been
**deleted** from `artwork_sheet_frame.dart` — it had zero call sites, and
`grep -rni "coming soon" lib/` now returns nothing. Buy, Buy edition, Make offer,
Place bid, Cancel auction, Settle auction, Reclaim/Claim NFT, Accept highest
offer and Update/Cancel listing are all live transactions dispatched through
`lib/features/artwork/screens/artwork_detail_screen/actions.dart`; so are the
three CTAs most often mis-read as stubs — the connect-wallet sheet
(`AuthService.refresh()`), `View on mallow web` (`openArtworkOnWeb`) and
`View N offers` (`_showOffers`). The one genuinely inert control is the raffle
sheet's `Draw pending…`, which is a status line in a button slot: `enabled: false,
onPressed: null`, no `onDisabledTap`, no snackbar. Where a CTA is not rendered at
all, the tables say so explicitly rather than calling it a stub.

## Input Dimensions

The dispatcher resolves a state from these inputs:

- **Auth** — `AuthService.currentAddress` (`null` = wallet not connected)
- **Relationship** — derived from `currentAddress` against the artwork:
  - `owner` — membership in `artwork.ownerAddresses` (full list of wallets
    linked to the indexed owner) or matches `auctionMetadata.seller` for
    active auctions. The single `ownerAddress` field is checked as a
    fallback when the user has only one linked wallet. Note: when an NFT
    is listed, on-chain ownership transfers to the marketplace escrow —
    the API tracks the seller, so this check works for listed items too.
  - `creator` — membership in `artistAddresses`, or matches
    `artistAddress`, `updateAuthority`, any `royaltySplits[].address`, or
    any wallet in `_creatorLinkedAddresses`
  - `viewer` — connected but unrelated
  - `disconnected` — `currentAddress == null`
- **Listing type** — `NftDetail.listingType` enum: `unlisted` | `buy-now` |
  `auction` | `raffle` | `store` | `gumball` | `airdrop` | `jellybean`
- **Supply type** — `SupplyType`: `1/1` | `limited-edition` |
  `open-edition` | `edition-print` | `collection`
- **Auction sub-state** (when `listingType == auction`):
  `pre-start` | `live-no-bids` | `live-with-bids` | `ended-with-bids` |
  `ended-no-bids` — derived from `auctionMetadata.startsAt/endsAt/bidCount`
- **Edition mastership** — `isPrintableMasterEdition` 🔴 — needs DAS supply
- **Offer state** — `highestOffer != null`, `offersCount`, `userOwnOffer` 🔴
- **Permissions** — `ArtworkPermissions { canList, canTransfer, canBurn,
canEdit }` from `ArtworkPermissionService`

## State Resolution Decision Tree

The dispatcher walks the checks in this exact order. The first matching branch
selects the sheet variant. Solana-only — Tezos / Objkt / OpenSea / Ethereum
branches from the reference web client are intentionally absent.

**mallow-program-only.** Every CTA below builds an instruction for
`mallow_market`, `mallow-auction` or `rafffle`. A **listed** artwork whose
`lastSource` names another marketplace (`magic-eden`, `exchange-art`,
`formfunction`, `objkt`, `opensea`) gets **no sheet at all** — the owner keeps
only Transfer, which lives in the permission-driven context menu and is out of
this tree. Null and `unknown` mean mallow, matching the reference web client,
which defaults an absent source to mallow; the field is sparsely
populated, so defaulting the other way would suppress every legitimate CTA.

The suppression is scoped to `listingType != unlisted` on purpose.
`lastSource` records the last marketplace the piece **traded** on, not where it
currently lives, so an unlisted artwork that once sold on magic-eden still
carries a foreign source. Suppressing on the source alone would strip the List
CTA from a piece its owner holds outright — a mallow listing built for it is
perfectly valid, and the reference web client's list-permission rule never
consults `lastSource` either.

```
if currentAddress == null:
    → ConnectWalletSheet(label = labelFor(listingType))

if listingType != unlisted and lastSource is foreign (not null / mallow / unknown):
    → NoAction                      # no Buy / bid / update / cancel / claim

if listingType == gumball | airdrop | store | jellybean:
    → ExternalLinkSheet(listingType)

if a raffle in unclaimedRaffles is claimable BY THIS WALLET
   (excludes the raffle the main sheet already shows):
    → UnclaimedRaffleSheet(raffle, claim)

if listingType == raffle:
    → RaffleSheet(role, subState, gate)

if listingType == auction:
    if auctionEnded(auctionMetadata):
        → AuctionClaimSheet(role, hasBids)
    else if relationship == owner:
        → AuctionOwnerSheet(auctionMetadata)
    else:
        → AuctionBidSheet(auctionMetadata)

if listingType == buy-now:
    if relationship == owner:
        → OwnerListedSheet(highestOffer)
    buyBlock = saleWindowBlock(buyNowMetadata) ?? currencyBlock(supplyType, currency)
    if isPrintableMasterEdition || supplyType in {limited-edition, open-edition}:
        → BuyEditionSheet(buyNowMetadata, buyBlock)
    → BuySheet(buyNowMetadata, buyBlock)  // existing widget, 1/1 + edition-print

// listingType == unlisted
if relationship == owner:
    canSend = permissions.canTransfer
    canList = permissions.canList && !isFlagged && !soldOutMaster
    if !canList && !canSend:
        → null                             // no movement and no listing → no sheet
    → OwnerUnlistedSheet(canList, canSend, highestOffer)
→ UnlistedViewerSheet(highestOffer)        // viewer or creator
```

### Buy blocks (`ArtworkBuyBlock`)

Both buy sheets take an optional block; non-null renders the CTA disabled with
the reason instead of an enabled Buy that fails downstream.

| Block                 | Condition                                                      | CTA label            | Why                                                                    |
| --------------------- | -------------------------------------------------------------- | -------------------- | ---------------------------------------------------------------------- |
| `notStarted`          | `buyNowMetadata.startsAt > now`                                 | "Sale not started"   | parity — the reference web client hard-disables Buy outside the sale window |
| `ended`               | `buyNowMetadata.endsAt <= now`                                  | "Sale ended"         | same window check, upper bound                                         |
| `unknownCurrency`     | listing currency's metadata is still resolving or failed        | "Buy" (disabled)     | mobile-only — never sign for an amount that was never displayed        |

There is **no currency-support gate**. Both v2 buy builders settle in the
listing's own currency, so an SPL-denominated 1/1, a secondary `edition-print`
resale and a master-edition print are all normal purchases; `swapQuote` is only
for paying with a *different* token, which mobile never sends. An
`unsupportedCurrency` block that disabled those CTAs as "Unavailable in app" was
removed 2026-08-06 when the contract confirmed the behavior.

### Owner listing policy (`soldOutMaster`)

`supplyType ∈ {limited-edition, open-edition}` and `supply >= maxSupply` (both
present). Mirrors the reference web client's sold-out rule.
`isFlagged` gates listing only — that client wraps just its "List for sale"
button and leaves Transfer outside it.

When the resolver returns `null`, the screen simply omits the sticky sheet and
restores its bottom padding to zero.

## State Matrix

Tables below quote button strings exactly as they render. There is no longer a
"stub" class — every CTA listed is wired unless the cell says **not rendered**
or the Sheet column says **(no sheet)**.

### `unlisted`

| Relationship         | Supply                             | Sheet                 | Primary CTA                                                            | Secondary                                                 | Status text                                                                                          | Disabled when                                       | Data needed                                            |
| -------------------- | ---------------------------------- | --------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------ |
| `disconnected`       | any                                | `ConnectWalletSheet`  | "Sign in to make offer"                                                | —                                                         | —                                                                                                    | —                                                   | none                                                   |
| `owner` + `canList` + `canTransfer` | any (non-collection) | `OwnerUnlistedSheet`  | "List artwork"                                                         | "Send artwork"; "Accept highest offer" when `highestOffer != null` | "You own this artwork" / "Create a sale to put it on the marketplace." / "Highest offer: X SOL"      | —                                                   | `highestOffer` ✅, `userOwnOffer` 🔴                   |
| `owner` + `!canList` + `canTransfer` (flagged, sold-out master, or listing-denied) | any | `OwnerUnlistedSheet` | "Send artwork"                                | "Accept highest offer" when `highestOffer != null`        | as above                                                                                             | "List artwork" not rendered                         | `permissions.canTransfer` ✅, `isFlagged` ✅           |
| `owner` + `canList` + `!canTransfer` | any                | `OwnerUnlistedSheet`  | "List artwork"                                                         | "Accept highest offer" when `highestOffer != null`        | as above                                                                                             | "Send artwork" not rendered                         | `permissions.canTransfer` ✅                           |
| `owner` + `!canList` + `!canTransfer` | any               | (no sheet)            | —                                                                      | —                                                         | —                                                                                                    | hidden                                              | `permissions` ✅                                       |
| `viewer` / `creator` | `1/1` ∨ `edition-print`            | `UnlistedViewerSheet` | "Make offer" — or "Cancel offer" when user owns an offer               | —                                                         | "Highest offer: X SOL" when `highestOffer != null`; "View offers" link when `offersCount > 1`        | "Cancel offer" disabled while cancelling            | `highestOffer` ✅, `offersCount` ✅, `userOwnOffer` 🔴 |
| `viewer` / `creator` | `limited-edition` ∨ `open-edition` | **(no sheet)**        | **not rendered** — edition masters resolve to `ArtworkNoAction`         | —                                                         | — (`resolveArtworkActionState`'s edition-master arm in `artwork_action_state.dart`, marked `// TODO: show make offer when edition offers are live`)      | hidden                                              | — (blocked on edition offers)                          |
| any                  | `collection`                       | (no sheet)            | —                                                                      | —                                                         | —                                                                                                    | hidden — collection root has no per-listing actions | —                                                      |

### `buy-now`

| Relationship         | Supply                             | Sheet                 | Primary CTA             | Secondary                                                                          | Status text                                                                                                         | Disabled when                                                    | Data needed                                                         |
| -------------------- | ---------------------------------- | --------------------- | ----------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------- |
| `disconnected`       | any                                | `ConnectWalletSheet`  | "Sign in to buy"        | —                                                                                  | listing price + supply progress                                                                                     | —                                                                | `buyNowMetadata` ✅                                                 |
| `owner`              | any                                | `OwnerListedSheet`    | "Update listing"        | "Accept highest offer" when `highestOffer != null` — **"Cancel listing" is not a secondary button on this sheet**; it lives inside the update sheet (the `_cancelFlow` / "Cancel listing" action in `market/widgets/update_listing_sheet.dart`) | listing price; "Highest offer: X SOL" when present                                                                  | "Update listing" disabled during in-flight tx                    | `buyNowMetadata` ✅, `highestOffer` ✅                              |
| `viewer` / `creator` | `1/1` ∨ `edition-print`            | `BuySheet` (existing) | "Buy"                   | "Make offer" when 1/1 or printed edition                                           | listing price + USD; supply progress when `quantityTotal != null`; block explanation when disabled                  | "Buy" disabled while loading, or on any `ArtworkBuyBlock`        | `buyNowMetadata` ✅                                                 |
| `viewer` / `creator` | `limited-edition` ∨ `open-edition` | `BuyEditionSheet`     | "Buy edition"           | **not rendered** — the "Make offer" button is commented out in `artwork_buy_edition_sheet.dart` (`// TODO: Unhide when we support master edition offers.`) until edition offers ship | "X / Y sold" supply progress; "Sale ends in …" countdown when `endsAt != null`; "Starts in …" when `startsAt > now` | "Buy edition" disabled when sold out, before start, or after end | `buyNowMetadata` ✅, `isPrintableMasterEdition` ✅, wallet-limit ✅  |
| any                  | `collection`                       | (no sheet)            | —                       | —                                                                                  | —                                                                                                                   | hidden — collection root has no per-listing actions              | —                                                                   |

### `auction` (active — see Auction Sub-States below)

| Relationship         | Sub-state                    | Sheet                | Primary CTA                                                                                            | Secondary | Status text                                         |
| -------------------- | ---------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------ | --------- | --------------------------------------------------- |
| `disconnected`       | active                       | `ConnectWalletSheet` | "Sign in to place bid"                                                                                 | —         | reserve / highest bid + countdown                   |
| `owner`              | `pre-start` ∨ `live-no-bids` | `AuctionOwnerSheet`  | "Cancel auction"                                                                                       | —         | "Reserve price: X" / "Auction starts in …"          |
| `owner`              | `live-with-bids`             | `AuctionOwnerSheet`  | (no primary; cancel disabled)                                                                          | —         | "Highest bid: X" / "Auction ends in …"              |
| `viewer` / `creator` | `pre-start`                  | `AuctionBidSheet`    | "Auction pending start" (disabled) — the `timing.preStart` arm of `ArtworkAuctionBidSheet`'s `actionBuilder`                               | —         | "Auction starts in …" + reserve price               |
| `viewer` / `creator` | `live-no-bids`               | `AuctionBidSheet`    | "Place bid"                                                                                            | —         | "Reserve price: X" + "Auction ends in …"            |
| `viewer` / `creator` | `live-with-bids`             | `AuctionBidSheet`    | "Place bid" — or "You are the highest bidder" disabled when the current wallet is the high bidder      | —         | "Highest bid: X" + bidder ref + "Auction ends in …" |

### `auction` (ended — see Auction Sub-States below)

| Relationship                      | Sub-state         | Sheet                | Primary CTA             | Status text                   |
| --------------------------------- | ----------------- | -------------------- | ----------------------- | ----------------------------- |
| `disconnected`                    | ended             | `ConnectWalletSheet` | "Sign in to view"       | "Auction ended"               |
| `owner` (seller)                  | `ended-with-bids` | `AuctionClaimSheet`  | "Settle auction"        | "Winning bid: X" + winner ref |
| `owner` (seller)                  | `ended-no-bids`   | `AuctionClaimSheet`  | "Reclaim NFT"           | "Auction ended with no bids"  |
| winner 🔴                         | `ended-with-bids` | `AuctionClaimSheet`  | "Claim NFT"             | "You won! Winning bid: X"     |
| `viewer` (not winner, not seller) | `ended-with-bids` | `AuctionClaimSheet`  | (no CTA; status only)   | "Final price: X" + winner ref |

### `raffle` — see Raffle Sub-States below

`RaffleRole.owner` is the raffle's **creator** (`raffleMetadata.creator`), not
the indexed NFT owner: a live raffle escrows the prize, so the creator is
usually not the owner of record. Resolving the role off ownership alone
classified the creator as a buyer and left the terminal states with no CTA.

**Ticket purchase links out.** The primary buy CTA is "View on mallow.art",
not an in-app transaction (`kShowRaffleEntry`, `core/config/store_build.dart`).
The gates below therefore govern what the sheet *shows and allows* — a
sold-out, limit-reached or finished raffle must never present a live buy CTA.

| Relationship   | Sub-state                | Sheet                | Primary CTA                                | Secondary | Status text                          |
| -------------- | ------------------------ | -------------------- | ------------------------------------------ | --------- | ------------------------------------ |
| `disconnected` | any                      | `ConnectWalletSheet` | "Sign in to buy tickets"                   | —         | ticket price + entries / slots       |
| `buyer`        | `selling` (can buy)      | `RaffleSheet`        | "View on mallow.art" (buy CTA behind flag) | —         | price + "X / Y sold" + wallet limit  |
| `buyer`        | `selling` (sold out)     | `RaffleSheet`        | "Sold out" (disabled) + view on web        | —         | "Sold out"                           |
| `buyer`        | `selling` (limit hit)    | `RaffleSheet`        | "Tickets unavailable" (disabled)           | —         | price + "Your tickets: N"            |
| `owner`        | `selling` (no entries)   | `RaffleSheet`        | "Cancel raffle"                            | —         | ticket price + "0 / Y sold"          |
| `owner`        | `selling` (with entries) | `RaffleSheet`        | "Cancel unavailable (tickets sold)"        | —         | "X / Y sold"                         |
| any            | `awaiting-draw`          | `RaffleSheet`        | "Draw pending…" (disabled)                 | —         | "Awaiting draw"                      |
| winner         | `drawn-unclaimed`        | `RaffleSheet`        | "Claim NFT"                                | —         | "You won!"                           |
| `owner`        | `drawn-unclaimed`        | `RaffleSheet`        | "Claim proceeds"                           | —         | "Raffle drawn — proceeds pending"    |
| viewer         | `drawn-unclaimed`        | `RaffleSheet`        | (no CTA; status only)                      | —         | "Raffle drawn" + winner ref          |
| `owner`        | `drawn-claimed`          | `RaffleSheet`        | "Claim proceeds" (or "Proceeds claimed")   | —         | "Raffle drawn — prize claimed"       |
| winner/viewer  | `drawn-claimed`          | `RaffleSheet`        | (no CTA; status only)                      | —         | "You claimed your prize" / "Raffle drawn" |
| `owner`        | `ended-cancelled`        | `RaffleSheet`        | **"Reclaim NFT"**                          | —         | "Raffle ended — no tickets sold"     |
| viewer         | `ended-cancelled`        | `RaffleSheet`        | (no CTA; status only)                      | —         | "Raffle ended — no tickets sold"     |

The `owner` × `drawn-unclaimed` row previously offered "Reclaim NFT". That
transaction cannot succeed — the prize belongs to the winner, and the backend
rejects it with "Creator can only reclaim the prize after a no-bid expiry". The creator's reclaim
lives on the `ended-cancelled` row only.

### Unclaimed raffles (`UnclaimedRaffleSheet`)

`/v1/artwork/byMint` returns **every** initialized, unclaimed raffle for the
mint, with no user scoping, and the response may be served from a cache for a
few minutes. The dispatcher filters it down to the one raffle **this** wallet
can act on, porting the web client:

| Condition                                                     | `UnclaimedRaffleClaim` | CTA              |
| ------------------------------------------------------------- | ---------------------- | ---------------- |
| viewer is `winner` and `!isPrizeClaimed`                      | `prize`                | "Claim NFT"      |
| viewer is `creator`, winner drawn, `!isClaimed`               | `proceeds`             | "Claim proceeds" |
| viewer is `creator`, no winner, `sold == 0`, `!isPrizeClaimed`| `reclaim`              | "Reclaim NFT"    |

The raffle the main sheet is already showing is always excluded. One
deliberate narrowing from the reference web client: it also keeps any awaiting-draw raffle
because its box renders *above* the action box and is informational; mobile
has a single sheet slot, so an inert panel there would displace the live
listing's CTA.

### `gumball` / `airdrop` / `store` / `jellybean`

| Relationship | Sheet               | Primary CTA                                 | Status text                             |
| ------------ | ------------------- | ------------------------------------------- | --------------------------------------- |
| any          | `ExternalLinkSheet` | "View on mallow web" — live outlink, not a stub: `_openOnWeb` → `openArtworkOnWeb(mintAccount)` | "This sale runs on the mallow web app." |

`jellybean` routes here too. It reaches the branch **before** the owner /
viewer arms, which is the point: falling through offered "List artwork" and
"Accept offer" on a Jellybean artwork, both of which the reference web client refuses.

## Auction Sub-States

Computed from `auctionMetadata` (`startsAt`, `endsAt`, `bidCount`).

| Sub-state         | Condition                            | UI Notes                                                                             |
| ----------------- | ------------------------------------ | ------------------------------------------------------------------------------------ |
| `pre-start`       | `startsAt != null && startsAt > now` | Shows "Auction starts in …" countdown; primary CTA reads "Place bid" but is disabled |
| `live-no-bids`    | started, not ended, `bidCount == 0`  | Title: "Reserve price". CTA enabled. Owner can cancel                                |
| `live-with-bids`  | started, not ended, `bidCount > 0`   | Title: "Highest bid". Owner cannot cancel (parity with the reference web client)                       |
| `ended-with-bids` | `endsAt < now && bidCount > 0`       | Switches to claim panel — settle for seller, claim for winner                        |
| `ended-no-bids`   | `endsAt < now && bidCount == 0`      | Owner sees "Reclaim NFT"; viewers see status only                                    |

When `startsAt == 0` the auction "starts on first bid" — treat as `live-no-bids`.

## Raffle Sub-States

Sub-states for `listingType == raffle`, at parity with the reference web client.
Backend data is 🔴 — see Data Requirements.

Port of that client's own raffle-state derivation. Checked in this order:

| Sub-state         | Condition                                                        |
| ----------------- | ---------------------------------------------------------------- |
| `drawn-unclaimed` | `winner != null && !isPrizeClaimed`                              |
| `drawn-claimed`   | `winner != null && isPrizeClaimed` — creator may still claim proceeds |
| `selling`         | no winner and (`endsAt == null` or `endsAt > now`)                |
| `ended-cancelled` | closed, no winner, `sold == 0` (or `isExpired`) — creator reclaims |
| `awaiting-draw`   | closed, no winner, `sold > 0`                                    |

A winner is terminal whatever the clock says. `endsAt == null` reads as
*selling* on mobile — the reference web client gets "ended" there only because
its date helper treats an undefined end as *now*, which is the wrong default
for a live raffle.

`drawn-claimed` did not exist before and fell through to `selling`, putting a
live "Buy tickets" CTA on a finished raffle. `ended-cancelled` was only
reachable via the server's `isExpired` flag, which left the creator's reclaim
path dark whenever the flag was absent.

### Buy gates (`RaffleGate`)

Port of the reference web client's buy-eligibility and per-wallet-limit rules:

- `isSoldOut` = `sold >= (supply ?? 0)`
- `walletLimit` = `min(ticketLimit, floor(supply × 0.4))`, or the 40 % cap when
  no `ticketLimit` is configured
- `userTickets` = `countByEntrant` summed over the session's wallets
- `canBuyTickets` = `supply != null && userTickets < walletLimit && !isOwner &&
  subState == selling && !isSoldOut`

**`raffleMetadata.price` is raw base units, not display units.** The API returns
the on-chain integer and passes it through untouched; every client is expected to
divide by `10 ** token.decimals` before display. The Dart field
is named `priceRaw` so the mistake cannot be repeated silently — rendering it
directly turned a 0.1 SOL ticket into "100000000 SOL" and made the balance
check demand 1e17 lamports.

## Connect-Wallet Variants

`ConnectWalletSheet` re-skins by `listingType` so the CTA matches the action
the wallet would unlock.

| `listingType`                   | Button label             |
| ------------------------------- | ------------------------ |
| `unlisted`                      | "Sign in to make offer"  |
| `buy-now`                       | "Sign in to buy"         |
| `auction` (active)              | "Sign in to place bid"   |
| `auction` (ended)               | "Sign in to view"        |
| `raffle`                        | "Sign in to buy tickets" |
| `gumball` / `airdrop` / `store` | "Sign in to participate" |

The button is **live**, not a stub: it calls `AuthService.refresh()` and then
re-resolves the action state so the sheet swaps to the real CTA
(`artwork_connect_wallet_sheet.dart`, `_signIn`). Note there is no separate
"connect a wallet" identity in this app — the signing wallet *is* the account —
so this sheet is only reachable in the narrow window where a wallet exists but
its backend login does not.

## Data Requirements

Layouts above mark fields with one of:

- ✅ already on `ArtworkDetails`
- 🟡 in `/v1/artwork/byMint/:mint` payload but not yet parsed in Flutter
- 🔴 needs additional on-chain RPC / DAS / program fetch
- 🟠 needs a separate API endpoint (HTTP)

This is the complete list of supplemental data the reference web client's action
box and its child panels — the unlisted, buy-now (buyer and seller), auction bid,
auction claim, edition, raffle and unclaimed-raffle panels, plus the activity and
bid-history views — consume on top of `/byMint`. Each placeholder in the Flutter
dispatcher carries a `// TODO(byMint): <field>` comment naming which row below
blocks it.

### ✅ Already in `/byMint` payload — parsed in Flutter (Phase 1, landed)

These come back from `/v1/artwork/byMint/:mint` and are now parsed on
`packages/mallow_api/lib/src/models/artwork.dart` and surfaced through
`ArtworkDetails`. The resolver consumes them for raffle sub-state, auction
winner detection, and the unclaimed-raffles branch.

| Field                             | Surfaced as                                                | Used by                                                                                                      |
| --------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `auctionMetadata.bidders`         | `AuctionMetadata.bidders: List<String>`                    | bid-history button (avatar strip — Phase 5), auction-claim modal handoff                                     |
| `auctionMetadata.bidderPfps`      | `AuctionMetadata.bidderPfps: List<String?>`                | bid-history avatar strip                                                                                     |
| `auctionMetadata.currentBidder`   | `AuctionMetadata.currentBidder: String?`                   | resolver winner detection (`AuctionEndedRole.winner`); future "You're the highest bidder" disable in Phase 5 |
| `auctionMetadata.minBidIncrement` | `AuctionMetadata.minBidIncrement: int?`                    | absolute-amount min-bid alternative to bps                                                                   |
| `raffleMetadata`                  | `ArtworkDetails.raffleMetadata: RaffleMetadata?`           | every `ArtworkRaffleSheet` sub-state — resolver derives `RaffleSubState` from `winner`/`isPrizeClaimed`/`endsAt`/`sold` |
| `raffleMetadata.price`            | `RaffleMetadata.priceRaw: double?` (**base units**)        | ticket price + total-cost lines, and the buy-side balance check                                              |
| `raffleMetadata.supply`/`sold`/`ticketLimit` | same names on `RaffleMetadata`                   | `RaffleGate` — sold-out, wallet limit, remaining supply                                                      |
| `raffleMetadata.countByEntrant`   | nested map                                                 | `RaffleGate.userTickets` — "Your tickets: N" + the wallet-limit gate                                         |
| `unclaimedRaffles`                | `ArtworkDetails.unclaimedRaffles: List<RaffleMetadata>`    | `ArtworkUnclaimedRaffleSheet` — filtered to raffles THIS wallet can claim (the list is user-agnostic)        |
| `lastSource`                      | `ArtworkDetails.lastSource: MarketSource?`                 | foreign-marketplace suppression — no sheet at all, for listed artwork only (`listingType != unlisted`)       |
| `creator.isFlagged`               | `ArtworkDetails.creatorIsFlagged: bool`                    | hides the owner "List artwork" CTA (and nothing else)                                                        |
| `secondaryEditions`               | `ArtworkDetails.secondaryEditions: SecondaryEditionsData?` | "Buy lowest secondary price" sub-CTA + listed-count badge (Phase 6 wiring)                                   |
| `groupedSale`                     | `ArtworkDetails.groupedSale: GroupedSale?`                 | "Select edition" dropdown (Phase 6 wiring)                                                                   |
| `redeemableTxId`                  | `ArtworkDetails.redeemableTxId: String?`                   | "Redeem physical item" CTA (future phase wiring)                                                             |
| `isFlagged`                       | `ArtworkDetails.isFlagged: bool`                           | resolver hides owner "List artwork" CTA when true                                                            |
| `offChainWhitelistDenied`         | `ArtworkDetails.offChainWhitelistDenied: bool?`            | edition allowlist gating in Phase 2                                                                          |
| `creatorIsFlagged`                | not yet                                                    | requires `User.isFlagged` on the creator object — pending model extension                                    |

### 🔴 On-chain RPC / DAS / program fetches (routed through backend)

Each of these requires a dedicated Solana fetch. None are bundled into
`/byMint`. The Flutter wallet does not decode program accounts itself —
every read goes through a backend wrapper route. Below is the consumer side
on Flutter:

| Concern                          | Flutter consumer                                                                                                                     | Status     |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ---------- |
| Live auction state               | `AuctionLiveRepository.getState` → `GET /v2/auctions/:mint` on the v2 client. **Not polled.** Fetched once by `ArtworkBloc._primeLiveAuction` when the artwork loads with auction metadata, and re-primed on realtime reconnect/invalidation; live bids otherwise arrive over the account subscription. The only `Timer.periodic` nearby is `ArtworkAuctionLivePanel`'s countdown ticker, which does no I/O | ✅ Phase 5 |
| Edition wallet caps + whitelist  | `MarketListingRepository.getEditionPurchaseStats` (`GET /v2/editions/:mint/buyers/:buyer` — `BuyEditionHistory` + `WhitelistConfig` in one round trip)                                | ✅ Phase 6 |
| Live raffle state                | `RaffleRepository.getState` (`GET /v2/raffles/:raffle_key`) — fetched by `_maybeLoadRaffleLive`, overlaid onto `raffleMetadata` before the sub-state + gate derivation | ✅ wired    |
| Offer detection (per-buyer)      | `OfferRepository.getUserActiveOffer` via existing `POST /v1/offers` (no new on-chain fetch needed)                                   | ✅ Phase 3 |
| `isPrintableMasterEdition` (DAS) | `MarketListingRepository.getEditionState` (`GET /v2/editions/:mint`) — drives dispatcher routing + live supply progress bar | ✅ Phase 9 |

#### DAS provider

| Field                                                     | Source                                                            | Gates                                                                                               |
| --------------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `isPrintableMasterEdition`                                | `getAsset` → `supply` / `maxSupply` / `edition` on `DigitalAsset` | dispatcher: `BuyEditionSheet` vs `BuySheet` routing                                                 |
| Live `supplyInfo` (sold count, total minted for editions) | `getAsset` `supply` field — refreshes with each mint              | `BuyEditionSheet` progress bar (currently uses cached `quantitySold`/`quantityTotal` from indexer)  |
| Token-account state (current holder, freeze, delegate)    | `getAsset` + token-account fetch                                  | `ArtworkPermissionService` already partial; needed in full for "Cancel listing" / "Transfer" gating |

#### `mallowMarket` program

| Field                                | Source                                                                 | Gates                                                                                                                                                                                                                                                   |
| ------------------------------------ | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MallowMarket.Listing` PDA           | `mallowMarket.accounts.listing(mint)`                                  | `OwnerListedSheet` "Cancel listing" / "Update listing" — needs the live listing PDA to build the cancel/update tx                                                                                                                                       |
| `MallowMarket.Offer` PDA per buyer   | `mallowMarket.accounts.offer(buyer, mint)`                             | ✅ avoided in Phase 3 — `OfferRepository` reads `POST /v1/offers` with `filter: { buyer, nftMint, activeOnly }` and gets the same signal without a new on-chain fetch. Direct PDA read becomes useful only if we need fields the index doesn't surface. |
| `MallowMarket.WhitelistConfig` PDA   | `mallowMarket.program.account.whitelistConfig.fetch(...)`              | edition allowlist phase: provides Merkle root + duration; combined with `/v0/whitelist/checkEligibility` to disable buy with "Not allowlisted"                                                                                                          |
| `MallowMarket.BuyEditionHistory` PDA | `mallowMarket.program.account.buyEditionHistory.fetch(buyer, listing)` | `BuyEditionSheet` per-wallet purchase cap — disables "Buy edition" with "Wallet limit reached" when `buyCount >= editionsLimit`                                                                                                                         |

#### `mallowAuction` program

| Field                                 | Source                       | Gates                                                                                              |
| ------------------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------- |
| Live `MallowAuction` state            | `mallowAuction` PDA          | authoritative `currentBidder`, `currentBidAmount`, `endsAt` (the indexed values can lag the chain) |
| Settlement state (claimed vs settled) | derived from auction account | `AuctionClaimSheet` — distinguishes "Settle auction" (still owed) from no-CTA observer view        |

#### `rafffles` program

| Field          | Source                                | Gates                                                                                                    |
| -------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Raffle account | `rafffles.accounts.raffle(raffleKey)` | `RaffleSheet` `awaiting-draw` / `drawn-unclaimed` sub-states; `Reclaim NFT` / `Claim proceeds` for owner |

### 🟠 Separate API endpoints (HTTP)

| Endpoint                           | Method                          | Status                                                            | Returns                                           | Used by                                                                                                                                          |
| ---------------------------------- | ------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/v0/whitelist/checkEligibility`   | POST `{ merkleRoots, address }` | ✅ Phase 2 (`WhitelistEligibilityRepository`)                     | `string[]` of roots the user is eligible for      | edition allowlist gating in `BuyEditionSheet` (combined with on-chain `WhitelistConfig`)                                                         |
| `/v0/userWithDetails`              | POST                            | ✅ via existing `UserProfileRepository.getUserProfiles` (Phase 2) | `UserWithDetails` (display name, avatar, socials) | "Winner: @handle" / "by @handle" rows in `AuctionClaimSheet`, `AuctionBidSheet`, `AuctionOwnerSheet`, `RaffleSheet`                              |
| `/v0/events/byMint/:mint`          | POST (paginated)                | ✅ Phase 2 (`ArtworkEventsRepository`)                            | `MarketEvent[]`                                   | activity-history panel + bid-history modal opened from `AuctionBidSheet` / `AuctionClaimSheet` (UI consumption deferred to Phase 5)             |
| `/v0/events/gumballSales/:id`      | POST (paginated)                | not yet                                                           | `CollectionActivityEvent[]`                       | activity panel for gumball drops                                                                                                                 |
| `/v0/events/jellybeanSales/:id`    | POST (paginated)                | not yet                                                           | `CollectionActivityEvent[]`                       | activity panel for jellybean drops                                                                                                               |
| `offers-by-mint` (not implemented) | —                               | n/a                                                               | offer list                                        | Fallback for `userOwnOffer` if we choose not to do the per-buyer PDA fetch above. The PDA fetch is more direct; this endpoint stays speculative. |

### Suggested service decomposition

To keep the dispatcher unblocked, group the work behind these services:

- `OnChainAssetService` (extend the existing `DigitalAsset` fetch) — DAS supply / edition / token-account state
- `MarketListingService` — `MallowMarket.Listing` + `Offer` + `WhitelistConfig` + `BuyEditionHistory` PDAs
- `AuctionLiveService` — `MallowAuction` PDA + settlement state
- `RaffleService` — `rafffles` program account + winner derivation
- `WhitelistEligibilityClient` — wraps `/v0/whitelist/checkEligibility`
- `EventsRepository` — wraps `/v0/events/*` for activity/bid history
- `UserWithDetailsRepository` — wraps `/v0/userWithDetails`
- Extend the `mallow_api` `NftDetail` / `AuctionMetadata` / `ArtworkResult`
  models to parse the 🟡 fields above; then add pass-throughs on
  `ArtworkDetails`.

## Out of Scope

The web client also routes the following branches; Flutter does
not implement them and the dispatcher does not check for them:

- Tezos / Objkt panels ("Buy on Objkt", "Place bid on Objkt", Objkt edition
  flows)
- Ethereum / OpenSea panels ("Buy on OpenSea", Ethereum unlisted view)
- Jellybean and Gumball external app panels (Flutter shows a generic
  `ExternalLinkSheet` instead)
- Header / dots-menu actions (cast / share / like) — owned by the screen,
  unchanged by this spec
- `MarketConfirmationSheet` — unchanged; drives buy/offer confirmation flows for
  the (now wired) buttons above
