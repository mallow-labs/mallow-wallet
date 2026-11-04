import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/models/account.dart' show WalletType;
import '../../../core/services/signing_copy.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';

/// Where a `signAndSendTransaction` request stands in its sheet.
sealed class BrowserSendStep {
  const BrowserSendStep();
}

/// The user is still reading the review.
class BrowserSendReview extends BrowserSendStep {
  const BrowserSendReview();
}

/// Approved; step-up auth and signing are running.
class BrowserSendSigning extends BrowserSendStep {
  const BrowserSendSigning(this.walletType);

  /// Picks the signing copy. Null reads as a local key.
  final WalletType? walletType;
}

/// Approval did not end in a broadcast, for [message]. Nothing was sent.
class BrowserSendFailed extends BrowserSendStep {
  const BrowserSendFailed(this.message);

  final String message;
}

/// A browser transaction review that shows signing progress until the service
/// dismisses it. The website handles submission and confirmation status.
class BrowserSendSheet extends StatelessWidget {
  const BrowserSendSheet({
    required this.step,
    required this.review,
    required this.onClose,
    super.key,
  });

  final ValueListenable<BrowserSendStep> step;

  /// Shown while [step] is [BrowserSendReview].
  final Widget review;

  /// Closes exactly this sheet.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<BrowserSendStep>(
    valueListenable: step,
    builder: (context, step, _) => SheetStepSwitcher(
      child: step is BrowserSendReview
          ? KeyedSubtree(key: const ValueKey('review'), child: review)
          : KeyedSubtree(
              key: const ValueKey('pipeline'),
              child: _pipeline(step),
            ),
    ),
  );

  Widget _pipeline(BrowserSendStep step) => switch (step) {
    BrowserSendReview() || BrowserSendSigning() => TransactionPipelineSheet(
      phase: TransactionPipelinePhase.progress,
      label: _signingLabel(step),
      sublabel: _signingSublabel(step),
    ),
    BrowserSendFailed(:final message) => TransactionPipelineSheet(
      phase: TransactionPipelinePhase.error,
      label: kLocalSigningLabel,
      errorTitle: 'Transaction not sent',
      errorSublabel: message,
      onClose: onClose,
    ),
  };

  static String _signingLabel(BrowserSendStep step) =>
      _isLocal(step) ? kLocalSigningLabel : kExternalSigningLabel;

  static String _signingSublabel(BrowserSendStep step) {
    if (_isLocal(step)) return kLocalSigningSublabel;
    final type = step is BrowserSendSigning ? step.walletType : null;
    return switch (type) {
      WalletType.ledger => kLedgerSigningSublabel,
      WalletType.keystone => kKeystoneSigningSublabel,
      _ => kExternalSigningSublabel,
    };
  }

  /// HD and imported keys sign in-app with nothing to approve elsewhere; every
  /// other signer waits on an external prompt.
  static bool _isLocal(BrowserSendStep step) => switch (step) {
    BrowserSendSigning(:final walletType) =>
      walletType == null ||
          walletType == WalletType.hd ||
          walletType == WalletType.importedKey,
    _ => true,
  };
}
