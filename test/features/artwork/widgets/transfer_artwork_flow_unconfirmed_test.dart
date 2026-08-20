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
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/core/services/preferences_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/services/transfer_artwork_bloc.dart';
import 'package:mallow_wallet/features/artwork/widgets/transfer_artwork_flow.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

const _mint = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _recipient = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

/// The sharpest edge of the pipeline family: a **double-landed NFT transfer is
/// irreversible** — the artwork is in someone else's wallet and no retry undoes
/// it. So when the broadcast outcome is unknown
/// (`SolanaTransactionUnconfirmedException`: the blockhash expired before the
/// transaction was ever observed landing), the pipeline step must neither claim
/// the transfer failed nor put the user one tap from re-sending. On a
/// determinate failure nothing moved, so the ordinary "Try again → back to the
/// recipient step" loop stays exactly as it was.
void main() {
  late _MockTransferBloc bloc;
  late StreamController<TransferArtworkState> states;

  final artwork = PortfolioArtwork(
    mintAccount: _mint,
    title: 'Test NFT',
    imageUrl: '',
    artistName: 'Artist',
  );

  // Simulation succeeded for this recipient, so the confirm step's Send CTA is
  // live — the only gate between the test and the pipeline step.
  const ready = TransferReady(
    recipient: _recipient,
    simulationResult: SimulationResult(success: true),
  );

  setUp(() async {
    bloc = _MockTransferBloc();
    states = StreamController<TransferArtworkState>.broadcast();
    whenListen(bloc, states.stream, initialState: ready);

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
    // The confirm step's recipient pill renders an AccountAvatar, which reads
    // this off the locator on build.
    register<AvatarService>(AvatarService.forTest(Dio()));
  });

  tearDown(() async {
    await states.close();
    for (final drop in [
      () => sl.unregister<TransferArtworkBloc>(),
      () => sl.unregister<RemoteConfigService>(),
      () => sl.unregister<PreferencesService>(),
      () => sl.unregister<AvatarService>(),
    ]) {
      drop();
    }
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Drives recipient → confirm → Send, then lands [pipelineState] in the
  /// pipeline step.
  Future<void> transferUntilPipelineState(
    WidgetTester tester,
    TransferArtworkState pipelineState,
  ) async {
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

    // The sheet mounts on the recipient step; the ready emission is what moves
    // it to confirm (the initial state alone never reaches the listener).
    states.add(ready);
    await flush(tester);

    await tester.tap(find.text('Send'));
    await flush(tester);

    states.add(pipelineState);
    await flush(tester);
  }

  testWidgets('a determinate failure keeps the failure headline and offers a '
      'retry back to the form', (tester) async {
    await transferUntilPipelineState(
      tester,
      const TransferError(message: 'Transfer failed: insufficient funds'),
    );

    expect(find.text('Transfer failed'), findsOneWidget);

    // Retry morphs back to the recipient step so the user can re-send —
    // nothing moved on-chain, so that is safe.
    await tester.tap(find.text('Try again'));
    await flush(tester);
    expect(find.text('Transfer failed'), findsNothing);
    verify(
      () => bloc.add(const TransferArtworkEvent.reset()),
    ).called(greaterThanOrEqualTo(1));
  });

  testWidgets('an unconfirmed broadcast is not framed as a failure, cannot be '
      'retried, and bows out of the flow', (tester) async {
    final failure = AppFailure.from(
      const SolanaTransactionUnconfirmedException('sigSTUCK'),
    );
    await transferUntilPipelineState(
      tester,
      TransferError(message: failure.message, failure: failure),
    );

    expect(find.text('Transfer failed'), findsNothing);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    // The exception's own copy points the user at Activity / the explorer.
    expect(find.textContaining('may still land'), findsOneWidget);

    // The button is still laid out (the sheet keeps a fixed footprint) but is
    // inert — it must not walk the user back to a prefilled form.
    await tester.tap(find.text('Try again'), warnIfMissed: false);
    await flush(tester);
    expect(find.text('Not confirmed yet'), findsOneWidget);

    // Back closes the whole flow rather than returning to the recipient step:
    // the address is still typed there, so "back" would leave a re-send two
    // taps away over an artwork that may already have moved.
    await tester.tap(find.text('Back'));
    await flush(tester);
    expect(find.text('Not confirmed yet'), findsNothing);
    expect(find.text('Send'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('shows Done once an EVM-style broadcast is registered', (
    tester,
  ) async {
    await transferUntilPipelineState(
      tester,
      const TransferBroadcasting(pendingRegistered: true),
    );

    expect(find.text('Confirming transaction…'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await flush(tester);
    expect(find.text('Confirming transaction…'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
