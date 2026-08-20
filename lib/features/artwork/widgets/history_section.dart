import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/router/app_router.dart';
import '../../../core/services/token_metadata_service.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/time_utils.dart';
import '../../../shared/widgets/token_amount_text.dart';
import '../data/artwork_events_repository.dart';
import 'activity_list_row.dart';
import 'paged_section.dart';

/// Webapp parity: the History component fetches `/v0/events/byMint` with
/// `mode: all` in 100-row pages (`History`).
const int _kPageSize = 100;

/// History tab on the artwork page. Shows the same
/// activity rows the webapp's "Activity" list renders, with load-more
/// paging mirroring the webapp's infinite query.
class HistorySection extends StatelessWidget {
  const HistorySection({
    required this.mintAccount,
    this.refreshToken = 0,
    super.key,
  });

  final String mintAccount;

  /// Bumped on each indexer-driven refresh to re-pull page 0 in place.
  final int refreshToken;

  @override
  Widget build(BuildContext context) {
    return PagedSection<api.MarketActivityEvent>(
      refreshToken: refreshToken,
      identity: (event) => event.txId,
      // `fetchEvents`, not `getEvents`: the swallowing variant turns a dropped
      // request into an empty page, which this surface would render as "No
      // history yet." — a claim about the chain, made from a network failure.
      fetchPage: (page) async {
        final result = await sl<ArtworkEventsRepository>().fetchEvents(
          mintAccount: mintAccount,
          page: page,
          pageSize: _kPageSize,
          mode: api.EventMode.all,
        );
        return (
          items: result.result
              .where((e) => e.type != api.MarketEventType.ignore)
              .toList(),
          nextPage: result.nextPage,
        );
      },
      emptyLabel: 'No history yet.',
      errorLabel: "Couldn't load history.",
      rowBuilder: (event) => _ActivityRow(event: event),
    );
  }
}

/// Marketplace badge appended to a mint row — the webapp's
/// `MarketSourceDisplay` (`Constants`). `mallow` and
/// `unknown` are omitted at the call site, so they're absent here.
const _marketSourceDisplay = <String, String>{
  'magic-eden': 'ME',
  'exchange-art': 'EA',
  'formfunction': 'FoFu',
  'objkt': 'Objkt',
  'opensea': 'OpenSea',
};

