import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/shared/widgets/flow_unavailable_sheet.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

/// Stands in for the live config poller. The gates read [config] and nudge
/// [refreshIfStale]; nothing else is touched.
class _FakeRemoteConfigService extends Fake implements RemoteConfigService {
  final ValueNotifier<RemoteConfig> notifier = ValueNotifier(
    RemoteConfig.permissive,
  );

  /// How many times a gate fired the staleness nudge.
  int refreshes = 0;

  @override
  ValueListenable<RemoteConfig> get config => notifier;

  @override
  Future<void> refreshIfStale() async => refreshes++;
}

/// Build the sparse payload the backend would send for [cells].
RemoteConfig _kill(Map<FlowKey, String> cells) => RemoteConfig(
  disabledMessages: {
    for (final entry in cells.entries)
      '${entry.key.chain.toDbString()}:${entry.key.flow.wire}': entry.value,
  },
);

const _fixedPriceCreate = FlowKey.solana(AppFlow.fixedPriceCreate);
const _fixedPriceCancel = FlowKey.solana(AppFlow.fixedPriceCancel);
const _auctionCreate = FlowKey.solana(AppFlow.auctionCreate);
const _auctionSettle = FlowKey.solana(AppFlow.auctionSettle);
const _fixedPriceBuy = FlowKey.solana(AppFlow.fixedPriceBuy);
const _editionBuy = FlowKey.solana(AppFlow.editionBuy);
const _nftMint = FlowKey.solana(AppFlow.nftMint);
const _nftEdit = FlowKey.solana(AppFlow.nftEdit);
const _solTransfer = FlowKey.solana(AppFlow.nftTransfer);
const _ethTransfer = FlowKey(Chain.ethereum, AppFlow.nftTransfer);

