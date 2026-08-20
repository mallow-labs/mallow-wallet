// Extension methods on [_ArtworkDetailViewState] call protected State APIs
// like setState. The analyzer flags this for plain extensions, but the
// part-file scope keeps the pattern internal to the screen library.
// ignore_for_file: invalid_use_of_protected_member

part of '../artwork_detail_screen.dart';

/// Async side-effect loaders for [_ArtworkDetailViewState] — permissions,
/// edition live state / stats, realtime invalidations, user-own-offer,
/// and creator usernames. Each loader is deduped on its own key so it
/// is safe to call from build().
extension _ArtworkDetailLoaders on _ArtworkDetailViewState {
  void _maybeLoadPermissions(ArtworkDetails artwork) {
    if (_permissionsLoading || _permissions != null) return;
    _permissionsLoading = true;
    sl<ArtworkPermissionService>()
        .checkPermissions(
          artwork.mintAccount,
          // Widen the owner-sheet gates (List, etc.) across the session so an
          // artwork held by a non-active session wallet still shows its owner
          // actions; `_ensureSigner` switches to the holder before signing.
          sessionAddresses: sl<SessionManager>().sessionAddresses,
          // Transfer/burn must see the indexed listing state: the frozen bit
          // alone misses delegate-only and non-custodial listings.
          listingType: artwork.listingType,
          inGroupedSale: artwork.groupedSale != null,
        )
        .then((perms) {
          if (!mounted) return;
          setState(() => _permissions = perms);
        })
        .whenComplete(() => _permissionsLoading = false);
  }

  /// DAS-derived edition state — fetched once per mint. Drives the
  /// dispatcher's `BuyEditionSheet` vs `BuySheet` routing, plus the live
  /// supply progress bar on the edition sheet. Backend wraps
  /// `getSupplyInfoFromDigitalAsset` + `isPrintableMasterEditionFromSupplyType`.
  void _maybeLoadEditionLive(String mintAccount) {
    if (_editionLiveLoadedFor == mintAccount) return;
    _editionLiveLoadedFor = mintAccount;
    sl<MarketListingRepository>().getEditionState(mintAccount).then((state) {
      if (!mounted || _editionLiveLoadedFor != mintAccount) return;
      setState(() => _editionLive = state);
    });
  }

  /// Live raffle PDA snapshot — fetched once per raffle account. The indexed
  /// `raffleMetadata` lags exactly where it matters most: `sold` and `winner`
  /// decide awaiting-draw vs expired-unsold, and therefore whether a creator
  /// is offered the reclaim that gets their NFT out of raffle escrow.
  /// Mirrors the webapp, which reads the raffle account directly
  /// (`useRaffle` via `useRaffleState`).
  void _maybeLoadRaffleLive(ArtworkDetails artwork) {
    final raffleKey = artwork.raffleMetadata?.raffleAccount;
    if (raffleKey == null || raffleKey.isEmpty) return;
    if (_raffleLiveLoadedFor == raffleKey) return;
    _raffleLiveLoadedFor = raffleKey;
    sl<RaffleRepository>().getState(raffleKey).then((state) {
      if (!mounted || _raffleLiveLoadedFor != raffleKey) return;
      setState(() => _raffleLive = state);
    });
  }

  /// True for limited- and open-edition master artworks. Used to branch
  /// the post-buy success handler so edition buys keep the sheet visible
  /// instead of falling into the indexer-gate path.
  bool _isEditionMasterArtwork(ArtworkDetails artwork) {
    final st = artwork.supplyType;
    return st == SupplyType.limitedEdition || st == SupplyType.openEdition;
  }

