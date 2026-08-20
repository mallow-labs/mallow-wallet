import 'package:flutter/foundation.dart';

/// A creator or update-authority reference, optionally resolved to a
/// mallow username.
@immutable
class CreatorRef {
  const CreatorRef({
    required this.address,
    this.username,
    this.sharePercent = 0,
  });

  final String address;

  /// `null` when the address has not been resolved to a mallow profile —
  /// the widget falls back to a truncated address in that case.
  final String? username;

  /// 0–100. Only meaningful for entries in [ArtworkInfoViewData.proceedsSplits].
  final int sharePercent;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CreatorRef &&
          other.address == address &&
          other.username == username &&
          other.sharePercent == sharePercent);

  @override
  int get hashCode => Object.hash(address, username, sharePercent);
}

/// Normalized data feeding [ArtworkInfoTabs]. Both the mint review step and
/// the post-mint artwork detail screen construct this from their own state.
///
/// Rows in the Details tab render only when their backing field is non-null
/// (or non-empty for list fields), so callers can safely pass `null` for
/// data that isn't available in their context.
@immutable
class ArtworkInfoViewData {
  const ArtworkInfoViewData({
    this.description = '',
    this.mintAddress,
    this.contractAddress,
    this.tokenId,
    this.editionNumber,
    this.maxSupply,
    this.editionCountLabel,
    this.printedCount,
    this.updateAuthority,
    this.royaltyPercent,
    this.royaltyPending = false,
    this.proceedsSplits = const [],
    this.mimeType,
    this.dimensions,
    this.fileSizeBytes,
    this.isImmutable,
    this.tokenStandard,
    this.metadataUrl,
    this.blockchain = 'Solana',
    this.chain,
    this.categories = const [],
    this.tags = const [],
    this.traits = const [],
  });

  final String description;
  final String? mintAddress;

  /// Ethereum/Tezos collection contract. When set, the Details tab swaps
  /// the Solana `Mint address` row for a `Contract address` row. Webapp
  /// parity gates this on a verified collection key being present.
  final String? contractAddress;

  /// Token id within [contractAddress]. Rendered as the `Token ID` row on
  /// ETH/Tezos artworks.
  final String? tokenId;
  final int? editionNumber;
  final int? maxSupply;

  /// When set, replaces the auto-formatted `"N / N"` edition-count value
  /// with this string (e.g. `"Open edition"`). Takes precedence over
  /// [editionNumber]/[maxSupply].
  final String? editionCountLabel;

  /// Actual number of prints minted so far. Rendered as a `Printed count`
  /// row directly under `Edition count`. Callers pass this only for Open /
  /// Limited editions (never 1/1), so the Details tab renders the row
  /// whenever it is non-null.
  final int? printedCount;

  final CreatorRef? updateAuthority;

  /// Whole-number percent as text (e.g. `"10"`). Rendered as `"10%"`.
  ///
  /// `null` hides the Royalties row entirely — used both for "caller has no
  /// royalty data" and for "the on-chain fallback read failed", because an
  /// affirmative `0%` on an unknown royalty is a trust-surface lie.
  final String? royaltyPercent;

  /// The royalty is still being resolved (the caller's on-chain fallback read
  /// is in flight). Renders the Royalties row with a placeholder instead of a
  /// number, so the row doesn't pop in — and, critically, so a not-yet-known
  /// royalty never renders as `0%`. Takes precedence over [royaltyPercent].
  final bool royaltyPending;

  final List<CreatorRef> proceedsSplits;

  /// e.g. `"image/png"`. Formatted to `"Image (PNG)"` in the row.
  final String? mimeType;

  final ({int width, int height})? dimensions;
  final int? fileSizeBytes;

  /// `null` means "unknown" and the row is hidden.
  final bool? isImmutable;

  /// Wire token-standard string from the API (e.g. `core`, `nft`, `pnft`).
  /// Mapped to a human label by the artwork-info widget.
  final String? tokenStandard;

  /// Off-chain JSON metadata URL. Drives the `Metadata host` Details row,
  /// which classifies the URL (arweave / IPFS / S3 / shdw-drive / custom)
  /// and links the value to an in-app browser. Hidden when null/empty.
  final String? metadataUrl;

  final String blockchain;

  /// Wire chain id (`solana`, `ethereum`, `tezos`). Used to swap address
  /// labels (`Contract address` / `Token ID` / `Deployer address`) and to
  /// route the long-press explorer link to the right chain. Null defaults
  /// to Solana behavior.
  final String? chain;
  final List<String> categories;
  final List<String> tags;

  /// Trait/attribute pairs from the on-chain metadata. Rendered in the
  /// Traits tab as key/value rows; the tab is hidden when empty.
  final List<({String name, String value})> traits;
}
