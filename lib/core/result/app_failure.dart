/// Common failure type returned from blocs/repositories.
///
/// Carries a user-facing [message] plus an optional [cause] (the original
/// throwable) and a coarse [kind] tag so the UI can branch — e.g. silently
/// reset on `cancelled`, show a retry on `network`, surface a real error
/// banner on `unknown`.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:solana/solana.dart';

import '../crypto/exceptions.dart' as crypto_exceptions;
import '../network/solana_rpc_service.dart'
    show SolanaTransactionUnconfirmedException;
import '../network/tezos_rpc_service.dart'
    show TezosOperationUnconfirmedException;
import '../security/transaction_auth_gate.dart' as auth_gate;

enum AppFailureKind {
  /// User aborted the flow (e.g. biometric prompt cancelled). Treat as a
  /// clean reset, not an error.
  cancelled,

  /// Backend HTTP failure — non-2xx response, connection error, timeout
  /// reaching the mallow API or any other REST service. Caller should
  /// surface a retry affordance.
  network,

  /// Solana RPC failure — `JsonRpcException`, simulation rejection,
  /// blockhash-not-found, RPC timeout. Distinct from [network] so the UI
  /// can copy "Solana network is busy" instead of a generic API error.
  rpc,

  /// Local signing failed — Ledger device error, social-wallet limitation,
  /// signature verification mismatch. Anything thrown by the signer that
  /// is NOT a user cancellation.
  signing,

  /// Caller-side validation problem (missing fields, bad input).
  validation,

  /// An operator has remotely killed this `(chain, flow)` cell, or the cell
  /// isn't implemented by this build. NOT a
  /// [cancelled] — surfaces that drop cancels silently would swallow the
  /// operator's message, which is the only thing that can tell the user
  /// whether their funds are safe. [message] is that copy, rendered verbatim
  /// by `handleFlowDisabled`.
  flowDisabled,

  /// Anything else — unknown server state, parsing failure, etc.
  unknown,
}

class AppFailure {
  const AppFailure({required this.kind, required this.message, this.cause});

  /// User cancelled or aborted the flow.
  const AppFailure.cancelled([String message = 'Cancelled', Object? cause])
    : this(kind: AppFailureKind.cancelled, message: message, cause: cause);

  /// Network / API failure.
  const AppFailure.network(String message, [Object? cause])
    : this(kind: AppFailureKind.network, message: message, cause: cause);

  /// Solana RPC failure (preflight rejection, blockhash expired, etc.).
  const AppFailure.rpc(String message, [Object? cause])
    : this(kind: AppFailureKind.rpc, message: message, cause: cause);

  /// Local signing failure (Ledger error, unsupported wallet path, etc.).
  const AppFailure.signing(String message, [Object? cause])
    : this(kind: AppFailureKind.signing, message: message, cause: cause);

  /// Client-side validation problem.
  const AppFailure.validation(String message, [Object? cause])
    : this(kind: AppFailureKind.validation, message: message, cause: cause);

  /// Remote kill switch (or unimplemented cell) blocked the flow. [message] is
  /// the operator's copy and must reach the user verbatim.
  const AppFailure.flowDisabled(String message, [Object? cause])
    : this(kind: AppFailureKind.flowDisabled, message: message, cause: cause);

  /// Unknown / unclassified.
  const AppFailure.unknown(String message, [Object? cause])
    : this(kind: AppFailureKind.unknown, message: message, cause: cause);

  /// Classify a thrown error. Known exception types map to their natural
  /// [AppFailureKind]; everything else becomes [AppFailureKind.unknown] with
  /// the throwable's `toString` as the message.
  factory AppFailure.from(Object error) {
    if (error is AppFailure) return error;

    // Kill switch FIRST — before the cancel mappings below, which would
    // otherwise swallow the operator's message on every surface that renders
    // cancels silently.
    if (error is auth_gate.TransactionFlowDisabledException) {
      return AppFailure.flowDisabled(error.operatorMessage, error);
    }

    // Cancellation — two flavors. crypto/ is raised by wallet_manager, and
    // security/ is raised by the auth gate. Both map to the same UI
    // semantics: user backed out, treat as a clean abort.
    if (error is crypto_exceptions.TransactionAuthCancelledException) {
      return AppFailure.cancelled(error.message, error);
    }
    if (error is auth_gate.TransactionAuthCancelledException) {
      // Defense in depth: a throw site that hasn't been converted to
      // [auth_gate.TransactionFlowDisabledException] still carries the gate's
      // outcome, so a kill is recoverable here rather than mis-filed as a
      // user cancel.
      final disabled = error.outcome.disabledMessage;
      if (disabled != null) return AppFailure.flowDisabled(disabled, error);
      return AppFailure.cancelled(error.toString(), error);
    }

    // Signing — local signer failures that are NOT user cancellation.
    if (error is crypto_exceptions.SigningException) {
      return AppFailure.signing(error.message, error);
    }
    if (error
        is crypto_exceptions.SocialTransactionSigningNotSupportedException) {
      return AppFailure.signing(error.message, error);
    }
    if (error is crypto_exceptions.LegacySocialWalletException) {
      return AppFailure.signing(error.message, error);
    }
    if (error is crypto_exceptions.NonSolanaSigningWalletException) {
      return AppFailure.signing(error.message, error);
    }
    if (error is crypto_exceptions.ViewOnlyWalletException) {
      return AppFailure.signing(error.message, error);
    }
    if (error is crypto_exceptions.NoWalletException) {
      return AppFailure.signing(error.message, error);
    }

    // Validation — caller-side bad input. Surfaced by the import flows and
    // any future form validators that throw rather than return Result.
    if (error is crypto_exceptions.InvalidMnemonicException) {
      return AppFailure.validation(error.message, error);
    }
    if (error is crypto_exceptions.InvalidPrivateKeyException) {
      return AppFailure.validation(error.message, error);
    }

    // Solana RPC — preflight rejection, blockhash-not-found, RPC timeout.
    if (error is JsonRpcException) {
      return AppFailure.rpc(error.message, error);
    }
    if (error is RpcTimeoutException) {
      return AppFailure.rpc('Solana RPC timed out', error);
    }

    // HTTP — Dio is the only HTTP client in use.
    if (error is DioException) {
      final response = error.response;
      debugPrint(
        '[AppFailure] ${error.requestOptions.method} '
        '${error.requestOptions.uri} '
        '→ ${response?.statusCode ?? error.type.name}: ${response?.data}',
      );
      return AppFailure.network(_dioMessage(error), error);
    }

    return AppFailure.unknown(error.toString(), error);
  }

