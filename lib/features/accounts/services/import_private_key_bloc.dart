import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/crypto/private_key_parser.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/result/result.dart';
import '../../../core/security/redacted.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';

import '../../../shared/utils/chain.dart';
part 'import_private_key_bloc.freezed.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

@freezed
abstract class ImportPrivateKeyEvent with _$ImportPrivateKeyEvent {
  // SECURITY: the raw key is wrapped so freezed's generated `toString()` masks
  // it — see [Redacted].
  const factory ImportPrivateKeyEvent.validateKey(Redacted<String> input) =
      _ValidateKey;
  const factory ImportPrivateKeyEvent.importWallet() = _ImportWallet;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@freezed
abstract class ImportPrivateKeyState with _$ImportPrivateKeyState {
  const factory ImportPrivateKeyState.initial() = _Initial;
  const factory ImportPrivateKeyState.validating() = _Validating;
  const factory ImportPrivateKeyState.validated({
    required String address,
    // SECURITY: held in state until the user confirms the import, so it is
    // also what a BlocObserver's onChange would print. Masked via [Redacted].
    required Redacted<String> rawInput,
    @Default(Chain.solana) Chain chain,
    int? artworkCount,
    int? createdCount,
    int? collectedCount,
  }) = ImportPrivateKeyValidated;
  const factory ImportPrivateKeyState.importing() = _Importing;
  const factory ImportPrivateKeyState.imported(WalletInfo wallet) = _Imported;
  const factory ImportPrivateKeyState.error(String message) = _Error;
}

// ---------------------------------------------------------------------------
// BLoC
// ---------------------------------------------------------------------------

@injectable
class ImportPrivateKeyBloc
    extends Bloc<ImportPrivateKeyEvent, ImportPrivateKeyState> {
  ImportPrivateKeyBloc(this._walletRepo, this._walletManager)
    : super(const ImportPrivateKeyState.initial()) {
    on<_ValidateKey>(_onValidateKey);
    on<_ImportWallet>(_onImportWallet);
  }

  final WalletRepository _walletRepo;
  final WalletManager _walletManager;

  Future<void> _onValidateKey(
    _ValidateKey event,
    Emitter<ImportPrivateKeyState> emit,
  ) async {
    if (event.input.value.trim().isEmpty) {
      emit(const ImportPrivateKeyState.initial());
      return;
    }

    emit(const ImportPrivateKeyState.validating());
    // InvalidPrivateKeyException classifies as `validation` via AppFailure.from,
    // so the user-facing copy flows through error.message uniformly.
    final result = await Result.guard(() async {
      final parsed = await PrivateKeyParser.parse(event.input.value);
      return ImportPrivateKeyState.validated(
        address: parsed.address,
        chain: parsed.chain,
        rawInput: event.input,
      );
    });
    switch (result) {
      case ResultSuccess(:final value):
        emit(value);
      case ResultFailure(:final error):
        AppLogger.debug(
          'ImportPrivateKeyBloc',
          'Validate key failed: ${error.message}',
        );
        emit(ImportPrivateKeyState.error(_safeKeyMessage(error)));
    }
  }

  Future<void> _onImportWallet(
    _ImportWallet event,
    Emitter<ImportPrivateKeyState> emit,
  ) async {
    final current = state;
    if (current is! ImportPrivateKeyValidated) return;

    emit(const ImportPrivateKeyState.importing());
    final result = await Result.guard(() async {
      final wallet = await _walletRepo.addImportedKeyWallet(
        current.rawInput.value,
        'Imported wallet',
      );

      // Activate via WalletManager so onWalletChanged fires and AuthService
      // re-logs in with the new address — otherwise post-onboarding signing
      // hits a wallet/auth mismatch. Skip when the active Profile already links
      // this address (importing the real key for a read-only linked wallet):
      // the user stays on their Profile and its current signer, rather than
      // this new wallet hijacking the session.
      if (!_activeProfileOwns(wallet.address)) {
        await _walletManager.switchWalletById(wallet.id);
      }

      return wallet;
    });
    switch (result) {
      case ResultSuccess(:final value):
        emit(ImportPrivateKeyState.imported(value));
        _trackImported(value.chainEnum);
      case ResultFailure(:final error):
        // This is a key-handling path: for `unknown` the message is
        // error.toString(), which can leak keystore/crypto exception text.
        // Keep validation copy (e.g. "Could not parse…") but never surface
        // raw detail for anything else — log it instead.
        AppLogger.debug(
          'ImportPrivateKeyBloc',
          'Import failed: ${error.message}',
        );
        emit(ImportPrivateKeyState.error(_safeKeyMessage(error)));
        _trackImportFailed(error.kind);
    }
  }

  /// True when the active session is a Profile that already links [address].
  /// Guarded on registration so unit tests (no DI container) treat every import
  /// as a fresh wallet and keep asserting the activate-on-import behavior.
  bool _activeProfileOwns(String address) {
    if (!sl.isRegistered<SessionManager>()) return false;
    return sl<SessionManager>().activeProfileContainsAnyAddress([address]);
  }

  /// Fire the analytics `Wallet Imported` event once the imported-key wallet is
  /// persisted. Guarded on registration so unit tests (no DI container) skip it.
  void _trackImported(Chain chain) {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImported,
        properties: {
          AnalyticsProp.chain: AnalyticsChain.fromChain(chain).wire,
          AnalyticsProp.method: 'private_key',
        },
      ),
    );
  }

  void _trackImportFailed(AppFailureKind kind) {
    if (!sl.isRegistered<AnalyticsService>()) return;
    unawaited(
      sl<AnalyticsService>().track(
        AnalyticsEvent.walletImportFailed,
        properties: {
          AnalyticsProp.method: 'private_key',
          AnalyticsProp.reason: FailureReason.fromAppFailureKind(kind).wire,
        },
      ),
    );
  }

  /// Returns the validation message verbatim, or a safe fallback for any other
  /// failure kind (which may carry raw exception detail via error.toString()).
  String _safeKeyMessage(AppFailure error) =>
      error.kind == AppFailureKind.validation
      ? error.message
      : 'Could not import this key.';
}
