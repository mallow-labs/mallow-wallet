// Extension methods on [_ArtworkDetailViewState] call protected State APIs
// like setState — same pattern as loaders.dart; the part-file scope keeps it
// internal to the screen library.
// ignore_for_file: invalid_use_of_protected_member

part of '../artwork_detail_screen.dart';

/// User-initiated action handlers for [_ArtworkDetailViewState] — buy /
/// offer / bid / raffle entry points, plus the management actions
/// (cancel listing, update listing, etc.). Each handler enforces the
/// shared `guardViewOnly` + mounted gate before dispatching to the
/// matching bloc.
extension _ArtworkDetailActions on _ArtworkDetailViewState {
  /// The currently loaded artwork, or null while the bloc is loading/errored.
  ArtworkDetails? _loadedArtwork() {
    final state = context.read<ArtworkBloc>().state;
    return state is ArtworkLoaded ? state.artwork : null;
  }

  /// Authority candidates for the owner-side marketplace actions (accept
  /// offer, update listing), most specific first.
  ///
  /// Deliberately only the two addresses that can actually sign: the holding
  /// wallet ([ArtworkDetails.ownerAddress], which the index keeps pointed at
  /// the seller while the piece is listed) and the auction's escrow-side
  /// seller. `ownerAddresses` (**plural**) must NOT be used here — it carries
  /// the owner profile's other linked wallets, and `ensureSignerForAny` lets
  /// an active candidate win over candidate order, so an active linked wallet
  /// that doesn't hold the piece would short-circuit the switch and build the
  /// tx with the wrong `seller`.
  List<String?> _ownerAuthorityCandidates(ArtworkDetails artwork) => [
    artwork.ownerAddress,
    artwork.auctionMetadata?.seller,
  ];

  /// The creator / winner authorities of the raffle identified by [raffleKey]
  /// — the artwork's own raffle listing, or one of its unclaimed-prize raffles
  /// (which the unclaimed sheet claims by their own `raffleAccount`). Both
  /// null when the raffle isn't on the loaded artwork, which leaves the signer
  /// unchanged (`ensureSigner(null)` is a no-op).
  ({String? creator, String? winner}) _raffleAuthorities(String raffleKey) {
    final artwork = _loadedArtwork();
    if (artwork == null) return (creator: null, winner: null);
    final listed = artwork.raffleMetadata;
    if (listed != null && listed.raffleAccount == raffleKey) {
      return (creator: listed.creator, winner: listed.winner);
    }
    for (final raffle in artwork.unclaimedRaffles) {
      if (raffle.raffleAccount == raffleKey) {
        return (creator: raffle.creator, winner: raffle.winner);
      }
    }
    return (creator: null, winner: null);
  }

  /// Add this artwork to one of the viewer's curations. Loads the viewer's
  /// curations, then opens the shared picker; toggling persists immediately
  /// and "New Curation" creates one, adds the artwork to it, and dismisses
  /// the picker. Mirrors the collection screen's curation flow.
  Future<void> _addToCuration(ArtworkDetails artwork) async {
    if (!await requireProfile(context)) return;
    if (!mounted) return;
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    final repo = sl<CurationRepository>();
    List<UserCuration> curations;
    try {
      curations = await repo.getCurations(mintAccount: artwork.mintAccount);
    } catch (_) {
      curations = [];
    }
    if (!mounted) return;
    var changed = false;
    final pendingToggles = <Future<void>>[];
    await showAddToCurationSheet(
      context,
      artworkTitle: formatArtworkName(
        name: artwork.title,
        editionNumber: artwork.editionNumber,
      ),
      artworkImageUrl: artwork.imageUrl.isNotEmpty ? artwork.imageUrl : null,
      artistUsername: artwork.artistUsername ?? artwork.artistName,
      curations: curations,
      onToggleCuration: (curationId, isSelected) {
        changed = true;
        pendingToggles.add(
          isSelected
              ? repo.addArtwork(curationId, artwork.mintAccount)
              : repo.removeArtwork(curationId, artwork.mintAccount),
        );
      },
      onCreateNew: () async {
        final result = await showNewCurationSheet(context);
        if (result == null) return null;
        try {
          final created = await repo.createCuration(
            result.name,
            isPrivate: result.isPrivate,
          );
          await repo.addArtwork(created.id, artwork.mintAccount);
          changed = true;
          return created;
        } catch (_) {
          return null;
        }
      },
    );
    if (!changed || !mounted) return;
    // Wait for in-flight toggle writes so the refetch reflects them, then
    // refresh the artwork so its curations section picks up the changes.
    try {
      await Future.wait(pendingToggles);
    } catch (_) {
      // Failed toggles surface as the row simply not reflecting the change
      // after refresh.
    }
    if (!mounted) return;
    context.read<ArtworkBloc>().add(const ArtworkEvent.refresh());
  }

  Future<void> _onBuy(ArtworkDetails artwork) async {
    // Fixed-price buys and edition-print buys are separate builders behind
    // separate sheets ([ArtworkBuySheet] / [ArtworkBuyEditionSheet]) and
    // therefore separate cells. Resolved through the SAME shared helper
    // `MarketBloc._onBuy` routes the builder with — and with the same priority
    // order the action-sheet dispatcher applies (live DAS edition state >
    // server `isMasterEdition` > `supplyType`) — so the sheet the user tapped,
    // the entry gate, the builder and the signing backstop cannot disagree.
    // The resolved value rides on the event so the bloc doesn't have to
    // re-derive it from the weaker `supplyType` alone.
    final printsEdition = resolvePrintableMasterEdition(
      supplyType: artwork.supplyType,
      isMasterEdition: artwork.isMasterEdition,
      editionState: _editionLive,
    );
    final buyFlow = printsEdition ? AppFlow.editionBuy : AppFlow.fixedPriceBuy;
    if (await guardFlowDisabled(context, FlowKey.solana(buyFlow))) return;
    if (!mounted) return;
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    // SYOP ("set your own price"): the listing's on-chain price is 0 and the
    // buyer names the amount, so the flow gains an entry step and the entered
    // price is sent as the wire `maxPrice`. Without it the backend falls back
    // to `listing.price` = 0 and the artist is paid nothing.
    // Printing an edition spends SOL beyond the listing price — the
    // standard's rent + Metaplex protocol fee (+ the buyer's ATA rent on the
    // legacy standard). Quoted here, where the master's token standard is
    // known, and folded into the confirm step's balance gate together with the
    // prepared print fee (webapp `useBuyNow`'s `requiredSolLamports`). Zero
    // for a 1/1 buy, which mints nothing.
    final editionMintFee = printsEdition
        ? editionPrintSolFeeLamports(
            tokenStandard: _editionLive?.tokenStandard ?? artwork.tokenStandard,
          )
        : 0;
    if (artwork.buyNowMetadata?.buyerSetsPrice ?? false) {
      await _onBuyWithBuyerPrice(
        artwork,
        printsEdition: printsEdition,
        editionMintFeeLamports: editionMintFee,
      );
      return;
    }
    // artwork.price is the raw on-chain amount in artwork.currency's
    // smallest unit (per ArtworkDetails docstring); pass it through
    // unchanged so the confirmation sheet renders the correct symbol
    // + decimals via PriceFormatter. Null currency falls back to SOL.
    final pricePerUnit = MarketPrice(
      rawAmount: artwork.price ?? 0,
      currencyMint: artwork.currency,
    );
    context.read<MarketBloc>().add(
      MarketEvent.buy(
        mintAccount: widget.mintAccount,
        supplyType: artwork.supplyType,
        pricePerUnit: pricePerUnit,
        isPrintableMasterEdition: printsEdition,
      ),
    );

    // Open the confirm sheet immediately rather than waiting for TxFlowReady
    // (which leaves the Buy tap unresponsive while the tx builds + simulates).
    // The cost breakdown shimmers through the preparing + simulation phases,
    // then resolves in place. The `_marketSheetActive` guard set inside
    // _runMarketActionFlow keeps the screen's Ready listener from opening a
    // second sheet.
    await _runMarketActionFlow(
      artwork: artwork,
      actionType: 'buy',
      preview: MarketActionPreview(
        actionType: 'buy',
        mintAccount: widget.mintAccount,
        // 1/1 buys settle at the per-unit price (quantity 1); the resolved
        // TxFlowReady reports the same total, so the shimmer fills without a
        // jump. Edition buys swap to the fee-inclusive breakdown on Ready.
        totalCost: pricePerUnit,
      ),
      editionMintFeeLamports: editionMintFee,
    );
  }

