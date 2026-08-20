/// Truncates a wallet/mint address to `{lead}…{trail}` form.
///
/// Returns the input unchanged if it's shorter than `lead + trail + 1`.
/// Default 5/5 matches the Figma artwork-detail spec (e.g. `8DkNB…RYfS4`).
String truncateAddress(String address, {int lead = 5, int trail = 5}) {
  if (address.length <= lead + trail) return address;
  return '${address.substring(0, lead)}…${address.substring(address.length - trail)}';
}

final _base58Regex = RegExp(r'^[1-9A-HJ-NP-Za-km-z]+$');

/// Heuristic check for whether [value] looks like a Solana base58 address.
/// Solana pubkeys are 32–44 base58 chars; anything outside that range
/// (e.g. a mallow username like `BEER`) returns false.
bool isLikelySolanaAddress(String value) {
  if (value.length < 32 || value.length > 44) return false;
  return _base58Regex.hasMatch(value);
}
