import 'package:flutter/material.dart';

import '../../core/data/mallow_tokens.dart'
    show solMint, ethMint, xtzMint, oXtzMint;
import '../theme/mallow_theme.dart';
import '../widgets/mallow_network_image.dart';
import '../widgets/mallow_svg_icon.dart';
import 'address_utils.dart';

/// Mapping of token mint addresses to local asset paths.
///
/// Mint addresses sourced from tokens.
const _mintToAsset = <String, String>{
  // SOL (native + wrapped — same canonical mint).
  'So11111111111111111111111111111111111111112':
      'assets/images/tokens/sol.webp',
  // BONK
  'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263':
      'assets/images/tokens/bonk.webp',
  // BOOP
  'Gx2yQqgguqpKwGCrrgx4dr8toTYevczEtGd6B1pKpump':
      'assets/images/tokens/boop.webp',
  // BUU
  '28tVhteKZkzzWjrdHGXzxfm4SQkhrDrjLur9TYCDVULE':
      'assets/images/tokens/buu.webp',
  // FOXY
  'FoXyMu5xwXre7zEoSvzViRk3nGawHUp9kUh97y2NDhcq':
      'assets/images/tokens/foxy.webp',
  // FWOG
  'A8C3xuqscfmyLrte3VmTqrAq8kgMASius9AFNANwpump':
      'assets/images/tokens/fwog.webp',
  // GCATS
  'UbESBaztbkxJRWxPcfDeK8Fft15igTbrv3sed1bsegM':
      'assets/images/tokens/gcats.webp',
  // GECKO
  '6CNHDCzD5RkvBWxxyokQQNQPjFWgoHF94D7BmC73X6ZK':
      'assets/images/tokens/gecko.webp',
  // GLOOM
  'Dx7MFxtRKGcVmLCT2ZVTKeCj9UcwyurSnhWH1B85moKK':
      'assets/images/tokens/gloom.webp',
  // GUAC
  'AZsHEMXd36Bj1EMNXhowJajpUXzrKcK57wW4ZGXVa7yR':
      'assets/images/tokens/guac.webp',
  // JUP
  'JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN':
      'assets/images/tokens/jup.webp',
  // LSP
  'BAy5FmGzFwcVcZq1yXaDvF1mEAChF3MPtBLrUMBsnLN9':
      'assets/images/tokens/lsp.webp',
  // mallowSOL
  'MLLWWq9TLHK3oQznWqwPyqD7kH4LXTHSKXK4yLz7LjD':
      'assets/images/tokens/mallow-sol.webp',
  // MOUTAI
  '45EgCwcPXYagBC7KqBin4nCFgEZWN7f3Y6nACwxqMCWX':
      'assets/images/tokens/moutai.webp',
  // PXLPSHR
  'EaJKiTVet7m9poGcvdSTcSw14emxpCrdTuuWaW9bpump':
      'assets/images/tokens/pxlpshr.webp',
  // SILLY
  '7EYnhQoR9YM3N7UoaKRoA44Uy8JeaZV3qyouov87awMs':
      'assets/images/tokens/silly.webp',
  // SMORES
  'smoEhMZMweWBnpd1QoU4ZjuVNBxMFchqy4NRMBbtW7V':
      'assets/images/tokens/smores.webp',
  // STASH
  'EWMfSJgDCE7CXDAYz3hbCaA7NsFHTnddySXx3shco2Hs':
      'assets/images/tokens/stash.webp',
  // USD*
  'star9agSpjiFe3M49B3RniVU4CMBBEK3Qnaqn3RGiFM':
      'assets/images/tokens/usd-star.webp',
  // USDC
  'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v':
      'assets/images/tokens/usdc.webp',
  // USDC (DEV) — devnet token surfaced as a renamed USDC variant
  '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU':
      'assets/images/tokens/usdc.webp',
  // VALUE
  'DcRHumYETnVKowMmDSXQ5RcGrFZFAnaqrQ1AZCHXpump':
      'assets/images/tokens/value.webp',
  // WEN
  'WENWENvqqNya429ubCdR81ZmD69brwQaaBYY6p3LCpk':
      'assets/images/tokens/wen.webp',
  // XNU
  'EKuYvkDkNxkvGgpnmDJtFyp7bpaeKffMPp5DoTSJpHjs':
      'assets/images/tokens/xnu.webp',
};

/// Returns the local asset path for a known token mint, or null.
String? localTokenImagePath(String mint) => _mintToAsset[mint];

/// Local square-tile logos for the native chain coins that share the `native`
/// sentinel mint (so they can't be keyed by mint like SOL). Keyed by symbol.
const _nativeSymbolToAsset = <String, String>{
  'ETH': 'assets/images/tokens/eth.webp',
  'XTZ': 'assets/images/tokens/xtz.webp',
};

/// The local square-tile logo for a native chain coin (ETH / XTZ) by [symbol],
/// or null. SOL resolves via its real mint in [localTokenImagePath]; ETH and
/// XTZ arrive with the shared `native` sentinel mint, so they resolve here.
String? nativeCoinImagePath(String? symbol) =>
    symbol == null ? null : _nativeSymbolToAsset[symbol.toUpperCase()];

