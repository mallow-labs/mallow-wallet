/// Model for a curation entry on an artwork.
class ArtworkCuration {
  const ArtworkCuration({
    required this.id,
    required this.name,
    required this.slug,
    this.imageUrl,
    this.creatorAddress,
  });

  final String id;
  final String name;
  final String slug;
  final String? imageUrl;
  final String? creatorAddress;
}
