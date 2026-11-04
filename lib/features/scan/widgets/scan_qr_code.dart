import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/remote_config_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/deep_link_handler_registry.dart';
import '../../../di.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../send/widgets/send_qr_scanner_view.dart';
import '../../send/widgets/send_sheet.dart';
import '../../walletconnect/walletconnect_module.dart';
import '../models/scanned_code.dart';
import '../services/scanned_code_router.dart';
import 'send_to_address_sheet.dart';

/// Opens the camera from the account menu and opens what the code holds: a
/// WalletConnect pairing, a wallet address to send to, a payment request, a
/// link of the app's own, or a website.
///
/// A code the app cannot open is refused inside the scanner, which keeps
/// reading, so a stray code in view never closes it.
Future<void> scanQrCode(BuildContext context) async {
  String? refused;
  final code = await Navigator.of(context, rootNavigator: true)
      .push<ScannedCode>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (routeContext) => SendQrScannerView(
            offersPaste: false,
            onDetect: (capture) {
              final raw = capture.barcodes.firstOrNull?.rawValue;
              if (raw == null) return;
              // Detection fires repeatedly; only the first hit may pop.
              final route = ModalRoute.of(routeContext);
              if (route == null || !route.isCurrent) return;
              final code = ScannedCode.parse(raw);
              if (code is UnsupportedCode) {
                // Said once per code, not on every frame it stays in view.
                if (raw == refused) return;
                refused = raw;
                AppSnackBar.show(
                  routeContext,
                  code.message,
                  type: AppSnackBarType.error,
                );
                return;
              }
              Navigator.of(routeContext).pop(code);
            },
            onClose: () => Navigator.of(routeContext).pop(),
          ),
        ),
      );
  if (code == null) return;
  BuildContext? target() =>
      context.mounted ? context : AppRoutes.rootNavigatorKey.currentContext;
  ScannedCodeRouter(
    handlers: sl<DeepLinkHandlerRegistry>(),
    connect: handleWalletConnectText,
    sendTo: (recipient) {
      final at = target();
      if (at != null && at.mounted) {
        unawaited(showSendToAddressSheet(at, recipient));
      }
    },
    pay: (request) {
      final at = target();
      if (at != null && at.mounted) {
        unawaited(showSendSheet(at, payment: request));
      }
    },
    push: (location, {extra}) {
      final at = target();
      if (at != null && at.mounted) at.push(location, extra: extra);
    },
    browserEnabled: () => sl<RemoteConfigService>().config.value.browserEnabled,
    showMessage: (message) {
      final at = target();
      if (at == null || !at.mounted) return;
      AppSnackBar.show(at, message, type: AppSnackBarType.error);
    },
  ).open(code);
}
