import 'package:json_annotation/json_annotation.dart';

enum SupplyType {
  @JsonValue('1/1')
  oneOfOne,

  @JsonValue('limited-edition')
  limitedEdition,

  @JsonValue('open-edition')
  openEdition,

  @JsonValue('edition-print')
  editionPrint,

  @JsonValue('collection')
  collection,
}

extension SupplyTypeX on SupplyType {
  bool get usesBuySingleTx => this == SupplyType.oneOfOne;

  bool get usesBuyEditionTxs =>
      this == SupplyType.limitedEdition ||
      this == SupplyType.openEdition ||
      this == SupplyType.editionPrint;

  String get label => switch (this) {
    SupplyType.oneOfOne => '1/1',
    SupplyType.limitedEdition => 'Limited Edition',
    SupplyType.openEdition => 'Open Edition',
    SupplyType.editionPrint => 'Edition Print',
    SupplyType.collection => 'Collection',
  };

  /// Full supply-type label shown at the top of the artwork screen, e.g.
  /// "Open Edition", "Limited Edition of 14", "Edition #4", "1 / 1 Artwork".
  /// Mirrors the webapp's `getSupplyTypeTitle`.
  String supplyTitle({int? maxSupply, int? editionNumber}) => switch (this) {
    SupplyType.oneOfOne => '1 / 1 Artwork',
    SupplyType.limitedEdition => 'Limited Edition of $maxSupply',
    SupplyType.openEdition => 'Open Edition',
    SupplyType.editionPrint => 'Edition #$editionNumber',
    SupplyType.collection => 'Collection',
  };
}
