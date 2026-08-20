part of '../collection_screen.dart';

/// Tabbed Description / Statistics / Details / Tags sections that mirror
/// the webapp's [ItemDetailsSection]. Empty sections are skipped from
/// both the tab bar and the body.
class _CollectionSections extends StatefulWidget {
  const _CollectionSections({
    required this.collection,
    required this.creatorHandle,
    required this.fallbackMint,
    this.chain,
  });

  final api.CollectionFullRender? collection;
  final String? creatorHandle;
  final String fallbackMint;

  /// Chain of the collection's loaded artworks — the statistics block needs it
  /// to denominate the floor. See [_StatsBlock.chain].
  final String? chain;

  @override
  State<_CollectionSections> createState() => _CollectionSectionsState();
}

class _CollectionSectionsState extends State<_CollectionSections> {
  int _activeIndex = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.collection;
    final hasDescription = (c?.description ?? '').isNotEmpty;
    final hasStats = c != null;
    final royalties = c?.nft?.royalties;
    final tokenStandard = c?.nft?.tokenStandard;
    final metadataUrl = c?.nft?.metadataUrl;
    final hasDetails =
        (c?.nft?.mintAccount ?? widget.fallbackMint).isNotEmpty ||
        (widget.creatorHandle ?? '').isNotEmpty ||
        royalties != null ||
        tokenStandard != null ||
        classifyMetadataHost(metadataUrl) != null;
    final allTags = c?.tags ?? const <String>[];
    final categoryNames = mintCategoryDisplayNamesFromTags(allTags);
    final freeTags = mintFilterOutCategories(allTags);

    final labels = <String>[];
    final panes = <Widget>[];
    if (hasDescription) {
      labels.add('Description');
      panes.add(ExpandableText(text: c!.description!));
    }
    if (hasStats) {
      labels.add('Statistics');
      panes.add(_StatsBlock(collection: c, chain: widget.chain));
    }
    if (hasDetails) {
      labels.add('Details');
      panes.add(
        _DetailsBlock(
          mint: c?.nft?.mintAccount ?? widget.fallbackMint,
          creatorHandle: widget.creatorHandle,
          royalties: royalties,
          tokenStandard: tokenStandard,
          metadataUrl: metadataUrl,
        ),
      );
    }
    if (categoryNames.isNotEmpty) {
      labels.add('Categories');
      panes.add(_ChipsBlock(values: categoryNames));
    }
    if (freeTags.isNotEmpty) {
      labels.add('Tags');
      panes.add(_ChipsBlock(values: freeTags.map((t) => '#$t').toList()));
    }
    // Traits tab is intentionally omitted: collection NFTs only carry
    // trait *names* on-chain (no values), and `CollectionFullRender`
    // doesn't surface them today. The empty-tab rule would hide it
    // anyway — keep the surface clean until the API exposes data.

    if (labels.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final safeIndex = _activeIndex.clamp(0, labels.length - 1);

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MallowUnderlineTabBar(
              tabs: labels,
              activeIndex: safeIndex,
              onTabSelected: (i) => setState(() => _activeIndex = i),
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            Padding(
              padding: const EdgeInsets.only(bottom: MallowTheme.spacingMd),
              child: AnimatedTabContent(
                activeIndex: safeIndex,
                builder: (_, i) => Align(
                  alignment: Alignment.centerLeft,
                  child: panes[i.clamp(0, panes.length - 1)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsBlock extends StatelessWidget {
  const _StatsBlock({required this.collection, required this.chain});

  final api.CollectionFullRender collection;

  /// Chain the collection's artworks live on. `CollectionFullRender` doesn't
  /// carry the wire's `chain`, so the screen passes the chain of the loaded
  /// artworks — an ETH collection's floor is denominated in ETH, and labelling
  /// it "SOL" (as this row used to, unconditionally) states a price in a
  /// currency the collection never trades in.
  final String? chain;

  @override
  Widget build(BuildContext context) {
    // Webapp `CollectionPageDetails`: the floor is already in
    // display units (`formatPrice({ isShortAmount: true })`), rendered in the
    // chain's base token, abbreviated past 1K, and "--" when absent.
    final floorToken = baseTokenForChain(chain) ?? defaultBidToken;
    final floor = collection.floor;
    final rows = <_DetailRow>[
      _DetailRow(
        label: 'Floor',
        value: floor != null && floor > 0
            ? '${PriceFormatter.formatDisplayAmount(floor, floorToken.mint)} '
                  '${floorToken.symbol}'
            : '--',
      ),
      _DetailRow(
        label: 'Volume',
        // Never-traded collections show "--", not "$0"
        // (`CollectionPageDetails`).
        value: collection.usdVolume > 0
            ? '\$${groupThousands(collection.usdVolume.round().toString())}'
            : '--',
      ),
      _DetailRow(label: 'Artworks', value: formatCount(collection.itemCount)),
      _DetailRow(
        label: 'Collectors',
        value: formatCount(collection.collectorCount),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: MallowTheme.spacingSm),
          rows[i],
        ],
      ],
    );
  }
}

class _DetailsBlock extends StatelessWidget {
  const _DetailsBlock({
    required this.mint,
    required this.creatorHandle,
    required this.royalties,
    required this.tokenStandard,
    required this.metadataUrl,
  });

  final String mint;
  final String? creatorHandle;
  final api.CollectionRoyalties? royalties;
  final api.TokenStandard? tokenStandard;
  final String? metadataUrl;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (mint.isNotEmpty) {
      rows.add(_DetailRow(label: 'Mint', value: truncateAddress(mint)));
    }
    if ((creatorHandle ?? '').isNotEmpty) {
      rows.add(_DetailRow(label: 'Creator', value: '@$creatorHandle'));
    }
    if (royalties != null) {
      rows.add(
        _DetailRow(
          label: 'Royalties',
          value: '${(royalties!.feeBPS / 100).toStringAsFixed(1)}%',
        ),
      );
    }
    if (tokenStandard != null) {
      rows.add(
        _DetailRow(
          label: 'Token standard',
          value: tokenStandardLabel(tokenStandard!),
        ),
      );
    }
    final hostLabel = classifyMetadataHost(metadataUrl);
    if (hostLabel != null) {
      rows.add(
        _DetailRow(
          label: 'Metadata host',
          value: hostLabel,
          onTap: () => launchUrl(
            Uri.parse(metadataUrl!.trim()),
            mode: LaunchMode.inAppBrowserView,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: MallowTheme.spacingSm),
          rows[i],
        ],
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
        ),
        Text(
          value,
          style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
        ),
      ],
    );
    if (onTap == null) return row;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: row,
      ),
    );
  }
}

/// Outlined-pill wrap matching the artwork-info Categories/Tags tab.
class _ChipsBlock extends StatelessWidget {
  const _ChipsBlock({required this.values});

  final List<String> values;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MallowTheme.spacingSm,
      runSpacing: MallowTheme.spacingSm,
      children: [for (final v in values) MallowPillChip(v)],
    );
  }
}
