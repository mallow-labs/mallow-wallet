import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../di.dart';
import '../../features/portfolio/data/portfolio_repository.dart';
import '../../features/portfolio/services/portfolio_bloc.dart';
import '../../features/search/widgets/search_input.dart';
import '../theme/mallow_theme.dart';
import '../utils/artwork_display.dart';
import 'loading_indicator.dart';
import 'mallow_artwork_media.dart';
import 'mallow_sheet.dart';
import 'mallow_svg_icon.dart';
import 'tap_target_expander.dart';

/// Listing-flow step: choose an owned artwork to list.
///
/// Bloc-agnostic — driven by props + callbacks. The host wires
/// [selectedMint] from its bloc state and dispatches the bloc-appropriate
/// "select + advance" pair from [onSelected].
///
/// [nonPrintableOnly] scopes what counts as listable: true for the auction
/// flow (1/1s and already-minted edition prints only), false for fixed-price
/// (also accepts master editions with remaining supply). The filter is
/// applied server-side via `POST /v1/artwork/byOwner/:owner`.
///
/// [artworksLoader] lets flows with different ownership semantics provide
/// their own source. The transfer chooser uses the cross-chain v2 portfolio
/// query, while listing flows keep the v1 listable-artwork query above.
class SelectArtworkStep extends StatefulWidget {
  const SelectArtworkStep({
    required this.selectedMint,
    required this.onSelected,
    required this.nonPrintableOnly,
    this.artworksLoader,
    this.emptyStateMessage,
    super.key,
  });

  final String? selectedMint;
  final ValueChanged<PortfolioArtwork> onSelected;
  final bool nonPrintableOnly;

  /// Optional source override for flows that do not use the listing endpoint.
  final Future<PortfolioArtworksResult> Function()? artworksLoader;

  /// Empty-state copy for the current flow. Listing flows default to
  /// "listable"; transfer supplies its own wording.
  final String? emptyStateMessage;

  @override
  State<SelectArtworkStep> createState() => _SelectArtworkStepState();
}

enum _DisplayStyle { list, grid }

