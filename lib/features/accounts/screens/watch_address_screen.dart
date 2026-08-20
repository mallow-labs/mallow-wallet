import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/crypto/ens_resolver.dart';
import '../../../core/crypto/sns_resolver.dart';
import '../../../core/models/account.dart';
import '../../../core/router/app_router.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/utils/address_format.dart' show isLikelySolanaAddress;
import '../../../di.dart';
import '../../home/widgets/drawer_signal.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart' show isEthereumAddress;
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';

/// Whether a raw (non-domain) [input] is a well-formed address on a chain the
/// watch flow supports.
///
/// A length-only check is not enough: `Chain.fromAddress` (used by
/// `addViewOnlyWallet`) falls through to Solana for anything it doesn't
/// recognise, so a truncated EVM address (`0x…`, 41 chars) or non-base58
/// garbage inside the 32–44 range would be persisted as a bogus "Solana"
/// watch wallet — it then rides along in every feed read, permanently empty,
/// with nothing telling the user why.
@visibleForTesting
bool isWatchableAddress(String input) {
  // Anything 0x-prefixed is meant to be EVM; require the full 40 hex chars
  // rather than letting a mistyped one fall back to the base58 branch.
  if (input.startsWith('0x')) return isEthereumAddress(input);
  // Tezos (`tz1…`/`KT1…`) addresses are base58 in the same 32–44 range, so
  // this also admits them — `Chain.fromAddress` tags those Tezos.
  return isLikelySolanaAddress(input);
}

/// Screen for adding a view-only (watch) wallet.
///
/// Supports entering a Solana or Ethereum address, or a `.sol`/`.eth` domain.
class WatchAddressScreen extends StatefulWidget {
  const WatchAddressScreen({required this.accountId, super.key});

  final String accountId;

  @override
  State<WatchAddressScreen> createState() => _WatchAddressScreenState();
}

class _WatchAddressScreenState extends State<WatchAddressScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _isLoading = false;
  bool _isResolving = false;
  String? _resolvedAddress;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onInputChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _error = null;
      _resolvedAddress = null;
      _isResolving = false;
    });

    final trimmed = value.trim();
    if (!_isDomain(trimmed)) return;

    setState(() => _isResolving = true);
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      // Re-check in case text changed during the delay
      if (_controller.text.trim() != trimmed) return;

      final resolved = await _resolveDomain(trimmed);
      if (!mounted || _controller.text.trim() != trimmed) return;

      setState(() {
        _isResolving = false;
        if (resolved != null) {
          _resolvedAddress = resolved;
        } else {
          _error = 'Could not resolve domain';
        }
      });
    });
  }

  /// True when the input is a resolvable name (`.sol` or `.eth`) rather than a
  /// raw address.
  bool _isDomain(String input) =>
      SnsResolver.isSolDomain(input) || EnsResolver.isEthDomain(input);

  /// Resolve a `.sol`/`.eth` domain to its address, or null if unresolvable.
  Future<String?> _resolveDomain(String input) async {
    if (SnsResolver.isSolDomain(input)) return SnsResolver.resolve(input);
    if (EnsResolver.isEthDomain(input)) return EnsResolver.resolve(input);
    return null;
  }

  bool get _canContinue => _controller.text.trim().isNotEmpty && !_isLoading;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mallowColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 8),
              const MallowHeader(title: 'Watch address'),
              const SizedBox(height: 32),
              // Eye icon
              MallowSvgIcon(
                'assets/icons/watch.svg',
                width: 72,
                height: 72,
                color: context.mallowColors.textSecondary,
              ),
              const SizedBox(height: MallowTheme.spacingSm),
              Text(
                'Enter the wallet you want to watch',
                style: MallowTheme.uiMeta.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              MallowPillField(
                controller: _controller,
                hintText: 'Address or .sol/.eth domain',
                errorText: _error,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: _onInputChanged,
              ),
              if (_isResolving) ...[
                const SizedBox(height: MallowTheme.spacingSm),
                Row(
                  children: [
                    MallowLoader(
                      size: 12,
                      color: context.mallowColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Resolving...',
                      style: MallowTheme.uiCaption.copyWith(
                        color: context.mallowColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ] else if (_resolvedAddress != null) ...[
                const SizedBox(height: MallowTheme.spacingSm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _resolvedAddress!,
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              MallowButton(
                label: _isLoading ? 'Resolving...' : 'Continue',
                onPressed: _canContinue ? _onContinue : null,
                isFullWidth: true,
                enabled: _canContinue,
                isLoading: _isLoading,
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onContinue() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String address;

      if (_isDomain(input)) {
        // Use already-resolved address if available, otherwise resolve now
        final resolved = _resolvedAddress ?? await _resolveDomain(input);
        if (resolved == null) {
          setState(() {
            _error = 'Could not resolve domain';
            _isLoading = false;
          });
          return;
        }
        address = resolved;
      } else {
        if (!isWatchableAddress(input)) {
          setState(() {
            _error = 'Invalid address';
            _isLoading = false;
          });
          return;
        }
        address = input;
      }

      final repo = sl<WalletRepository>();

      final wallets = await repo.getAllWallets();
      final watchCount = wallets
          .where((w) => w.walletType == WalletType.viewOnly)
          .length;
      final name = 'Watch wallet ${watchCount + 1}';
      final wallet = await repo.addViewOnlyWallet(address, name);

      // Take the new account along — not just the wallet — so the drawer/home
      // header shows "Account NN" + dicebear avatar (matching mnemonic/ledger
      // import) instead of falling back to the "Watch wallet 1" local label.
      // Skip the switch when the active Profile already links this address, so
      // the user stays on their Profile rather than jumping to the new account.
      final session = sl<SessionManager>();
      if (!session.activeProfileContainsAnyAddress([wallet.address])) {
        await session.switchToWallet(wallet.id);
      }

      if (mounted) {
        AppSnackBar.show(context, 'Watch wallet added');
        DrawerSignal.showAccountsOnNextOpen = true;
        context.go(AppRoutes.home);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to add wallet: $e';
          _isLoading = false;
        });
      }
    }
  }
}
