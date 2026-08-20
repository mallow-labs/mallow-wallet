import 'package:flutter/material.dart';

import '../../../di.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../profile/screens/curation_screen.dart';
import '../../search/data/search_repository.dart';

/// Screen that displays artworks from an exhibition.
///
/// Wraps [CurationScreen] with a [customFetchArtworks] callback that loads
/// artworks via the explore endpoint filtered by exhibition slug.
class ExhibitionScreen extends StatelessWidget {
  const ExhibitionScreen({
    required this.exhibitionSlug,
    required this.exhibitionTitle,
    this.exhibitionThumbnailUrl,
    super.key,
  });

  final String exhibitionSlug;
  final String exhibitionTitle;
  final String? exhibitionThumbnailUrl;

  @override
  Widget build(BuildContext context) {
    return CurationScreen(
      group: ArtGroup(
        id: exhibitionSlug,
        type: ArtGroupType.curation,
        name: exhibitionTitle,
        thumbnailUrl: exhibitionThumbnailUrl,
        artworkCount: 0,
      ),
      ownerAddress: '',
      isEphemeral: true,
      customFetchArtworks: () =>
          sl<SearchRepository>().fetchExhibitionArtworks(exhibitionSlug),
    );
  }
}
