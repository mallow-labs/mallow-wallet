part of '../artwork_detail_screen.dart';

/// Body content below the artwork image: title, artist row, collection /
/// curated-in row, the artwork-info tabs, and the secondary History / Offers
/// tab strip. Owns the local tab index so the parent doesn't rebuild on
/// every tab swap.
class _ArtworkDetailBody extends StatefulWidget {
  const _ArtworkDetailBody({
    required this.artwork,
    required this.revision,
    required this.viewData,
    required this.onOpenCollection,
    required this.onOpenCurations,
  });

  final ArtworkDetails artwork;

  /// [ArtworkLoaded.revision] — bumped on each indexer-driven refresh. Passed
  /// as the History / Offers sections' `refreshToken` so a completed listing /
  /// offer re-pulls their first page in the background (they otherwise fetch
  /// once on mount and cache forever), keeping the current rows on screen
  /// instead of remounting into a loading state.
  final int revision;

  final ArtworkInfoViewData viewData;

  /// Null when the artwork has no collection mint (no tap target).
  final VoidCallback? onOpenCollection;

  /// Null when the artwork is in no curations (no tap target).
  final VoidCallback? onOpenCurations;

  @override
  State<_ArtworkDetailBody> createState() => _ArtworkDetailBodyState();
}

class _ArtworkDetailBodyState extends State<_ArtworkDetailBody> {
  static const _tab2Labels = ['History', 'Offers'];

  int _tab2Index = 0;

