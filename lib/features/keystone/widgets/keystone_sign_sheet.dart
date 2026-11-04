import 'dart:async';

import 'package:flutter/material.dart';
import 'package:keystone_ur/keystone_ur.dart';

import '../../../core/services/keystone_sign_service.dart';
import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import 'animated_ur_qr.dart';
import 'ur_scanner_view.dart';

/// The two halves of one QR round trip.
enum _Step { showRequest, scanSignature }

/// Runs one Keystone signature: shows the request for the device to scan,
/// then reads the signature the device shows back.
///
/// The sheet decides nothing about the reply itself — every scanned code goes
/// through [KeystoneSignPrompt.validate], and only an accepted one completes
/// the prompt. A rejected code (a stale signature, another device) keeps the
/// scanner open with the reason, so the user rescans instead of starting over.
class KeystoneSignSheet extends StatefulWidget {
  const KeystoneSignSheet({required this.prompt, super.key});

  final KeystoneSignPrompt prompt;

  @override
  State<KeystoneSignSheet> createState() => _KeystoneSignSheetState();
}

class _KeystoneSignSheetState extends State<KeystoneSignSheet> {
  _Step _step = _Step.showRequest;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // The flow that asked can cancel underneath the sheet (a navigation away,
    // a browser tab closing). Close with it rather than leave a QR up for a
    // request nobody is waiting on.
    widget.prompt.completer.future.then(
      (_) {},
      onError: (Object _) {
        _close();
      },
    );
  }

  @override
  void dispose() {
    // Dismissed by a drag or the back gesture: that is a cancel.
    widget.prompt.cancel();
    super.dispose();
  }

  Future<String?> _onScanned(UR reply) async {
    final rejection = await widget.prompt.validate(reply);
    // Cancellation can close the route while validation is still in flight;
    // the exit animation keeps this state mounted until well after the pop.
    if (!mounted || widget.prompt.completer.isCompleted) return null;
    if (rejection != null) return rejection;
    widget.prompt.completer.complete(reply);
    _close();
    return null;
  }

  void _close() {
    if (!mounted || _closing) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _closing = true;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      // A permission sheet can cover this one when the flow cancels. Remove
      // only our route so neither that sheet nor the host page is popped.
      navigator.removeRoute(route);
    }
  }

  void _cancel() {
    if (widget.prompt.completer.isCompleted) {
      _close();
    } else {
      widget.prompt.cancel();
      // The completer's error listener closes the sheet.
    }
  }

  String get _what => switch (widget.prompt.purpose) {
    KeystoneSignPurpose.transaction => 'transaction',
    KeystoneSignPurpose.message => 'message',
  };

  /// The signing address, then the position in a batch when there is one.
  String get _subtitle {
    final address = truncateAddress(widget.prompt.address);
    final index = widget.prompt.index;
    final total = widget.prompt.total;
    if (index == null || total == null || total <= 1) return address;
    return '$address • Transaction ${index + 1} of $total';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SheetDragHandle(),
                const SizedBox(height: 8),
                Text(
                  'Sign with Keystone',
                  style: MallowTheme.editorialSection.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _subtitle,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                if (widget.prompt.notice case final notice?) ...[
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.surfaceMuted,
                        border: Border.all(color: colors.warning),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        notice,
                        style: MallowTheme.uiBodyRelaxed.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                ...switch (_step) {
                  _Step.showRequest => _requestStep(context),
                  _Step.scanSignature => _scanStep(context),
                },
                const SizedBox(height: 8),
                MallowButton(
                  label: 'Cancel',
                  variant: MallowButtonVariant.text,
                  isFullWidth: true,
                  onPressed: _cancel,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _requestStep(BuildContext context) {
    final colors = context.mallowColors;
    return [
      Text(
        'On your Keystone, tap Scan and point it at this code. Check the '
        '$_what on the device before you approve it.',
        style: MallowTheme.uiBodyRelaxed.copyWith(color: colors.textSecondary),
      ),
      const SizedBox(height: 16),
      Center(child: AnimatedUrQr(ur: widget.prompt.request)),
      const SizedBox(height: 20),
      MallowButton(
        label: 'Scan the signature',
        isFullWidth: true,
        onPressed: () => setState(() => _step = _Step.scanSignature),
      ),
    ];
  }

  List<Widget> _scanStep(BuildContext context) {
    return [
      UrScannerView(
        expectedTypes: {widget.prompt.replyType},
        hint:
            'Once you approve on the Keystone, it shows a code. Scan it '
            'here.',
        onScanned: _onScanned,
        captionAlign: TextAlign.start,
        unexpectedTypeError:
            "That isn't a signature. Scan the code your Keystone shows "
            'after you approve.',
      ),
      const SizedBox(height: 16),
      MallowButton(
        label: 'Show the request again',
        variant: MallowButtonVariant.secondary,
        isFullWidth: true,
        onPressed: () => setState(() => _step = _Step.showRequest),
      ),
    ];
  }
}

/// Shows [KeystoneSignSheet] for [prompt] over the root navigator.
Future<void> showKeystoneSignSheet(
  BuildContext context,
  KeystoneSignPrompt prompt,
) => showMallowSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => KeystoneSignSheet(prompt: prompt),
);
