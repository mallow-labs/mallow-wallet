import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/swap/widgets/swap_sheet.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';
import 'package:mocktail/mocktail.dart';

class MockRemoteConfigService extends Mock implements RemoteConfigService {}

class MockSessionManager extends Mock implements SessionManager {}

/// Phase 4b — the `solana:token-swap` entry gate.
///
/// Gated inside [showSwapSheet] rather than at its three callers, so a fourth
/// caller inherits it instead of quietly shipping an ungated path.
void main() {
  late ValueNotifier<RemoteConfig> config;
  late MockRemoteConfigService service;
  late MockSessionManager session;

  setUp(() {
    config = ValueNotifier(RemoteConfig.permissive);
    service = MockRemoteConfigService();
    when(() => service.config).thenReturn(config);
    when(service.refreshIfStale).thenAnswer((_) async {});
    if (sl.isRegistered<RemoteConfigService>()) {
      sl.unregister<RemoteConfigService>();
    }
    sl.registerFactory<RemoteConfigService>(() => service);

    // `showSwapSheet` runs the chain gate ahead of the kill-switch gate, so
    // these tests need a session that *can* swap — otherwise every case would
    // stop at "Swap is only available on Solana" and never reach the cell
    // under test. See `chain_support_guard.dart`.
    session = MockSessionManager();
    when(() => session.sessionWalletForChain(Chain.solana)).thenReturn(
      const WalletInfo(
        id: 'w1',
        address: 'SoLaNaAddr',
        name: 'W1',
        walletType: WalletType.hd,
        chain: 'solana',
      ),
    );
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    sl.registerFactory<SessionManager>(() => session);
  });

  tearDown(() {
    if (sl.isRegistered<RemoteConfigService>()) {
      sl.unregister<RemoteConfigService>();
    }
    if (sl.isRegistered<SessionManager>()) sl.unregister<SessionManager>();
    config.dispose();
  });

  Future<void> tapSwap(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showSwapSheet(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a killed token-swap explains instead of opening the sheet', (
    tester,
  ) async {
    const message = 'Swaps are paused while our routing partner recovers.';
    config.value = const RemoteConfig(
      disabledMessages: {'solana:token-swap': message},
    );

    await tapSwap(tester);

    expect(find.text(message), findsOneWidget);
    // The sheet must not be built at all — it spins up a SwapBloc and starts
    // quoting, which is exactly the machinery the kill switch exists to stop.
    expect(find.byType(SwapSheet), findsNothing);
  });

  testWidgets('entering the flow refreshes a stale config', (tester) async {
    // A session left in the foreground for hours would otherwise never
    // see a cell flipped after launch. Fired before the check and never
    // awaited, so the tap itself is unaffected by the round-trip.
    config.value = const RemoteConfig(
      disabledMessages: {'solana:token-swap': 'Paused.'},
    );

    await tapSwap(tester);

    verify(service.refreshIfStale).called(1);
  });
}