  /// Best-effort user-facing copy for a [DioException]. Prefers the
  /// server-provided `message`/`error` field when present so backend
  /// copy (e.g. "Listing not found") wins over framework-default strings.
  static String _dioMessage(DioException error) {
    final response = error.response;
    if (response != null) {
      final data = response.data;
      if (data is Map) {
        final msg = data['message'] ?? data['error'];
        if (msg is String && msg.isNotEmpty) return msg;
      }
      // Plain-text error bodies (e.g. proxy/gateway responses).
      if (data is String && data.isNotEmpty && data.length <= 200) {
        return data;
      }
      return 'Request failed (${response.statusCode ?? '?'})';
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'Network request timed out',
      DioExceptionType.connectionError => 'Could not reach the server',
      _ => 'Network request failed',
    };
  }

  final AppFailureKind kind;
  final String message;
  final Object? cause;

  bool get isCancelled => kind == AppFailureKind.cancelled;

  /// A remote kill (or unimplemented cell) stopped the flow. Deliberately not
  /// folded into [isCancelled]: every existing silent-cancel branch must fall
  /// through so `handleFlowDisabled` can present the operator's message.
  bool get isFlowDisabled => kind == AppFailureKind.flowDisabled;

  /// The transaction was broadcast but never observed as confirmed — on Solana
  /// before its blockhash expired ([SolanaTransactionUnconfirmedException],
  /// thrown by `SolanaRpcService.awaitConfirmationOrThrow`), on Tezos before
  /// the inclusion poll timed out ([TezosOperationUnconfirmedException], thrown
  /// by `TezosTransferService.sendNativeTransfer`).
  ///
  /// **Indeterminate, not failed.** The tx may still land, so every surface
  /// that renders this failure must drop its retry affordance — a retry
  /// re-signs and re-broadcasts a *fresh* transaction (new blockhash, and for
  /// prints a new ephemeral mint signer), so if the original lands too the user
  /// pays twice. See `SendPipelineView`, which established the pattern.
  ///
  /// Read off [cause] rather than carried as its own [AppFailureKind]: the kind
  /// is a coarse *source* tag that several exhaustive switches bucket onto
  /// analytics vocabularies, and this is an orthogonal outcome flag on what is
  /// otherwise an ordinary RPC/unknown failure.
  bool get isUnconfirmed =>
      cause is SolanaTransactionUnconfirmedException ||
      cause is TezosOperationUnconfirmedException;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppFailure &&
          other.kind == kind &&
          other.message == message &&
          other.cause == cause;

  @override
  int get hashCode => Object.hash(kind, message, cause);

  @override
  String toString() => 'AppFailure(${kind.name}, $message)';
}

extension AppFailurePrefix on AppFailure {
  /// Wraps [message] with a phase-specific `"$prefix: "` for display while
  /// preserving [kind] and [cause] so downstream classification still works.
  ///
  /// User cancellations pass through untouched — a cancel message is already
  /// user-facing and must never surface as a generic failure (e.g. a
  /// dismissed signing prompt should not read "Listing failed: Cancelled").
  /// This is the single prefixing path; per-bloc `_prefix` helpers used to
  /// re-implement it with drifting cancel handling.
  ///
  /// Kills pass through for the same reason plus a stronger one: the operator's
  /// copy is written for the incident and is rendered verbatim, so
  /// "Listing failed: Buying is paused, your funds are safe" is not acceptable.
  ///
  /// Unconfirmed broadcasts pass through because the flow did NOT fail — the
  /// outcome is unknown. "Listing failed: This transaction may still land"
  /// contradicts itself, and `signSendConfirm`'s contract requires the
  /// exception's message to reach the user verbatim rather than be restated as
  /// a failure of the caller's own.
  AppFailure prefixedWith(String prefix) {
    if (isCancelled || isFlowDisabled || isUnconfirmed) return this;
    return AppFailure(kind: kind, message: '$prefix: $message', cause: cause);
  }
}
