import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/services/wallet_change_listening.dart';
import 'package:mocktail/mocktail.dart';

class _MockWalletManager extends Mock implements WalletManager {}

class _Reload {
  const _Reload();
}

class _TestBloc extends Bloc<_Reload, int>
    with WalletChangeListening<_Reload, int> {
  _TestBloc(this.walletManager) : super(0) {
    on<_Reload>((_, emit) => emit(state + 1));
    startWalletChangeListening();
  }

  @override
  final WalletManager walletManager;

  @override
  void onWalletChanged() => add(const _Reload());
}

void main() {
  group('WalletChangeListening', () {
    late _MockWalletManager wallet;
    late StreamController<String> controller;

    setUp(() {
      wallet = _MockWalletManager();
      controller = StreamController<String>.broadcast();
      when(() => wallet.onWalletChanged).thenAnswer((_) => controller.stream);
    });

    tearDown(() async {
      if (!controller.isClosed) await controller.close();
    });

    test('invokes onWalletChanged for each emission', () async {
      final bloc = _TestBloc(wallet);
      // Allow the stream subscription to register.
      await Future<void>.delayed(Duration.zero);

      controller.add('WALLET_A');
      controller.add('WALLET_B');
      // Flush pending events.
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, 2);
      await bloc.close();
    });

    test(
      'startWalletChangeListening is idempotent — only one subscription',
      () async {
        final bloc = _TestBloc(wallet);
        // Second call should not register a duplicate listener.
        bloc.startWalletChangeListening();
        await Future<void>.delayed(Duration.zero);

        controller.add('WALLET_A');
        await Future<void>.delayed(Duration.zero);

        // A single emission must yield exactly one reload, not two.
        expect(bloc.state, 1);
        await bloc.close();
      },
    );

    test('close() cancels the subscription so no more events fire', () async {
      final bloc = _TestBloc(wallet);
      await Future<void>.delayed(Duration.zero);

      // Sanity: the bloc actually subscribed. Without this guard, the
      // post-close assertion would pass trivially if startWalletChangeListening
      // ever regressed to a no-op.
      expect(
        controller.hasListener,
        isTrue,
        reason: 'bloc should have subscribed in its constructor',
      );

      await bloc.close();

      // close() must release the subscription.
      expect(controller.hasListener, isFalse);
    });
  });
}
