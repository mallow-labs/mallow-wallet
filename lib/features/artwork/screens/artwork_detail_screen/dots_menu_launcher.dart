// ignore_for_file: invalid_use_of_protected_member

part of '../artwork_detail_screen.dart';

/// Dots-menu launcher and debug logging — kept here so the state class
/// in [artwork_detail_screen.dart] focuses on the persistent action sheet
/// orchestration and scroll body.
extension _ArtworkDetailDotsMenu on _ArtworkDetailViewState {
  Future<void> _showDotsMenu(ArtworkDetails artwork) async {
    // Same sheet as the grid/curation surfaces — the detail screen only
    // hides "View artwork" (the viewer is already here) and adds the
    // detail-only Sync token / View master edition rows.
    final portfolioArtwork = artwork.toPortfolioArtwork();
    final action = await showArtworkContextMenu(
      context,
      artwork: portfolioArtwork,
      showViewArtwork: false,
      showSyncToken: true,
      // "View master edition" only for printed editions — `parentEdition`
      // is the master mint and is populated by the DAS edition-state load
      // only for print children (null for masters / 1-of-1s).
      showViewMasterEdition: _editionLive?.parentEdition != null,
      inGroupedSale: artwork.groupedSale != null,
      ownerAddresses: [
        if (artwork.ownerAddress != null) artwork.ownerAddress!,
        ...artwork.ownerAddresses,
      ],
      collectionMint: artwork.collectionMint,
      // Cast is allowed for owner OR any creator (royalty splits, linked
      // addresses) — richer than the sheet's on-chain owner/update-auth gate.
      canCastOverride: _canCast(artwork),
      // Route like taps through the bloc so the on-screen like count and
      // heart stay in sync with the sheet's row.
      initialIsLiked: artwork.isLiked,
      onToggleLike: () {
        context.read<ArtworkBloc>().add(const ArtworkEvent.toggleLike());
      },
      // Widen Transfer / Burn / Edit across the session; the detail screen's
      // `_ensureSigner` switches to the holding wallet before signing.
      sessionAddresses: sl<SessionManager>().sessionAddresses,
      // Reporting hides the artwork from the reporter. Grids drop the tile via
      // [ArtworkRemovalSignal]; this screen *is* the artwork, so it leaves.
      dismissOnReport: true,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case ArtworkContextMenuAction.download:
        await downloadArtworkWithVerify(context, portfolioArtwork);
      case ArtworkContextMenuAction.hideArtwork:
        // The bloc reflects the flip via [ArtworkHiddenSignal] (see
        // ArtworkBloc), keeping the on-screen state and this sheet in sync.
        await toggleArtworkHidden(
          context,
          mintAccount: artwork.mintAccount,
          currentlyHidden: artwork.isHidden,
        );
      case ArtworkContextMenuAction.castToScreen:
        unawaited(_onCast(artwork));
      case ArtworkContextMenuAction.addToCastQueue:
        _onAddToCast(artwork);
      case ArtworkContextMenuAction.addToCuration:
        unawaited(_addToCuration(artwork));
      case ArtworkContextMenuAction.syncToken:
        unawaited(_syncToken(artwork));
      case ArtworkContextMenuAction.viewMasterEdition:
        context.goToArtwork(_editionLive!.parentEdition!);
      case ArtworkContextMenuAction.transfer:
        unawaited(_handleTransfer(artwork));
      case ArtworkContextMenuAction.burn:
        unawaited(_handleBurn(artwork));
      default:
        break;
    }
  }

  /// Ask the indexer to re-pull on-chain metadata for this mint, then
  /// reload the detail view. Webapp "Sync token" parity, including the
  /// soft failure copy — the backend enqueues a background job and
  /// dedupes per mint for 5 minutes, so an error usually just means
  /// "still working", not "failed".
  Future<void> _syncToken(ArtworkDetails artwork) async {
    try {
      await sl<ArtworkRepository>().syncArtwork(artwork.mintAccount);
      if (!mounted) return;
      AppSnackBar.show(context, 'Token synced');
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        'Syncing is taking longer than expected, '
        'please check the artwork in 5 minutes',
      );
    }
    // Webapp parity: invalidate/refetch the asset either way.
    if (!mounted) return;
    context.read<ArtworkBloc>().add(const ArtworkEvent.refresh());
  }

  /// Print the resolver inputs + output once per distinct resolution, so
  /// the console isn't spammed on every rebuild. Pair with the visible
  /// `_ActionStateDebugBanner` for at-a-glance state info on device.
  void _debugLogActionState(
    ArtworkDetails artwork,
    String? currentAddress,
    ArtworkActionState state,
  ) {
    if (!kDebugMode) return;
    final auction = artwork.auctionMetadata;
    final isHighestBidder =
        currentAddress != null && currentAddress == auction?.currentBidder;
    // The pending-indexer gate hides the sheet entirely while a just-confirmed
    // tx (e.g. the user's own bid) is mid-index — a prime suspect when the bid
    // sheet "dismisses" instead of flipping to "you are the highest bidder".
    final pendingIndexer = _pendingIndexerMints.contains(artwork.mintAccount);
    final key =
        '${state.runtimeType}|$currentAddress|'
        '${artwork.listingType}|${artwork.ownerAddress}|'
        '${artwork.ownerAddresses.join(",")}|'
        '${_permissions?.canList}|'
        '${auction?.currentBidder}|${auction?.currentBidAmount}|'
        '${auction?.bidCount}|$isHighestBidder|$pendingIndexer';
    if (_lastDebugKey == key) return;
    _lastDebugKey = key;
    debugPrint('--- [ArtworkDetail] action state ---');
    debugPrint('  resolved        : ${state.runtimeType}');
    debugPrint('  pendingIndexer  : $pendingIndexer (sheet hidden when true)');
    debugPrint('  currentAddress  : $currentAddress');
    debugPrint('  listingType     : ${artwork.listingType}');
    debugPrint('  supplyType      : ${artwork.supplyType}');
    debugPrint('  ownerAddress    : ${artwork.ownerAddress}');
    debugPrint('  ownerAddresses  : ${artwork.ownerAddresses}');
    debugPrint('  artistAddress   : ${artwork.artistAddress}');
    debugPrint('  artistAddresses : ${artwork.artistAddresses}');
    debugPrint('  updateAuthority : ${artwork.updateAuthority}');
    debugPrint('  auction.seller  : ${auction?.seller}');
    debugPrint('  auction.account : ${auction?.auctionAccount}');
    debugPrint('  auction.bidder  : ${auction?.currentBidder}');
    debugPrint('  auction.bid     : ${auction?.currentBidAmount}');
    debugPrint('  auction.bidCount: ${auction?.bidCount}');
    debugPrint('  auction.endsAt  : ${auction?.endsAt}');
    debugPrint('  isHighestBidder : $isHighestBidder');
    debugPrint('  highestOffer    : ${artwork.highestOffer}');
    debugPrint('  offersCount     : ${artwork.offersCount}');
    debugPrint('  buyNow.amount   : ${artwork.buyNowMetadata?.amount}');
    debugPrint('  buyNow.account  : ${artwork.buyNowMetadata?.listingAccount}');
    debugPrint('  permissions     : $_permissions');
    debugPrint('  @ ${DateTime.now().toIso8601String()}');
    debugPrint('-------------------------------------');
  }
}