  /// Buy a SYOP ("set your own price") listing: [SetPriceSheet] entry step →
  /// confirmation in place, same shape as the bid/offer flows. The entered
  /// amount is both the confirm step's total and — via
  /// `MarketEvent.buy(buyerSetsPrice: true)` — the wire `maxPrice`, because a
  /// SYOP listing's on-chain price is 0 and the tx builder would otherwise
  /// default the payment to it.
  ///
  /// Called only from [_onBuy], which has already run the flow-disabled and
  /// view-only guards.
  Future<void> _onBuyWithBuyerPrice(
    ArtworkDetails artwork, {
    required bool printsEdition,
    required int editionMintFeeLamports,
  }) async {
    final title = formatArtworkName(
      name: artwork.title,
      editionNumber: artwork.editionNumber,
    );
    final imageUrl = artwork.imageUrl.isNotEmpty ? artwork.imageUrl : null;
    // The same bloc _runMarketActionFlow hands the confirm step, so the entry
    // sheet's affordability gate reads the balances the confirm step will.
    final balances = context.read<TokenBalanceBloc>();
    await _runMarketActionFlow(
      artwork: artwork,
      actionType: 'buy',
      // Once the price is submitted, advance straight to the confirm step with
      // its cost line shimmering while the tx builds (the flow sheet uses the
      // submitted amount as the preview total).
      preview: MarketActionPreview(
        actionType: 'buy',
        mintAccount: widget.mintAccount,
      ),
      entryBuilder: (onNext, isSubmitting) => SetPriceSheet(
        artworkTitle: title,
        mintAccount: widget.mintAccount,
        tokenBalanceBloc: balances,
        currencyMint: artwork.currency,
        artworkImageUrl: imageUrl,
        artistUsername: artwork.artistUsername,
        nsfw: artwork.nsfw,
        onNext: onNext,
        isSubmitting: isSubmitting,
      ),
      onSubmit: (price) => context.read<MarketBloc>().add(
        MarketEvent.buy(
          mintAccount: widget.mintAccount,
          supplyType: artwork.supplyType,
          pricePerUnit: price,
          buyerSetsPrice: true,
          isPrintableMasterEdition: printsEdition,
        ),
      ),
      editionMintFeeLamports: editionMintFeeLamports,
    );
  }

  /// Cast is allowed for the current owner OR any creator on the artwork.
  /// "Creator" includes the primary artist, anyone in the royalty splits,
  /// the on-chain update authority, and — for users with multiple linked
  /// wallets — any wallet linked to any of those mallow user accounts.
  bool _canCast(ArtworkDetails artwork) {
    final me = sl<AuthService>().currentAddress;
    // Cast is a no-signing display/streaming gate, so ANY wallet in the current
    // session (Profile/Account) counts as owner/creator — not just the active
    // signing wallet. Union the active address with the session set (empties
    // dropped), the same pattern as _relationshipOf in artwork_action_state.dart.
    final mine = <String>{?me, ...sl<SessionManager>().sessionAddresses}
      ..removeWhere((a) => a.isEmpty);
    if (mine.isEmpty) return false;
    // Membership checks against the full linked-addresses lists — see
    // ArtworkDetails.ownerAddresses doc + the resolver in
    // artwork_action_state.dart for the same pattern.
    if (artwork.ownerAddresses.any(mine.contains)) return true;
    if (mine.contains(artwork.ownerAddress)) return true;
    if (artwork.artistAddresses.any(mine.contains)) return true;
    if (mine.contains(artwork.artistAddress)) return true;
    if (mine.contains(artwork.updateAuthority)) return true;
    if (artwork.royaltySplits.any((s) => mine.contains(s.address))) return true;
    return _creatorLinkedAddresses.any(mine.contains);
  }

  /// The escrowed own-offer amount the make-offer balance gate may net off the
  /// new price, or null when it must not.
  ///
  /// The own-offer lookup is session-wide (A1b), but this is a **signing** gate:
  /// `CreateOfferTxRequest.buyer` is the ACTIVE wallet. [_onMakeOffer] re-points
  /// the signer to the maker (like [_onCancelOffer]) *before* it evaluates this,
  /// so an "Update offer" that genuinely re-bids credits the escrow it is about
  /// to move. It still returns null whenever that re-point did not land — a
  /// maker outside the session takes `ensureSigner`'s delegate pass-through, and
  /// the program then opens a brand-new full-price offer for the signer, so
  /// crediting it would let the gate clear an amount that wallet can't fund,
  /// the failure landing after the user confirms.
  MarketPrice? _ownOfferEscrowForSigner() {
    if (!_userOwnOffer) return null;
    final me = sl<AuthService>().currentAddress;
    if (me == null || _userOwnOfferBuyer != me) return null;
    return _userOwnOfferAmount;
  }

