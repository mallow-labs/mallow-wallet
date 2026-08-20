import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../../shared/widgets/pin_prompt_sheet.dart';
import '../config/remote_config.dart';
import '../config/remote_config_service.dart';
import '../router/app_router.dart';
import '../services/sentry_service.dart';
import 'biometric_auth.dart';
import 'secure_storage.dart';

/// Default USD threshold above which a signing surface must demand step-up
/// auth, used when the user hasn't configured their own.
///
/// Set by the wallet security review. The check is `> threshold` — a
/// transaction exactly at the threshold still passes without re-auth. The
/// effective threshold is user-configurable via
/// [SecureWalletStorage.storeTransactionAuthThresholdUsd]; this constant is
/// only the fallback default.
const double kTransactionAuthThresholdUsd = 100.0;

/// Copy shown when an unimplemented `(chain, flow)` cell reaches the signing
/// backstop. That is a bug, not a routine rejection — the UI should
/// never have offered the action — so it is reported to Sentry *and* surfaced
/// to the user rather than swallowed.
const String kUnsupportedFlowMessage =
    'This action is not supported on this network in this version of the app.';

/// Bland fallback for a killed cell whose operator message is empty.
///
/// Defined here rather than beside the sheet because both the backstop and the
/// entry-gate UI need it, and the client is allowed exactly one bland generic:
/// per-flow fallback copy would drift from the operator's wording and defeat
/// the reason the kill switch ships a message field at all. That rule only
/// holds if there is literally one — two copies of the same string in two
/// layers is how it quietly stops being true.
const String kFlowDisabledFallbackMessage =
    'This action is temporarily unavailable. Please try again later.';

/// Outcome of a [TransactionAuthGate.authorize] call.
///
/// Deliberately not an enum: [TransactionAuthOutcome.flowDisabled] carries the
/// operator's message from the remote kill switch. The other three stay const
/// singletons so the existing `outcome != TransactionAuthOutcome.allowed`
/// identity checks keep working unchanged. Not `sealed` either — mockito
/// generates a fake that `implements` this type for mocked gates.
class TransactionAuthOutcome {
  const TransactionAuthOutcome._(this._name, {this.disabledMessage});

  /// An operator has killed this `(chain, flow)` cell remotely, or the cell
  /// isn't implemented by this build at all. [message] is rendered verbatim —
  /// the server's copy for a kill, [kUnsupportedFlowMessage] for the bug case.
  /// Callers must abort.
  const TransactionAuthOutcome.flowDisabled(String message)
    : this._('flowDisabled', disabledMessage: message);

  /// Below threshold, or step-up auth succeeded.
  static const allowed = TransactionAuthOutcome._('allowed');

  /// User cancelled biometric, dismissed the PIN sheet, or entered the
  /// wrong PIN too many times. Callers must abort the signing flow.
  static const cancelled = TransactionAuthOutcome._('cancelled');

  /// Neither biometric nor an app PIN is set up, so we have no second
  /// factor to challenge with. Callers must abort — never sign in this
  /// state.
  static const unavailable = TransactionAuthOutcome._('unavailable');

  final String _name;

  /// Operator copy for the rejection — non-null only for
  /// [TransactionAuthOutcome.flowDisabled].
  final String? disabledMessage;

  /// True when the remote kill switch (or the unsupported-cell backstop)
  /// rejected this transaction.
  bool get isFlowDisabled => disabledMessage != null;

  @override
  String toString() => 'TransactionAuthOutcome.$_name';
}

/// Reports an unsupported `(chain, flow)` cell that reached the backstop.
/// Injectable so tests can observe the fail-loud path — [SentryService] is
/// static and no-ops without a DSN.
typedef UnsupportedFlowReporter = void Function(FlowKey flow);