void main() {
  late _FakeRemoteConfigService service;

  setUp(() {
    service = _FakeRemoteConfigService();
    if (sl.isRegistered<RemoteConfigService>()) {
      sl.unregister<RemoteConfigService>();
    }
    sl.registerSingleton<RemoteConfigService>(service);
  });

  tearDown(() {
    sl.unregister<RemoteConfigService>();
    service.notifier.dispose();
  });

  /// Set once the guarded action's tap handler has run to completion. A killed
  /// cell parks inside `guardFlowDisabled` until the explanation sheet is
  /// acknowledged, so this stays null while the sheet is up.
  bool? aborted;

  /// Tap a button wired to [guardFlowDisabled]. Leaves the explanation sheet
  /// open when the cell is killed, so a caller can assert on its copy.
  Future<void> tapGuardedAction(WidgetTester tester, FlowKey flow) async {
    aborted = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                aborted = await guardFlowDisabled(context, flow);
              },
              child: const Text('Go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
  }

  /// Tap through the whole gate — dismissing the explanation sheet if one
  /// appeared — and report whether the caller was told to abort.
  Future<bool> runGate(WidgetTester tester, FlowKey flow) async {
    await tapGuardedAction(tester, flow);
    if (find.text('OK').evaluate().isNotEmpty) {
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }
    return aborted!;
  }

  group('guardFlowDisabled', () {
    testWidgets('lets a live cell through without interrupting the user', (
      tester,
    ) async {
      expect(await runGate(tester, _fixedPriceBuy), isFalse);
      expect(find.text('Temporarily unavailable'), findsNothing);
    });

    testWidgets('aborts a killed cell and shows the operator copy verbatim', (
      tester,
    ) async {
      // The server's message is the only thing that can tell a user mid-
      // incident whether their funds are safe, so the gate renders it as sent
      // — no truncation, no per-flow substitute.
      const message =
          'Buying is paused while we fix a fee bug. Your funds are safe.';
      service.notifier.value = _kill({_fixedPriceBuy: message});

      await tapGuardedAction(tester, _fixedPriceBuy);
      expect(find.text(message), findsOneWidget);
      // The caller is only released once the user acknowledges — and is told
      // to abort.
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(aborted, isTrue);
    });

    testWidgets('nudges the config on entry whether or not the cell is live', (
      tester,
    ) async {
      // An app left in the foreground for hours would otherwise
      // never see a kill. Fire-and-forget — the tap must not wait on it.
      await runGate(tester, _fixedPriceBuy);
      expect(service.refreshes, 1);

      service.notifier.value = _kill({_fixedPriceBuy: 'Paused.'});
      await runGate(tester, _fixedPriceBuy);
      expect(service.refreshes, 2);
    });
  });

  group('escape hatches survive their create-path twin being killed', () {
    testWidgets('killing fixed-price-create leaves delisting reachable', (
      tester,
    ) async {
      // The failure this whole granular axis exists to prevent: with one
      // coarse `list` cell, an operator killing broken listing *creation*
      // would also kill *cancellation* and strand every listed asset with no
      // way out. If this test fails, the two actions have been collapsed back
      // onto one cell somewhere.
      service.notifier.value = _kill({
        _fixedPriceCreate: 'Listing creation is paused.',
      });

      expect(await runGate(tester, _fixedPriceCreate), isTrue);
      expect(await runGate(tester, _fixedPriceCancel), isFalse);
    });

    testWidgets('killing auction-create leaves settlement reachable', (
      tester,
    ) async {
      // Same shape, higher stakes: until settle runs, both the winning bid and
      // the NFT sit in escrow.
      service.notifier.value = _kill({
        _auctionCreate: 'Auction creation is paused.',
      });

      expect(await runGate(tester, _auctionCreate), isTrue);
      expect(await runGate(tester, _auctionSettle), isFalse);
    });
  });

  group('sibling cells are independently killable', () {
    testWidgets('killing fixed-price-buy leaves edition buys alone', (
      tester,
    ) async {
      // Separate builders (`/tx/fixed-price/buy` vs the batched, partial-
      // signed `buy-edition`) behind separate sheets. A 1/1 buy breaking says
      // nothing about edition buys, so killing one must not take the other
      // down with it.
      service.notifier.value = _kill({_fixedPriceBuy: '1/1 buys are paused.'});

      expect(await runGate(tester, _fixedPriceBuy), isTrue);
      expect(await runGate(tester, _editionBuy), isFalse);
    });

    testWidgets('killing nft-mint leaves editing alone', (tester) async {
      // The reason for splitting them: `/tx/nft/mint` and `/tx/nft/edit`
      // are different builders, and an owner fixing broken metadata must not
      // be blocked because minting is down.
      service.notifier.value = _kill({_nftMint: 'Minting is paused.'});

      expect(await runGate(tester, _nftMint), isTrue);
      expect(await runGate(tester, _nftEdit), isFalse);
    });

    testWidgets('killing a flow on one chain leaves the other chain alone', (
      tester,
    ) async {
      // The per-chain half of the matrix: EVM and Solana NFT transfers are
      // independent builders with independent failure modes.
      service.notifier.value = _kill({_ethTransfer: 'EVM transfers paused.'});

      expect(await runGate(tester, _ethTransfer), isTrue);
      expect(await runGate(tester, _solTransfer), isFalse);
    });
  });

  group('flowGatedScreen', () {
    Widget destination() => const Text('destination');

    testWidgets('builds the destination when the cell is live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: flowGatedScreen(const [_nftMint], destination)),
      );

      expect(find.text('destination'), findsOneWidget);
      expect(service.refreshes, 1);
    });

    testWidgets('explains instead of silently bouncing the route', (
      tester,
    ) async {
      // A route that just pops the user back with no explanation is the
      // dead end this feature exists to remove.
      const message = 'Minting is paused while we redeploy the program.';
      service.notifier.value = _kill({_nftMint: message});

      await tester.pumpWidget(
        MaterialApp(home: flowGatedScreen(const [_nftMint], destination)),
      );
      await tester.pumpAndSettle();

      expect(find.text('destination'), findsNothing);
      expect(find.text(message), findsOneWidget);
    });

    testWidgets('a chooser stays open while any option it fronts is live', (
      tester,
    ) async {
      // The sell chooser fronts both sale kinds. Killing fixed-price listing
      // creation must not close the door on auctions — the destination route
      // re-checks its own cell.
      service.notifier.value = _kill({
        _fixedPriceCreate: 'Listing creation is paused.',
      });

      await tester.pumpWidget(
        MaterialApp(
          home: flowGatedScreen(const [
            _fixedPriceCreate,
            _auctionCreate,
          ], destination),
        ),
      );

      expect(find.text('destination'), findsOneWidget);
    });

    testWidgets('a chooser closes once every option it fronts is killed', (
      tester,
    ) async {
      service.notifier.value = _kill({
        _fixedPriceCreate: 'Listing creation is paused.',
        _auctionCreate: 'Auctions are paused.',
      });

      await tester.pumpWidget(
        MaterialApp(
          home: flowGatedScreen(const [
            _fixedPriceCreate,
            _auctionCreate,
          ], destination),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('destination'), findsNothing);
      expect(find.text('Listing creation is paused.'), findsOneWidget);
    });

    testWidgets('a kill landing mid-session does not destroy a live form', (
      tester,
    ) async {
      // go_router re-invokes EVERY stacked route's builder when
      // the RouteMatchList changes, so the old builder-time read swapped the
      // live form for FlowUnavailableScreen on the next push/pop — a differing
      // runtimeType, which tears down the form State and every typed field with
      // it. The snapshot is what makes that impossible; users already inside are
      // stopped at submit by the authorize() backstop instead.
      late StateSetter rebuildRoute;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuildRoute = setState;
              return flowGatedScreen(const [_nftMint], () => const _FormStub());
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'half-written title');
      await tester.pump();

      service.notifier.value = _kill({_nftMint: 'Minting is paused.'});
      rebuildRoute(() {});
      await tester.pumpAndSettle();

      expect(find.text('half-written title'), findsOneWidget);
      expect(find.text('Minting is paused.'), findsNothing);

      // …and the snapshot is per *entry*, not per session: leaving and coming
      // back picks up the kill.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(
        MaterialApp(
          home: flowGatedScreen(const [_nftMint], () => const _FormStub()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(find.text('Minting is paused.'), findsOneWidget);
    });
  });
}

/// Stands in for a real gated form (mint, edit): holds user-typed state that a
/// mid-session rebuild must not be allowed to throw away.
class _FormStub extends StatefulWidget {
  const _FormStub();

  @override
  State<_FormStub> createState() => _FormStubState();
}

class _FormStubState extends State<_FormStub> {
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: TextField(), primary: false);
}