  /// Bump cached edition supply + per-wallet buy count by one so the buy-
  /// edition sheet reflects the just-confirmed purchase before the
  /// indexer / DAS refetch lands. Reconciled by the standard refetch on
  /// the `MarketSuccess.indexed` flip and by realtime invalidations.
  void _applyOptimisticEditionBuy() {
    setState(() {
      final live = _editionLive;
      if (live != null) {
        _editionLive = live.copyWith(
          supplyInfo: live.supplyInfo.copyWith(
            supply: live.supplyInfo.supply + 1,
          ),
        );
      }
      final stats = _editionStats;
      if (stats != null) {
        _editionStats = stats.copyWith(buyCount: stats.buyCount + 1);
      }
    });
  }

  /// Pre-fetch edition wallet-cap + allowlist state when the artwork is a
  /// buy-now master edition. Runs once per (mint × buyer) pair. The
  /// backend resolves the listing PDA from the mint internally.
  void _maybeLoadEditionStats(ArtworkDetails artwork) {
    final me = sl<AuthService>().currentAddress;
    final isMaster =
        artwork.supplyType == SupplyType.limitedEdition ||
        artwork.supplyType == SupplyType.openEdition;
    final isBuyNow = artwork.listingType == ListingType.buyNow;
    if (!isMaster || !isBuyNow || me == null) {
      if (_editionStats != null && _editionStatsLoadedFor != null) {
        setState(() {
          _editionStats = null;
          _editionStatsLoadedFor = null;
          _editionOnChainAllowlisted = null;
          _editionHoldsGatingNft = null;
        });
      }
      return;
    }
    final key = '${artwork.mintAccount}|$me';
    if (_editionStatsLoadedFor == key) return;
    _editionStatsLoadedFor = key;
    // The two verdicts below are answers about a SPECIFIC wallet, so a key
    // change (wallet switch, or a post-tx / invalidation key reset) invalidates
    // them the instant it happens — not when the replacement fetches land.
    // Leaving them would let the previous wallet's definitive `false`s keep
    // driving [isWhitelistPhaseBlocked] and block a newly-selected wallet that
    // IS allowlisted (and, symmetrically, carry a stale qualification forward).
    // Null means "unknown", which never blocks — the same thing the early
    // return above does. Plain assignment rather than `setState`: this runs
    // from build() and the fields are read later in the same pass.
    _editionOnChainAllowlisted = null;
    _editionHoldsGatingNft = null;
    sl<MarketListingRepository>()
        .getEditionPurchaseStats(mint: artwork.mintAccount, buyer: me)
        .then((stats) {
          if (!mounted || _editionStatsLoadedFor != key) return;
          setState(() => _editionStats = stats);
          _maybeLoadEditionWhitelistEligibility(artwork, me, key, stats);
        });
  }

  /// Resolve both halves of the on-chain whitelist phase for the connected
  /// wallet — the Merkle wallet allowlist and the holder-only token gate.
  /// Either one qualifies the buyer, so both are fetched and ORed
  /// ([isWhitelistPhaseBlocked]); the webapp does the same
  /// (`useWhitelistConfig`).
  ///
  /// Chained off the stats fetch because that response is what reveals whether
  /// a phase exists at all. A listing with no `whitelistConfig` has nothing to
  /// be excluded from, so it skips both round-trips and leaves the verdicts
  /// null (never blocking) — the webapp fires its holder query unconditionally,
  /// but the result is only ever consulted inside `isWhitelistPhase`.
  void _maybeLoadEditionWhitelistEligibility(
    ArtworkDetails artwork,
    String me,
    String key,
    EditionPurchaseStats? stats,
  ) {
    final config = stats?.whitelistConfig;
    if (config == null) return;
    // Both verdicts are consulted only inside [isWhitelistPhaseBlocked], which
    // returns "not blocked" for an inactive phase whatever they say — a closed
    // allowlist window makes the listing public. So for every past drop (the
    // steady state) these two round-trips can only ever produce an answer
    // nobody reads, on every artwork-detail open. Skip them and leave the
    // verdicts null; if the phase later opens, the stats refetch that reveals
    // it re-runs this loader with the fresh config.
    if (!config.isActive) return;

    sl<WhitelistEligibilityRepository>()
        .isWalletAllowlisted(walletsRoot: config.walletsRoot, address: me)
        .then((allowlisted) {
          if (!mounted || _editionStatsLoadedFor != key) return;
          setState(() => _editionOnChainAllowlisted = allowlisted);
        });

    // The holder-only route keys on the LISTING PDA, not the mint. The
    // derivation is local (`["listing", mint]`), so this costs no extra
    // round-trip.
    sl<MarketAccountRepository>()
        .deriveListingPda(artwork.mintAccount)
        .then(
          (pda) => sl<WhitelistEligibilityRepository>().holdsGatingNft(
            listingPda: pda,
            address: me,
          ),
        )
        .then((holds) {
          if (!mounted || _editionStatsLoadedFor != key) return;
          setState(() => _editionHoldsGatingNft = holds);
        });
  }

