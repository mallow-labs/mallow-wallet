/// Display label for an artwork. When [editionNumber] is non-null, suffixes
/// the name with `#N` (e.g. `My Artwork #5`) — matching the webapp's
/// `getNameWithEditionNumber`.
///
/// Use everywhere the artwork name is rendered to the user so printed
/// editions are distinguishable from their master.
String formatArtworkName({required String name, int? editionNumber}) {
  if (editionNumber == null) return name;
  return '$name #$editionNumber';
}
