import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import 'chain_visuals.dart';

import '../../../shared/utils/chain.dart';

/// Shows the Receive bottom sheet: the wallet address as a QR code and text,
/// with copy-to-clipboard.
///
/// Defaults to the active wallet's address on [chain]; pass [address] to show a
/// specific wallet's QR without switching the active wallet (per-wallet receive
/// from the switcher). [chain] drives the centered mark, the resolved default
/// address and the "only send …" warning (defaults to Solana for the
/// active-wallet case).
///
/// The sheet shows exactly one address and offers no in-sheet wallet switch —
/// picking between session wallets is the caller's job
/// (`showWalletsReceiveSheet`), which opens this sheet per wallet.
Future<void> showReceiveSheet(
  BuildContext context, {
  String? address,
  Chain chain = Chain.solana,
}) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ReceiveSheet(address: address, chain: chain),
  );
}

class _ReceiveSheet extends StatefulWidget {
  const _ReceiveSheet({this.address, this.chain = Chain.solana});

  final String? address;
  final Chain chain;

  @override
  State<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends State<_ReceiveSheet> {
  /// The single source of truth for everything the user can act on — the QR
  /// payload, the printed address and the clipboard target all read this one
  /// field, so they can never end up pointing at different wallets.
  String? _address;

  bool _copied = false;

  @override
  void initState() {
    super.initState();
    final explicit = widget.address;
    if (explicit != null) {
      _address = explicit;
    } else {
      unawaited(_loadAddress());
    }
  }

  /// Resolves the default address **for this sheet's chain**. Passing the chain
  /// is load-bearing: the chain-blind `getAddress()` this replaced always
  /// returned the active Solana address, so an Ethereum/Tezos sheet opened
  /// without an explicit address rendered a Solana address under an ETH glyph
  /// and "Only send Ethereum tokens" copy.
  Future<void> _loadAddress() async {
    final walletManager = sl<WalletManager>();
    String? address;
    try {
      final active = await walletManager.getAddress(chain: widget.chain);
      // `getAddress` resolves a non-Solana chain from the active *account*,
      // whose ETH/Tezos siblings a Profile session need not link. Handing out
      // that address would invite funds to a wallet outside the session, so it
      // only counts when it is one of this chain's session candidates.
      address = sl<SessionManager>().scopedToSession(active);
    } on Object {
      // No wallet selected on this chain — fall through to a session candidate
      // rather than spinning on the loader forever.
    }
    // Falling back to a session wallet on this chain, view-only included — you
    // can always receive into an address you can't sign for.
    address ??= sl<SessionManager>()
        .sessionWalletsForChain(widget.chain)
        .firstOrNull
        ?.address;
    if (!mounted || address == null) return;
    final resolved = address;
    setState(() => _address = resolved);
  }

  Future<void> _copyAddress() async {
    final address = _address;
    if (address == null) return;

    await Clipboard.setData(ClipboardData(text: address));
    unawaited(HapticFeedback.lightImpact());
    setState(() => _copied = true);
    if (mounted) {
      AppSnackBar.show(
        context,
        'Address copied to clipboard',
        type: AppSnackBarType.success,
        duration: const Duration(seconds: 2),
      );
    }

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bottomPad = sheetBottomInset(context);
    final address = _address;

    return Container(
      decoration: BoxDecoration(
        color: colors.bgPrimary,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MallowTheme.spacing20,
              0,
              MallowTheme.spacing20,
              MallowTheme.spacing20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MallowHeader(
                  title: 'Receive',
                  onBack: () => Navigator.of(context).pop(),
                ),
                if (address == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 96),
                    child: Center(child: MallowLoader()),
                  )
                else ...[
                  const SizedBox(height: MallowTheme.spacingLg),
                  Center(
                    child: _QrCode(
                      // Keyed on the address so the QR is rebuilt from scratch
                      // on a switch — and so a test can prove the QR moved with
                      // the printed address (the encoded payload is not
                      // readable back off PrettyQrView).
                      key: ValueKey('receive-qr-$address'),
                      address: address,
                      chain: widget.chain,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  Text(
                    address,
                    textAlign: TextAlign.center,
                    style: MallowTheme.uiBody.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  Text(
                    'Only send ${widget.chain.label} tokens '
                    'to this address',
                    textAlign: TextAlign.center,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: MallowButton(
                          label: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                          variant: MallowButtonVariant.secondary,
                        ),
                      ),
                      const SizedBox(width: MallowTheme.spacing12),
                      Expanded(
                        child: MallowButton(
                          label: _copied ? 'Copied' : 'Copy',
                          onPressed: _copyAddress,
                          svgAsset: _copied
                              ? 'assets/icons/checkmark.svg'
                              : 'assets/icons/copy.svg',
                        ),
                      ),
                    ],
                  ),
                ],
                SizedBox(height: bottomPad),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The white QR card with the chain mark centered over it.
class _QrCode extends StatelessWidget {
  const _QrCode({required this.address, required this.chain, super.key});

  final String address;
  final Chain chain;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(MallowTheme.spacingMd),
            decoration: BoxDecoration(
              // QR code uses literal white for scannability.
              color: Colors.white,
              borderRadius: BorderRadius.circular(MallowTheme.radiusMd),
            ),
            child: PrettyQrView.data(
              data: address,
              // High correction tolerates the centered logo overlay.
              errorCorrectLevel: QrErrorCorrectLevel.H,
              decoration: const PrettyQrDecoration(
                // White card already provides the quiet-zone margin.
                quietZone: PrettyQrQuietZone.zero,
                // Connected modules with rounded ends/turns (only exposed
                // corners are rounded; adjacent modules flow together).
                shape: PrettyQrSmoothSymbol(
                  color: Color(0xFF121212),
                  roundFactor: 0.8,
                ),
              ),
            ),
          ),
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(MallowTheme.spacingSm),
            ),
            // Tint to the QR module color so all three marks read as one dark
            // glyph — the raw ethereum/tezos assets are exported gray (#A1A1A1),
            // which clashes with solana's dark mark under `useOriginalColors`.
            child: ChainGlyph(
              chain: chain,
              size: 28,
              color: const Color(0xFF121212),
            ),
          ),
        ],
      ),
    );
  }
}