  /// Open (or reuse) a realtime subscription for this mint. Subsequent
  /// invalidation events drive the per-screen refetches that match the
  /// webapp's on-account-change handlers.
  void _maybeStartRealtime(String mintAccount) {
    if (_realtimeMint == mintAccount && _realtimeSub != null) return;
    _realtimeSub?.cancel();
    _realtimeMint = mintAccount;
    _realtimeSub = sl<MarketRealtimeService>()
        .watchMint(mintAccount)
        .listen((event) => _onInvalidation(mintAccount, event));
  }

  void _stopRealtime() {
    _realtimeSub?.cancel();
    _realtimeSub = null;
    _realtimeMint = null;
  }

  /// (Re)schedule a one-shot rebuild for the instant a live auction's `endsAt`
  /// passes, so the bid/owner sheet re-resolves into the claim/settle sheet
  /// even when no [ArtworkAuctionLivePanel] ticker is mounted to notice it
  /// (the sheet is hidden while the high bidder's own bid is mid-index — see
  /// [_pendingIndexerMints]). Auction-ended is a pure clock comparison, so a
  /// plain `setState` is enough to flip the resolved action state. Deduped on
  /// the target instant so it doesn't churn the timer on every rebuild; a bid
  /// that extends `endsAt` reschedules against the later deadline. Safe to call
  /// from build().
  void _scheduleAuctionEndCheck(ArtworkDetails artwork) {
    final endsAt = artwork.listingType == ListingType.auction
        ? artwork.auctionMetadata?.endsAt
        : null;
    // No future deadline to watch (not an auction, on-bid with no clock yet, or
    // already ended — the resolver returns the claim state on every build once
    // past `endsAt`). Tear down any stale timer.
    if (endsAt == null || !endsAt.isAfter(DateTime.now())) {
      _auctionEndTimer?.cancel();
      _auctionEndTimer = null;
      _scheduledAuctionEnd = null;
      return;
    }
    if (_scheduledAuctionEnd == endsAt) return;
    _auctionEndTimer?.cancel();
    _scheduledAuctionEnd = endsAt;
    _auctionEndTimer = Timer(endsAt.difference(DateTime.now()), () {
      if (!mounted) return;
      setState(() {});
    });
  }