void _reportUnsupportedFlowToSentry(FlowKey flow) {
  unawaited(
    SentryService.captureException(
      StateError('Unsupported flow cell reached the signing backstop: $flow'),
      message:
          'A UI surface offered $flow, which this build does not implement. '
          'The entry gate that should have hidden it is missing or wrong.',
      extras: {'chain': flow.chain.toDbString(), 'flow': flow.flow.wire},
    ),
  );
}

/// Gates transaction signing behind biometric / PIN re-auth when the
/// USD-equivalent outflow exceeds [kTransactionAuthThresholdUsd].
///
/// Fail-closed: when [usdValue] is `null` (e.g. price data unavailable or
/// the value couldn't be computed), auth is required. We cannot decide a
/// transaction is "small" without a price reference.
///
/// PIN fallback: if biometric is unavailable / not enrolled / no
/// credentials on the device, the gate falls back to an app-PIN sheet.
/// A user cancelling the biometric prompt itself is treated as a
/// cancellation — we don't second-guess the user's "no" with a PIN prompt.
///
/// It is also the **remote kill-switch backstop**: every signing path in the
/// app funnels through [authorize], so the per-`(chain, flow)` check at the
/// very top of it is the guarantee that a killed flow cannot be signed even
/// when an entry gate is missed or bypassed.
@lazySingleton
class TransactionAuthGate {
  @factoryMethod
  TransactionAuthGate(
    BiometricAuthService biometric,
    SecureWalletStorage storage,
    RemoteConfigService remoteConfig,
  ) : this.withReporter(
        biometric,
        storage,
        remoteConfig,
        _reportUnsupportedFlowToSentry,
      );

  /// Test seam for the fail-loud report.
  @visibleForTesting
  TransactionAuthGate.withReporter(
    this._biometric,
    this._storage,
    this._remoteConfig,
    this._reportUnsupportedFlow,
  );

  final BiometricAuthService _biometric;
  final SecureWalletStorage _storage;
  final RemoteConfigService _remoteConfig;
  final UnsupportedFlowReporter _reportUnsupportedFlow;

  /// Pure classification against an explicit [threshold] — true when
  /// [usdValue] is null or strictly greater than [threshold]. Private so it
  /// stays off the public interface (hand-written test fakes `implements`
  /// this class and would otherwise have to provide it).
  bool _exceedsThreshold(double? usdValue, double threshold) =>
      usdValue == null || usdValue > threshold;

  /// Pure classification against the built-in default threshold. Does not
  /// prompt and does not read the user's configured value — use [authorize]
  /// for the configured behaviour.
  bool requiresAuth(double? usdValue) =>
      _exceedsThreshold(usdValue, kTransactionAuthThresholdUsd);

