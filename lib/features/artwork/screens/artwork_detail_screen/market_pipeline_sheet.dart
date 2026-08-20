part of '../artwork_detail_screen.dart';

/// Thin artwork-screen adapter over the shared [MarketPipelineSheetView] —
/// maps the screen's [ArtworkDetails] into the view's primitive header fields.
class _MarketPipelineSheetView extends StatelessWidget {
  const _MarketPipelineSheetView({required this.actionType, this.artwork});

  final String actionType;

  /// Artwork the action targets — renders as the sheet header (image +
  /// title) so the user keeps sight of what they're transacting on while
  /// the pipeline runs. Null falls back to the plain
  /// panel-only sheet.
  final ArtworkDetails? artwork;

  @override
  Widget build(BuildContext context) {
    final artwork = this.artwork;
    return MarketPipelineSheetView(
      actionType: actionType,
      title: artwork == null
          ? null
          : formatArtworkName(
              name: artwork.title,
              editionNumber: artwork.editionNumber,
            ),
      imageUrl: artwork != null && artwork.imageUrl.isNotEmpty
          ? artwork.imageUrl
          : null,
      username: artwork?.artistUsername,
      nsfw: artwork?.nsfw ?? false,
    );
  }
}