  /// Tab indices that have been shown at least once. Sections mount lazily
  /// on first activation, then stay alive (hidden, state intact) across
  /// toggles so switching back doesn't refetch their pages.
  final Set<int> _tab2Mounted = {0};

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final artwork = widget.artwork;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formatArtworkName(
            name: artwork.title,
            editionNumber: artwork.editionNumber,
          ),
          style: MallowTheme.editorialSection.copyWith(
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: MallowTheme.spacingXs),
        TapTargetExpander(
          child: GestureDetector(
            onTap: () => context.goToProfile(artwork.artistAddress),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatHandleOrAddress(
                    username: artwork.artistUsername,
                    address: artwork.artistAddress,
                  ),
                  style: MallowTheme.uiMeta.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                if (artwork.isVerified || artwork.isAdmin) ...[
                  const SizedBox(width: MallowTheme.spacingXs),
                  VerifiedBadge(size: 16, isAdmin: artwork.isAdmin),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: MallowTheme.spacing20),
        CollectionCurationRow(
          collectionName: artwork.collectionName,
          collectionImageUrl: artwork.collectionImageUrl,
          onCollectionTap: widget.onOpenCollection,
          curations: artwork.curations,
          onCurationsTap: widget.onOpenCurations,
        ),
        const SizedBox(height: MallowTheme.spacing20),
        ArtworkInfoTabs(data: widget.viewData),
        const SizedBox(height: MallowTheme.spacing20),
        MallowUnderlineTabBar(
          tabs: _tab2Labels,
          activeIndex: _tab2Index,
          onTabSelected: (i) => setState(() => _tab2Index = i),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        AnimatedTabContent(
          activeIndex: _tab2Index,
          builder: (_, i) {
            _tab2Mounted.add(i);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Visibility(
                  visible: i == 0,
                  maintainState: true,
                  child: HistorySection(
                    key: ValueKey('history-${artwork.mintAccount}'),
                    mintAccount: artwork.mintAccount,
                    refreshToken: widget.revision,
                  ),
                ),
                if (_tab2Mounted.contains(1))
                  Visibility(
                    visible: i == 1,
                    maintainState: true,
                    child: OffersSection(
                      key: ValueKey('offers-${artwork.mintAccount}'),
                      mintAccount: artwork.mintAccount,
                      refreshToken: widget.revision,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Addresses the artwork-info view-data builder needs resolved before it
/// can render usernames for creators, royalty splits, the update authority,
/// auction bidders, raffle winners, and curation creators.
List<String> _collectArtworkInfoAddresses(ArtworkDetails artwork) {
  return <String>{
    artwork.artistAddress,
    for (final s in artwork.royaltySplits) s.address,
    if (artwork.updateAuthority != null) artwork.updateAuthority!,
    if (artwork.auctionMetadata?.currentBidder != null)
      artwork.auctionMetadata!.currentBidder!,
    ...?artwork.auctionMetadata?.bidders,
    if (artwork.raffleMetadata?.winner != null) artwork.raffleMetadata!.winner!,
    for (final c in artwork.curations)
      if (c.creatorAddress != null) c.creatorAddress!,
  }.where((a) => a.isNotEmpty).toList()..sort();
}

/// The Royalties row's value when the index reports no seller fee.
///
/// Webapp parity (`ArtworkDetails`): `sellerFeeBasisPoints === 0`
/// falls back to the on-chain royalty (`getRoyalties`, mobile's
/// [resolveOnChainRoyalties] via [ArtworkPermissions.onChainRoyaltyBps]) and,
/// failing that, renders `0%`. Only ever called with a RESOLVED permissions
/// read — see [_royaltyRowState]; a null [bps] there means the read succeeded
/// and found no on-chain royalty (or the asset is EVM/Tezos, where none is
/// readable), which is a genuine `0%`.
String _onChainRoyaltyPercent(int? bps) =>
    stripTrailingZeros(((bps ?? 0) / 100).toStringAsFixed(2));

/// How the Details tab's Royalties row should render, given the indexed seller
/// fee and the on-chain permissions read that backs it up.
///
/// The row is a trust surface, so "not known yet" and "we failed to find out"
/// must never render as an affirmative `0%` — that understates the royalty on
/// every Core / pNFT artwork whose royalty lives in an on-chain plugin the
/// index doesn't carry. Four states:
///
///  1. indexed seller fee > 0 → show it immediately, no on-chain read needed;
///  2. indexed 0/absent, [permissions] still null (read in flight) → pending,
///     the row renders a placeholder;
///  3. read resolved → its value, including a confirmed `0%`;
///  4. read failed ([ArtworkPermissionsResolution.resolveFailed]) → no row.
({String? percent, bool pending}) _royaltyRowState(
  String? indexedPercent,
  ArtworkPermissions? permissions,
) {
  if (indexedPercent != null) return (percent: indexedPercent, pending: false);
  if (permissions == null) return (percent: null, pending: true);
  if (permissions.resolveFailed) return (percent: null, pending: false);
  return (
    percent: _onChainRoyaltyPercent(permissions.onChainRoyaltyBps),
    pending: false,
  );
}

/// Build the [ArtworkInfoViewData] payload from an [ArtworkDetails] plus
/// the address → username map that the parent state maintains.
ArtworkInfoViewData _buildArtworkInfoViewData(
  ArtworkDetails artwork,
  Map<String, String?> creatorUsernames, {
  ArtworkPermissions? permissions,
}) {
  final splits = [
    for (final s in artwork.royaltySplits)
      CreatorRef(
        address: s.address,
        // Prefer the API-embedded user fields so the row renders the
        // creator handle on first paint instead of waiting for the
        // username-resolution fetch to land.
        username: (s.username?.isNotEmpty ?? false)
            ? s.username
            : (s.displayName?.isNotEmpty ?? false)
            ? s.displayName
            : creatorUsernames[s.address],
        sharePercent: s.sharePercent,
      ),
  ];

  // Webapp parity (ArtworkDetails): keyed off maxSupply
  // alone — null → "Open edition", 1 → "1/1", anything else → just
  // the count. supplyType can't carry the LE count, so we stay on
  // the raw field for the display label.
  final maxSupply = artwork.maxSupply;
  final editionCountLabel = maxSupply == null
      ? 'Open edition'
      : (maxSupply == 0 || maxSupply == 1)
      ? '1/1'
      : '$maxSupply';

  // `supply` is the number of prints minted so far. Surface it as a
  // `Printed count` row only for Open (maxSupply null) and Limited
  // (maxSupply > 1) editions — a 1/1 has no meaningful print count.
  // A master edition with no prints yet reports null/0 supply; render the
  // row with `0` rather than dropping it.
  final isEditionSupply = maxSupply == null || maxSupply > 1;
  final printedCount = isEditionSupply ? (artwork.supply ?? 0) : null;

  // ETH/Tezos artworks identify a token by `<contract>-<tokenId>`. The
  // Details tab renders these as a Contract address + Token ID pair
  // instead of the Solana-style Mint address row. Contract address is
  // gated on `collectionMint` (= API `collection.slug`), mirroring the
  // webapp's `verifiedCollectionKey != null` check.
  String? contractAddress;
  String? tokenId;
  final isEvmOrTezos = isEvmOrTezosArtwork(
    mintAccount: artwork.mintAccount,
    chain: artwork.chain,
  );
  if (isEvmOrTezos) {
    final parts = artwork.mintAccount.split('-');
    if (parts.length == 2) tokenId = parts[1];
    contractAddress = artwork.collectionMint;
  }

  final royalty = _royaltyRowState(artwork.royaltyPercent, permissions);

  return ArtworkInfoViewData(
    description: artwork.description ?? '',
    mintAddress: artwork.mintAccount,
    contractAddress: contractAddress,
    tokenId: tokenId,
    editionCountLabel: editionCountLabel,
    printedCount: printedCount,
    updateAuthority: artwork.updateAuthority == null
        ? null
        : CreatorRef(
            address: artwork.updateAuthority!,
            username: creatorUsernames[artwork.updateAuthority!],
          ),
    royaltyPercent: royalty.percent,
    royaltyPending: royalty.pending,
    proceedsSplits: splits,
    mimeType: artwork.mimeType,
    dimensions: artwork.dimensions,
    fileSizeBytes: artwork.fileSizeBytes,
    isImmutable: artwork.isMutable == null ? null : !artwork.isMutable!,
    tokenStandard: artwork.tokenStandard,
    metadataUrl: artwork.metadataUrl,
    chain: artwork.chain,
    categories: mintCategoryDisplayNamesFromTags(artwork.tags),
    tags: mintFilterOutCategories(artwork.tags),
    traits: [
      for (final a in artwork.attributes)
        if (a.value.trim().isNotEmpty) (name: a.traitType, value: a.value),
    ],
  );
}
