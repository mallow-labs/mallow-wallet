/// Classifies an off-chain metadata URL into a short host-type label
/// ("Arweave", "Irys", "IPFS", "S3", "Shdw-drive", or the bare domain) for
/// the artwork / collection Details rows.
///
/// IPFS-only gateway providers (Pinata, NFT.Storage, web3.storage, dweb.link,
/// 4everland, Fleek, Cloudflare) collapse into the generic "IPFS" bucket
/// — from the user's perspective the data lives on IPFS, the gateway is
/// just how it's fetched.
library;

/// Display labels for the well-known host buckets. Kept as constants so call
/// sites can compare without re-stringifying. Unrecognized hosts fall back
/// to the URL's bare domain instead of a generic "Custom" label.
const String metadataHostArweave = 'Arweave';
const String metadataHostIrys = 'Irys';
const String metadataHostIpfs = 'IPFS';
const String metadataHostS3 = 'S3';
const String metadataHostShdwDrive = 'Shdw-drive';

/// Returns the host-type label for [url], or `null` when the URL is empty
/// or unparseable. Treats common IPFS gateways as plain "IPFS". Falls back
/// to the bare domain (e.g. `example.com`) when nothing matches.
String? classifyMetadataHost(String? url) {
  if (url == null) return null;
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;

  final lower = trimmed.toLowerCase();
  if (lower.startsWith('ipfs://') || lower.startsWith('ipns://')) {
    return metadataHostIpfs;
  }
  if (lower.startsWith('ar://')) return metadataHostArweave;

  final Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } catch (_) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;

  if (host == 'arweave.net' || host.endsWith('.arweave.net')) {
    return metadataHostArweave;
  }
  // Irys (ex-Bundlr) settles onto Arweave, but its gateways
  // (gateway/uploader/devnet.irys.xyz) get their own label so the row names
  // the service the data was actually uploaded through.
  if (host == 'irys.xyz' || host.endsWith('.irys.xyz')) {
    return metadataHostIrys;
  }
  if (host == 'shdw-drive.genesysgo.net' || host.contains('shdw-drive')) {
    return metadataHostShdwDrive;
  }
  if (_isIpfsGatewayHost(host) || uri.pathSegments.contains('ipfs')) {
    return metadataHostIpfs;
  }
  if (host.endsWith('amazonaws.com') || host.endsWith('.s3.dualstack')) {
    return metadataHostS3;
  }
  return _stripWww(host);
}

String _stripWww(String host) =>
    host.startsWith('www.') ? host.substring(4) : host;

bool _isIpfsGatewayHost(String host) {
  const ipfsHosts = <String>{
    'ipfs.io',
    'gateway.pinata.cloud',
    'nftstorage.link',
    'nftstorage.io',
    'dweb.link',
    'w3s.link',
    'cf-ipfs.com',
    'cloudflare-ipfs.com',
    '4everland.io',
    'ipfs.fleek.co',
    'ipfs.infura.io',
  };
  if (ipfsHosts.contains(host)) return true;
  return host.endsWith('.mypinata.cloud') ||
      host.endsWith('.ipfs.nftstorage.link') ||
      host.endsWith('.ipfs.dweb.link') ||
      host.endsWith('.ipfs.w3s.link') ||
      host.endsWith('.ipfs.cf-ipfs.com') ||
      host.endsWith('.ipfs.4everland.io') ||
      host.endsWith('.ipfs.fleek.co');
}
