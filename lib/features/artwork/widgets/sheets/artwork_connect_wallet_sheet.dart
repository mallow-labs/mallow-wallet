import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/auth_service.dart';
import '../../../../di.dart';
import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/widgets/app_snack_bar.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_sheet_frame.dart';

/// Bottom sheet shown when no wallet is connected. The CTA label is chosen
/// upstream to match the action the connected wallet would unlock — see the
/// "Connect-Wallet Variants" table in `docs/artwork_state.md`.
class ArtworkConnectWalletSheet extends StatefulWidget {
  const ArtworkConnectWalletSheet({
    required this.label,
    this.subtitle,
    super.key,
  });

  /// e.g. "Sign in to buy", "Sign in to make offer", "Sign in to place bid".
  final String label;

  /// Optional context line above the CTA (e.g. listing price summary).
  final String? subtitle;

  @override
  State<ArtworkConnectWalletSheet> createState() =>
      _ArtworkConnectWalletSheetState();
}

class _ArtworkConnectWalletSheetState extends State<ArtworkConnectWalletSheet> {
  bool _signingIn = false;

  /// Re-establishes the backend session for the active local wallet.
  ///
  /// There is no separate "connect a wallet" identity in this app — the
  /// signing wallet *is* the account, and the router keeps every main-app
  /// route behind wallet creation. So `AuthService.currentAddress` is null
  /// only when a wallet exists but its login does not: the window inside
  /// [AuthService.switchWallet] between `_clearSession()` and the new login,
  /// or a switch whose login threw (offline / backend down).
  ///
  /// [AuthService.refresh] falls through to `initializeSession()` in exactly
  /// that state, which logs the active wallet back in — the same call
  /// `SessionInitializer` makes at startup.
  Future<void> _signIn() async {
    if (_signingIn) return;
    setState(() => _signingIn = true);
    try {
      await sl<AuthService>().refresh();
      if (!mounted) return;
      // Re-resolve the action state now the address is back, so the sheet
      // swaps to the real CTA instead of sitting on a stale sign-in prompt.
      context.read<ArtworkBloc>().add(const ArtworkEvent.refresh());
    } catch (_) {
      if (mounted) {
        AppSnackBar.show(
          context,
          'Could not sign in. Check your connection and try again.',
          type: AppSnackBarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final subtitle = widget.subtitle;

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle != null) ...[
            Text(
              subtitle,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: MallowTheme.spacingSm),
          ],
          MallowButton(
            label: widget.label,
            onPressed: _signIn,
            isLoading: _signingIn,
            isFullWidth: true,
          ),
        ],
      ),
    );
  }
}