/// Maps a market event onto [ActivityListRow]. Verbs mirror the webapp's
/// `EventDescription`; which rows carry a price mirrors `ProvenanceEvents`.
class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.event});

  final api.MarketActivityEvent event;

  /// The user the row leads with. byMint responses carry the resolved
  /// profile (username + pfp) on the event's `user` — the server already picked the
  /// buyer/seller side (`marketplaceEntryRenderer.renderSingleV1`). The
  /// switch is a fallback for payloads without it, mirroring
  /// `getMainUserFromEvent`, but those carry bare addresses only.
  api.ApiUserRef? get _actor =>
      event.user ??
      switch (event.type) {
        api.MarketEventType.sale ||
        api.MarketEventType.gumballDraw ||
        api.MarketEventType.candyMachineDraw ||
        api.MarketEventType.jellybeanDraw ||
        api.MarketEventType.acceptBid ||
        api.MarketEventType.bid ||
        api.MarketEventType.cancelBid ||
        api.MarketEventType.buyTicket => event.buyer ?? event.seller,
        _ => event.seller ?? event.buyer,
      };

  /// `{n} ticket` / `{n} tickets`, or null when the event carries no count.
  /// The webapp bolds this inside the sentence; mobile's row renders one
  /// style, so it reads inline.
  String? get _ticketCount {
    final quantity = event.quantity;
    if (quantity == null || quantity <= 0) return null;
    return '$quantity ticket${quantity > 1 ? 's' : ''}';
  }

  String get _action => switch (event.type) {
    api.MarketEventType.mint =>
      event.listingType == api.ListingType.airdrop
          ? 'airdropped artwork'
          // The source suffix only rides on mints — a mallow-minted piece
          // says nothing, an imported one names where it came from
          // (`EventDescription`).
          : 'minted artwork$_sourceSuffix',
    api.MarketEventType.edit => 'edited',
    api.MarketEventType.list => switch (event.listingType) {
      api.ListingType.auction => 'listed for auction',
      api.ListingType.raffle => 'listed for raffle',
      _ => 'listed for sale',
    },
    api.MarketEventType.updatePrice => 'updated price',
    api.MarketEventType.delist => 'delisted',
    api.MarketEventType.sale ||
    api.MarketEventType.gumballDraw ||
    api.MarketEventType.candyMachineDraw ||
    api.MarketEventType.jellybeanDraw => switch (event.listingType) {
      api.ListingType.auction => 'won the auction',
      // A raffle win is won *with* a ticket count — the count is the whole
      // point of the row (how many entries it took).
      api.ListingType.raffle =>
        _ticketCount == null
            ? 'won the raffle'
            : 'won raffle with $_ticketCount',
      _ => 'collected',
    },
    api.MarketEventType.acceptBid => 'had their offer accepted',
    api.MarketEventType.bid =>
      event.listingType == api.ListingType.auction
          ? 'placed a bid'
          : 'made an offer',
    api.MarketEventType.cancelBid => 'cancelled an offer',
    api.MarketEventType.buyTicket =>
      _ticketCount == null ? 'bought tickets' : 'bought $_ticketCount',
    _ => '',
  };

  /// `Edition #12` for a buy-now edition sale, else null.
  ///
  /// The webapp names the print and links it (`EventDescription`).
  /// The sale entry is written against the *print's* mint, so on a master
  /// edition's provenance every buy-now sale otherwise reads an identical
  /// "collected" — there is nothing telling edition #2 from edition #200, and
  /// no way to open the one that sold.
  String? get _editionLabel {
    if (event.listingType != api.ListingType.buyNow) return null;
    const saleTypes = {
      api.MarketEventType.sale,
      api.MarketEventType.gumballDraw,
      api.MarketEventType.candyMachineDraw,
      api.MarketEventType.jellybeanDraw,
    };
    if (!saleTypes.contains(event.type)) return null;
    final number = event.metadata?.editionNumber;
    if (number == null) return null;
    return 'Edition #${formatCount(number)}';
  }

  String get _sourceSuffix {
    final display = _marketSourceDisplay[event.source];
    return display == null ? '' : ' on $display';
  }

  /// Which events carry a meaningful price, ported from
  /// `ProvenanceEvents`. Three exclusions matter:
  /// a zero-priced auction listing (the reserve isn't set at list time), any
  /// raffle list/sale (the amount is ambiguously the ticket price or the total
  /// take), and every type outside the list/sale/bid family — mobile used to
  /// price `cancelBid` rows, which the webapp never does.
  bool get _showPrice {
    // A "set your own price" sale records the one buyer's figure. The webapp
    // drops the price block entirely on that row (`ProvenanceEvents`)
    // — printed as a plain amount it reads as an asking price the seller never
    // set, which is exactly the wrong inference on a provenance surface.
    if ((event.buyerSetsPrice ?? false) &&
        event.type == api.MarketEventType.sale) {
      return false;
    }
    if (event.listingType == api.ListingType.auction &&
        event.type == api.MarketEventType.list &&
        (event.price ?? 0) == 0) {
      return false;
    }
    const listTypes = {
      api.MarketEventType.list,
      api.MarketEventType.updatePrice,
      api.MarketEventType.gumballAdd,
      api.MarketEventType.jellybeanAdd,
    };
    if (event.listingType == api.ListingType.raffle &&
        (listTypes.contains(event.type) ||
            event.type == api.MarketEventType.sale)) {
      return false;
    }
    return listTypes.contains(event.type) ||
        const {
          api.MarketEventType.sale,
          api.MarketEventType.gumballDraw,
          api.MarketEventType.candyMachineDraw,
          api.MarketEventType.jellybeanDraw,
          api.MarketEventType.acceptBid,
          api.MarketEventType.bid,
          api.MarketEventType.buyTicket,
        }.contains(event.type);
  }

  /// Quantity multiplier applied to the price. A
  /// multi-ticket raffle entry or a multi-print buy records the *unit* price,
  /// so the row would otherwise understate what changed hands. Excluded for
  /// `list`, where the quantity is the supply offered, not a count bought
  /// (`ProvenanceEvents`).
  int get _multiplier {
    final quantity = event.quantity;
    if (quantity == null || quantity <= 0) return 1;
    if (event.type == api.MarketEventType.list) return 1;
    return quantity;
  }

  String? get _amount {
    if (!_showPrice) return null;
    // The listing/update/bid side of a SYOP listing: the webapp prints the word
    // rather than a figure (`ProvenanceEvents`), because the amount
    // on those rows is a placeholder, not a price anyone committed to.
    if (event.buyerSetsPrice ?? false) return 'SYOP';
    final price = event.price;
    if (price == null || price == 0) return null;
    if (_needsCurrencyLookup) return null;
    return PriceFormatter.formatRawAmountWithSymbol(
      price * _multiplier,
      event.currencyMint,
      chain: event.chain,
    );
  }

  /// True when the sale's currency isn't in the static registry. Passing
  /// `chain` to [PriceFormatter] resolves such a mint to the chain's *native*
  /// token, which is how a 5,000 WEN sale used to render as "0.5 SOL" —
  /// provenance is a trust surface, so it takes the async lookup instead.
  bool get _needsCurrencyLookup => sl<TokenMetadataService>().needsLookup(
    event.currencyMint,
    chain: event.chain,
  );

  Widget? get _amountWidget {
    if (!_showPrice || !_needsCurrencyLookup) return null;
    if (event.buyerSetsPrice ?? false) return null;
    final price = event.price;
    if (price == null || price == 0) return null;
    return TokenAmountText(
      rawAmount: price * _multiplier,
      currencyMint: event.currencyMint,
      chain: event.chain,
      shimmerWidth: 56,
    );
  }

  @override
  Widget build(BuildContext context) {
    final actor = _actor;
    final address = actor?.effectiveAddress;
    return ActivityListRow(
      name:
          actor?.username ??
          actor?.displayName ??
          // 5/5, the app-wide default, matching the webapp's `shortenAddress`
          // in provenance rows. Users compare truncated addresses across the
          // two clients, so the two halves have to line up character for
          // character.
          (address == null || address.isEmpty
              ? 'Unknown'
              : truncateAddress(address)),
      action: _action,
      circularAvatar: true,
      avatarUrl: actor?.avatarUrl,
      username: actor?.username,
      address: address,
      actionLinkLabel: _editionLabel,
      onActionLinkTap: () =>
          context.push(AppRoutes.artworkDetailPath(event.mintAccount)),
      amount: _amount,
      amountWidget: _amountWidget,
      age: event.date == null ? null : formatLastUpdated(event.date),
    );
  }
}
