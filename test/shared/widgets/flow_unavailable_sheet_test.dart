import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/config/store_build.dart';
import 'package:mallow_wallet/core/security/transaction_auth_gate.dart'
    show kFlowDisabledFallbackMessage, kStoreGatedFlowMessage;
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/flow_unavailable_sheet.dart';

Future<void> _openSheet(WidgetTester tester, String message) async {
  await tester.pumpWidget(
    MaterialApp(
      // The real app always runs under MallowTheme, and the theme changes the
      // sheet's entrance timing — testing under the bare default theme would
      // exercise a configuration that never ships.
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showFlowUnavailableSheet(context, message),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  // `showMallowSheet` arms `_sheetSettleBuffer` (mallow_sheet.dart:79), a 100ms
  // barrier that swallows taps landing right as a sheet settles — app-wide
  // accidental-double-tap protection. It is a bare `Timer`, so it schedules no
  // frames and `pumpAndSettle` returns with the barrier still up; a tap here
  // would be silently eaten and the sheet would look unresponsive. Pump past it.
  await tester.pump(_entranceGuard);
}

/// Comfortably past `_sheetSettleBuffer`.
const _entranceGuard = Duration(milliseconds: 250);

/// Nothing killed. The route gate reads it for every non-store cell, and the
/// entry nudge calls [refreshIfStale], so both must exist.
class _PermissiveRemoteConfigService extends Fake
    implements RemoteConfigService {
  final ValueNotifier<RemoteConfig> _config = ValueNotifier(
    RemoteConfig.permissive,
  );

  @override
  ValueListenable<RemoteConfig> get config => _config;

  @override
  Future<void> refreshIfStale() async {}
}

Future<void> _pumpGated(WidgetTester tester, List<FlowKey> flows) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: FlowGatedScreen(flows: flows, builder: () => const Text('real')),
    ),
  );
  // `FlowUnavailableScreen` presents its sheet after the first frame.
  await tester.pumpAndSettle();
  await tester.pump(_entranceGuard);
}

void main() {
  testWidgets('renders the server message verbatim', (tester) async {
    // The operator's copy is the only thing that can tell a user mid-incident
    // whether their funds are safe. Any client-side rewording — truncation,
    // a prepended "Sorry,", a per-flow substitute — defeats the reason the
    // payload carries a message field at all.
    const message =
        'Ethereum sends are paused while we fix a fee-estimation bug. '
        'Your funds are safe.';

    await _openSheet(tester, message);

    expect(find.text(message), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
  });

  testWidgets('falls back to the generic copy for an empty message', (
    tester,
  ) async {
    // A blank message must still explain something — but with exactly one
    // bland fallback, not per-flow copy that would drift from the backend.
    await _openSheet(tester, '   ');

    expect(find.text(kFlowDisabledFallbackMessage), findsOneWidget);
  });

  testWidgets('OK dismisses the sheet', (tester) async {
    await _openSheet(tester, 'Paused.');

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Paused.'), findsNothing);
  });

  group('FlowGatedScreen store gate', () {
    setUpAll(() {
      if (!sl.isRegistered<RemoteConfigService>()) {
        sl.registerSingleton<RemoteConfigService>(
          _PermissiveRemoteConfigService(),
        );
      }
    });
    tearDown(() => debugShowNftCommerceOverride = null);

    testWidgets('a route fronting only commerce cells is closed with the '
        'neutral store copy when commerce is hidden', (tester) async {
      debugShowNftCommerceOverride = false;

      await _pumpGated(tester, const [
        FlowKey.solana(AppFlow.nftMint),
        FlowKey.solana(AppFlow.editionMint),
        FlowKey.solana(AppFlow.collectionMint),
      ]);

      expect(find.text('real'), findsNothing);
      // Neutral on purpose: no platform, no policy, nothing that reads as a
      // feature waiting to be switched on.
      expect(find.text(kStoreGatedFlowMessage), findsOneWidget);
    });

    testWidgets('a route with one non-commerce cell stays open — the '
        'every-cell rule, same as for kills', (tester) async {
      debugShowNftCommerceOverride = false;

      await _pumpGated(tester, const [
        FlowKey.solana(AppFlow.fixedPriceCreate),
        FlowKey.solana(AppFlow.nftTransfer),
      ]);

      expect(find.text('real'), findsOneWidget);
      expect(find.text(kStoreGatedFlowMessage), findsNothing);
    });

    testWidgets('with commerce shown a commerce route renders normally', (
      tester,
    ) async {
      debugShowNftCommerceOverride = true;

      await _pumpGated(tester, const [FlowKey.solana(AppFlow.nftMint)]);

      expect(find.text('real'), findsOneWidget);
    });
  });
}
