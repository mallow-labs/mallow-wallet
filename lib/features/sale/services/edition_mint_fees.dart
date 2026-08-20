// SOL an edition print costs the buyer *on top of* the listing price.
//
// Faithful port of webapp `getEditionMintSolFeeLamports`
// (`swapFunding`), whose per-standard
// quotes come from `getTokenStandardMintFees`
// (`assets`):
//
//   Core            rent 0.0025 + protocol 0.0015
//   CoreCollection  rent 0.0015 + protocol 0.0015
//   Nft (legacy)    rent 0.01   + protocol 0.01   + 0.002 buyer ATA
//
// plus the flat marketplace print fee (`feeConfig.printFee`) per print. That
// is the 0.015–0.033 SOL the webapp requires beyond the price, and the reason
// an SPL-priced edition needs SOL at all.

import '../../mint/data/mint_repository.dart'
    show kCoreProtocolFeeLamports, kCoreRentLamports;

/// Rent for a legacy token-metadata print — `getTokenStandardMintFees`
/// `TokenStandard.Nft` (0.01 SOL).
const kLegacyNftRentLamports = 10000000;

/// Metaplex protocol fee for a legacy token-metadata print (0.01 SOL).
const kLegacyNftProtocolFeeLamports = 10000000;

/// Rent for the buyer's associated token account. Legacy prints only — Core
/// assets aren't SPL tokens and need no ATA (`swapFunding` adds this term
/// for `TokenStandard.Nft` alone).
const kLegacyNftAtaRentLamports = 2000000;

/// SOL (lamports) one printed edition costs beyond the listing price and the
/// marketplace print fee: the new asset's rent plus the Metaplex protocol fee,
/// plus the buyer's ATA rent on the legacy standard.
///
/// [tokenStandard] is the wire string (`core`, `core-collection`, `nft`,
/// `pnft`, …) for the *master* being printed. Both Core flavours quote the
/// `Core` fee, exactly as the webapp does: the on-chain `Listing.tokenStandard`
/// is a two-variant enum (`core` | `nonFungible`) and `toTokenStandard` maps it
/// to `TokenStandard.Core`, even though a Core master edition is itself a
/// CoreCollection. Everything else — including an unknown/absent standard —
/// quotes the legacy `Nft` fee, matching `toTokenStandard`'s own fallback and
/// erring high rather than under-gating the buyer's balance.
int editionPrintSolFeeLamports({String? tokenStandard}) {
  final normalized = tokenStandard?.toLowerCase().replaceAll(
    RegExp(r'[-_\s]'),
    '',
  );
  if (normalized == 'core' || normalized == 'corecollection') {
    return kCoreRentLamports + kCoreProtocolFeeLamports;
  }
  return kLegacyNftRentLamports +
      kLegacyNftProtocolFeeLamports +
      kLegacyNftAtaRentLamports;
}
