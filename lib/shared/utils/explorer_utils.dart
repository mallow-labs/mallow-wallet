import '../../core/config/environment.dart';
import '../../core/services/preferences_service.dart';
import '../../di.dart';
import 'chain.dart';

/// URL patterns for supported block explorers.
const _explorerUrls = <String, String>{
  'solscan': 'https://solscan.io/tx/',
  'solana_beach': 'https://solanabeach.io/transaction/',
  'solana_explorer': 'https://explorer.solana.com/tx/',
  'orb': 'https://orbmarkets.io/tx/',
};

/// URL patterns for viewing a token / mint address. Solscan canonicalizes
/// SPL token mints under `/token/`; the others use a generic `/address/`
/// path that resolves any account.
const _tokenExplorerUrls = <String, String>{
  'solscan': 'https://solscan.io/token/',
  'solana_beach': 'https://solanabeach.io/address/',
  'solana_explorer': 'https://explorer.solana.com/address/',
  'orb': 'https://orbmarkets.io/address/',
};

/// URL patterns for viewing a wallet/account address. Solscan uses
/// `/account/` for wallets (vs `/token/` for SPL mints); the others
/// share a generic `/address/` path that resolves any account.
const _accountExplorerUrls = <String, String>{
  'solscan': 'https://solscan.io/account/',
  'solana_beach': 'https://solanabeach.io/address/',
  'solana_explorer': 'https://explorer.solana.com/address/',
  'orb': 'https://orbmarkets.io/address/',
};

/// Display names for supported block explorers.
const _explorerNames = <String, String>{
  'solscan': 'Solscan',
  'solana_beach': 'Solana Beach',
  'solana_explorer': 'Solana Explorer',
  'orb': 'Orb',
};

/// Build a transaction URL for the given [signature] and [explorerKey].
///
/// Appends `?cluster=devnet` in development/staging environments.
String buildExplorerUrl(String signature, String explorerKey) {
  final base = _explorerUrls[explorerKey] ?? _explorerUrls['solscan']!;
  final url = '$base$signature';
  if (!Config.isProduction) return '$url?cluster=devnet';
  return url;
}

/// Build a transaction URL using the user's preferred explorer.
String buildExplorerUrlFromPrefs(String signature) {
  final key = sl<PreferencesService>().explorer;
  return buildExplorerUrl(signature, key);
}

/// Build a token / mint URL for the given [mintAddress] and [explorerKey].
///
/// Appends `?cluster=devnet` in development/staging environments.
String buildTokenExplorerUrl(String mintAddress, String explorerKey) {
  final base =
      _tokenExplorerUrls[explorerKey] ?? _tokenExplorerUrls['solscan']!;
  final url = '$base$mintAddress';
  if (!Config.isProduction) return '$url?cluster=devnet';
  return url;
}

/// Build a token / mint URL using the user's preferred explorer.
String buildTokenExplorerUrlFromPrefs(String mintAddress) {
  final key = sl<PreferencesService>().explorer;
  return buildTokenExplorerUrl(mintAddress, key);
}

/// Build a wallet/account URL for the given [address] and [explorerKey].
///
/// Appends `?cluster=devnet` in development/staging environments.
String buildAccountExplorerUrl(String address, String explorerKey) {
  final base =
      _accountExplorerUrls[explorerKey] ?? _accountExplorerUrls['solscan']!;
  final url = '$base$address';
  if (!Config.isProduction) return '$url?cluster=devnet';
  return url;
}

/// Build a wallet/account URL using the user's preferred explorer.
String buildAccountExplorerUrlFromPrefs(String address) {
  final key = sl<PreferencesService>().explorer;
  return buildAccountExplorerUrl(address, key);
}

/// Build a transaction URL for [signature] on the given [chain]. Routes to
/// the user's preferred Ethereum explorer (mainnet) for Ethereum tx hashes and
/// tzkt for Tezos operations; falls back to the user's preferred Solana explorer
/// otherwise (null chain included). Used by per-token activity rows whose chain
/// is known.
///
/// [ethExplorerKey] overrides the stored Ethereum-explorer preference; when
/// null the preference is read from [PreferencesService]. Tests pass it
/// explicitly to stay free of service-locator wiring.
String buildTxExplorerUrlForChain(
  String signature,
  Chain? chain, {
  String? ethExplorerKey,
}) {
  if (chain == Chain.ethereum) {
    return '${_ethExplorer(ethExplorerKey).activeHost}/tx/$signature';
  }
  if (chain == Chain.tezos) return 'https://tzkt.io/$signature';
  return buildExplorerUrlFromPrefs(signature);
}

/// Best-effort chain inference from a transaction [signature]'s encoding, for
/// surfaces whose items carry no explicit chain (the global activity feed).
/// Returns null when undetermined, so callers keep the user's preferred Solana
/// explorer.
///
/// The three encodings are disjoint:
///   * Ethereum — `0x`-prefixed hex, 66 chars.
///   * Tezos — Base58Check with the `o` operation prefix, always 51 chars.
///   * Solana — base58 of a 64-byte signature, 86–88 chars, never `0x`.
///
/// Length is what separates Tezos from Solana: a bare `o` prefix is a legal
/// leading character for a base58 Solana signature too, so matching on the
/// prefix alone would send Solana signatures to tzkt. Without the Tezos arm a
/// Tezos operation hash resolved to null and opened the user's *Solana*
/// explorer with a Tezos hash.
Chain? inferChainFromTxSignature(String signature) {
  if (signature.startsWith('0x')) return Chain.ethereum;
  if (signature.length == 51 && signature.startsWith('o')) return Chain.tezos;
  return null;
}

