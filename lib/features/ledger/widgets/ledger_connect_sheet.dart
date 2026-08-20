import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart';

import '../../../di.dart';
import '../../../shared/widgets/loading_indicator.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../services/ledger_auth_service.dart';

/// Bottom sheet shown when a Ledger wallet is about to sign but the device
/// isn't currently connected (cold start, inactivity timeout, out of range).
///
/// Scope is intentionally narrow: scan → connect → dismiss. The caller
/// resumes its signing flow once the [completer] resolves `true`.
///
/// The sheet is a thin view over [LedgerAuthService] — all BLE-session
/// state lives in the service so a Ledger flow doesn't have to choose
/// between this sheet and the verify sheet for shared scan/connect logic.
class LedgerConnectSheet extends StatefulWidget {
  const LedgerConnectSheet({
    required this.address,
    required this.completer,
    super.key,
  });

  /// Address of the wallet about to sign. Drives the "open the `<chain>` app"
  /// hint so the prompt matches the wallet's chain instead of always Solana.
  final String address;
  final Completer<bool> completer;

  @override
  State<LedgerConnectSheet> createState() => _LedgerConnectSheetState();
}

class _LedgerConnectSheetState extends State<LedgerConnectSheet> {
  final _auth = sl<LedgerAuthService>();
  late StreamSubscription<LedgerSessionState> _sub;
  late LedgerSessionState _state;

  /// Guards [_complete] so it pops exactly once. The session stream can emit
  /// `connected` more than once (the BLE connection-state stream *and*
  /// `connectDevice`'s explicit emit after `getOpenApp`). A route's State stays
  /// `mounted` through its pop animation, so without this a second event
  /// re-enters [_complete] and pops the route *underneath* this sheet — the
  /// send/sign sheet — tearing the signing flow down mid-approval.
  bool _completed = false;

  /// The Ledger app the user must open for this wallet, inferred from the
  /// address shape.
  String get _blockchainName => Chain.fromAddress(widget.address).label;

  @override
  void initState() {
    super.initState();
    _state = _auth.currentState;
    _sub = _auth.sessionState.listen(_onState);

    if (_auth.isConnected) {
      // Defer pop until the sheet is mounted; popping in initState pops
      // the navigator's currently-building route.
      WidgetsBinding.instance.addPostFrameCallback((_) => _complete(true));
      return;
    }

    unawaited(_auth.loadKnownDevices());
    unawaited(_auth.startScan());
  }

  @override
  void dispose() {
    _sub.cancel();
    // Drop the in-memory device list so a re-opened sheet starts with a
    // fresh scan instead of showing devices from the previous session.
    // LedgerAuthService is a singleton, so without this the list survives.
    _auth.clearDevices();
    if (!widget.completer.isCompleted) {
      widget.completer.complete(false);
    }
    super.dispose();
  }

  void _onState(LedgerSessionState state) {
    if (!mounted) return;
    setState(() => _state = state);
    if (state is LedgerSessionConnected) {
      _complete(true);
    }
  }

  void _complete(bool success) {
    // Fire once: a repeat `connected` event would otherwise pop the route
    // beneath this (already-popping) sheet.
    if (_completed) return;
    _completed = true;
    if (!widget.completer.isCompleted) {
      widget.completer.complete(success);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _retryScan() async {
    await _auth.loadKnownDevices();
    await _auth.startScan();
  }

  Future<void> _connectDevice(LedgerDevice device) =>
      _auth.connectDevice(device, expectedApp: _blockchainName);

  @override
  Widget build(BuildContext context) {
    return Container(
      // Pin to full width: the connecting/error bodies have no full-width
      // child (unlike the scan view's buttons/device rows), so without this
      // the bottom sheet collapses to content width and renders as a narrow
      // centred card.
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
                'Connect Ledger',
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
    final state = _state;
    if (state is LedgerSessionConnecting) {
      return _buildConnectingView(context);
    }
    if (state is LedgerSessionError) {
      return _buildErrorView(context, state.message);
    }
    final scanning = state is LedgerSessionScanning ? state : null;
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
          'Reconnect your Ledger device to continue.',
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
        ...devices.map(
          (device) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: () => _connectDevice(device),
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
        if (active) ...[
          const MallowLoader(size: 24),
          const SizedBox(height: 12),
          Text(
            devices.isEmpty
                ? 'Searching for devices...'
                : 'Still searching for more devices...',
            style: MallowTheme.uiBody.copyWith(
              color: context.mallowColors.textSecondary,
            ),
          ),
        ] else ...[
          if (devices.isEmpty) ...[
            Text(
              "We didn't find any Ledger devices nearby.",
              textAlign: TextAlign.center,
              style: MallowTheme.uiBodyRelaxed.copyWith(
                color: context.mallowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
          ] else
            const SizedBox(height: 4),
          MallowButton(
            label: 'Scan again',
            onPressed: _retryScan,
            isFullWidth: true,
            variant: MallowButtonVariant.secondary,
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

  Widget _buildErrorView(BuildContext context, String message) {
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
          onPressed: _retryScan,
          isFullWidth: true,
        ),
      ],
    );
  }
}
