import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart' as api;

import '../../../core/data/mallow_tokens.dart';
import '../../../core/services/rewards_store_service.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/price_format.dart' show stripTrailingZeros;
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/utils/user_display.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/nsfw_obscured.dart';
import '../utils/activity_helpers.dart';

/// A single activity list item matching the Figma design.
///
/// Layout: [48x48 thumbnail] [Title verb + Subtitle] [Amount + USD]
///
/// When the activity's mint slot carries a rewards-store SKU (dotted form
/// like `merch.shirt.skitchism` — see [RewardsStoreService.looksLikeSku]),
/// the row swaps in the product image + name from the rewards CDN once the
/// metadata resolves.
class ActivityListItem extends StatefulWidget {
  const ActivityListItem({
    required this.activity,
    super.key,
    this.onTap,
    this.tokenMintContext,
  });

  final api.Activity activity;
  final VoidCallback? onTap;

  /// When set, swap amounts are rendered from this token's perspective
  /// (negative if the token was the swap input, positive if it was the output)
  /// instead of always showing the output token.
  final String? tokenMintContext;

  @override
  State<ActivityListItem> createState() => _ActivityListItemState();
}

/// Side of the square thumbnail every row leads with.
const double _thumbSize = 48;

class _ActivityListItemState extends State<ActivityListItem> {
  RewardsStoreProduct? _rewardsProduct;
  String? _watchedSku;

  @override
  void initState() {
    super.initState();
    _maybeFetchRewardsMetadata();
    _maybeResolveTokens();
  }