  /// Opens the unified make-offer flow sheet: amount entry advances in place
  /// to the confirmation step (no dismiss/re-present), then dispatches
  /// `MarketEvent.makeOfferV2`. Used by `ArtworkUnlistedViewerSheet` and
  /// `ArtworkBuySheet`.
  Future<void> _onMakeOffer(ArtworkDetails artwork) async {
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.offerCreate),
    )) {
      return;
    }
    if (!mounted) return;
    // "Update offer" reaches this handler too, and the own-offer lookup is
    // session-wide (A1b) — so the live offer may have been placed by a wallet
    // that is no longer active. `CreateOfferTxRequest.buyer` is the active
    // signer, so without re-pointing, "Update offer" would escrow a SECOND
    // full-price offer for the active wallet instead of re-bidding the existing
    // one. Mirror `_onCancelOffer`: switch to the maker before dispatching, and
    // before `guardViewOnly` (A1d) so a watch-only active wallet can't block an
    // update whose maker is signable. Gate on `_userOwnOffer`, not on
    // `_userOwnOfferBuyer` alone: the maker outlives a cancel (it is held for
    // the reconcile poll), and a fresh offer must stay with the active wallet.
    final offerMaker = _userOwnOffer ? _userOwnOfferBuyer : null;
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSigner(
      context,
      offerMaker,
      watchOnlyMessage:
          'This offer was made by a watch-only wallet in your account. '
          'Import its private key to sign for it.',
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    // The make-offer sheet renders the current-best comparison in the input
    // currency (`currencyMint`, defaulting to SOL). Use the loaded
    // `OfferRender` — which carries the offer's raw `price` + `currencyMint` —
    // rather than the indexer's unit-ambiguous `artwork.highestOffer` scalar,
    // and only surface it when it's denominated in that same currency so its
    // raw amount isn't mis-scaled against the wrong token.
    final currencyMint = artwork.currency;
    final inputMint = currencyMint ?? solMint;
    final offer = _highestOffer;
    final highestOffer = offer != null && offer.currencyMint == inputMint
        ? MarketPrice(rawAmount: offer.price, currencyMint: offer.currencyMint)
        : null;
    final isOneOfOne = artwork.supplyType == SupplyType.oneOfOne;
    final title = formatArtworkName(
      name: artwork.title,
      editionNumber: artwork.editionNumber,
    );
    final imageUrl = artwork.imageUrl.isNotEmpty ? artwork.imageUrl : null;
    // Set by `onSubmit`, so an entry step abandoned before any amount is
    // submitted can undo the maker re-point below (the bloc never leaves idle
    // there, so `_runMarketActionFlow`'s own restore doesn't fire).
    var submitted = false;
    await _runMarketActionFlow(
      artwork: artwork,
      actionType: 'offer',
      // "Update offer" reaches this same flow — the backend builder issues an
      // `updateOffer` re-bid when the buyer already has one. That only moves
      // the difference on-chain, so hand the confirm step the escrowed amount
      // and its balance gate requires the delta, not the full new price
      // (webapp `useUpdateOffer`). Evaluated here, after the
      // `ensureSigner` above resolved, so it credits the wallet that will sign.
      escrowedOfferAmount: _ownOfferEscrowForSigner(),
      // Once the offer amount is submitted, advance straight to the confirm
      // step with its cost line shimmering while the tx builds, instead of
      // holding the entry form with a spinning CTA.
      preview: MarketActionPreview(
        actionType: 'offer',
        mintAccount: widget.mintAccount,
      ),
      entryBuilder: (onNext, isSubmitting) => MakeOfferSheet(
        artworkTitle: title,
        mintAccount: widget.mintAccount,
        currencyMint: currencyMint,
        currentBestOffer: highestOffer,
        artworkImageUrl: imageUrl,
        artistUsername: artwork.artistUsername,
        nsfw: artwork.nsfw,
        onNext: onNext,
        isSubmitting: isSubmitting,
      ),
      onSubmit: (price) {
        submitted = true;
        context.read<MarketBloc>().add(
          MarketEvent.makeOfferV2(
            mintAccount: widget.mintAccount,
            amount: price,
            oneOfOneOnly: isOneOfOne,
          ),
        );
      },
      previousSigner: previousSigner,
    );
    // Opened "Update offer" and walked away without entering an amount: undo
    // the re-point, same convention as an abandoned confirm sheet.
    if (!submitted) await restoreSigner(previousSigner);
  }

  /// Bid on an active auction via the unified flow sheet ([PlaceBidSheet]
  /// entry → confirmation in place). The bid currency lives on the auction's
  /// `bidMint` (not `artwork.currency`, which is the buy-now/listing currency
  /// and is null for auctions).
  Future<void> _onPlaceBid(ArtworkDetails artwork) async {
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.auctionBid),
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    final auction = artwork.auctionMetadata;
    final currencyMint = auction?.bidMint ?? artwork.currency;
    // `currentBidAmount` is a raw on-chain amount in `bidMint`'s smallest unit
    // (like every mallow price — see PriceFormatter), so hand it to the sheet
    // as-is; PlaceBidSheet resolves decimals + symbol from the mint.
    final currentBid = auction?.currentBidAmount;
    final highestBid = currentBid != null
        ? MarketPrice(rawAmount: currentBid, currencyMint: currencyMint)
        : null;
    // Lowest acceptable bid, in the same raw `bidMint` units as `currentBid`.
    // Mirrors the webapp's shared `getMinBid`: reserve when no bids exist,
    // otherwise the highest bid plus its increment (bps preferred over flat).
    final minBidRaw = auction != null ? _minBidRaw(auction) : null;
    final title = formatArtworkName(
      name: artwork.title,
      editionNumber: artwork.editionNumber,
    );
    final imageUrl = artwork.imageUrl.isNotEmpty ? artwork.imageUrl : null;
    // The same bloc _runMarketActionFlow hands the confirm step, so the entry
    // sheet's affordability gate reads the balances the confirm step will.
    final balances = context.read<TokenBalanceBloc>();
    await _runMarketActionFlow(
      artwork: artwork,
      actionType: 'bid',
      // Once the bid amount is submitted, advance straight to the confirm step
      // with its cost line shimmering while the tx builds, instead of holding
      // the entry form with a spinning CTA.
      preview: MarketActionPreview(
        actionType: 'bid',
        mintAccount: widget.mintAccount,
      ),
      entryBuilder: (onNext, isSubmitting) => PlaceBidSheet(
        artworkTitle: title,
        mintAccount: widget.mintAccount,
        tokenBalanceBloc: balances,
        currencyMint: currencyMint,
        currentHighestBid: highestBid,
        minBidRaw: minBidRaw,
        // Surfaces the minimum bid increment + the anti-sniping end phase,
        // the two facts that decide whether a bid reverts on-chain.
        auction: auction,
        artworkImageUrl: imageUrl,
        artistUsername: artwork.artistUsername,
        nsfw: artwork.nsfw,
        onNext: onNext,
        isSubmitting: isSubmitting,
      ),
      onSubmit: (price) => context.read<MarketBloc>().add(
        MarketEvent.placeBid(mintAccount: widget.mintAccount, amount: price),
      ),
    );
  }

  /// Minimum acceptable bid in raw `bidMint` units, or null when the auction
  /// carries no increment info. Port of the webapp's shared `getMinBid`:
  /// with no bids the floor is the reserve; once bidding starts it's the
  /// highest bid plus its increment (bps preferred over the flat amount).
  int? _minBidRaw(AuctionMetadata auction) {
    final highest = (auction.currentBidAmount ?? 0).toInt();
    if (highest == 0) {
      return (auction.reservePrice ?? 0).toInt();
    }
    final bps = auction.minBidIncrementBps;
    if (bps != null) {
      return highest + (highest * bps) ~/ 10000;
    }
    final increment = auction.minBidIncrement;
    if (increment != null) {
      return highest + increment;
    }
    return null;
  }

  /// Shared host for every market action's confirm + pipeline (and, for
  /// offer/bid, the amount-entry step too): one modal route whose steps morph
  /// in place via [MarketActionFlowSheet]. The `_marketSheetActive` guard
  /// routes the screen's `TxFlowReady` listener (which would otherwise push a
  /// second sheet on each simulate re-emit) to the open sheet, which listens to
  /// the bloc directly.
  ///
  /// Omit [entryBuilder]/[onSubmit] for actions with no amount input (buy,
  /// accept-offer, cancel-*, settle) — the flow opens straight at the confirm
  /// step. Listing-management actions still skip this entirely (see
  /// [_skipsConfirmation] + [_showMarketPipelineSheet]).
  ///
  /// [previousSigner] is the [activeSignerSnapshot] taken by an authority
  /// action that re-pointed the active signer before dispatching (accept-offer,
  /// cancel-offer, settle-auction). It is restored when the user abandons the
  /// sheet before signing, so opening-then-dismissing a confirm sheet never
  /// moves the active wallet. Once signed, the signer stays put — same
  /// convention as transfer / burn.
  Future<void> _runMarketActionFlow({
    required ArtworkDetails artwork,
    required String actionType,
    Widget Function(ValueChanged<MarketPrice> onNext, bool isSubmitting)?
    entryBuilder,
    void Function(MarketPrice price)? onSubmit,
    MarketActionPreview? preview,
    WalletInfo? previousSigner,
    MarketPrice? escrowedOfferAmount,
    int editionMintFeeLamports = 0,
  }) async {
    final marketBloc = context.read<MarketBloc>();
    final tokenBalanceBloc = context.read<TokenBalanceBloc>();
    final title = formatArtworkName(
      name: artwork.title,
      editionNumber: artwork.editionNumber,
    );
    final imageUrl = artwork.imageUrl.isNotEmpty ? artwork.imageUrl : null;
    _marketSheetActive = true;
    try {
      await showMallowSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => BlocProvider.value(
          value: marketBloc,
          child: MarketActionFlowSheet(
            entryBuilder: entryBuilder,
            onSubmit: onSubmit,
            preview: preview,
            tokenBalanceBloc: tokenBalanceBloc,
            artworkTitle: title,
            artworkImageUrl: imageUrl,
            artistUsername: artwork.artistUsername,
            artistName: artwork.artistName,
            creatorAddress: artwork.updateAuthority,
            nsfw: artwork.nsfw,
            escrowedOfferAmount: escrowedOfferAmount,
            editionMintFeeLamports: editionMintFeeLamports,
            pipelineBuilder: (_) => _MarketPipelineSheetView(
              actionType: actionType,
              artwork: artwork,
            ),
          ),
        ),
      );
    } finally {
      _marketSheetActive = false;
    }
    if (!mounted) return;
    // Cancelled before signing (still Ready/Preparing) — reset so the stale
    // payload doesn't linger. Success/error are owned by the pipeline step,
    // which resets to idle as it pops, so those don't reach here.
    final state = marketBloc.state;
    if (state is TxFlowReady<MarketPrepData, MarketSuccessData> ||
        state is TxFlowPreparing<MarketPrepData, MarketSuccessData>) {
      marketBloc.add(const MarketEvent.reset());
      // Abandoned before signing — undo the authority re-point so merely
      // opening and dismissing the sheet leaves the active wallet alone.
      await restoreSigner(previousSigner);
    }
    // After buying a print from a master edition, route to the bought print's
    // detail page now that the flow has closed (the listener stashed the
    // signature on buy-success). Deferring to close keeps the new route from
    // landing behind the still-open sheet.
    final signature = _pendingEditionBuySig;
    if (signature != null) {
      _pendingEditionBuySig = null;
      unawaited(_navigateToBoughtPrint(signature));
    }
  }

  /// Buy raffle tickets. Prompts for ticket count, dispatches
  /// `RaffleEvent.buyTickets`. The raffleKey lives on
  /// `artwork.raffleMetadata.raffleAccount`.
  Future<void> _onBuyRaffleTickets(ArtworkDetails artwork) async {
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.raffleBuyTickets),
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) return;
    if (!mounted) return;
    final raffleKey = artwork.raffleMetadata?.raffleAccount;
    if (raffleKey == null || raffleKey.isEmpty) return;
    final ticketCount = await _promptTicketCount(artwork);
    if (ticketCount == null || ticketCount <= 0 || !mounted) return;
    context.read<RaffleBloc>().add(
      RaffleEvent.buyTickets(raffleKey: raffleKey, ticketCount: ticketCount),
    );
  }

  /// Prompts for a raffle ticket count via a design-system bottom sheet.
  /// Returns the parsed count, or null when cancelled/dismissed.
  ///
  /// The sheet is given the unit price and the per-wallet ceiling so it can
  /// show a running total and refuse an over-limit count, the same two things
  /// the webapp's `BuyTicketsModal` does
  /// (`BuyTicketsModal`).
  Future<int?> _promptTicketCount(ArtworkDetails artwork) {
    final raffle = artwork.raffleMetadata;
    return showMallowSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RaffleTicketSheet(
        unitPriceRaw: raffle?.priceRaw,
        currencyMint: raffle?.currencyMint,
        maxTickets: _maxTicketsFor(artwork),
      ),
    );
  }

  /// `min(remaining supply, walletLimit - ticketsAlreadyHeld)`, or null when
  /// the raffle reports no supply. Read off the resolved action state so the
  /// picker and the sheet's buy gate share one derivation.
  int? _maxTicketsFor(ArtworkDetails artwork) {
    final state = resolveArtworkActionState(
      artwork: artwork,
      currentAddress: sl<AuthService>().currentAddress,
      creatorLinkedAddresses: _creatorLinkedAddresses,
      sessionAddresses: sl<SessionManager>().sessionAddresses,
      permissions: _permissions,
      userOwnOffer: _userOwnOffer,
      editionState: _editionLive,
      raffleState: _raffleLive,
    );
    if (state is! ArtworkRaffleAction) return null;
    final remaining = state.gate.ticketsRemaining;
    if (remaining == null) return null;
    final allowed = state.gate.walletLimit - state.gate.userTickets;
    final max = remaining < allowed ? remaining : allowed;
    return max > 0 ? max : null;
  }

  /// Listener entry point for actions with no amount input (buy, accept-offer,
  /// cancel-offer, cancel-auction, settle-auction): opens the unified flow at
  /// its confirm step, which morphs into the pipeline step in place on confirm.
  Future<void> _showConfirmationSheet(
    MarketPrepData ready,
    ArtworkDetails artwork,
  ) {
    return _runMarketActionFlow(artwork: artwork, actionType: ready.actionType);
  }

  /// Pushes the unified pipeline sheet wired to [MarketBloc]. Stays mounted
  /// across `signing → broadcasting → success/error`. Used by the auto-confirm
  /// path (update-listing, cancel-listing) that skips the confirmation step
  /// entirely — every other market action routes through
  /// [_runMarketActionFlow], which hosts the pipeline as a morphing step.
  void _showMarketPipelineSheet(String actionType) {
    final marketBloc = context.read<MarketBloc>();
    // Snapshot the artwork for the sheet header — the pipeline outlives
    // taps on the host screen, so capture it at open time.
    final artworkState = context.read<ArtworkBloc>().state;
    final artwork = artworkState is ArtworkLoaded ? artworkState.artwork : null;
    // Mark the sheet active so within-`TxFlowReady` re-emits don't push a
    // second pipeline sheet. This matters for the `_skipsConfirmation`
    // (update-/cancel-listing) path, which opens the pipeline straight from
    // the listener without going through `_showConfirmationSheet`'s guard.
    _marketSheetActive = true;
    showTransactionPipelineSheet(
      context: context,
      builder: (sheetContext) => BlocProvider.value(
        value: marketBloc,
        child: _MarketPipelineSheetView(
          actionType: actionType,
          artwork: artwork,
        ),
      ),
    ).whenComplete(() {
      if (!mounted) return;
      _marketSheetActive = false;
      // After buying a print from a master edition, route to the bought
      // print's detail page now that the success sheet has dismissed.
      // Deferring to sheet-close keeps the new route from landing behind the
      // still-open pipeline sheet.
      final signature = _pendingEditionBuySig;
      if (signature != null) {
        _pendingEditionBuySig = null;
        unawaited(_navigateToBoughtPrint(signature));
      }
    });
  }

  /// Resolve the bought print's mint from the indexed sale event for
  /// [signature], then route to its detail page. The buy-edition tx builder
  /// partial-signs with an ephemeral print-mint key that does NOT match the
  /// mint that lands on-chain (a stale-blockhash rebuild swaps in a fresh
  /// key), so the indexed event — keyed off this screen's master mint — is
  /// the only reliable source. That event lands after the print's own artwork
  /// record, so by the time it resolves the print's `getArtworkByMint` is
  /// queryable and the detail page won't 404. Bails without navigating if the
  /// screen is gone or the event never indexes (the buy still succeeded).
  Future<void> _navigateToBoughtPrint(String signature) async {
    final printMint = await sl<ArtworkEventsRepository>().printedMintForBuy(
      masterMint: widget.mintAccount,
      txId: signature,
    );
    if (!mounted || printMint == null) return;
    context.goToArtwork(printMint);
  }

  /// Accept the highest offer as the owner — live tx through [MarketBloc]
  /// and the unified pipeline sheet.
  Future<void> _onAcceptHighestOffer(OfferRender offer) async {
    // Needs the loaded artwork both for the authority candidates and for the
    // flow sheet's header.
    final artwork = _loadedArtwork();
    if (artwork == null) return;
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.offerAccept),
    )) {
      return;
    }
    if (!mounted) return;
    // Re-point the signer to the session wallet that actually holds the piece
    // BEFORE `guardViewOnly` (A1d): the guard reads the *active* wallet, so
    // running it first would block a watch-only active wallet even though a
    // signable session wallet is the authority. Post-switch it reads the newly
    // selected wallet, so it still blocks a view-only *active owner*.
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSignerForAny(
      context,
      _ownerAuthorityCandidates(artwork),
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    // Gross offer amount — the seller's net proceeds resolve from the tx
    // simulation, so the confirm sheet's "You'll receive" line shimmers off
    // this gross until then (same as auction settle).
    final amount = MarketPrice(
      rawAmount: offer.price,
      currencyMint: offer.currencyMint,
    );
    // Stash the buyer so the success listener can optimistically hand ownership
    // to them: the owner accepting an offer relinquishes the NFT, so
    // the seller's sheet flips to the unlisted "Make offer" viewer state at once
    // instead of gating behind the indexer with an empty-sheet gap.
    _pendingAcceptOfferBuyer[widget.mintAccount] = offer.buyerAddress;
    context.read<MarketBloc>().add(
      MarketEvent.acceptOffer(
        mintAccount: widget.mintAccount,
        buyer: offer.buyerAddress,
        amount: amount,
      ),
    );

    // Open the confirm sheet immediately rather than waiting for TxFlowReady
    // (which leaves the Accept tap unresponsive while the tx builds + simulates).
    // It shows the "You'll receive" earnings breakdown shimmering through the
    // preparing + simulation phases, then resolves in place. The
    // `_marketSheetActive` guard set inside _runMarketActionFlow keeps the
    // screen's Ready listener from opening a second sheet.
    await _runMarketActionFlow(
      artwork: artwork,
      actionType: 'accept-offer',
      preview: MarketActionPreview(
        actionType: 'accept-offer',
        mintAccount: widget.mintAccount,
        totalCost: amount,
      ),
      previousSigner: previousSigner,
    );
  }

  Future<void> _onCast(ArtworkDetails artwork) {
    return castArtworkWithVerify(
      CastQueueItemFromArtwork.fromArtworkDetails(artwork),
    );
  }

  void _onAddToCast(ArtworkDetails artwork) {
    addArtworksToCastQueue([
      CastQueueItemFromArtwork.fromArtworkDetails(artwork),
    ]);
    AppSnackBar.show(context, 'Added to cast');
  }

  void _openCollection(ArtworkDetails artwork) {
    final mint = artwork.collectionMint;
    if (mint == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CollectionScreen(
          group: ArtGroup(
            id: mint,
            type: ArtGroupType.collection,
            name: artwork.collectionName ?? '',
            thumbnailUrl: artwork.collectionImageUrl,
            artworkCount: 0,
            artistAddress: artwork.artistAddress,
            collectionMint: mint,
            creatorName: artwork.artistUsername,
          ),
        ),
      ),
    );
  }

  /// Single curation: push its screen directly. Multiple: show a picker
  /// sheet first.
  void _openCurations(ArtworkDetails artwork) {
    final curations = artwork.curations;
    if (curations.isEmpty) return;
    if (curations.length == 1) {
      _openCuration(curations.first);
      return;
    }
    showCuratedInSheet(
      context,
      curations: curations,
      onSelect: _openCuration,
      // Curation creator addresses are part of the artwork-info resolution
      // pool (see _collectArtworkInfoAddresses), so usernames are loaded by
      // the time the row is tappable; snapshot for the sheet's lifetime.
      usernameByAddress: Map.of(_creatorUsernames),
    );
  }

  void _openCuration(ArtworkCuration curation) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CurationScreen(
          group: ArtGroup(
            id: curation.id,
            type: ArtGroupType.curation,
            name: curation.name,
            thumbnailUrl: curation.imageUrl,
            artworkCount: 0,
            creatorName: _creatorUsernames[curation.creatorAddress],
          ),
          ownerAddress: curation.creatorAddress ?? '',
        ),
      ),
    );
  }

  Future<void> _handleTransfer(ArtworkDetails artwork) async {
    // EVM holders are threaded through the transfer flow (there is no per-chain
    // active-wallet selection to re-point). Pass `evmHolder: true` so a
    // watch-only ETH holder is still routed to import rather than short-
    // circuited by the default `0x` no-op.
    final isEvm = isEthereumArtwork(
      mintAccount: artwork.mintAccount,
      chain: artwork.chain,
    );
    // Resolve the EVM holder to the session wallet that actually holds the copy.
    // The owner affordance spans ALL the owner's linked addresses, but the
    // primary `ownerAddress` may be a linked wallet not held in this session —
    // signing then falls back to the active ETH wallet, which need not hold the
    // copy (a dead end at the pre-sign simulation). Solana signs via the active
    // wallet, so it keeps using the primary owner address.
    final holder = isEvm ? _resolveEvmHolder(artwork) : artwork.ownerAddress;
    // Snapshot the active signer so an abandoned transfer restores it. EVM
    // signs by holder wallet id (no active re-point), so nothing to snapshot.
    final previousSigner = isEvm ? null : activeSignerSnapshot();
    // Signer first, guard second (A1d): `guardViewOnly` reads the *active*
    // wallet, so running it first blocks a watch-only active wallet even when
    // the holder is a signable session wallet. Post-switch it reads the newly
    // selected wallet, so a view-only active holder is still blocked.
    if (!await ensureSigner(context, holder, evmHolder: isEvm)) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    final portfolioArtwork = PortfolioArtwork(
      mintAccount: artwork.mintAccount,
      title: artwork.title,
      imageUrl: artwork.imageUrl,
      artistName: artwork.artistName,
      artistUsername: artwork.artistUsername,
      editionNumber: artwork.editionNumber,
      updateAuth: artwork.updateAuthority,
      // Carry chain + standard so the transfer flow can take the EVM
      // (erc721/erc1155) path without a Solana-only DAS lookup.
      chain: artwork.chain,
      tokenStandard: artwork.tokenStandard,
    );
    // ArtworkDetails carries no `parentEdition`, so the printable-master
    // signal can't be derived from supply fields here (that mislabels edition
    // prints as masters). Pass the authoritative value: the live DAS edition
    // state when present, else the server's master-edition flag.
    final isMasterEdition =
        _editionLive?.isPrintableMasterEdition ??
        artwork.isMasterEdition ??
        false;
    final transferred = await runTransferArtworkFlow(
      context,
      artwork: portfolioArtwork,
      isMasterEdition: isMasterEdition,
      // Thread the specific EVM holder so the service signs as that wallet even
      // when it isn't the active ETH wallet (there is no per-chain active
      // selection). Solana transfers resolve the signer via the active wallet.
      evmHolder: isEvm ? holder : null,
    );
    // Abandoned (or failed before signing): undo the signer re-point that
    // `ensureSigner` persisted so opening-then-cancelling doesn't silently move
    // the active wallet. On a confirmed transfer the artwork has left the
    // holder, so leave the signer put and close the detail screen (as burn does).
    if (!transferred) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// The EVM holder address to sign the transfer as: the first of the
  /// artwork's owner addresses that is a wallet in the current session (matched
  /// case-insensitively, per EIP-55 checksum), falling back to
  /// [ArtworkDetails.ownerAddress]. `ownerAddresses` lists the real holders
  /// (ERC-1155 balances included) ahead of the owner profile's linked wallets,
  /// so this picks a wallet that can actually sign — the copy may be held by a
  /// session wallet other than the active one, which has no per-chain
  /// selection to re-point.
  String? _resolveEvmHolder(ArtworkDetails artwork) {
    final session = sl<SessionManager>();
    for (final address in artwork.ownerAddresses) {
      if (session.sessionWalletForAddressCaseInsensitive(address) != null) {
        return address;
      }
    }
    return artwork.ownerAddress;
  }

  Future<void> _handleBurn(ArtworkDetails artwork) async {
    // Snapshot the active signer so an abandoned burn restores it (the burn tx
    // builds against the active wallet as soon as the sheet opens, so the
    // re-point must happen up front — hence restore, not defer).
    final previousSigner = activeSignerSnapshot();
    // Signer first, guard second — see `_handleTransfer` (A1d).
    if (!await ensureSigner(context, artwork.ownerAddress)) return;
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    final portfolioArtwork = PortfolioArtwork(
      mintAccount: artwork.mintAccount,
      title: artwork.title,
      imageUrl: artwork.imageUrl,
      artistName: artwork.artistName,
      editionNumber: artwork.editionNumber,
      updateAuth: artwork.updateAuthority,
    );
    final burned = await runBurnArtworkFlow(context, artwork: portfolioArtwork);
    if (!burned) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Auto-confirms raffle txs and surfaces success / error snackbars.
  /// Mirrors the MarketBloc consumer above but skips the confirmation
  /// sheet (raffle txs don't have a price-confirmation step on the
  /// webapp either).
  void _onRaffleStateChanged(BuildContext context, RaffleState state) {
    state.mapOrNull(
      readyToSign: (_) {
        context.read<RaffleBloc>().add(const RaffleEvent.confirmAndSign());
      },
      success: (success) {
        if (success.indexed == null) {
          // First (chain-confirmed) emission — show the success message. The
          // refresh is deferred to the indexed flip so it reads post-action
          // raffle state instead of the pre-index slots/owner.
          AppSnackBar.show(context, _raffleSuccessMessage(success.actionType));
        } else {
          context.read<ArtworkBloc>().add(const ArtworkEvent.refresh());
        }
      },
      error: (error) {
        // Kill switch: the four raffle actions are four independent
        // cells, and a kill lands here from the signing backstop — where the
        // raw message would otherwise flash by in a snackbar the user can miss.
        // Show the operator's copy instead; the screen stays open and idle.
        //
        // No `flow` for the event: [RaffleError] doesn't carry which of the
        // four cells was in flight (the ready state that did is already gone),
        // and re-deriving it from the artwork would be a guess. The `surface`
        // dimension still lands.
        //
        // Deferred a frame + re-checked: sibling listeners on this screen pop
        // and push routes synchronously on the same emission, and a
        // `Navigator.pop()` racing our push would take the explanation route.
        final failure = error.failure;
        if (failure != null && failure.isFlowDisabled) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            handleFlowDisabled(this.context, failure);
          });
          return;
        }
        AppSnackBar.show(context, error.message);
      },
    );
  }

  /// Update-listing flow — opens `UpdateListingSheet`, which lets the
  /// user either submit a new price (in the listing's currency) or
  /// cancel the listing entirely. Each branch dispatches the matching
  /// [MarketEvent].
  Future<void> _onUpdateListing(ArtworkDetails artwork) async {
    // One sheet, two builders: `/tx/fixed-price/update` and 🔓
    // `/tx/fixed-price/cancel`. They are separate cells, so there is **no**
    // entry gate here: the sheet reads both cells
    // itself and renders each button dead with its own operator copy. Even a
    // dual kill opens it, because an early return could only show one of the two
    // messages and the one it dropped — whether delisting is paused, i.e.
    // whether the owner's asset is stuck — is the one that matters most.
    //
    // `UpdateFixedPriceTxRequest.seller` is the active signer, so re-point to
    // the owning session wallet before the sheet opens — and before
    // `guardViewOnly` (A1d).
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSignerForAny(
      context,
      _ownerAuthorityCandidates(artwork),
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    final currentPrice = MarketPrice(
      rawAmount: artwork.price ?? 0,
      currencyMint: artwork.currency,
    );
    final result = await showMallowSheet<UpdateListingResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => UpdateListingSheet(
        mintAccount: widget.mintAccount,
        currentPrice: currentPrice,
        // Same proceeds breakdown the listing-creation review step shows.
        // Resolved for the signer we just re-pointed to above — the seller the
        // update tx will carry.
        proceedsResolver: () =>
            resolveUpdateListingProceeds(widget.mintAccount),
        editionsSold: artwork.supplyType == SupplyType.openEdition
            ? artwork.quantitySold
            : null,
      ),
    );
    if (result == null) {
      // Dismissed without choosing — put the signer back.
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    final marketBloc = context.read<MarketBloc>();
    switch (result) {
      case UpdateListingPriceResult(:final newPrice):
        // Stash the RAW on-chain amount (in the listing currency's smallest
        // unit) so the success listener can flip the bottom sheet to the new
        // price immediately, without waiting for the indexer ack. Passing raw
        // through — instead of round-tripping via display units and a
        // hardcoded ×1e9 — keeps it correct for SOL AND non-9-decimal mints
        // like USDC.
        _pendingPriceUpdates[widget.mintAccount] = newPrice.rawAmount;
        marketBloc.add(
          MarketEvent.updateListing(
            mintAccount: widget.mintAccount,
            newPrice: newPrice,
          ),
        );
      case UpdateListingCancelResult():
        _pendingCancellations.add(widget.mintAccount);
        marketBloc.add(
          MarketEvent.cancelListing(mintAccount: widget.mintAccount),
        );
    }
  }

  // ----- Action-sheet callback wrappers ---------------------------------
  // Each wrapper enforces the shared `guardViewOnly` + mounted gate and
  // then dispatches the matching bloc event. Kept here so the dispatcher
  // function in `action_sheet.dart` stays bloc-/state-free.

  Future<void> _onCancelOffer() async {
    // Needs the loaded artwork for the flow sheet's header.
    final artwork = _loadedArtwork();
    if (artwork == null) return;
    // 🔓 Escape hatch — its own cell so killing offer *creation* can never
    // strand an escrowed bid.
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.offerCancel),
    )) {
      return;
    }
    if (!mounted) return;
    // `CancelOfferTxRequest.buyer` is the active signer, and the offer may have
    // been placed by any wallet in the session (the own-offer lookup is
    // session-wide — see `_maybeLoadUserOwnOffer`). Re-point to that maker
    // before dispatching, and before `guardViewOnly` (A1d).
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSigner(
      context,
      _userOwnOfferBuyer,
      watchOnlyMessage:
          'This offer was made by a watch-only wallet in your account. '
          'Import its private key to sign for it.',
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    context.read<MarketBloc>().add(
      MarketEvent.cancelOffer(
        mintAccount: widget.mintAccount,
        amount: _userOwnOfferAmount,
      ),
    );

    // Sheet-first: open the confirm sheet immediately, its "Total returned"
    // line shimmering while the cancel tx builds, then resolving in place —
    // rather than leaving the tap unresponsive until TxFlowReady. The
    // `_marketSheetActive` guard keeps the screen's Ready listener from
    // opening a second sheet.
    await _runMarketActionFlow(
      artwork: artwork,
      actionType: 'cancel-offer',
      preview: MarketActionPreview(
        actionType: 'cancel-offer',
        mintAccount: widget.mintAccount,
        // Matches the bloc's `event.amount ?? zero` fallback so the shimmer
        // resolves without a jump.
        totalCost: _userOwnOfferAmount ?? MarketPrice.zero(),
      ),
      previousSigner: previousSigner,
    );
  }

  Future<void> _onListUnlisted(ArtworkDetails artwork) async {
    // Snapshot the active signer so opening-then-leaving the sell flow doesn't
    // silently move the active wallet. The listing tx is signed inside the
    // pushed sell flow (which relies on the active wallet being the holder), so
    // the re-point must happen up front; restore it once the flow returns.
    final previousSigner = activeSignerSnapshot();
    // Signer first, guard second — see `_handleTransfer` (A1d).
    if (!await ensureSigner(context, artwork.ownerAddress)) return;
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    final supplyTypeJson = Uri.encodeQueryComponent(
      _supplyTypeJsonValue(artwork.supplyType),
    );
    // Refetch on return: the realtime invalidation fires off the indexer
    // ack, which can land before `getArtworkByMint` reflects the new
    // listing (and is skipped entirely if the poll times out). Re-pulling
    // when the listing flow pops guarantees the screen leaves stale
    // "unlisted" state behind.
    await context.push(
      '${AppRoutes.sellChooser}'
      '?mint=${artwork.mintAccount}'
      '&supplyType=$supplyTypeJson',
    );
    // The sell flow has returned (listed or backed out); any signing that needed
    // the holder as the active signer is done, so put the previous signer back.
    await restoreSigner(previousSigner);
    if (!mounted) return;
    context.read<ArtworkBloc>().add(const ArtworkEvent.refresh());
  }

  Future<void> _onCancelAuction({bool reclaim = false}) async {
    // 🔓 Escape hatch. Both branches (cancel and no-bid reclaim) are the same
    // on-chain `cancelAuction` ix and the same cell — matching the single
    // `AppFlow.auctionCancel` MarketBloc tags both with.
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.auctionCancel),
    )) {
      return;
    }
    if (!mounted) return;
    // `CancelAuctionTxRequest.seller` is the active signer — re-point to the
    // auction's seller (a session wallet that need not be active) before
    // dispatching, and before `guardViewOnly` (A1d).
    final artwork = _loadedArtwork();
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSigner(context, artwork?.auctionMetadata?.seller)) return;
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    context.read<MarketBloc>().add(
      MarketEvent.cancelAuction(
        mintAccount: widget.mintAccount,
        reclaim: reclaim,
      ),
    );

    // Sheet-first: open the gas-only confirm sheet immediately (network fee
    // shimmering while the tx builds) instead of waiting for TxFlowReady. The
    // bloc tags the action `reclaim-auction` / `cancel-auction`; both render the
    // same gas-only sheet. The `_marketSheetActive` guard keeps the screen's
    // Ready listener from opening a second sheet.
    final actionType = reclaim ? 'reclaim-auction' : 'cancel-auction';
    if (artwork == null) return;
    await _runMarketActionFlow(
      artwork: artwork,
      actionType: actionType,
      preview: MarketActionPreview(
        actionType: actionType,
        mintAccount: widget.mintAccount,
        // Cancel/reclaim collect no payment — gas only. Zero keeps the flow
        // sheet rendering the confirm step while the tx builds.
        totalCost: MarketPrice.zero(),
      ),
      // Dismissable confirm sheet — put the signer back if the user abandons
      // it, like accept-offer / cancel-offer / settle.
      previousSigner: previousSigner,
    );
  }

  /// The live auction sheet's countdown reached zero. Auction-ended is a
  /// purely time-based check — `resolveArtworkActionState` compares `endsAt`
  /// against the wall clock, since nothing flips on-chain at the end instant —
  /// so a plain rebuild re-resolves the bid/owner sheet into the claim/settle
  /// sheet. No refetch needed (and a failed one would dedup to a no-op); the
  /// realtime subscription covers the eventual settlement. Fires at most once
  /// per auction (the sheet guards re-entry).
  void _onAuctionEnded() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _onSettleAuction() async {
    // 🔓 Escape hatch — funds and the NFT sit in escrow until this runs, so it
    // is a separate cell from `auction-create` on purpose.
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.auctionSettle),
    )) {
      return;
    }
    if (!mounted) return;
    final artwork = _loadedArtwork();
    final auction = artwork?.auctionMetadata;
    // A1a: resolve the signer FIRST. Everything below is derived from `me` —
    // the proceeds breakdown and the optimistic ownership bookkeeping — so it
    // must be computed against the post-switch signer, or a seller settling
    // from a non-active wallet gets a gas-only sheet with no proceeds line.
    // `SettleAuctionTxRequest.caller` is either side of the auction; the active
    // wallet wins over candidate order inside `ensureSignerForAny`, so a winner
    // tapping "Claim NFT" is never switched to the seller. Signer before
    // `guardViewOnly` (A1d).
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSignerForAny(context, [
      auction?.seller,
      auction?.currentBidder,
    ])) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    // Populate the confirmation sheet's earnings breakdown only when the
    // connected wallet is the auction seller and the auction drew bids. The
    // winner-claim path (same ix) and no-bid reclaim carry no proceeds, so
    // they leave these null and fall back to the gas-only sheet.
    final me = sl<AuthService>().currentAddress;
    final bidAmount = auction?.currentBidAmount;

    MarketPrice? winningBid;
    if (auction != null &&
        me != null &&
        auction.seller == me &&
        auction.bidCount > 0 &&
        bidAmount != null &&
        bidAmount > 0) {
      // `currentBidAmount` is raw atomic units in `bidMint` (the gross
      // escrowed bid). The bloc resolves the seller's net proceeds from a tx
      // simulation, so only the gross + currency are needed here.
      winningBid = MarketPrice(
        rawAmount: bidAmount,
        currencyMint: auction.bidMint,
      );
    }

    // Capture the ownership outcome now, while the auction metadata is intact.
    // By the time `TxFlowSuccess` lands, the account-close socket event can have
    // existence-reconciled the auction away (nulling `currentBidder` / `seller`),
    // which defeats the live-artwork detection the success handler runs — so the
    // sheet would blink hidden behind the indexer gate then re-resolve, instead
    // of flipping straight to the post-settle state. Mirrors the accept-offer
    // dispatch-time capture (`_pendingAcceptOfferBuyer`).
    final winner = auction?.currentBidder;
    if (me != null && winner != null && winner == me) {
      // Winner tapped "Claim NFT" — they take possession of the NFT.
      _pendingSettleClaim.add(widget.mintAccount);
    } else if (auction != null &&
        me != null &&
        winner != null &&
        winner != me &&
        auction.seller == me &&
        auction.bidCount > 0) {
      // Seller settling a won auction — the NFT leaves them for the winner.
      _pendingSettleRelinquish[widget.mintAccount] = winner;
    }

    context.read<MarketBloc>().add(
      MarketEvent.settleAuction(
        mintAccount: widget.mintAccount,
        winningBid: winningBid,
      ),
    );

    // Open the confirm sheet immediately rather than waiting for TxFlowReady
    // (which leaves the Settle tap unresponsive while the tx builds). It shows
    // the "You'll receive" earnings line shimmering through the preparing +
    // simulation phases, then resolves in place. The `_marketSheetActive` guard
    // set inside _runMarketActionFlow keeps the screen's Ready listener from
    // opening a second sheet. Needs the loaded artwork for the header.
    if (artwork == null) return;
    await _runMarketActionFlow(
      artwork: artwork,
      actionType: 'settle-auction',
      preview: MarketActionPreview(
        actionType: 'settle-auction',
        mintAccount: widget.mintAccount,
        // Seller settle shows the gross winning bid (proceeds resolve from the
        // simulation); winner-claim / no-bid carry none → gas-only sheet.
        totalCost: winningBid ?? MarketPrice.zero(),
      ),
      previousSigner: previousSigner,
    );
  }

  Future<void> _onCancelRaffle(String raffleKey) async {
    // 🔓 Escape hatch.
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.raffleCancel),
    )) {
      return;
    }
    if (!mounted) return;
    // `getCancelRaffleTx(creator:)` is the active signer.
    final raffle = _raffleAuthorities(raffleKey);
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSigner(
      context,
      raffle.creator,
      watchOnlyMessage:
          'This raffle was created by a watch-only wallet in your account. '
          'Import its private key to sign for it.',
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    context.read<RaffleBloc>().add(RaffleEvent.cancel(raffleKey: raffleKey));
  }

  Future<void> _onClaimRaffleNft(String raffleKey) async {
    // 🔓 Escape hatch — the prize is held by the raffle until it is claimed.
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.raffleClaimPrize),
    )) {
      return;
    }
    if (!mounted) return;
    // `getClaimNftTx(caller:)` is the active signer — the winner claiming the
    // prize, or the creator reclaiming an expired raffle's NFT.
    final raffle = _raffleAuthorities(raffleKey);
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSignerForAny(
      context,
      [raffle.winner, raffle.creator],
      watchOnlyMessage:
          'This raffle prize belongs to a watch-only wallet in your account. '
          'Import its private key to sign for it.',
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    context.read<RaffleBloc>().add(RaffleEvent.claimNft(raffleKey: raffleKey));
  }

  Future<void> _onClaimRaffleProceeds(String raffleKey) async {
    // 🔓 Escape hatch — ticket revenue is held by the raffle until it is
    // claimed.
    if (await guardFlowDisabled(
      context,
      const FlowKey.solana(AppFlow.raffleClaimProceeds),
    )) {
      return;
    }
    if (!mounted) return;
    // `getClaimProceedsTx(creator:)` is the active signer.
    final raffle = _raffleAuthorities(raffleKey);
    final previousSigner = activeSignerSnapshot();
    if (!await ensureSigner(
      context,
      raffle.creator,
      watchOnlyMessage:
          "This raffle's proceeds belong to a watch-only wallet in your "
          'account. Import its private key to sign for it.',
    )) {
      return;
    }
    if (!mounted) return;
    if (await guardViewOnly(context)) {
      await restoreSigner(previousSigner);
      return;
    }
    if (!mounted) return;
    context.read<RaffleBloc>().add(
      RaffleEvent.claimProceeds(raffleKey: raffleKey),
    );
  }
}