/// Brand SVG mark for a chain currency (SOL / ETH / wETH / XTZ / oXTZ), or
/// null for any other token. Keyed by mint (SOL, ETH, and the `xtz` sentinel /
/// oXTZ FA contract that objkt reports as a Tezos listing's `currencyMint`)
/// and by symbol, so wrapped variants (wETH, oXTZ) share their chain's mark.
///
/// When [paddedSolana] is true (default) Solana uses the `_padded` variant so
/// its mark carries the same internal padding as the square ETH/XTZ marks —
/// matches the chain-icon convention in `receive/sheets/chain_visuals.dart` and
/// `account_picker_card.dart`. Pass false for the full-bleed `solana.svg` used
/// in front of numbers (matches the staking amount input).
String? chainSymbolSvgAsset({
  String? mint,
  String? symbol,
  bool paddedSolana = true,
}) {
  final sym = symbol?.toUpperCase();
  if (mint == solMint || sym == 'SOL') {
    return paddedSolana
        ? 'assets/icons/solana_padded.svg'
        : 'assets/icons/solana.svg';
  }
  if (mint == ethMint || sym == 'ETH' || sym == 'WETH') {
    return 'assets/icons/ethereum.svg';
  }
  if (mint == xtzMint || mint == oXtzMint || sym == 'XTZ' || sym == 'OXTZ') {
    return 'assets/icons/tezos.svg';
  }
  return null;
}

/// Builds a widget displaying a token's logo image with fallback chain:
/// 1. Local asset (by mint address, then by symbol)
/// 2. Network image via [logoUrl] (through CDN proxy)
/// 3. Symbol text in a muted circle
///
/// When [useChainSvg] is true (default), native chain currencies (SOL / ETH /
/// XTZ) short-circuit to their brand SVG mark. Pass false to render the token's
/// fetched logo image (local asset / [logoUrl]) like any other token — used by
/// the activity rows, which show asset images rather than chain marks.
///
/// Set [enlargeChainGlyph] when the mark sits in front of a number (price rows,
/// amount inputs): Solana uses the full-bleed `solana.svg` instead of the
/// padded variant so it reads at the same scale as the ETH/XTZ marks and the
/// staking amount input. The full-bleed glyph is rendered 4px smaller than
/// [size] so it doesn't overpower the digits beside it. Has no effect on
/// non-chain token logos.
Widget tokenImageWidget({
  required String mint,
  required double size,
  String? symbol,
  String? logoUrl,
  bool useChainSvg = true,
  bool enlargeChainGlyph = false,
}) {
  // 0. Native chain currency (SOL / ETH / XTZ) — chain SVG mark, themed to
  // textPrimary so it stays legible in both light and dark mode.
  if (useChainSvg) {
    final chainSvg = chainSymbolSvgAsset(
      mint: mint,
      symbol: symbol,
      paddedSolana: !enlargeChainGlyph,
    );
    if (chainSvg != null) {
      final glyphSize = enlargeChainGlyph ? size - 4 : size;
      return MallowSvgIcon(chainSvg, width: glyphSize, height: glyphSize);
    }
  }

  // 1. Local asset — by mint (SOL and known SPL/ERC-20s), then the native
  // ETH/XTZ square tiles keyed by symbol (they share the `native` mint). The
  // `useChainSvg: true` callers already returned their chain mark at step 0, so
  // this only swaps in the filled tiles for the asset-image (chain-svg-off)
  // surfaces — token detail header, activity rows.
  final localPath = localTokenImagePath(mint) ?? nativeCoinImagePath(symbol);
  if (localPath != null) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      child: Image.asset(
        localPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            _symbolFallback(size: size, symbol: symbol, mint: mint),
      ),
    );
  }

  // 2. Network image
  if (logoUrl != null && logoUrl.isNotEmpty) {
    return MallowNetworkImage(
      imageUrl: logoUrl,
      logicalSize: size,
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      placeholderBuilder: (_) =>
          _symbolFallback(size: size, symbol: symbol, mint: mint),
      errorBuilder: (_) =>
          _symbolFallback(size: size, symbol: symbol, mint: mint),
    );
  }

  // 2.5 Native chain currency with no fetched logo — fall back to the brand
  // mark so ETH / XTZ from the EVM / Tezos feeds (which carry the `native`
  // sentinel mint, no local asset, and often no logoUrl) still render a
  // recognizable icon instead of bare symbol text. Only runs for the
  // `useChainSvg: false` callers (activity rows); the `true` callers already
  // handled natives at step 0. Solana resolves via its local webp above, so
  // this only catches the non-Solana natives here. Rendered with original
  // colors (not the textPrimary tint) so the marks read as real brand logos.
  if (!useChainSvg) {
    final sym = symbol?.toUpperCase();
    // Native ETH → the official multi-tone ETH token logo (blue diamond).
    if (sym == 'ETH' || mint == ethMint) {
      return MallowSvgIcon(
        'assets/icons/ethereum_color.svg',
        width: size,
        height: size,
        useOriginalColors: true,
      );
    }
    final chainSvg = chainSymbolSvgAsset(
      mint: mint,
      symbol: symbol,
      paddedSolana: !enlargeChainGlyph,
    );
    if (chainSvg != null) {
      final glyphSize = enlargeChainGlyph ? size - 4 : size;
      return MallowSvgIcon(
        chainSvg,
        width: glyphSize,
        height: glyphSize,
        useOriginalColors: true,
      );
    }
  }

  // 3. Symbol fallback
  return _symbolFallback(size: size, symbol: symbol, mint: mint);
}

/// Displays the token symbol text in a muted background container,
/// matching the Figma design for tokens without images (e.g. "BONE").
Widget _symbolFallback({required double size, String? symbol, String? mint}) {
  return Builder(
    builder: (context) {
      final String display;
      if (symbol != null) {
        display = symbol.length > 5 ? symbol.substring(0, 5) : symbol;
      } else if (mint != null) {
        display = truncateAddress(mint);
      } else {
        display = '?';
      }
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: context.mallowColors.surfaceMuted,
          borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        ),
        alignment: Alignment.center,
        child: Text(
          display,
          style: MallowTheme.uiMeta.copyWith(
            color: context.mallowColors.textPrimary,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
        ),
      );
    },
  );
}
