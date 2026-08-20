import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/data/mallow_tokens.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/price_formatter.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/explorer_utils.dart';
import '../../../shared/utils/price_format.dart' show stripTrailingZeros;
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../artwork/services/artwork_download_actions.dart';
import '../../artwork/widgets/artwork_context_menu_sheet.dart';
import '../../artwork/widgets/burn_artwork_flow.dart';
import '../../artwork/widgets/transfer_artwork_flow.dart';
import '../../cast/models/cast_queue.dart';
import '../../cast/services/cast_actions.dart';
import '../../cast/services/cast_bloc.dart';
import '../../../shared/widgets/mallow_kv_row.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../utils/activity_helpers.dart';
import '../widgets/activity_preview.dart';

/// Detail view for a single activity, shown inside the activity sheet.
class ActivityDetailScreen extends StatefulWidget {
  const ActivityDetailScreen({
    required this.activity,
    required this.onBack,
    this.chain,
    super.key,
  });

  final api.Activity activity;
  final VoidCallback onBack;

  /// Chain context supplied by the caller, when known. The detail screen still
  /// derives the row's chain from the activity first because the global feed
  /// can contain activities from more than one wallet/chain.
  final Chain? chain;

  @override
  State<ActivityDetailScreen> createState() => _ActivityDetailScreenState();
}

class _ActivityDetailScreenState extends State<ActivityDetailScreen> {
  bool _copied = false;

  api.Activity get activity => widget.activity;
  VoidCallback get onBack => widget.onBack;

  @override
  void initState() {
    super.initState();
    // The preview hero and the Paid / Received rows both name the token, which
    // the feed doesn't. Usually already warm from the list row that was
    // tapped — but not on a push-notification deep link into this screen.
    resolveActivityTokenMetadata(activity).then((resolved) {
      if (resolved && mounted) setState(() {});
    });
  }

