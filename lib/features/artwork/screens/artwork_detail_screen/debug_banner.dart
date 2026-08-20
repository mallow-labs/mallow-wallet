part of '../artwork_detail_screen.dart';

/// Translucent on-screen banner showing the resolved [ArtworkActionState] and
/// the inputs that produced it. Debug-only — gated by `kDebugMode` at the
/// call site. Collapsed to a small "debug" button by default; tap to expand,
/// tap the banner to collapse again.
class _ActionStateDebugBanner extends StatefulWidget {
  const _ActionStateDebugBanner({
    required this.artwork,
    required this.currentAddress,
    required this.permissions,
    required this.creatorLinkedAddresses,
    required this.actionState,
  });

  final ArtworkDetails artwork;
  final String? currentAddress;
  final ArtworkPermissions? permissions;
  final Set<String> creatorLinkedAddresses;
  final ArtworkActionState actionState;

  @override
  State<_ActionStateDebugBanner> createState() =>
      _ActionStateDebugBannerState();
}

class _ActionStateDebugBannerState extends State<_ActionStateDebugBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (!_expanded) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          child: OutlinedButton(
            onPressed: () => setState(() => _expanded = true),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.amber,
              side: BorderSide(color: Colors.amber.withValues(alpha: 0.6)),
              backgroundColor: Colors.black.withValues(alpha: 0.78),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            child: const Text('debug'),
          ),
        ),
      );
    }

    final artwork = widget.artwork;
    final actionState = widget.actionState;
    final permissions = widget.permissions;
    final lines = <String>[
      'state: ${actionState.runtimeType}',
      'me:    ${_short(widget.currentAddress)}',
      'owner: ${_short(artwork.ownerAddress)}'
          '${artwork.ownerAddresses.length > 1 ? "  (+${artwork.ownerAddresses.length - 1} linked)" : ""}',
      'list:  ${artwork.listingType.name}   supply: ${artwork.supplyType.name}',
      if (artwork.buyNowMetadata != null)
        'price: ${artwork.buyNowMetadata!.amount}',
      if (artwork.auctionMetadata?.seller != null)
        'auct.seller: ${_short(artwork.auctionMetadata!.seller)}',
      'canList: ${permissions?.canList}',
      'matches owner? ${_isOwner()}'
          '   matches creator? ${_isCreator()}',
    ];
    return GestureDetector(
      onTap: () => setState(() => _expanded = false),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          // Debug-only banner — intentional dev-tool black/amber styling,
          // kept literal so it visually stands out regardless of app theme.
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.amber.withValues(alpha: 0.6)),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.amber,
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.3,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [for (final l in lines) Text(l)],
          ),
        ),
      ),
    );
  }

  bool _isOwner() {
    final me = widget.currentAddress;
    if (me == null) return false;
    return widget.artwork.ownerAddresses.contains(me) ||
        widget.artwork.ownerAddress == me ||
        widget.artwork.auctionMetadata?.seller == me;
  }

  bool _isCreator() {
    final me = widget.currentAddress;
    if (me == null) return false;
    return widget.artwork.artistAddresses.contains(me) ||
        widget.artwork.artistAddress == me ||
        widget.artwork.updateAuthority == me ||
        widget.artwork.royaltySplits.any((s) => s.address == me) ||
        widget.creatorLinkedAddresses.contains(me);
  }

  String _short(String? a) {
    if (a == null || a.isEmpty) return 'null';
    return truncateAddress(a, lead: 6, trail: 4);
  }
}
