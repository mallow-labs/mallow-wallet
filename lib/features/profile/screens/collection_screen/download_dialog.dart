part of '../collection_screen.dart';

/// Webapp-parity CSV builder. Matches the conditional shape in
/// `CollectionOptionsButton–255`: include the Edition Number
/// column only when at least one row carries one.
String _holdersToCsv(List<api.HolderEntry> holders) {
  final hasEditions = holders.any((h) => h.editionNumber > 0);
  if (hasEditions) {
    final sorted = [...holders]
      ..sort((a, b) => a.editionNumber.compareTo(b.editionNumber));
    return 'Edition Number,Asset ID,Owner\n'
        '${sorted.map((h) => '${h.editionNumber},${h.assetId},${h.owner}').join('\n')}';
  }
  return 'Asset ID,Owner\n'
      '${holders.map((h) => '${h.assetId},${h.owner}').join('\n')}';
}
