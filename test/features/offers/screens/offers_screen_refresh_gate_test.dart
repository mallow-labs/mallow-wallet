import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/core/config/remote_config_service.dart';
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/services/avatar_service.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/market/services/market_bloc.dart';
import 'package:mallow_wallet/features/offers/screens/offers_screen.dart';
import 'package:mallow_wallet/features/offers/services/offers_inbox_bloc.dart';
import 'package:mallow_wallet/features/portfolio/services/token_balance_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

class _MockOffersInboxBloc extends MockBloc<OffersInboxEvent, OffersInboxState>
    implements OffersInboxBloc {}

class _MockMarketBloc extends MockBloc<MarketEvent, MarketState>
    implements MarketBloc {}

class _MockTokenBalanceBloc
    extends MockBloc<TokenBalanceEvent, TokenBalanceState>
    implements TokenBalanceBloc {}

class _PermissiveRemoteConfigService extends Fake
    implements RemoteConfigService {
  final ValueNotifier<RemoteConfig> _config = ValueNotifier(
    RemoteConfig.permissive,
  );

  @override
  ValueNotifier<RemoteConfig> get config => _config;

  @override
  Future<void> refreshIfStale() async {}
}

/// The offers inbox must refetch on the *indexed* `TxFlowSuccess`, not the
/// chain-confirmed one.
///
/// `MarketBloc` emits `TxFlowSuccess` twice for every action: once the moment
/// the tx confirms on chain (`indexed == null`), then again when the indexer
/// acks (`indexed` true/false). Refetching on the first re-reads pre-index
/// truth, so the just-accepted/cancelled offer is painted straight back into
/// the list — and its Accept/Cancel pill then re-prompts the signer against an
/// Offer PDA that is already closed. Refetching only on the flip is the same
/// invalidate-after-checkTx rule the artwork screen follows.
void main() {
  const solMint = 'So11111111111111111111111111111111111111112';

  TxFlowSuccess<MarketPrepData, MarketSuccessData> success({bool? indexed}) =>
      TxFlowSuccess<MarketPrepData, MarketSuccessData>(
        signature: 'SIG',
        result: MarketSuccessData(
          explorerUrl: 'https://orbmarkets.io/tx/SIG',
          actionType: 'accept-offer',
          mintAccount: 'MINT',
          indexed: indexed,
        ),
      );

  group('marketOffersListenWhen', () {
    test('lets the indexed re-emit through — a runtimeType comparison would '
        'swallow it, because both success emissions share one runtime type and '
        'only `indexed` differs', () {
      expect(marketOffersListenWhen(success(), success(indexed: true)), isTrue);
      // The exact predicate the fix replaced, kept explicit so this test
      // fails the moment someone reverts to it.
      expect(
        success().runtimeType == success(indexed: true).runtimeType,
        isTrue,
      );
    });

    test('a timed-out ack (indexed=false) still counts as a flip', () {
      expect(
        marketOffersListenWhen(success(), success(indexed: false)),
        isTrue,
      );
    });

    test('fires on the transition into success and on any failure', () {
      const idle = TxFlowIdle<MarketPrepData, MarketSuccessData>();
      expect(marketOffersListenWhen(idle, success()), isTrue);
      expect(
        marketOffersListenWhen(
          idle,
          const TxFlowFailure<MarketPrepData, MarketSuccessData>(
            AppFailure.unknown('boom'),
          ),
        ),
        isTrue,
      );
    });

    test('does not re-fire on an unchanged success', () {
      expect(
        marketOffersListenWhen(success(indexed: true), success(indexed: true)),
        isFalse,
      );
    });
  });

  group('OffersScreen refetch gating', () {
    late _MockOffersInboxBloc offersBloc;
    late _MockMarketBloc marketBloc;
    late _MockTokenBalanceBloc tokenBalanceBloc;

    setUpAll(() {
      sl.registerLazySingleton<AvatarService>(
        () => AvatarService.forTest(_MockDio(), cacheDir: Directory.systemTemp),
      );
      if (!sl.isRegistered<RemoteConfigService>()) {
        sl.registerSingleton<RemoteConfigService>(
          _PermissiveRemoteConfigService(),
        );
      }
    });
    tearDownAll(() => sl.unregister<AvatarService>());

    setUp(() {
      offersBloc = _MockOffersInboxBloc();
      marketBloc = _MockMarketBloc();
      tokenBalanceBloc = _MockTokenBalanceBloc();

      whenListen(
        offersBloc,
        const Stream<OffersInboxState>.empty(),
        initialState: const OffersInboxState.loaded(
          items: [
            api.OffersInboxItem(
              kind: api.OffersInboxKind.offer,
              direction: api.OffersInboxDirection.received,
              asset: 'RecvArt',
              artworkTitle: 'RecvArt',
              actorAddress: 'ACTOR',
              viewerAddress: 'W1',
              rawAmount: 1000000000,
              currencyMint: solMint,
            ),
          ],
        ),
      );
      whenListen(
        tokenBalanceBloc,
        const Stream<TokenBalanceState>.empty(),
        initialState: const TokenBalanceState.initial(),
      );

      if (sl.isRegistered<OffersInboxBloc>()) sl.unregister<OffersInboxBloc>();
      if (sl.isRegistered<MarketBloc>()) sl.unregister<MarketBloc>();
      if (sl.isRegistered<TokenBalanceBloc>()) {
        sl.unregister<TokenBalanceBloc>();
      }
      sl.registerFactory<OffersInboxBloc>(() => offersBloc);
      sl.registerFactory<MarketBloc>(() => marketBloc);
      sl.registerFactory<TokenBalanceBloc>(() => tokenBalanceBloc);
    });

    tearDown(() {
      if (sl.isRegistered<OffersInboxBloc>()) sl.unregister<OffersInboxBloc>();
      if (sl.isRegistered<MarketBloc>()) sl.unregister<MarketBloc>();
      if (sl.isRegistered<TokenBalanceBloc>()) {
        sl.unregister<TokenBalanceBloc>();
      }
    });

    testWidgets(
      'the chain-confirmed success alone does not refetch — that read would '
      'return the still-live offer and re-arm its action pill',
      (tester) async {
        whenListen(
          marketBloc,
          Stream<MarketState>.fromIterable([success()]),
          initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
        );

        await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
        await tester.pumpAndSettle();

        verifyNever(() => offersBloc.add(const OffersInboxEvent.refresh()));
      },
    );

    testWidgets(
      'the indexer ack drives exactly one refetch — the gated emission must '
      'not be suppressed, or the list never updates at all',
      (tester) async {
        whenListen(
          marketBloc,
          Stream<MarketState>.fromIterable([success(), success(indexed: true)]),
          initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
        );

        await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
        await tester.pumpAndSettle();

        verify(
          () => offersBloc.add(const OffersInboxEvent.refresh()),
        ).called(1);
      },
    );

    testWidgets(
      'a flushed ack (indexed=false, emitted when a second market flow '
      'supersedes the first) still refetches — otherwise the settled offer '
      'keeps a live pill re-prompting against a closed Offer PDA',
      (tester) async {
        // `MarketBloc._emitFlow` flips `indexed` to false before leaving an
        // optimistic success for a new flow, precisely so this listener still
        // fires; the real ack that lands later is dropped by the bloc, so the
        // refetch must happen exactly once here.
        whenListen(
          marketBloc,
          Stream<MarketState>.fromIterable([
            success(),
            success(indexed: false),
            const TxFlowPreparing<MarketPrepData, MarketSuccessData>(),
          ]),
          initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
        );

        await tester.pumpWidget(const MaterialApp(home: OffersScreen()));
        await tester.pumpAndSettle();

        verify(
          () => offersBloc.add(const OffersInboxEvent.refresh()),
        ).called(1);
      },
    );

    // Returning from the artwork screen is the *other* way a row in this feed
    // gets resolved: the artwork screen runs its own MarketBloc, so settling
    // an auction (or accepting/cancelling) there completes on a route this
    // screen's listener never observes. Without a refetch on pop, the dead row
    // is still on screen and its action pill re-prompts the signer against an
    // account that no longer exists.
    testWidgets(
      'refetches when the pushed artwork screen pops, not when it opens',
      (tester) async {
        whenListen(
          marketBloc,
          const Stream<MarketState>.empty(),
          initialState: const TxFlowIdle<MarketPrepData, MarketSuccessData>(),
        );
        // A bid row deep-links straight to the artwork (auctions have no
        // in-app re-bid flow) — no signer re-point in the way.
        whenListen(
          offersBloc,
          const Stream<OffersInboxState>.empty(),
          initialState: const OffersInboxState.loaded(
            items: [
              api.OffersInboxItem(
                kind: api.OffersInboxKind.bid,
                direction: api.OffersInboxDirection.received,
                asset: 'MINT',
                artworkTitle: 'BidArt',
                actorAddress: 'ACTOR',
                viewerAddress: 'W1',
                rawAmount: 1000000000,
                currencyMint: solMint,
              ),
            ],
          ),
        );

        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const OffersScreen()),
            GoRoute(
              path: '/artwork/:mint',
              builder: (_, _) =>
                  const Scaffold(body: Center(child: Text('artwork'))),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        await tester.tap(find.text('View'));
        await tester.pumpAndSettle();
        expect(find.text('artwork'), findsOneWidget);
        // Refetching on the way *in* would be wasted work and would drop the
        // rows out from under the screen the user is leaving.
        verifyNever(() => offersBloc.add(const OffersInboxEvent.refresh()));

        router.pop();
        await tester.pumpAndSettle();

        verify(
          () => offersBloc.add(const OffersInboxEvent.refresh()),
        ).called(1);
      },
    );
  });
}
