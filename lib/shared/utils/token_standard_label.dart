import 'package:mallow_api/mallow_api.dart'
    show TokenStandard, TokenStandardDas;

/// Display label for a token standard, mirroring `TokenStandardLabel` in
/// the server's shared Solana token-standard type
/// so the wallet matches the webapp.
String tokenStandardLabel(TokenStandard ts) => switch (ts) {
  TokenStandard.nft => 'Metaplex Legacy',
  TokenStandard.core || TokenStandard.coreCollection => 'Metaplex Core',
  TokenStandard.pnft => 'Metaplex Programmable',
  TokenStandard.cnft => 'Metaplex Compressed',
  TokenStandard.objkt => 'FA2',
  TokenStandard.native => 'Ethereum',
  TokenStandard.erc20 => 'ERC-20',
  TokenStandard.erc721 => 'ERC-721',
  TokenStandard.erc1155 => 'ERC-1155',
};

/// Variant for callers that hold the raw API wire string rather than the
/// typed enum (e.g. `ArtworkDetails.tokenStandard`). Falls back to the raw
/// value for unknown standards so the row never renders empty.
String tokenStandardLabelFromWire(String wire) {
  for (final ts in TokenStandard.values) {
    if (ts.wireValue == wire) return tokenStandardLabel(ts);
  }
  return wire;
}
