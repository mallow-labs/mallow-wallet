import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';

import '../../../core/services/ledger_service.dart';
import '../../../di.dart';
import '../../../shared/widgets/loading_indicator.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../services/ledger_auth_service.dart';

/// Verify-specific phases layered over the shared [LedgerSessionState]. The
/// session covers scan → connect; this enum covers what happens once the
/// device is ready and the user taps "Sign transaction".
enum _VerifyPhase { idle, signing, success, errored }

/// Bottom sheet shown when a Ledger wallet receives a 401 "Signature required".
///
/// Delegates scan → connect → ready to [LedgerAuthService.sessionState] and
/// the memo-sign + backend verify + JWT cache to
/// [LedgerAuthService.verifyOwnership].
class LedgerVerifySheet extends StatefulWidget {
  const LedgerVerifySheet({
    required this.address,
    required this.completer,
    super.key,
  });

  final String address;
  final Completer<bool> completer;

  @override
  State<LedgerVerifySheet> createState() => _LedgerVerifySheetState();
}

class _LedgerVerifySheetState extends State<LedgerVerifySheet> {
  final _auth = sl<LedgerAuthService>();

  late StreamSubscription<LedgerSessionState> _sessionSub;
  StreamSubscription<LedgerSigningState>? _signingSub;

  late LedgerSessionState _session;
  _VerifyPhase _phase = _VerifyPhase.idle;
  String? _errorMessage;

  /// The Ledger app the user must open for this wallet, inferred from the
  /// address shape.
  String get _blockchainName => Chain.fromAddress(widget.address).label;

  /// Solana verifies by signing a memo *transaction*; Ethereum and Tezos sign
  /// an off-chain *message*. Drives the verify copy so it matches what the
  /// device actually prompts for.
  String get _signArtifact =>
      isEthereumAddress(widget.address) || isTezosAddress(widget.address)
      ? 'message'
      : 'transaction';

  @override
  void initState() {
    super.initState();
    _session = _auth.currentState;
    _sessionSub = _auth.sessionState.listen(_onSession);

    if (!_auth.isConnected) {
      unawaited(_auth.startScan());
    }
  }

  @override
  void dispose() {
    _sessionSub.cancel();
    _signingSub?.cancel();
    // Drop the in-memory device list so a re-opened sheet starts with a
    // fresh scan instead of showing devices from the previous session.
    // LedgerAuthService is a singleton, so without this the list survives.
    _auth.clearDevices();
    if (!widget.completer.isCompleted) {
      widget.completer.complete(false);
    }
    super.dispose();
  }

