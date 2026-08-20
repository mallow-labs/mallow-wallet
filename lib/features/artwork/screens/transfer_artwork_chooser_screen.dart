import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/remote_config.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/chain_support_guard.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/select_artwork_step.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../services/artwork_permission_service.dart';
import '../services/transfer_artwork_bloc.dart';
import '../widgets/transfer_artwork_flow.dart';

/// Why [artwork] can't be transferred, or null when it can.
///
/// The first arm is the **chain** the artwork lives on. The picker uses the
/// cross-chain v2 portfolio query, so a Tezos artwork can be shown here and,
/// left alone, would take the Solana branch of the transfer flow: the recipient
/// field hints "Solana address" and the confirm step throws base58-decoding a
/// `KT1…` mint. `AppFlow.nftTransfer.chains` is the build's own capability
/// matrix (the same set the signing backstop reads), so deriving the check
/// from it — rather than a hardcoded `{solana, ethereum}` here — means the
/// picker can never drift from what the transaction builders actually
/// implement.
///
/// Refused at the point of action with a reason, not filtered out of the grid:
/// a Tezos holder who taps their artwork and watches the row do nothing learns
/// nothing, and hiding it is indistinguishable from the app having lost the
/// asset. This matches the sibling arms below, `MallowButton.onDisabledTap`, and
/// the entry-gate convention generally — explain a refused affordance rather
/// than hide it. It also has to run *before* the permission round-trip, which
/// is a Solana DAS lookup that throws on a Tezos address.
///
/// The remaining arms are the same gate the artwork context menu's Transfer row
/// applies
/// (`artwork_context_menu_sheet.dart:571-580`): the indexer listing term first,
/// then `ArtworkPermissions.canTransfer` (frozen bit + owner / delegate arms,
/// and the parent-collection permanent freeze for Core). The v2 portfolio query
/// includes frozen and listed holdings so the chooser can explain a refused
/// transfer instead of silently omitting the artwork. Webapp parity:
/// `useCanTransfer` refuses whenever the on-chain listing PDA exists,
/// for every token standard.
///
/// Resolved on tap rather than by filtering rows: the permission check is a
/// per-mint DAS round-trip, so pre-filtering a paginated grid would cost one
/// call per tile — and a silently missing tile is exactly the "unexplained
/// failure" this is trying to remove. Explaining at the point of action mirrors
/// what the rest of the app does with a refused action
/// (`ensureSufficientBalance`, `handleFlowDisabled`). The portfolio query may
/// include every wallet in the active session, so assets that need a different
/// signer or an unsupported permission path can still explain their refusal.
@visibleForTesting
Future<String?> transferBlockedReason(PortfolioArtwork artwork) async {
  final chain = nftTransferFlowKey(
    mintAccount: artwork.mintAccount,
    chain: artwork.chain,
  ).chain;
  if (!AppFlow.nftTransfer.chains.contains(chain)) {
    return "${chain.label} artworks can't be transferred from the app yet — "
        'transfers are available on ${flowChainsLabel(AppFlow.nftTransfer)}.';
  }
  if (ArtworkPermissionService.isListedForSale(
    listingType: artwork.listingType,
  )) {
    return 'This artwork is listed for sale. Cancel the listing before '
        'transferring it.';
  }
  final permissions = await sl<ArtworkPermissionService>().checkPermissions(
    artwork.mintAccount,
    listingType: artwork.listingType,
  );
  if (permissions.canTransfer) return null;
  return "This artwork can't be transferred from this wallet — it may be "
      'frozen, delegated, or held by another wallet.';
}

/// Entry screen for the FAB "Transfer" action — the FAB has no artwork in
/// context, so the user first picks an owned artwork here and the transfer
/// flow runs on top.
///
/// Reuses the listing-flow [SelectArtworkStep] UI, but loads the cross-chain
/// portfolio (`nonPrintableOnly: false`, so master editions, 1/1s, and prints
/// are all eligible). On a confirmed transfer the artwork has left the wallet,
/// so the screen pops back home.
class TransferArtworkChooserScreen extends StatefulWidget {
  const TransferArtworkChooserScreen({super.key});

  @override
  State<TransferArtworkChooserScreen> createState() =>
      _TransferArtworkChooserScreenState();
}

class _TransferArtworkChooserScreenState
    extends State<TransferArtworkChooserScreen> {
  /// Guards against a second tap while the permission round-trip is in flight.
  bool _checking = false;

  Future<void> _onSelected(PortfolioArtwork artwork) async {
    if (_checking) return;
    setState(() => _checking = true);
    final String? blocked;
    try {
      blocked = await transferBlockedReason(artwork);
    } catch (e) {
      // The gate exists to explain a refused tap. An escaped throw would clear
      // the spinner and do nothing at all — the silent failure it's here to
      // eliminate — so a failed check refuses out loud too.
      debugPrint('[TransferArtworkChooser] Transfer gate failed: $e');
      if (mounted) {
        AppSnackBar.show(
          context,
          "Couldn't check this artwork right now. Please try again.",
          type: AppSnackBarType.error,
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (!mounted) return;
    if (blocked != null) {
      AppSnackBar.show(context, blocked);
      return;
    }
    final transferred = await runTransferArtworkFlow(context, artwork: artwork);
    // The success pipeline already confirms the transfer; on a confirmed
    // send the artwork is gone, so return the user home. A cancelled flow
    // (false) leaves them here to pick another artwork.
    if (transferred && mounted) context.pop();
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
              const MallowHeader(title: 'Transfer artwork'),
              const SizedBox(height: MallowTheme.spacing20),
              Expanded(
                child: SelectArtworkStep(
                  selectedMint: null,
                  nonPrintableOnly: false,
                  artworksLoader: () =>
                      sl<PortfolioRepository>().getOwnedArtworks(),
                  emptyStateMessage: "You don't own any transferrable artworks",
                  onSelected: _onSelected,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