  /// Coarse refetch in response to a realtime invalidation. Mirrors the
  /// webapp's on-account-change handlers across `useAuctionMetadata`,
  /// `useListing`, `useRaffle`, `useOnChainAsset` — `/byMint` is the root
  /// re-pull and covers indexer-derived auction / listing / raffle /
  /// edition fields. Edition supply (DAS) and per-buyer state get
  /// invalidated separately so they re-fetch from build().
  void _onInvalidation(String mintAccount, MarketInvalidation event) {
    if (!mounted || _realtimeMint != mintAccount) return;
    debugPrint(
      '[LIST-DEBUG] artwork invalidation mint=$mintAccount '
      'programs=${event.programs} slot=${event.slot} '
      '@${DateTime.now().toIso8601String()}',
    );
    // The invalidation carries its triggering tx's slot (post-index publish):
    // state for this mint changed at that slot, so raise the bloc's chain
    // floor — an absent read with an older view predates the change. Covers
    // actions from ANY actor, including this user's list flows that run on a
    // different screen. Synthetic reconnects / legacy publishes carry slot 0.
    if (event.slot > 0) {
      context.read<ArtworkBloc>().add(
        ArtworkEvent.chainActionLanded(slot: event.slot),
      );
    }
    context.read<ArtworkBloc>().add(const ArtworkEvent.refresh());
    // The refresh above fires when the marketplace entry is indexed, which
    // is before the derived event-log row lands — so the History tab can
    // re-mount without the new event. Poll the activity feed and refetch
    // once more when it appears. Skipped for synthetic reconnects (no sig).
    _reconcileHistory(mintAccount, event.signature);

    final touchesMarket = event.programs.contains(kMallowMarketProgramId);
    final isSyntheticReconnect = event.programs.contains(_kSyntheticReconnect);

    if (touchesMarket || isSyntheticReconnect) {
      _editionLiveLoadedFor = null;
      _editionStatsLoadedFor = null;
      _maybeLoadEditionLive(mintAccount);
    }
    // Offer state may have flipped (offer accepted / cancelled) — clear the
    // dedup keys so the next build() re-runs the offer loaders. But NOT while
    // this user has an in-flight offer / cancel-offer whose optimistic flip is
    // still pinned: an early invalidation clearing the key here would reload
    // the pre-index backend value and revert the Make↔Cancel flip. The tx's
    // indexed-ack releases the pin and reconciles then.
    if (_pendingOfferSigs.isEmpty) {
      _userOwnOfferLoadedFor = '';
      _highestOfferLoadedFor = null;
    }
  }

  /// Bridge the gap between marketplace-entry indexing (what the post-tx
  /// refresh waits on) and event-log indexing (what the History tab reads):
  /// poll the activity feed for [signature] and, once the row lands, fire a
  /// final [ArtworkEvent.refresh] so the History / Offers tabs surface it
  /// without a manual pull-to-refresh. Fire-and-forget; bails if the screen
  /// is gone or has navigated to a different mint. No-op for empty
  /// signatures (synthetic reconnect invalidations carry none).
  void _reconcileHistory(String mintAccount, String signature) {
    if (signature.isEmpty) return;
    unawaited(
      sl<ArtworkEventsRepository>()
          .waitForEvent(mintAccount: mintAccount, txId: signature)
          .then((found) {
            if (!mounted || !found || _realtimeMint != mintAccount) return;
            context.read<ArtworkBloc>().add(const ArtworkEvent.refresh());
          }),
    );
  }

