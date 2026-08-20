import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../crypto/wallet_manager.dart';

/// Mixin for BLoCs that need to react when the active wallet changes.
///
/// Usage:
/// ```dart
/// class MyBloc extends Bloc<E, S> with WalletChangeListening<E, S> {
///   MyBloc(this.walletManager) : super(...) {
///     on<...>(...);
///     startWalletChangeListening();
///   }
///
///   @override
///   final WalletManager walletManager;
///
///   @override
///   void onWalletChanged() => add(const MyEvent.load());
/// }
/// ```
///
/// The mixin overrides [close] to cancel the subscription, so subclasses
/// generally do not need their own `close()` override unless they have
/// other resources to release.
mixin WalletChangeListening<E, S> on Bloc<E, S> {
  WalletManager get walletManager;

  /// Called whenever the active wallet changes. Implementations typically
  /// dispatch a reload event.
  void onWalletChanged();

  StreamSubscription<String>? _walletChangeSubscription;

  /// Begin listening. Call from the constructor after registering handlers.
  void startWalletChangeListening() {
    _walletChangeSubscription ??= walletManager.onWalletChanged.listen(
      (_) => onWalletChanged(),
    );
  }

  @override
  Future<void> close() {
    _walletChangeSubscription?.cancel();
    return super.close();
  }
}