  @override
  void didUpdateWidget(covariant ActivityListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_skuFor(widget.activity) != _watchedSku) {
      _rewardsProduct = null;
      _maybeFetchRewardsMetadata();
    }
    // Rows are recycled as the feed scrolls, so a new activity in this slot
    // needs its own lookup.
    if (oldWidget.activity.id != widget.activity.id) {
      _maybeResolveTokens();
    }
  }

  /// Name and picture the swap legs and transfer token the feed left blank.
  /// Resolution is process-wide and cached, so the rebuild is the only per-row
  /// cost — a History tab whose rows are all one mint costs one lookup.
  void _maybeResolveTokens() {
    resolveActivityTokenMetadata(widget.activity).then((resolved) {
      if (resolved && mounted) setState(() {});
    });
  }

  /// Extract the dotted SKU that lives in a market/transfer activity's mint
  /// field, if any. Returns null for swap / gumball / unknown activities or
  /// any mint that's a regular base58 address.
  String? _skuFor(api.Activity activity) {
    final mint =
        activity.marketData?.artwork.mintAccount ??
        activity.transferData?.token.mint;
    return RewardsStoreService.looksLikeSku(mint) ? mint : null;
  }

  void _maybeFetchRewardsMetadata() {
    final sku = _skuFor(widget.activity);
    _watchedSku = sku;
    if (sku == null) return;

    final service = sl<RewardsStoreService>();
    final cached = service.cached(sku);
    if (cached != null) {
      _rewardsProduct = cached;
      return;
    }
    service.getBySku(sku).then((product) {
      if (!mounted) return;
      if (_watchedSku != sku) return;
      if (product != null) setState(() => _rewardsProduct = product);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MallowTheme.spacing20,
          vertical: MallowTheme.spacing12,
        ),
        child: Row(
          children: [
            _buildThumbnail(context),
            const SizedBox(width: MallowTheme.spacing12),
            Expanded(child: _buildContent(context)),
            const SizedBox(width: MallowTheme.spacing12),
            _buildTrailing(context),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context) {
    final activity = widget.activity;

    final product = _rewardsProduct;
    if (product != null && product.image.isNotEmpty) {
      return MallowNetworkImage(
        imageUrl: product.image,
        logicalSize: 48,
        width: 48,
        height: 48,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        errorBuilder: (ctx) => _unknownThumbnail(ctx),
      );
    }

    // NFT artwork thumbnail
    final marketData = activity.marketData;
    if (marketData != null) {
      // Blur a flagged artwork behind the viewer's show-NSFW setting, the same
      // treatment the artwork grids give their tiles. Feeds render the artwork
      // just as the grids do, so a flagged piece must not read as unflagged
      // purely because it arrived here in a feed row.
      return NsfwObscured(
        nsfw: marketData.artwork.nsfw,
        contentId: marketData.artwork.mintAccount,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        child: MallowNetworkImage(
          imageUrl: marketData.artwork.imageUrl,
          logicalSize: 48,
          width: 48,
          height: 48,
          borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          errorBuilder: (ctx) => Container(
            width: 48,
            height: 48,
            color: ctx.mallowColors.divider,
            alignment: Alignment.center,
            child: Text(
              truncateAddress(marketData.artwork.mintAccount),
              style: MallowTheme.uiMeta.copyWith(
                color: ctx.mallowColors.textPrimary,
                fontWeight: FontWeight.w500,
                fontSize: 9,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // Transfer (NFT or token) — show the asset being sent/received
    final transferData = activity.transferData;
    if (transferData != null) {
      final logoUrl = transferData.token.logoUrl;
      if (transferData.isNft) {
        // NFT — render the artwork as a rounded square (matches market rows).
        // No image (unindexed mint) falls back to the generic icon.
        if (logoUrl == null || logoUrl.isEmpty) {
          return _unknownThumbnail(context);
        }
        return NsfwObscured(
          nsfw: transferData.nftNsfw,
          contentId: transferData.token.mint,
          borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          child: MallowNetworkImage(
            imageUrl: logoUrl,
            logicalSize: 48,
            width: 48,
            height: 48,
            borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
            errorBuilder: (ctx) => _unknownThumbnail(ctx),
          ),
        );
      }
      return tokenImageWidget(
        mint: transferData.token.mint,
        // Not the raw wire fields, the same way the swap legs below aren't: a
        // Solana transfer arrives with an empty `symbol` and no logo at all, so
        // the tile rendered as a blank square with nothing to fall back to.
        symbol: tokenDisplaySymbol(transferData.token),
        logoUrl: tokenDisplayLogoUrl(transferData.token),
        size: 48,
        useChainSvg: false,
      );
    }

    // Swap — both legs, sold behind and received in front
    final swapData = activity.swapData;
    if (swapData != null) {
      return _buildSwapThumbnail(context, swapData);
    }

    // Native staking — the same diamond the staking sheet leads with, so the
    // row reads as staking rather than as a plain SOL movement.
    if (activity.stakeData != null) {
      return _thumbFrame(
        context,
        alignment: Alignment.center,
        child: MallowSvgIcon(
          'assets/icons/diamond.svg',
          width: 24,
          height: 24,
          color: context.mallowColors.textTertiary,
        ),
      );
    }

    // Gumball activities — crystal ball icon
    if (activity.type == api.ActivityType.gumballCreate ||
        activity.type == api.ActivityType.gumballUpdate) {
      return _thumbFrame(
        context,
        alignment: Alignment.center,
        child: MallowSvgIcon(
          'assets/icons/notif_crystal-ball.svg',
          width: 24,
          height: 24,
          color: context.mallowColors.textTertiary,
        ),
      );
    }

    // Unknown — gray circle
    return _unknownThumbnail(context);
  }

  /// The muted rounded square every non-image thumbnail is built on.
  Widget _thumbFrame(
    BuildContext context, {
    required Widget child,
    AlignmentGeometry? alignment,
  }) {
    return Container(
      width: _thumbSize,
      height: _thumbSize,
      alignment: alignment,
      decoration: BoxDecoration(
        color: context.mallowColors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: child,
    );
  }

  /// Swap thumbnail — the token sold sits at the top-left and the token
  /// received overlaps it in front at the bottom-right, so the tile reads as
  /// "this became that" before the amounts are.
  ///
  /// Each leg is two thirds of the frame, inset 2px from its own corner, which
  /// leaves the pair a 2px margin at both corners and 20px of overlap. No clip
  /// is needed: at that size neither leg can reach the frame's edge.
  Widget _buildSwapThumbnail(BuildContext context, api.SwapActivityData swap) {
    const legSize = _thumbSize * 2 / 3;
    const inset = 2.0;

    Widget leg(api.TokenInfo token) => tokenImageWidget(
      mint: token.mint,
      symbol: tokenDisplaySymbol(token),
      logoUrl: tokenDisplayLogoUrl(token),
      size: legSize,
      useChainSvg: false,
    );

    return _thumbFrame(
      context,
      child: Stack(
        children: [
          Positioned(left: inset, top: inset, child: leg(swap.inputToken)),
          Positioned(right: inset, bottom: inset, child: leg(swap.outputToken)),
        ],
      ),
    );
  }

  Widget _unknownThumbnail(BuildContext context) {
    return _thumbFrame(
      context,
      child: MallowSvgIcon(
        'assets/icons/receipt.svg',
        width: 22,
        height: 22,
        color: context.mallowColors.textTertiary,
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final colors = context.mallowColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          activityDisplayLabel(widget.activity),
          style: MallowTheme.editorialQuote.copyWith(color: colors.textPrimary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          _getSubtitle(),
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildTrailing(BuildContext context) {
    final amountText = _getAmountText();
    if (amountText.isEmpty) return const SizedBox.shrink();

    final secondary = _secondaryLine(context);

    // Cap the trailing column so a long token symbol truncates with an ellipsis
    // instead of overflowing the row (the middle content keeps the remaining
    // width). 140 comfortably fits compact amounts like "+1.23K USDC".
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            amountText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MallowTheme.uiBody.copyWith(
              fontSize: 14,
              // See [_isUnsignedAmount]: a price or a pending claim, not a
              // balance change.
              color: _isUnsignedAmount
                  ? context.mallowColors.textSecondary
                  : context.mallowColors.textPrimary,
            ),
          ),
          if (secondary != null) ...[
            const SizedBox(height: 4),
            Text(
              secondary.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MallowTheme.uiBody.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w300,
                color: secondary.color,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// True for the types whose amount is not a balance change — a listing price,
  /// or the stake an unstake will make claimable at the epoch boundary. None of
  /// them move anything in or out of the wallet, so the amount renders
  /// secondary and can't be mistaken for the signed debits and credits it sits
  /// alongside.
  bool get _isUnsignedAmount =>
      widget.activity.type == api.ActivityType.list ||
      widget.activity.type == api.ActivityType.delist ||
      widget.activity.type == api.ActivityType.unstake;

  String _getSubtitle() {
    final activity = widget.activity;

    final product = _rewardsProduct;
    if (product != null) return product.name;

    final marketData = activity.marketData;
    if (marketData != null) {
      return formatArtworkName(
        name: marketData.artwork.name,
        editionNumber: marketData.artwork.editionNumber,
      );
    }

    final swapData = activity.swapData;
    if (swapData != null) {
      return '${tokenDisplaySymbol(swapData.inputToken)} → ${tokenDisplaySymbol(swapData.outputToken)}';
    }

    final transferData = activity.transferData;
    if (transferData != null) {
      // NFT transfers read like marketplace rows: the artwork name is the
      // subtitle. Falls back to the counterparty when the mint isn't indexed.
      final nftName = transferData.nftName;
      if (transferData.isNft && nftName != null && nftName.isNotEmpty) {
        return formatArtworkName(
          name: nftName,
          editionNumber: transferData.nftEditionNumber,
        );
      }
      final cp = transferData.counterparty;
      final name = formatUsernameOrAddress(
        username: cp.username,
        address: cp.address,
      );
      return activity.type == api.ActivityType.send ? 'to $name' : 'from $name';
    }

    // Staking has two mechanisms in the app and they produce different rows:
    // liquid staking is a mallowSOL swap and lands in the branch above, so
    // naming the mechanism here is what tells the two apart.
    if (activity.stakeData != null) return 'Native stake';

    return truncateAddress(activity.signature);
  }

  String _getAmountText() {
    final activity = widget.activity;
    final marketData = activity.marketData;
    final transferData = activity.transferData;

    // When viewing a token's history, show the change in that token (the
    // actual on-chain leg) instead of the marketplace price — which may be
    // denominated in a different currency. Falls back to type-based direction
    // for plain (unenriched) transfers where transferDirection is unset.
    if (widget.tokenMintContext != null &&
        transferData != null &&
        transferData.token.mint == widget.tokenMintContext) {
      final isIn =
          transferData.transferDirection == 'in' ||
          activity.type == api.ActivityType.receive;
      final sym = tokenDisplaySymbol(transferData.token);
      if (transferData.isNft) {
        return '${isIn ? '+1' : '-1'} $sym';
      }
      final prefix = isIn ? '+' : '-';
      return '$prefix${PriceFormatter.formatCompactAmount(transferData.token.amount, transferData.token.decimals, maxBaseDecimals: 2, maxSubDecimals: 4)} $sym';
    }

    if (marketData != null) {
      final amount = PriceFormatter.formatCompactPrice(marketData.price);
      // No balance change — show nothing rather than "0 SOL" / "-0 SOL".
      if (amount == '0') return '';
      final prefix = isActivityOutgoing(activity)
          ? '-'
          : isActivityIncoming(activity)
          ? '+'
          : '';
      final sym = marketData.currencySymbol ?? 'SOL';
      return '$prefix$amount $sym';
    }

    final legs = _swapLegs;
    if (legs != null) return _signedLeg(legs.shown, credit: !legs.shownIsInput);

    if (transferData != null) {
      if (transferData.isNft) {
        // An NFT has no fungible amount — the trailing value is the viewer's
        // cost to transfer (network fee) on their own sends. Everything else
        // (receives, transfer-shaped Tezos mints, sends where the fee is
        // unknown) shows no amount: a mint reads as an acquisition of the
        // artwork, not a debit, and its fee isn't necessarily lamports.
        final fee = transferData.fee;
        if (activity.type != api.ActivityType.send || fee == null) {
          return '';
        }
        return _transferCost(activity, fee);
      }
      final prefix = activity.type == api.ActivityType.receive ? '+' : '-';
      final sym = tokenDisplaySymbol(transferData.token);
      final amount = PriceFormatter.formatCompactAmount(
        transferData.token.amount,
        transferData.token.decimals,
        maxBaseDecimals: 2,
        maxSubDecimals: 4,
      );
      return sym.isEmpty ? '$prefix$amount' : '$prefix$amount $sym';
    }

    // Native staking. Only the two ends of the lifecycle move money: funding a
    // stake account debits the wallet and claiming a deactivated one credits
    // it. Unstaking sits between them and moves nothing — the amount is what
    // will be claimable, so it renders unsigned like a listing price.
    final stakeData = activity.stakeData;
    if (stakeData != null) {
      final prefix = isActivityOutgoing(activity)
          ? '-'
          : isActivityIncoming(activity)
          ? '+'
          : '';
      final amount = PriceFormatter.formatCompactAmount(
        stakeData.token.amount,
        stakeData.token.decimals,
        maxBaseDecimals: 2,
        maxSubDecimals: 4,
      );
      return '$prefix$amount ${tokenDisplaySymbol(stakeData.token)}';
    }

    // Gumball activities — read price from raw data. Gated on the gumball types
    // this was written for: marketplace-payload rows that fall through as
    // `unknown` also carry a `price`, and rendering it here produced an
    // unsigned, uncontextualised "0.5 SOL" on an "Unknown transaction" row.
    final isGumball =
        activity.type == api.ActivityType.gumballCreate ||
        activity.type == api.ActivityType.gumballUpdate;
    final rawPrice = isGumball ? activity.data['price'] : null;
    if (rawPrice is num) {
      return '${PriceFormatter.formatCompactPrice(rawPrice.toDouble())} SOL';
    }

    return '';
  }

  /// What an NFT send cost the viewer, as a single negative amount.
  ///
  /// [fee] is the network fee; `data.rent` (SOL, present only when the viewer
  /// paid it) is the account-creation rent a legacy Solana NFT needs so the
  /// recipient has a token account — money genuinely spent, so the row shows
  /// the whole outlay rather than the network fee alone.
  ///
  /// The ticker is resolved in order of trust: the server-stated
  /// `data.feeCurrency`, then SOL but only when the row itself establishes
  /// Solana ([inferActivityChain]), else nothing. The lamports formatter is
  /// Solana-only for both halves of what it does — scaling by 1e9 and
  /// labelling "SOL" would make a tez or ETH fee numerically wrong as well as
  /// mislabelled — so every other row renders at its own magnitude, bare if
  /// need be. An unlabelled amount is recoverable; a wrong ticker is not.
  String _transferCost(api.Activity activity, double fee) {
    final rent = activity.data['rent'];
    final cost = fee + (rent is num ? rent.toDouble() : 0);

    final stated = activity.data['feeCurrency'];
    final ticker = stated is String && stated.trim().isNotEmpty
        ? stated.trim()
        : null;
    if (ticker == null && inferActivityChain(activity) == Chain.solana) {
      return PriceFormatter.formatFeeLamports((cost * 1e9).round(), sign: '-');
    }
    final amount = stripTrailingZeros(
      // Fees are dust-level fractions of a unit, so this leans on the default
      // 6-decimal sub-unit cap rather than a price-style 4-decimal one, which
      // rounds a typical 0.000005 SOL fee to "0".
      PriceFormatter.formatCompactAmount(
        cost.abs(),
        tokenBySymbol(ticker ?? '')?.decimals ?? 6,
      ),
    );
    return ticker == null ? '-$amount' : '-$amount $ticker';
  }

  /// The two halves of a swap, ordered for display, or null if this row isn't
  /// one.
  ///
  /// Which leg leads is the single decision behind the sign, the colour, and
  /// the order of both trailing lines, so it is made here once. A row inside a
  /// single token's history is about that token, so its leg leads; everywhere
  /// else the row leads with what the wallet received.
  ({api.TokenInfo shown, api.TokenInfo other, bool shownIsInput})?
  get _swapLegs {
    final swap = widget.activity.swapData;
    if (swap == null) return null;
    final shownIsInput =
        widget.tokenMintContext != null &&
        swap.inputToken.mint == widget.tokenMintContext;
    return (
      shown: shownIsInput ? swap.inputToken : swap.outputToken,
      other: shownIsInput ? swap.outputToken : swap.inputToken,
      shownIsInput: shownIsInput,
    );
  }

  /// One leg of a trade as a signed, symbol-bearing amount.
  String _signedLeg(api.TokenInfo token, {required bool credit}) {
    final amount = PriceFormatter.formatCompactAmount(
      token.amount,
      token.decimals,
      maxBaseDecimals: 2,
      maxSubDecimals: 4,
    );
    return '${credit ? '+' : '-'}$amount ${tokenDisplaySymbol(token)}';
  }

  /// The smaller line under the amount, with the colour it renders in.
  ///
  /// A swap moved two balances, and the USD value of one of them says nothing
  /// about the trade — so a swap spends this line on the leg [_swapLegs] did
  /// not lead with (what left the wallet, beneath what came in) rather than on
  /// a dollar figure. Every other row keeps its USD value.
  ({String text, Color color})? _secondaryLine(BuildContext context) {
    final colors = context.mallowColors;

    final legs = _swapLegs;
    if (legs != null) {
      return (
        text: _signedLeg(legs.other, credit: legs.shownIsInput),
        color: legs.shownIsInput ? colors.positive : colors.negative,
      );
    }

    final usdText = _getUsdText();
    if (usdText == null) return null;
    return (
      text: usdText,
      color:
          activityDirectionColor(widget.activity, colors) ??
          colors.textSecondary,
    );
  }

  String? _getUsdText() {
    final activity = widget.activity;
    final usd =
        activity.marketData?.usdPrice ??
        activity.transferData?.usdPrice ??
        (activity.data['usdPrice'] as num?)?.toDouble();
    if (usd == null) return null;
    return '\$${usd.toStringAsFixed(2)}';
  }
}