  /// Reconcile the connected wallet's own-offer state against the chain right
  /// after an offer / cancel-offer confirms, instead of holding a blind
  /// optimistic pin until the indexer acks. Reads the canonical Offer PDA
  /// (`["offer", buyer, mint]`) via the accounts endpoint:
  ///
  ///  * make-offer ([expectPresent] true): once the account is present, apply
  ///    the on-chain amount + currency — filling the gap where the optimistic
  ///    flip knew the offer existed but not its amount (cancel previously fell
  ///    back to rent-only until the indexer caught up).
  ///  * cancel-offer: once the account is absent AND the read's view slot is
  ///    at/past the cancel tx's landed slot (or, with no slot to order by, on
  ///    a repeated absent read), the offer is confirmed gone.
  ///
  /// Polls briefly (the read is `confirmed`-commitment, so one or two
  /// attempts normally suffice); bails when the screen navigates away or the
  /// indexed-ack has already reconciled. Fire-and-forget.
  Future<void> _reconcileOwnOffer({
    required String mintAccount,
    required bool expectPresent,
    required String signature,
  }) async {
    // The Offer PDA is keyed by its **maker**, which — with the session-wide
    // own-offer lookup (A1b) — need not be the active signer. Prefer the
    // resolved maker; fall back to the active address for a just-made offer
    // whose buyer is by definition the wallet that signed it.
    final buyer = _userOwnOfferBuyer ?? sl<AuthService>().currentAddress;
    if (buyer == null) return;
    final repo = sl<MarketAccountRepository>();
    final floorSlot = sl<TxLandedSlots>().slotFor(signature) ?? 0;
    for (var attempt = 1; attempt <= 5; attempt++) {
      final read = await repo.readOffer(buyer: buyer, mint: mintAccount);
      if (!mounted || _realtimeMint != mintAccount) return;
      // The indexed-ack reconcile released the pin and re-ran the loaders —
      // its server truth supersedes this poll.
      if (!_pendingOfferSigs.contains(signature)) return;
      if (expectPresent && read.status == OnChainReadStatus.present) {
        final acct = read.account!;
        final price = acct.offerPrice;
        setState(() {
          _userOwnOffer = true;
          _userOwnOfferBuyer = buyer;
          _userOwnOfferAmount = price == null
              ? null
              : MarketPrice(
                  rawAmount: price.toDouble(),
                  currencyMint: acct.offerCurrencyMint,
                );
        });
        return;
      }
      if (!expectPresent && read.status == OnChainReadStatus.absent) {
        final slotOrdered = read.viewSlot != null
            ? read.viewSlot! >= floorSlot
            : attempt >= 2;
        if (slotOrdered) {
          setState(() {
            _userOwnOffer = false;
            _userOwnOfferAmount = null;
            _userOwnOfferBuyer = null;
          });
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
    }
  }

  /// Every address that could have placed "my" offer: the active signer
  /// unioned with the current session's wallets. The own-offer lookup is
  /// session-wide (A1b) so an offer placed from a non-active session wallet
  /// still surfaces the Cancel affordance — `_onCancelOffer` then re-points
  /// the signer to that maker before dispatching.
  Set<String> _offerBuyerAddresses() => <String>{
    ?sl<AuthService>().currentAddress,
    ...sl<SessionManager>().sessionAddresses,
  }..removeWhere((a) => a.isEmpty);

  /// Dedup key for [_maybeLoadUserOwnOffer], keyed off the **session set**
  /// rather than the active address — a session change (wallet added/removed,
  /// profile switch) must re-run the widened lookup, and a plain active-wallet
  /// switch inside the same session must not (the answer is unchanged).
  /// Shared with the post-offer optimistic flip so its pin holds.
  String _userOwnOfferKey(String mintAccount) {
    final buyers = _offerBuyerAddresses();
    if (buyers.isEmpty) return '';
    final sorted = buyers.toList()..sort();
    return '$mintAccount|${sorted.join(',')}';
  }

  /// Fetch (once per mint × session set) whether any wallet in the session has
  /// a live offer, and which one placed it. No-op when no wallet is connected.
  void _maybeLoadUserOwnOffer(String mintAccount) {
    final buyers = _offerBuyerAddresses();
    final loadKey = _userOwnOfferKey(mintAccount);
    if (_userOwnOfferLoadedFor == loadKey) return;
    _userOwnOfferLoadedFor = loadKey;
    if (buyers.isEmpty) {
      if (_userOwnOffer) {
        setState(() {
          _userOwnOffer = false;
          _userOwnOfferAmount = null;
          _userOwnOfferBuyer = null;
        });
      }
      return;
    }
    sl<OfferRepository>()
        .getUserActiveOffer(mintAccount: mintAccount, buyerAddresses: buyers)
        .then((offer) {
          if (!mounted || _userOwnOfferLoadedFor != loadKey) return;
          setState(() {
            _userOwnOffer = offer != null;
            // The maker — the authority `CancelOfferTxRequest.buyer` needs.
            _userOwnOfferBuyer = offer?.buyerAddress;
            _userOwnOfferAmount = offer == null
                ? null
                : MarketPrice(
                    rawAmount: offer.price,
                    currencyMint: offer.currencyMint,
                  );
          });
        });
  }

  /// The mint every price and CTA on this screen is denominated in: the
  /// auction's `bidMint` when one is live (auctions carry no `currency`),
  /// otherwise the listing currency.
  String? _pricingMint(ArtworkDetails artwork) =>
      artwork.auctionMetadata?.bidMint ?? artwork.currency;

  /// Resolve the listing/bid currency's symbol + decimals for a mint the
  /// static registry doesn't key.
  ///
  /// Gates the buy / bid CTA (`ArtworkBuyBlock.unknownCurrency`) as well as
  /// feeding the price rows, which is the point: the CTA and the figure above
  /// it read the same [TokenMetadataService.statusOf], so the button can never
  /// be live for an amount the user was never shown. Warming it here also
  /// resolves the mint for everything downstream of it — funding source,
  /// balance check, confirmation-sheet breakdown — since they all read the
  /// registry overlay this populates.
  void _maybeLoadCurrencyMetadata(ArtworkDetails artwork) {
    final mint = _pricingMint(artwork);
    final service = sl<TokenMetadataService>();
    if (!service.needsLookup(mint, chain: artwork.chain)) return;
    final loadKey = '${artwork.mintAccount}|$mint';
    if (_currencyMetadataLoadedFor == loadKey) return;
    _currencyMetadataLoadedFor = loadKey;
    service.resolve(mint, chain: artwork.chain).whenComplete(() {
      if (!mounted || _currencyMetadataLoadedFor != loadKey) return;
      // Nothing to store — `statusOf` is the read model. This is purely the
      // "the answer landed, re-derive the action state" signal.
      setState(() {});
    });
  }

  /// Fetch (once per mint × offer-count) the highest active offer so the
  /// owner sheet can render its accept panel and the unlisted-viewer
  /// sheet its offer panel. Keyed on the indexer-reported `highestOffer`
  /// value so a new top offer re-fetches the buyer/date detail.
  void _maybeLoadHighestOffer(ArtworkDetails artwork) {
    final hasOffers =
        artwork.highestOffer != null || (artwork.offersCount ?? 0) > 0;
    final loadKey = hasOffers
        ? '${artwork.mintAccount}|${artwork.highestOffer}'
        : '';
    if (_highestOfferLoadedFor == loadKey) return;
    _highestOfferLoadedFor = loadKey;
    if (!hasOffers) {
      if (_highestOffer != null) setState(() => _highestOffer = null);
      return;
    }
    sl<OfferRepository>()
        .getHighestOffer(mintAccount: artwork.mintAccount)
        .then((offer) {
          if (!mounted || _highestOfferLoadedFor != loadKey) return;
          setState(() => _highestOffer = offer);
        });
  }

  void _maybeLoadCreatorUsernames(List<String> addresses) {
    final key = addresses.toList(growable: false);
    if (_loadedCreatorAddresses != null &&
        _listEquals(_loadedCreatorAddresses!, key)) {
      return;
    }
    _loadedCreatorAddresses = key;
    if (key.isEmpty) return;
    sl<UserProfileRepository>().getUserProfiles(key).then((map) {
      if (!mounted ||
          _loadedCreatorAddresses == null ||
          !_listEquals(_loadedCreatorAddresses!, key)) {
        return;
      }
      setState(() {
        _creatorUsernames
          ..clear()
          ..addEntries(
            map.entries.map((e) => MapEntry(e.key, e.value?.username)),
          );
        _creatorLinkedAddresses
          ..clear()
          ..addAll(map.keys.where((a) => a.isNotEmpty))
          ..addAll(
            map.values
                .whereType<UserProfile>()
                .expand((p) => p.linkedAddresses)
                .where((a) => a.isNotEmpty),
          );
      });
    });
  }
}