  /// Run the gate. Returns [TransactionAuthOutcome.allowed] when step-up
  /// auth is disabled, the value is below the configured threshold, OR
  /// step-up auth succeeded.
  ///
  /// [flow] is the `(chain, flow)` cell this transaction belongs to. Both flow
  /// gates run on it **before anything else** — the local `isImplemented` arm,
  /// then the remote kill switch. See the comment in the body; moving either
  /// below the early returns would silently disarm the backstop.
  Future<TransactionAuthOutcome> authorize({
    required double? usdValue,
    required FlowKey flow,
  }) async {
    // ── THE TWO FLOW GATES — NOTHING MAY RUN BEFORE THEM ──
    // The local `isImplemented` arm first, the remote kill switch second.
    // Both early returns below (the master opt-in, which is OFF BY DEFAULT,
    // and the sub-threshold short-circuit) return `allowed`. A kill check
    // placed after either is inert for every user who hasn't turned step-up
    // auth on — i.e. most of them — and still passes casual testing, because
    // testers have it on. Do not move either of them below this point.
    if (!flow.flow.isImplemented(flow.chain)) {
      // The UI should never have offered this cell. That is a bug, not
      // a routine rejection — report it and surface a visible error rather
      // than silently allowing or silently blocking.
      _reportUnsupportedFlow(flow);
      return const TransactionAuthOutcome.flowDisabled(kUnsupportedFlowMessage);
    }
    final killed = _remoteConfig.config.value.disabledMessage(
      flow.chain,
      flow.flow,
    );
    if (killed != null) {
      // An operator who saved an empty message must still produce a visible
      // rejection, not a blank error.
      return TransactionAuthOutcome.flowDisabled(
        killed.isEmpty ? kFlowDisabledFallbackMessage : killed,
      );
    }

    // Master opt-in. Off by default — when disabled the gate never prompts,
    // regardless of value or configured threshold.
    if (!await _storage.loadTransactionAuthEnabled()) {
      return TransactionAuthOutcome.allowed;
    }

    final threshold =
        await _storage.loadTransactionAuthThresholdUsd() ??
        kTransactionAuthThresholdUsd;
    if (!_exceedsThreshold(usdValue, threshold)) {
      return TransactionAuthOutcome.allowed;
    }

    final biometricEnabled = await _storage.loadBiometricEnabled();
    if (biometricEnabled) {
      final result = await _biometric.authenticateForTransaction();
      if (result.isSuccess) return TransactionAuthOutcome.allowed;
      // User-initiated cancel / wrong biometric → respect it. Do not
      // immediately re-prompt with PIN.
      if (result == BiometricAuthResult.failed) {
        return TransactionAuthOutcome.cancelled;
      }
      // notAvailable / notEnrolled / lockedOut / passcodeNotSet / error
      // → fall through to PIN fallback below.
    }

    final hasPin = await _storage.hasPin();
    if (!hasPin) return TransactionAuthOutcome.unavailable;

    final ctx = AppRoutes.rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return TransactionAuthOutcome.unavailable;

    final pinOk = await PinPromptSheet.show(ctx);
    return pinOk == true
        ? TransactionAuthOutcome.allowed
        : TransactionAuthOutcome.cancelled;
  }
}

/// Thrown by [signSendConfirm] (and other signing entry points) when the
/// remote kill switch — or the unimplemented-cell backstop — rejects the
/// transaction. Distinct from [TransactionAuthCancelledException] on purpose:
/// several surfaces render cancels *silently*, which would swallow the
/// operator's copy entirely. [AppFailure.from]
/// maps this onto `AppFailureKind.flowDisabled`, and
/// `handleFlowDisabled(context, failure)` is the one presentation for it.
class TransactionFlowDisabledException implements Exception {
  const TransactionFlowDisabledException(this.operatorMessage);

  /// The operator's copy for the incident, or [kUnsupportedFlowMessage] for
  /// the unimplemented-cell case. Rendered **verbatim** — it is the only thing
  /// that can tell a user whether their funds are safe.
  final String operatorMessage;

  /// Deliberately the bare operator message, matching
  /// [TransactionAuthCancelledException]: a surface that has not been converted
  /// to the [AppFailure] path yet and renders `e.toString()` must still show
  /// the operator copy, never a class name.
  @override
  String toString() => operatorMessage;
}

/// Thrown by [signSendConfirm] (and other signing entry points) when the
/// step-up auth gate rejects or the user cancels. Catch this specifically
/// to render a cancel/abort UI without surfacing a generic error.
///
/// A killed cell must throw [TransactionFlowDisabledException] instead — see
/// [AppFailure.from] still re-routes a `flowDisabled` outcome wrapped in
/// this type onto `flowDisabled` as defense in depth, but that is a safety net,
/// not the intended path.
class TransactionAuthCancelledException implements Exception {
  const TransactionAuthCancelledException(this.outcome);
  final TransactionAuthOutcome outcome;

  @override
  String toString() {
    // A killed cell renders the operator's copy verbatim — that message is
    // the whole reason the kill switch carries one.
    final disabled = outcome.disabledMessage;
    if (disabled != null) return disabled;
    return outcome == TransactionAuthOutcome.unavailable
        ? 'Re-authentication required but no biometric or PIN is set up.'
        : 'Authentication cancelled.';
  }
}