/// Action types that bypass [MarketConfirmationSheet] and go straight from
/// `readyToSign` → `signing`. These are listing-management actions where
/// the user already pressed an explicit, dedicated button (the
/// "Cancel listing" / "Update listing" affordance is itself the confirm
/// step) and a second confirmation adds friction without value.
bool _skipsConfirmation(String actionType) =>
    actionType == 'update-listing' || actionType == 'cancel-listing';

/// The curation [mintAccount] was last opened from, or null. Read back from
/// the same device-local store [MarketBloc] stamped on the buy request, so the
/// Mixpanel funnel and the on-chain `curation:<SLUG>` memo report the same
/// referral. Null-safe against widget tests that don't bootstrap DI.
String? _curationSource(String mintAccount) =>
    sl.isRegistered<CurationAttributionStore>()
    ? sl<CurationAttributionStore>().shareSlugFor(mintAccount)
    : null;

String _raffleSuccessMessage(String actionType) {
  switch (actionType) {
    case 'buy-tickets':
      return 'Tickets purchased!';
    case 'cancel-raffle':
      return 'Raffle cancelled.';
    case 'claim-nft':
      return 'NFT claimed.';
    case 'claim-proceeds':
      return 'Proceeds claimed.';
    default:
      return 'Transaction complete.';
  }
}