/// Display name of the explorer a tx link opens for [chain]. The user's
/// preferred Ethereum explorer / tzkt for ETH/Tezos; otherwise the user's
/// preferred Solana explorer.
String txExplorerName(Chain? chain) {
  if (chain == Chain.ethereum) return _ethExplorer(null).name;
  if (chain == Chain.tezos) return 'tzkt';
  return preferredExplorerName();
}

/// Build a token / mint URL for [address] on the given [chain]. Routes to the
/// user's preferred Ethereum explorer for Ethereum and tzkt for Tezos; falls
/// back to the user's preferred Solana explorer otherwise. Mirrors the webapp's
/// `getExplorerTokenUrl`. For ETH/Tezos the [address] may be the full
/// `<contract>-<tokenId>` form — split lookup handled here.
///
/// [ethExplorerKey] overrides the stored Ethereum-explorer preference; null
/// reads the preference. See [buildTxExplorerUrlForChain].
String buildTokenExplorerUrlForChain(
  String address,
  Chain? chain, {
  String? ethExplorerKey,
}) {
  if (chain == Chain.tezos) {
    final parts = address.split('-');
    if (parts.length == 2) {
      return 'https://tzkt.io/${parts[0]}/tokens/${parts[1]}';
    }
    return 'https://tzkt.io/$address';
  }
  if (chain == Chain.ethereum) {
    final ex = _ethExplorer(ethExplorerKey);
    final parts = address.split('-');
    if (parts.length == 2) {
      // NFT (`<contract>-<tokenId>`): mallow artworks are mainnet, so the NFT
      // page is built against the explorer's mainnet host regardless of env.
      return '${ex.mainnetHost}${ex.nftPath(parts[0], parts[1])}';
    }
    // Bare contract = a fungible token; its page uses `/token/` for the
    // holders/transfers view on the explorer's mainnet host.
    return '${ex.activeHost}/token/$address';
  }
  return buildTokenExplorerUrlFromPrefs(address);
}

/// Build a wallet/account URL for [address] on the given [chain]. Routes
/// to the user's preferred Ethereum explorer / tzkt for ETH/Tezos; otherwise
/// uses the user's preferred Solana explorer. Mirrors the webapp's
/// `getExplorerAddressUrl`.
///
/// [ethExplorerKey] overrides the stored Ethereum-explorer preference; null
/// reads the preference. See [buildTxExplorerUrlForChain].
String buildAccountExplorerUrlForChain(
  String address,
  Chain? chain, {
  String? ethExplorerKey,
}) {
  if (chain == Chain.tezos) return 'https://tzkt.io/$address';
  if (chain == Chain.ethereum) {
    return '${_ethExplorer(ethExplorerKey).activeHost}/address/$address';
  }
  return buildAccountExplorerUrlFromPrefs(address);
}

/// Get the display name for the given Solana explorer key.
String explorerDisplayName(String key) {
  return _explorerNames[key] ?? 'Solscan';
}

/// Get the display name for the user's preferred Solana explorer.
String preferredExplorerName() {
  final key = sl<PreferencesService>().explorer;
  return explorerDisplayName(key);
}

// ── Ethereum explorers ──────────────────────────────────────────────────────

/// A supported Ethereum block explorer. Ethereum is mainnet-only, so each
/// carries just the mainnet host, plus its own NFT-page path form (Etherscan and
/// Blockscout disagree on it).
class EthExplorer {
  const EthExplorer({
    required this.key,
    required this.name,
    required this.mainnetHost,
    required this.nftPath,
  });

  final String key;
  final String name;
  final String mainnetHost;

  /// Builds the NFT page path (with leading slash) from a contract + tokenId.
  final String Function(String contract, String tokenId) nftPath;

  /// Host for Ethereum links. Mainnet-only.
  String get activeHost => mainnetHost;
}

String _etherscanNftPath(String contract, String tokenId) =>
    '/nft/$contract/$tokenId';
String _blockscoutNftPath(String contract, String tokenId) =>
    '/token/$contract/instance/$tokenId';

/// Supported Ethereum explorers, keyed by the value stored in preferences.
/// The first entry is the default/fallback.
const ethExplorers = <EthExplorer>[
  EthExplorer(
    key: 'etherscan',
    name: 'Etherscan',
    mainnetHost: 'https://etherscan.io',
    nftPath: _etherscanNftPath,
  ),
  EthExplorer(
    key: 'blockscout',
    name: 'Blockscout',
    mainnetHost: 'https://eth.blockscout.com',
    nftPath: _blockscoutNftPath,
  ),
];

/// Resolve the [EthExplorer] for [key], falling back to the user's stored
/// preference when [key] is null and to Etherscan when neither matches.
EthExplorer _ethExplorer(String? key) {
  final resolved = key ?? sl<PreferencesService>().ethExplorer;
  return ethExplorers.firstWhere(
    (e) => e.key == resolved,
    orElse: () => ethExplorers.first,
  );
}

/// Display name for the given Ethereum explorer key.
String ethExplorerDisplayName(String key) => _ethExplorer(key).name;