class _SelectArtworkStepState extends State<SelectArtworkStep> {
  late final Future<PortfolioArtworksResult> _future;
  PortfolioSortOption _sort = PortfolioSortOption.recent;
  _DisplayStyle _displayStyle = _DisplayStyle.list;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future =
        (widget.artworksLoader ??
        () => sl<PortfolioRepository>().getOwnedArtworksForListing(
          nonPrintableOnly: widget.nonPrintableOnly,
        ))();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PortfolioArtworksResult>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: MallowLoadingIndicator());
        }
        if (snapshot.hasError || snapshot.data == null) {
          return Center(
            child: Text(
              'Could not load your artworks',
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
          );
        }

        final filtered = _applyFilterAndSort(snapshot.data!.artworks);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose artwork',
              style: MallowTheme.uiMeta.copyWith(
                color: context.mallowColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            SearchInput(
              autofocus: false,
              hintText: 'Search artworks',
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            _SortAndDisplayBar(
              sortLabel: _sortLabel,
              onSortTap: _showSortSheet,
              displayStyle: _displayStyle,
              onDisplayStyleToggle: () => setState(() {
                _displayStyle = _displayStyle == _DisplayStyle.list
                    ? _DisplayStyle.grid
                    : _DisplayStyle.list;
              }),
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            Expanded(
              child: filtered.isEmpty
                  ? _EmptyState(
                      hasQuery: _query.trim().isNotEmpty,
                      message: widget.emptyStateMessage,
                    )
                  : _displayStyle == _DisplayStyle.list
                  ? _ArtworkList(
                      artworks: filtered,
                      selectedMint: widget.selectedMint,
                      onSelected: widget.onSelected,
                    )
                  : _ArtworkGrid(
                      artworks: filtered,
                      selectedMint: widget.selectedMint,
                      onSelected: widget.onSelected,
                    ),
            ),
          ],
        );
      },
    );
  }

  String get _sortLabel => switch (_sort) {
    PortfolioSortOption.recent => 'Recent',
    PortfolioSortOption.name => 'Name',
    PortfolioSortOption.count => 'Count',
  };

  List<PortfolioArtwork> _applyFilterAndSort(List<PortfolioArtwork> input) {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? List<PortfolioArtwork>.from(input)
        : input.where((a) {
            return a.title.toLowerCase().contains(query) ||
                (a.collectionName?.toLowerCase().contains(query) ?? false);
          }).toList();
    if (_sort == PortfolioSortOption.name) {
      filtered.sort((a, b) => a.title.compareTo(b.title));
    }
    // `recent` is the API's default ordering; leave as-is.
    return filtered;
  }

  Future<void> _showSortSheet() async {
    final selected = await showMallowSheet<PortfolioSortOption>(
      context: context,
      builder: (sheetContext) {
        final colors = sheetContext.mallowColors;
        return Container(
          decoration: BoxDecoration(
            color: colors.bgSurface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(MallowTheme.popupRadius),
            ),
          ),
          padding: EdgeInsets.only(
            top: 12,
            bottom: MediaQuery.of(sheetContext).padding.bottom + 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in [
                PortfolioSortOption.recent,
                PortfolioSortOption.name,
              ])
                ListTile(
                  title: Text(
                    option == PortfolioSortOption.recent ? 'Recent' : 'Name',
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  trailing: _sort == option
                      ? MallowSvgIcon(
                          'assets/icons/checkmark.svg',
                          color: colors.accent,
                        )
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(option),
                ),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      setState(() => _sort = selected);
    }
  }
}

class _SortAndDisplayBar extends StatelessWidget {
  const _SortAndDisplayBar({
    required this.sortLabel,
    required this.onSortTap,
    required this.displayStyle,
    required this.onDisplayStyleToggle,
  });

  final String sortLabel;
  final VoidCallback onSortTap;
  final _DisplayStyle displayStyle;
  final VoidCallback onDisplayStyleToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: [
        TapTargetExpander(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onSortTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SvgPicture.asset(
                  'assets/icons/arrows-sort.svg',
                  width: 16,
                  height: 16,
                  colorFilter: ColorFilter.mode(
                    colors.textPrimary,
                    BlendMode.srcIn,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  sortLabel,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        TapTargetExpander(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDisplayStyleToggle,
            child: SvgPicture.asset(
              displayStyle == _DisplayStyle.list
                  ? 'assets/icons/list.svg'
                  : 'assets/icons/grid.svg',
              width: 24,
              height: 24,
              colorFilter: ColorFilter.mode(
                colors.textPrimary,
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ArtworkList extends StatelessWidget {
  const _ArtworkList({
    required this.artworks,
    required this.selectedMint,
    required this.onSelected,
  });

  final List<PortfolioArtwork> artworks;
  final String? selectedMint;
  final ValueChanged<PortfolioArtwork> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: artworks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final artwork = artworks[index];
        return _ArtworkListTile(
          artwork: artwork,
          isSelected: selectedMint == artwork.mintAccount,
          onTap: () => onSelected(artwork),
        );
      },
    );
  }
}

class _ArtworkListTile extends StatelessWidget {
  const _ArtworkListTile({
    required this.artwork,
    required this.isSelected,
    required this.onTap,
  });

  final PortfolioArtwork artwork;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final hasCollection =
        artwork.collectionName != null && artwork.collectionName!.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(
            width: 52,
            height: 52,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.surfaceMuted),
                  if (artwork.imageUrl.isNotEmpty)
                    MallowArtworkMedia(
                      imageUrl: artwork.imageUrl,
                      nsfw: artwork.nsfw,
                      logicalSize: 52,
                      width: 52,
                      height: 52,
                    ),
                  if (isSelected)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: colors.accent, width: 2),
                        borderRadius: BorderRadius.circular(
                          MallowTheme.radiusPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatArtworkName(
                    name: artwork.title,
                    editionNumber: artwork.editionNumber,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.editorialQuote.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasCollection ? artwork.collectionName! : 'No Collection',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiCaption.copyWith(
                    color: hasCollection
                        ? colors.textSecondary
                        : colors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtworkGrid extends StatelessWidget {
  const _ArtworkGrid({
    required this.artworks,
    required this.selectedMint,
    required this.onSelected,
  });

  final List<PortfolioArtwork> artworks;
  final String? selectedMint;
  final ValueChanged<PortfolioArtwork> onSelected;

  @override
  Widget build(BuildContext context) {
    // Host wraps SelectArtworkStep in horizontal padding of 20.
    final tileLogicalSize = (MediaQuery.sizeOf(context).width - 40 - 12) / 2;

    return GridView.builder(
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 170.5 / 224,
      ),
      itemCount: artworks.length,
      itemBuilder: (context, index) {
        final artwork = artworks[index];
        return _ArtworkTile(
          artwork: artwork,
          isSelected: selectedMint == artwork.mintAccount,
          logicalSize: tileLogicalSize,
          onTap: () => onSelected(artwork),
        );
      },
    );
  }
}

class _ArtworkTile extends StatelessWidget {
  const _ArtworkTile({
    required this.artwork,
    required this.isSelected,
    required this.logicalSize,
    required this.onTap,
  });

  final PortfolioArtwork artwork;
  final bool isSelected;
  final double logicalSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.surfaceMuted),
                  if (artwork.imageUrl.isNotEmpty)
                    MallowArtworkMedia(
                      imageUrl: artwork.imageUrl,
                      nsfw: artwork.nsfw,
                      logicalSize: logicalSize,
                    ),
                  if (isSelected)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: colors.accent, width: 2),
                        borderRadius: BorderRadius.circular(
                          MallowTheme.radiusPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            formatArtworkName(
              name: artwork.title,
              editionNumber: artwork.editionNumber,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            artwork.supplyLabel,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasQuery, this.message});

  final bool hasQuery;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        child: Text(
          hasQuery
              ? 'No artworks match your search'
              : message ?? "You don't own any listable artworks yet",
          textAlign: TextAlign.center,
          style: MallowTheme.uiBody.copyWith(color: colors.textSecondary),
        ),
      ),
    );
  }
}
