/// Durable prefix for database-only Solana edition masters.
///
/// The cNFT wording is a legacy wire/storage format. Cohorts may contain any
/// supported Solana NFT standard, but changing the prefix would break existing
/// parent links and edition identities.
const syntheticSolanaMasterPrefix = 'cnft-master-';

/// Compatibility alias for older cNFT-specific call sites.
@Deprecated('Use syntheticSolanaMasterPrefix')
const syntheticCnftMasterPrefix = syntheticSolanaMasterPrefix;

bool isSyntheticSolanaMaster(String mintAccount) =>
    mintAccount.startsWith(syntheticSolanaMasterPrefix);

/// Compatibility alias for older cNFT-specific call sites.
@Deprecated('Use isSyntheticSolanaMaster')
bool isSyntheticCnftMaster(String mintAccount) =>
    isSyntheticSolanaMaster(mintAccount);

/// A synthetic master has neither an explorer address nor an asset standard.
String? assetMintForDisplay(String mintAccount) =>
    isSyntheticSolanaMaster(mintAccount) ? null : mintAccount;

String? assetTokenStandardForDisplay(
  String mintAccount,
  String? tokenStandard,
) => isSyntheticSolanaMaster(mintAccount) ? null : tokenStandard;