  void _onSession(LedgerSessionState state) {
    if (!mounted) return;
    setState(() => _session = state);
    // If the device drops mid-signing, downgrade to error state.
    if (state is LedgerSessionDisconnected && _phase == _VerifyPhase.signing) {
      setState(() {
        _phase = _VerifyPhase.errored;
        _errorMessage = 'Ledger disconnected during signing.';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Verify flow
  // ---------------------------------------------------------------------------

  Future<void> _verify() async {
    setState(() {
      _phase = _VerifyPhase.signing;
      _errorMessage = null;
    });

    // Surface device-side rejection / timeout with more specific copy.
    await _signingSub?.cancel();
    _signingSub = _auth.signingState.listen((sigState) {
      if (!mounted) return;
      if (sigState == LedgerSigningState.rejected) {
        setState(() {
          _phase = _VerifyPhase.errored;
          _errorMessage = 'Signing request rejected on Ledger device.';
        });
      } else if (sigState == LedgerSigningState.timeout) {
        setState(() {
          _phase = _VerifyPhase.errored;
          _errorMessage = 'Signing timed out. Please try again.';
        });
      }
    });

    try {
      await _auth.verifyOwnership(widget.address);

      if (!mounted) return;
      setState(() => _phase = _VerifyPhase.success);
      if (!widget.completer.isCompleted) {
        widget.completer.complete(true);
      }
      if (mounted) Navigator.of(context).pop();
    } on LedgerDeviceException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _VerifyPhase.errored;
        _errorMessage = LedgerAuthService.describeLedgerError(
          e.errorCode,
          widget.address,
        );
      });
    } on LedgerException {
      // The signing-state listener already set a specific error message;
      // only set a generic one if the listener never fired.
      if (mounted && _phase == _VerifyPhase.signing) {
        setState(() {
          _phase = _VerifyPhase.errored;
          _errorMessage = 'Ledger signing failed. Please try again.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _VerifyPhase.errored;
        _errorMessage = e.toString();
      });
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.mallowColors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetDragHandle(),
              const SizedBox(height: 8),
              Text(
                'Verify Wallet',
                style: MallowTheme.uiBody.copyWith(
                  color: context.mallowColors.textPrimary,
                ),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: 8),
              _buildBody(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_phase) {
      case _VerifyPhase.signing:
        return _buildSigningView(context);
      case _VerifyPhase.success:
        return _buildSuccessView(context);
      case _VerifyPhase.errored:
        return _buildErrorView(context);
      case _VerifyPhase.idle:
        return _buildSessionView(context);
    }
  }

  Widget _buildSessionView(BuildContext context) {
    final session = _session;
    if (session is LedgerSessionConnecting) {
      return _buildConnectingView(context);
    }
    if (session is LedgerSessionConnected) {
      return _buildReadyView(context);
    }
    if (session is LedgerSessionError) {
      return _buildErrorView(context, override: session.message);
    }
    final scanning = session is LedgerSessionScanning ? session : null;
    return _buildScanView(
      context,
      devices: scanning?.devices ?? const [],
      active: scanning?.active ?? false,
    );
  }

  Widget _buildScanView(
    BuildContext context, {
    required List<LedgerDevice> devices,
    required bool active,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Connect your Ledger device to verify your wallet.',
          textAlign: TextAlign.center,
          style: MallowTheme.uiBodyRelaxed.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Make sure Bluetooth is enabled and the $_blockchainName app is open.',
          textAlign: TextAlign.center,
          style: MallowTheme.uiMeta.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        if (devices.isEmpty) ...[
          if (active) ...[
            const MallowLoader(size: 24),
            const SizedBox(height: 12),
            Text(
              'Searching for devices...',
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
          ] else ...[
            Text(
              'No devices found.',
              style: MallowTheme.uiBody.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _auth.startScan(),
              child: Text(
                'Scan again',
                style: MallowTheme.uiBody.copyWith(
                  fontWeight: FontWeight.w500,
                  color: context.mallowColors.textPrimary,
                ),
              ),
            ),
          ],
        ] else ...[
          ...devices.map(
            (device) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () =>
                    _auth.connectDevice(device, expectedApp: _blockchainName),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: context.mallowColors.bgPrimary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      MallowSvgIcon(
                        'assets/icons/bluetooth.svg',
                        width: 20,
                        height: 20,
                        color: context.mallowColors.textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          device.name,
                          style: MallowTheme.uiBody.copyWith(
                            fontWeight: FontWeight.w500,
                            color: context.mallowColors.textPrimary,
                          ),
                        ),
                      ),
                      MallowSvgIcon(
                        'assets/icons/arrow_right.svg',
                        width: 20,
                        height: 20,
                        color: context.mallowColors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (!active)
            TextButton(
              onPressed: () => _auth.startScan(),
              child: Text(
                'Scan again',
                style: MallowTheme.uiBody.copyWith(
                  fontWeight: FontWeight.w500,
                  color: context.mallowColors.textPrimary,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildConnectingView(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        const MallowLoader(size: 24),
        const SizedBox(height: 16),
        Text(
          'Connecting...',
          style: MallowTheme.uiBody.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildReadyView(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Sign a $_signArtifact to verify ownership of your wallet. '
          'This does not involve the $_blockchainName network.',
          textAlign: TextAlign.center,
          style: MallowTheme.uiBodyRelaxed.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        const SizedBox(height: 24),
        MallowButton(
          label: 'Sign $_signArtifact',
          onPressed: _verify,
          isFullWidth: true,
        ),
      ],
    );
  }

  Widget _buildSigningView(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        MallowSvgIcon(
          'assets/icons/shield.svg',
          width: 48,
          height: 48,
          color: context.mallowColors.textPrimary,
        ),
        const SizedBox(height: 16),
        Text(
          'Confirm on Ledger',
          style: MallowTheme.uiIdentity.copyWith(
            fontWeight: FontWeight.w600,
            color: context.mallowColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Review and approve the $_signArtifact on your Ledger device.',
          textAlign: TextAlign.center,
          style: MallowTheme.uiBodyRelaxed.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        const SizedBox(height: 24),
        const MallowLoader(size: 24),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSuccessView(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: context.mallowColors.accent, width: 2),
          ),
          alignment: Alignment.center,
          child: MallowSvgIcon(
            'assets/icons/checkmark.svg',
            width: 26,
            height: 26,
            color: context.mallowColors.accent,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Wallet verified',
          style: MallowTheme.uiIdentity.copyWith(
            fontWeight: FontWeight.w600,
            color: context.mallowColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildErrorView(BuildContext context, {String? override}) {
    final message = override ?? _errorMessage ?? 'Something went wrong.';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        MallowSvgIcon(
          'assets/icons/alert_triangle.svg',
          width: 48,
          height: 48,
          color: context.mallowColors.error,
        ),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: MallowTheme.uiBodyRelaxed.copyWith(
            color: context.mallowColors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        MallowButton(
          label: 'Try again',
          onPressed: () {
            if (_auth.isConnected) {
              setState(() {
                _phase = _VerifyPhase.idle;
                _errorMessage = null;
              });
              _verify();
            } else {
              setState(() {
                _phase = _VerifyPhase.idle;
                _errorMessage = null;
              });
              _auth.startScan();
            }
          },
          isFullWidth: true,
        ),
      ],
    );
  }
}
