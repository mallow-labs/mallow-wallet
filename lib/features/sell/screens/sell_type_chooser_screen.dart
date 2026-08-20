import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' show SupplyType;

import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/chooser_type_row.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../mint/widgets/mint_progress_bar.dart';
import '../services/listing_eligibility_service.dart';
import '../widgets/verify_to_list_sheet.dart';

/// Entry screen for the sell flow — lets the user pick a sale type.
///
/// When entered with an artwork in context (mint + supplyType from
/// the artwork detail screen), the next step skips select-artwork and
/// any sale types that don't apply to the artwork are hidden (e.g.
/// auctions aren't supported for open/limited editions).
///
class SellTypeChooserScreen extends StatefulWidget {
  const SellTypeChooserScreen({this.mintAccount, this.supplyType, super.key});

  /// Optional mint passed through to the next step so the user does
  /// not have to pick the artwork again.
  final String? mintAccount;

  /// Optional supply type used to gate sale types that don't apply
  /// to the in-context artwork.
  final SupplyType? supplyType;

  @override
  State<SellTypeChooserScreen> createState() => _SellTypeChooserScreenState();
}

class _SellTypeChooserScreenState extends State<SellTypeChooserScreen> {
  static const _progressFraction = 1 / 7;

  /// Both listing entry points funnel through this screen, so the
  /// verify-to-list gate runs here — before any sale type can be picked.
  /// The chooser stays blank while it resolves.
  bool _checkingEligibility = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runEligibilityGate());
  }

  /// Webapp parity: an ineligible user gets `VerifyToList` *instead of* the
  /// listing UI (`ListArtwork`). Here that means the sheet, then
  /// leaving the flow — there is nothing behind the sheet they may use.
  Future<void> _runEligibilityGate() async {
    final reason = await checkListingEligibility(
      mintAccount: widget.mintAccount,
    );
    if (!mounted) return;
    if (reason == null) {
      setState(() => _checkingEligibility = false);
      return;
    }
    final action = await showVerifyToListSheet(context, reason);
    if (!mounted) return;
    // Grabbed before the pop: this element is deactivated by it, so its
    // context can't route afterwards.
    final router = GoRouter.of(context);
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.home);
    }
    if (action == VerifyToListAction.editProfile) {
      unawaited(router.push(AppRoutes.editProfile));
    }
  }

  bool get _isMasterEdition =>
      widget.supplyType == SupplyType.limitedEdition ||
      widget.supplyType == SupplyType.openEdition;

  void _onAuctionTap() {
    final mint = widget.mintAccount;
    context.push(
      mint == null
          ? AppRoutes.sellAuction
          : '${AppRoutes.sellAuction}?mint=$mint',
    );
  }

  void _onFixedPriceTap() {
    final mint = widget.mintAccount;
    context.push(
      mint == null
          ? AppRoutes.sellFixedPrice
          : '${AppRoutes.sellFixedPrice}?mint=$mint',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MallowHeader(title: 'Create Sale'),
              const SizedBox(height: MallowTheme.spacing20),
              // Nothing below the header until the gate resolves — the sale
              // types must not be tappable while eligibility is unknown.
              if (_checkingEligibility) ...[
                const Expanded(child: Center(child: MallowLoader())),
              ] else ...[
                const MintProgressBar(fraction: _progressFraction),
                const SizedBox(height: MallowTheme.spacing20),
                Text(
                  'Choose sale type',
                  style: MallowTheme.uiLabel.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: MallowTheme.spacing20),
                if (!_isMasterEdition) ...[
                  ChooserTypeRow(
                    svgAsset: 'assets/icons/notif_gavel.svg',
                    title: 'Auction',
                    subtitle: 'Set a starting bid, let collectors compete',
                    onTap: _onAuctionTap,
                  ),
                  const SizedBox(height: MallowTheme.spacing20),
                ],
                ChooserTypeRow(
                  svgAsset: 'assets/icons/notif_coin.svg',
                  title: 'Fixed Price',
                  subtitle: 'Set your price, collectors buy when ready',
                  onTap: _onFixedPriceTap,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
