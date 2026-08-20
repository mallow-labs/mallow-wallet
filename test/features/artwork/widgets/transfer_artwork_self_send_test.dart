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
import 'package:mallow_wallet/shared/utils/address_utils.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The recipient step's "you can't send to your own wallet" guard.
///
/// It resolved the sender with a bare `WalletManager.getAddress()`, whose
/// `chain` parameter **defaults to Solana**. On an Ethereum artwork that
/// compared a base58 Solana address against a `0x…` recipient, so the guard
/// could never fire and the user's own address was never dropped from recents —
/// on a transfer that is irreversible the moment it lands.
///
/// These tests pin the two properties that make the guard real, and each fails
/// if the corresponding half of the fix is reverted:
///
///  * the sender is resolved on the *artwork's* chain (drop `chain:` and the
///    EVM case stops blocking);
///  * the comparison is case-normalised via `apiOwnerAddress` (EVM addresses
///    travel checksummed in some places and lowercased in others, and a raw
///    `==` between the two forms of one address silently disarms the guard).
///
/// The Solana case is here as the regression control — the fix must not have
/// changed the chain the Solana path resolves on.

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

/// The active account's per-chain wallets. `getAddress()` with no argument
/// returns [solana] — which is exactly the trap under test.
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

/// The session's active address per chain. The guard resolves the sender
/// through the session (not the active account) so a Profile compares against
/// a wallet it actually links; the per-chain answers mirror the account's here.
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

// Mixed-case (checksummed-shaped) as the wallet holds it; the same address
// lowercased is what a block explorer / the backend hands back.
const _ethSelf = '0xAbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCdEfAbCd';
const _ethSelfLower = '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd';
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
    String initialRecipient = '',
  }) async {
    final input = TransferInput(
      recipient: initialRecipient,
      isCheckingStandard: false,
      isEvm: isEvm,
    );
    whenListen(bloc, states.stream, initialState: input);

    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  runTransferArtworkFlow(context, artwork: artwork),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await flush(tester);
  }

  /// Opens the flow for [artwork], types [recipient], and taps Next.
  ///
  /// The bloc is mocked, so the input state carrying `recipient` (which is what
  /// makes `canProceed` true and Next tappable) is emitted by the test rather
  /// than produced by `recipientChanged`.
  Future<void> tapNextWith(
    WidgetTester tester, {
    required PortfolioArtwork artwork,
    required String recipient,
    required bool isEvm,
  }) async {
    await openWith(
      tester,
      artwork: artwork,
      isEvm: isEvm,
      initialRecipient: recipient,
    );

    await tester.enterText(find.byType(TextField).first, recipient);
    await flush(tester);

    await tester.tap(find.text('Next'));
    await flush(tester);
  }

  PortfolioArtwork evmArtwork() => PortfolioArtwork(
    mintAccount: _evmMint,
    title: 'EVM NFT',
    imageUrl: '',
    artistName: 'Artist',
    chain: 'ethereum',
  );

  PortfolioArtwork solArtwork() => PortfolioArtwork(
    mintAccount: _solMint,
    title: 'Solana NFT',
    imageUrl: '',
    artistName: 'Artist',
    chain: 'solana',
  );

  testWidgets(
    'an Ethereum artwork blocks a send to the account\'s own ETH wallet',
    (tester) async {
      await tapNextWith(
        tester,
        artwork: evmArtwork(),
        recipient: _ethSelf,
        isEvm: true,
      );

      // Chain-blind `getAddress()` would have compared `_solSelf` here and let
      // this through to the confirm step.
      expect(find.text("You can't send to your own wallet"), findsOneWidget);
      verifyNever(() => bloc.add(const TransferArtworkEvent.proceed()));
    },
  );

  testWidgets(
    'the ETH self-check is case-normalised, so the lowercased form of the same '
    'address is still refused',
    (tester) async {
      await tapNextWith(
        tester,
        artwork: evmArtwork(),
        recipient: _ethSelfLower,
        isEvm: true,
      );

      expect(find.text("You can't send to your own wallet"), findsOneWidget);
      verifyNever(() => bloc.add(const TransferArtworkEvent.proceed()));
    },
  );

  testWidgets('a genuinely different ETH recipient still advances', (
    tester,
  ) async {
    // The guard must not become a blanket block: refusing a real recipient
    // would be the same class of bug in the other direction.
    await tapNextWith(
      tester,
      artwork: evmArtwork(),
      recipient: _ethOther,
      isEvm: true,
    );

    expect(find.text("You can't send to your own wallet"), findsNothing);
    verify(() => bloc.add(const TransferArtworkEvent.proceed())).called(1);
  });

  testWidgets('recent recipients are limited to the artwork chain', (
    tester,
  ) async {
    final prefs = sl<PreferencesService>();
    await prefs.saveRecentSendAddress(_solOther);
    await prefs.saveRecentSendAddress(_ethOther);

    await openWith(tester, artwork: evmArtwork(), isEvm: true);

    // Each row renders the truncated address as both its display name and
    // trailing value.
    expect(find.text(truncateAddress(_ethOther)), findsNWidgets(2));
    expect(find.text(truncateAddress(_solOther)), findsNothing);
  });

  testWidgets('the Solana path still blocks the active Solana wallet', (
    tester,
  ) async {
    await tapNextWith(
      tester,
      artwork: solArtwork(),
      recipient: _solSelf,
      isEvm: false,
    );

    expect(find.text("You can't send to your own wallet"), findsOneWidget);
    verifyNever(() => bloc.add(const TransferArtworkEvent.proceed()));
  });

  testWidgets('the Solana path still advances a different Solana recipient', (
    tester,
  ) async {
    await tapNextWith(
      tester,
      artwork: solArtwork(),
      recipient: _solOther,
      isEvm: false,
    );

    expect(find.text("You can't send to your own wallet"), findsNothing);
    verify(() => bloc.add(const TransferArtworkEvent.proceed())).called(1);
  });
}
