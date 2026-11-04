import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/analytics/analytics_service.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/transfer_artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/transfer_artwork_flow.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An artwork transfer that starts with the recipient filled, as when the
/// user scanned a wallet address and then picked the artwork.
///
/// The address must reach both the field the user reviews and the bloc that
/// validates it. It must not be sent to on its own: proceeding stays the
/// user's tap.

class _MockTransferBloc
    extends MockBloc<TransferArtworkEvent, TransferArtworkState>
    implements TransferArtworkBloc {}

class _MockRemoteConfig extends Fake implements RemoteConfigService {
  @override
  final ValueListenable<RemoteConfig> config = ValueNotifier(
    RemoteConfig.permissive,
  );

  @override
  Future<void> refreshIfStale() async {}
}

/// The active account's per-chain wallets.
class _FakeWalletManager extends Fake implements WalletManager {
  _FakeWalletManager({required this.solana, required this.ethereum});

  final String solana;
  final String ethereum;

  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async =>
      switch (chain) {
        Chain.solana => solana,
        Chain.ethereum => ethereum,
        Chain.tezos => throw StateError('no tezos wallet'),
      };
}

/// The session's active address per chain, which the self-send guard reads.
class _FakeSessionManager extends Fake implements SessionManager {
  _FakeSessionManager({required this.solana, required this.ethereum});

  final String solana;
  final String ethereum;

  @override
  Future<String?> activeAddress(Chain chain) async => switch (chain) {
    Chain.solana => solana,
    Chain.ethereum => ethereum,
    Chain.tezos => null,
  };
}

const _solSelf = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _solOther = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

const _ethSelf = '0xAbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCd';
const _ethOther = '0x2222222222222222222222222222222222222222';

const _solMint = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _evmMint = '0x1111111111111111111111111111111111111111-42';

void main() {
  late _MockTransferBloc bloc;
  late StreamController<TransferArtworkState> states;

  setUp(() async {
    bloc = _MockTransferBloc();
    states = StreamController<TransferArtworkState>.broadcast();

    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.create();
    if (!sl.isRegistered<AnalyticsService>()) {
      sl.registerSingleton<AnalyticsService>(
        AnalyticsService(Dio(), prefs, const FlutterSecureStorage()),
      );
    }

    void register<T extends Object>(T instance) {
      if (sl.isRegistered<T>()) sl.unregister<T>();
      sl.registerFactory<T>(() => instance);
    }

    register<TransferArtworkBloc>(bloc);
    register<RemoteConfigService>(_MockRemoteConfig());
    register<PreferencesService>(prefs);
    register<AvatarService>(AvatarService.forTest(Dio()));
    register<WalletManager>(
      _FakeWalletManager(solana: _solSelf, ethereum: _ethSelf),
    );
    register<SessionManager>(
      _FakeSessionManager(solana: _solSelf, ethereum: _ethSelf),
    );
  });

  tearDown(() async {
    await states.close();
    for (final drop in [
      () => sl.unregister<TransferArtworkBloc>(),
      () => sl.unregister<RemoteConfigService>(),
      () => sl.unregister<PreferencesService>(),
      () => sl.unregister<AvatarService>(),
      () => sl.unregister<WalletManager>(),
      () => sl.unregister<SessionManager>(),
    ]) {
      drop();
    }
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> openWith(
    WidgetTester tester, {
    required PortfolioArtwork artwork,
    required bool isEvm,
    String? initialRecipient,
  }) async {
    whenListen(
      bloc,
      states.stream,
      initialState: TransferInput(isCheckingStandard: false, isEvm: isEvm),
    );

    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => runTransferArtworkFlow(
                context,
                artwork: artwork,
                initialRecipient: initialRecipient,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await flush(tester);
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  testWidgets('a Solana recipient fills the field and reaches the bloc', (
    tester,
  ) async {
    await openWith(
      tester,
      artwork: PortfolioArtwork(
        mintAccount: _solMint,
        title: 'Solana NFT',
        imageUrl: '',
        artistName: 'Artist',
        chain: 'solana',
      ),
      isEvm: false,
      initialRecipient: _solOther,
    );

    expect(fieldText(tester), _solOther);
    verify(
      () => bloc.add(const TransferArtworkEvent.recipientChanged(_solOther)),
    ).called(1);
    verifyNever(() => bloc.add(const TransferArtworkEvent.proceed()));
  });

  testWidgets('an Ethereum recipient fills the field and reaches the bloc', (
    tester,
  ) async {
    await openWith(
      tester,
      artwork: PortfolioArtwork(
        mintAccount: _evmMint,
        title: 'EVM NFT',
        imageUrl: '',
        artistName: 'Artist',
        chain: 'ethereum',
      ),
      isEvm: true,
      initialRecipient: _ethOther,
    );

    expect(fieldText(tester), _ethOther);
    verify(
      () => bloc.add(const TransferArtworkEvent.recipientChanged(_ethOther)),
    ).called(1);
    verifyNever(() => bloc.add(const TransferArtworkEvent.proceed()));
  });

  testWidgets('without one the field starts empty', (tester) async {
    await openWith(
      tester,
      artwork: PortfolioArtwork(
        mintAccount: _solMint,
        title: 'Solana NFT',
        imageUrl: '',
        artistName: 'Artist',
        chain: 'solana',
      ),
      isEvm: false,
    );

    expect(fieldText(tester), isEmpty);
  });
}