  /// Chain driving the tx-explorer link/label. Prefer the transaction's own
  /// signature because the global feed aggregates multiple chains and the
  /// caller may only know the active wallet's chain. The caller's chain
  /// remains a fallback for signatures whose encoding is undetermined.
  Chain? get _effectiveChain =>
      inferChainFromTxSignature(activity.signature) ?? widget.chain;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Row(
            children: [
              TapTargetExpander(
                child: GestureDetector(
                  onTap: onBack,
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: MallowSvgIcon(
                      'assets/icons/arrow_left.svg',
                      width: 16,
                      height: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  activityDisplayLabel(activity),
                  style: MallowTheme.editorialQuote.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              TapTargetExpander(
                child: GestureDetector(
                  onTap: _copied ? null : _copyTransactionLink,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _copied
                        ? MallowSvgIcon(
                            'assets/icons/checkmark.svg',
                            width: 16,
                            height: 16,
                            color: colors.positive,
                          )
                        : MallowSvgIcon(
                            'assets/icons/copy.svg',
                            width: 16,
                            height: 16,
                            color: colors.textPrimary,
                          ),
                  ),
                ),
              ),
              if (hasNftData(activity))
                TapTargetExpander(
                  child: GestureDetector(
                    onTap: () => _showContextMenu(context),
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: MallowSvgIcon(
                        'assets/icons/dots_vertical.svg',
                        width: 16,
                        height: 16,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // Scrollable content
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: MallowTheme.spacing20,
            ),
            child: Column(
              children: [
                // Preview image
                ActivityPreview(activity: activity),

                const SizedBox(height: 20),

                // Detail rows
                MallowKvList(rows: _buildDetailRows()),
              ],
            ),
          ),
        ),

        // Explorer button
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MallowTheme.spacing20,
            8,
            MallowTheme.spacing20,
            0,
          ),
          child: MallowButton(
            label: 'View on ${txExplorerName(_effectiveChain)}',
            onPressed: _openExplorer,
            isFullWidth: true,
          ),
        ),

        SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
      ],
    );
  }

  List<Widget> _buildDetailRows() {
    final rows = <Widget>[];
    final dateStr = DateFormat('d MMM yyyy, h:mm a').format(activity.dateTime);
    rows.add(MallowKvRow(label: 'Date', value: dateStr));
    rows.add(MallowKvRow(label: 'Status', value: statusLabel(activity.status)));

    switch (activity.type) {
      case api.ActivityType.buy:
        _addBuyRows(rows);
      case api.ActivityType.sale:
        _addSaleRows(rows);
      case api.ActivityType.swap:
        _addSwapRows(rows);
      case api.ActivityType.send:
        _addSendRows(rows);
      case api.ActivityType.receive:
        _addReceiveRows(rows);
      case api.ActivityType.mint:
        _addMintRows(rows);
      case api.ActivityType.list:
        _addListRows(rows);
      case api.ActivityType.delist:
        break; // Just date + status
      case api.ActivityType.offer:
        _addOfferRows(rows);
      case api.ActivityType.offerReceived:
        _addOfferReceivedRows(rows);
      case api.ActivityType.gumballCreate:
        _addGumballCreateRows(rows);
      case api.ActivityType.stake:
      case api.ActivityType.unstake:
      case api.ActivityType.stakeWithdraw:
        _addStakeRows(rows);
      case api.ActivityType.gumballUpdate:
      case api.ActivityType.altCreate:
      case api.ActivityType.unknown:
        break; // Just date + status
    }

    // Network fee — shown whenever the server includes a fee. `unknown` rows
    // (contract calls we can't classify) carry nothing else, so this is the
    // only substance they have beyond date + status.
    final fee = activity.data['fee'];
    if (fee is num) {
      rows.add(
        MallowKvRow(label: 'Network fee', value: _formatCost(fee.toDouble())),
      );
    }

    // Account rent — on Solana a legacy-NFT transfer has the sender fund the
    // recipient's token account. That rent is real money leaving the wallet,
    // not a validator fee, so it gets its own row directly under the fee
    // instead of being folded into it. Present only when the viewer paid it.
    final rent = activity.data['rent'];
    if (rent is num) {
      rows.add(
        MallowKvRow(label: 'Account rent', value: _formatCost(rent.toDouble())),
      );
    }

    return rows;
  }

  /// The `(ticker, decimals)` the fee / rent rows are denominated in, or null
  /// when it can't be established.
  ///
  /// These amounts are denominated in whatever the row's own chain settles in —
  /// SOL on Solana, the baker fee in XTZ on Tezos, ETH on EVM — so the ticker
  /// is resolved in descending order of trustworthiness:
  ///
  /// 1. `data.feeCurrency`, a ticker the server states for this row. It is the
  ///    only signal that stays correct in the aggregated activity feed, which
  ///    mixes rows from every session wallet while the caller can only pass one
  ///    chain (the *active* wallet's) for all of them.
  /// 2. [_effectiveChain], for rows the server hasn't stamped yet. Exact on the
  ///    token-detail caller (one token, one chain); on the mixed feed it is
  ///    only as good as the active wallet, hence (1) taking precedence.
  /// 3. Nothing — the amount renders bare. An unlabelled number is recoverable
  ///    (the user can open the explorer); a wrong ticker is the one error they
  ///    cannot catch from the screen, because the digits look right.
  ///
  /// Decimals only bound the display precision, so an unregistered ticker
  /// falling back to 6 still renders correctly for every chain we support.
  (String, int)? get _costCurrency {
    final stated = activity.data['feeCurrency'];
    if (stated is String && stated.isNotEmpty) {
      return (stated, tokenBySymbol(stated)?.decimals ?? 6);
    }
    final currency = baseTokenForChain(_effectiveChain?.toDbString());
    if (currency == null) return null;
    return (currency.symbol, currency.decimals);
  }

  /// A cost the viewer paid (network fee, account rent), in the row's own
  /// currency — see [_costCurrency]. Rent is Solana-only today but resolves the
  /// same way rather than hardcoding SOL, so it can't drift the way the fee row
  /// did.
  ///
  /// These are dust-level fractions of a unit, so this uses the amount path —
  /// whose default sub-unit cap is the same 6 decimals
  /// [PriceFormatter.formatFeeLamports] uses for SOL — rather than
  /// [PriceFormatter.formatCompactPrice], whose 4-decimal price cap rounds a
  /// typical 0.000005 SOL fee to "0". Trailing zeros are stripped so it reads
  /// "-0.00001", not "-0.000010".
  String _formatCost(double amount) {
    final currency = _costCurrency;
    final text = stripTrailingZeros(
      PriceFormatter.formatCompactAmount(amount.abs(), currency?.$2 ?? 6),
    );
    return currency == null ? '-$text' : '-$text ${currency.$1}';
  }

  /// The marketplace amount for [data] with its currency, or null when there
  /// is nothing to show and the row should be omitted entirely.
  ///
  /// `price` is `required double` on the wire, so the server cannot omit the
  /// key when it has no figure — it sends 0. That happens for a genuine zero
  /// (a free mint) *and* for an amount it deliberately declines to guess (a
  /// refund whose actual credit is unknowable because it landed in another
  /// session wallet, settled in a later tx, or was token-denominated). Both
  /// read the same to a user, and "+0 SOL" asserts they received nothing —
  /// strictly worse than saying nothing, because it's a claim about their
  /// money that we cannot stand behind.
  ///
  /// Suppressing on the *formatted* value rather than `price == 0` matches
  /// `activity_list_item.dart`'s market-amount rule exactly, so the list row
  /// and this screen agree on every input — including dust that rounds to "0"
  /// at display precision, which is just as meaningless to show.
  String? _marketAmount(api.MarketActivityData data) {
    final amount = PriceFormatter.formatCompactPrice(data.price);
    if (amount == '0') return null;
    return '$amount ${data.currencySymbol ?? 'SOL'}';
  }

  /// Counterparty row. When a username is set it renders `@handle` as a
  /// link to that user's profile; otherwise falls back to an address row
  /// (tap = copy, long-press = explorer).
  Widget _accountRow({
    required String label,
    required String? username,
    required String address,
  }) {
    if (username != null && username.isNotEmpty) {
      return MallowKvRow(
        label: label,
        value: '@$username',
        onTap: () => context.push(AppRoutes.profileByUsernamePath(username)),
      );
    }
    return MallowKvAddressRow(label: label, address: address, isAccount: true);
  }

  void _addBuyRows(List<Widget> rows) {
    final data = activity.marketData;
    if (data == null) return;
    final seller = data.counterparty;
    if (seller != null) {
      rows.add(
        _accountRow(
          label: 'From',
          username: seller.username,
          address: seller.address,
        ),
      );
    }
    final amount = _marketAmount(data);
    if (amount != null) {
      rows.add(MallowKvRow(label: 'Price', value: '-$amount'));
    }
  }

  void _addSaleRows(List<Widget> rows) {
    final data = activity.marketData;
    if (data == null) return;
    final buyer = data.counterparty;
    if (buyer != null) {
      rows.add(
        _accountRow(
          label: 'To',
          username: buyer.username,
          address: buyer.address,
        ),
      );
    }
    final amount = _marketAmount(data);
    if (amount != null) {
      rows.add(MallowKvRow(label: 'Received', value: '+$amount'));
    }
  }

  void _addSwapRows(List<Widget> rows) {
    final data = activity.swapData;
    if (data == null) return;
    rows.add(
      MallowKvRow(
        label: 'Paid',
        value:
            '-${PriceFormatter.formatCompactAmount(data.inputToken.amount, data.inputToken.decimals)} ${tokenDisplaySymbol(data.inputToken)}',
      ),
    );
    rows.add(
      MallowKvRow(
        label: 'Received',
        value:
            '+${PriceFormatter.formatCompactAmount(data.outputToken.amount, data.outputToken.decimals)} ${tokenDisplaySymbol(data.outputToken)}',
      ),
    );
    if (data.route != null) {
      rows.add(MallowKvRow(label: 'Provider', value: data.route!));
    }
  }

  void _addSendRows(List<Widget> rows) {
    final data = activity.transferData;
    if (data == null) return;
    rows.add(
      _accountRow(
        label: 'To',
        username: data.counterparty.username,
        address: data.counterparty.address,
      ),
    );
    final sym = tokenDisplaySymbol(data.token);
    final nftLabel = data.nftName?.isNotEmpty == true
        ? formatArtworkName(
            name: data.nftName!,
            editionNumber: data.nftEditionNumber,
          )
        : sym;
    final tokenName = data.isNft
        ? '1 $nftLabel'
        : '${PriceFormatter.formatCompactAmount(data.token.amount, data.token.decimals)} $sym';
    rows.add(MallowKvRow(label: 'Sent', value: '-$tokenName'));
    if (data.usdPrice != null) {
      rows.add(
        MallowKvRow(
          label: 'USD value',
          value: '\$${data.usdPrice!.toStringAsFixed(2)}',
        ),
      );
    }
  }

  void _addReceiveRows(List<Widget> rows) {
    final data = activity.transferData;
    if (data == null) return;
    rows.add(
      _accountRow(
        label: 'From',
        username: data.counterparty.username,
        address: data.counterparty.address,
      ),
    );
    final sym = tokenDisplaySymbol(data.token);
    final nftLabel = data.nftName?.isNotEmpty == true
        ? formatArtworkName(
            name: data.nftName!,
            editionNumber: data.nftEditionNumber,
          )
        : sym;
    final tokenName = data.isNft
        ? '+1 $nftLabel'
        : '+${PriceFormatter.formatCompactAmount(data.token.amount, data.token.decimals)} $sym';
    rows.add(MallowKvRow(label: 'Received', value: tokenName));
    if (data.usdPrice != null) {
      rows.add(
        MallowKvRow(
          label: 'USD value',
          value: '\$${data.usdPrice!.toStringAsFixed(2)}',
        ),
      );
    }
  }

  /// Native staking. The label states which end of the lifecycle this is,
  /// because only staking and claiming move money — an unstake states what the
  /// deactivating position will make claimable, and is deliberately unsigned.
  void _addStakeRows(List<Widget> rows) {
    final data = activity.stakeData;
    if (data == null) return;
    final amount =
        '${PriceFormatter.formatCompactAmount(data.token.amount, data.token.decimals)} '
        '${tokenDisplaySymbol(data.token)}';
    final (label, value) = switch (activity.type) {
      api.ActivityType.stake => ('Staked', '-$amount'),
      api.ActivityType.stakeWithdraw => ('Claimed', '+$amount'),
      _ => ('Deactivating', amount),
    };
    rows.add(MallowKvRow(label: label, value: value));
    final validator = data.validator;
    if (validator != null && validator.isNotEmpty) {
      rows.add(
        MallowKvAddressRow(
          label: 'Validator',
          address: validator,
          isAccount: true,
        ),
      );
    }
    if (data.usdPrice != null) {
      rows.add(
        MallowKvRow(
          label: 'USD value',
          value: '\$${data.usdPrice!.toStringAsFixed(2)}',
        ),
      );
    }
  }

  void _addMintRows(List<Widget> rows) {
    // Market data first: a Solana mint carries the marketplace payload and
    // must keep rendering price + artwork. The Tezos feed instead emits `mint`
    // with a transfer-shaped payload (token/counterparty/isNft), which
    // [api.Activity.transferData] now parses — that mint IS a receive, so
    // render it as one rather than degrading to date + status.
    final data = activity.marketData;
    if (data == null) {
      _addReceiveRows(rows);
      return;
    }
    // A free mint has no "Paid" row — its zero is a real price, and
    // [_marketAmount] omits it for the same reason the old `price > 0` guard
    // did (while additionally catching dust that formats to "0").
    final paid = _marketAmount(data);
    if (paid != null) {
      rows.add(MallowKvRow(label: 'Paid', value: '-$paid'));
    }
    rows.add(
      MallowKvRow(
        label: 'Received',
        value:
            '+1 ${formatArtworkName(name: data.artwork.name, editionNumber: data.artwork.editionNumber)}',
      ),
    );
  }

  void _addListRows(List<Widget> rows) {
    final data = activity.marketData;
    if (data == null) return;
    final amount = _marketAmount(data);
    if (amount != null) {
      rows.add(MallowKvRow(label: 'Listing price', value: amount));
    }
  }

  void _addOfferRows(List<Widget> rows) {
    final data = activity.marketData;
    if (data == null) return;
    // A refunded bid arrives on the same `offer` type but is escrow coming
    // back after being outbid — money in, not out. Rendering it as "To" +
    // "Amount" reads as a second spend of the same funds, so flip the framing
    // to incoming: the counterparty is who returned it, and the sign is "+".
    final refunded = isRefund(activity);
    if (data.counterparty != null) {
      rows.add(
        _accountRow(
          label: refunded ? 'From' : 'To',
          username: data.counterparty!.username,
          address: data.counterparty!.address,
        ),
      );
    }
    // Amount, in precedence order:
    //
    // 1. `amountUnknown` — the server states it could NOT determine the
    //    viewer's credit (the refund landed in another session wallet, or the
    //    auction was token-denominated). Say so outright. Omitting the row
    //    leaves the user to infer "we don't know" from an absence, which reads
    //    exactly like "nothing came back" — the two are indistinguishable from
    //    the outside, and only one of them is true.
    // 2. A figure we can stand behind — state it.
    // 3. A zero with no flag — a credit the server verified as nil. Stays
    //    silently suppressed (see [_marketAmount]); the "Bid returned" label
    //    and the counterparty above already carry the row.
    final amount = _marketAmount(data);
    if (refunded && activity.data['amountUnknown'] == true) {
      rows.add(
        const MallowKvRow(label: 'Refunded', value: 'Amount unavailable'),
      );
    } else if (amount != null) {
      rows.add(
        MallowKvRow(
          label: refunded ? 'Refunded' : 'Amount',
          value: refunded ? '+$amount' : amount,
        ),
      );
    }
  }

  void _addOfferReceivedRows(List<Widget> rows) {
    final data = activity.marketData;
    if (data == null) return;
    if (data.counterparty != null) {
      rows.add(
        _accountRow(
          label: 'From',
          username: data.counterparty!.username,
          address: data.counterparty!.address,
        ),
      );
    }
    final amount = _marketAmount(data);
    if (amount != null) {
      rows.add(MallowKvRow(label: 'Amount', value: amount));
    }
  }

  void _addGumballCreateRows(List<Widget> rows) {
    final price = activity.data['price'];
    if (price is num) {
      // Gumball machines are a Solana-only program, so SOL is safe here (unlike
      // the network-fee row, which spans chains).
      rows.add(
        MallowKvRow(
          label: 'Price',
          value: '${PriceFormatter.formatCompactPrice(price.toDouble())} SOL',
        ),
      );
    }
    final usd = activity.data['usdPrice'];
    if (usd is num) {
      rows.add(
        MallowKvRow(label: 'USD value', value: '\$${usd.toStringAsFixed(2)}'),
      );
    }
  }

  Future<void> _openExplorer() async {
    final url = buildTxExplorerUrlForChain(activity.signature, _effectiveChain);
    await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
  }

  void _copyTransactionLink() {
    final url = buildTxExplorerUrlForChain(activity.signature, _effectiveChain);
    Clipboard.setData(ClipboardData(text: url));
    HapticFeedback.lightImpact();
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _showContextMenu(BuildContext context) async {
    PortfolioArtwork? artwork;

    final marketData = activity.marketData;
    if (marketData != null) {
      artwork = PortfolioArtwork(
        mintAccount: marketData.artwork.mintAccount,
        title: marketData.artwork.name,
        imageUrl: marketData.artwork.imageUrl,
        artistName: marketData.artwork.artistName ?? '',
        collectionName: marketData.artwork.collectionName,
        editionNumber: marketData.artwork.editionNumber,
        updateAuth: marketData.artwork.updateAuth,
      );
    }

    final transferData = activity.transferData;
    if (artwork == null && transferData != null && transferData.isNft) {
      artwork = PortfolioArtwork(
        mintAccount: transferData.token.mint,
        title: transferData.nftName ?? transferData.token.symbol,
        imageUrl: transferData.token.logoUrl ?? '',
        artistName: '',
        editionNumber: transferData.nftEditionNumber,
      );
    }

    if (artwork == null || !context.mounted) return;

    // Hide/Unhide is suppressed here: activity artworks are synthesized from
    // tx data with no real hidden state, so the row would always read "Hide"
    // and re-hide an already-hidden item. See [showArtworkContextMenu].
    final action = await showArtworkContextMenu(
      context,
      artwork: artwork,
      showHide: false,
    );
    if (!context.mounted) return;

    await _handleCastAction(action, artwork);
  }

  Future<void> _handleCastAction(
    ArtworkContextMenuAction? action,
    PortfolioArtwork artwork,
  ) async {
    final item = CastQueueItemFromArtwork.fromPortfolioArtwork(artwork);
    switch (action) {
      case ArtworkContextMenuAction.viewArtwork:
        // Dismiss this detail overlay first so backing out of the artwork
        // page returns to the activity list, then push the artwork route.
        onBack();
        await context.push(AppRoutes.artworkDetailPath(artwork.mintAccount));
      case ArtworkContextMenuAction.castToScreen:
        unawaited(castArtworkWithVerify(item));
      case ArtworkContextMenuAction.addToCastQueue:
        sl<CastBloc>().add(CastEvent.addToQueue(item));
        AppSnackBar.show(context, 'Added to cast');
      case ArtworkContextMenuAction.download:
        await downloadArtworkWithVerify(context, artwork);
      case ArtworkContextMenuAction.transfer:
        final transferred = await runTransferArtworkFlow(
          context,
          artwork: artwork,
        );
        if (transferred && mounted) {
          AppSnackBar.show(context, 'Artwork transferred');
        }
      case ArtworkContextMenuAction.burn:
        final burned = await runBurnArtworkFlow(context, artwork: artwork);
        if (burned && mounted) {
          AppSnackBar.show(context, 'NFT burned');
        }
      default:
        break;
    }
  }
}
