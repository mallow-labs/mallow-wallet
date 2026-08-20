import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' show ListingType;
import 'package:mallow_wallet/core/config/remote_config.dart';
import 'package:mallow_wallet/di.dart';
import 'package:mallow_wallet/features/artwork/models/on_chain_asset.dart';
import 'package:mallow_wallet/features/artwork/screens/transfer_artwork_chooser_screen.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_permission_service.dart';
import 'package:mallow_wallet/features/portfolio/data/portfolio_repository.dart';
import 'package:mallow_wallet/features/portfolio/services/portfolio_bloc.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/chain.dart' show Chain;
import 'package:mocktail/mocktail.dart';

// The FAB "Transfer artwork" chooser reaches the transfer flow directly from a
// `byOwner` picker that has no listing, frozen or delegate filter — the same
// exposure as the context menu's Transfer row, by a shorter path. On a listing
// that delegates rather than escrows (edition listings, non-custodial, external
// markets) the transfer *confirms* and orphans the listing, so simulation does
// not save us; the gate has to run before the flow opens. And when it refuses,
// it must say why: a picker that silently does nothing on tap is the failure
// mode this whole audit is trying to eliminate.

class _MockPermissionService extends Mock implements ArtworkPermissionService {}

class _MockPortfolioRepository extends Mock implements PortfolioRepository {}

PortfolioArtwork _artwork({
  ListingType? listingType,
  String mintAccount = 'mint1',
  String? chain,
}) => PortfolioArtwork(
  mintAccount: mintAccount,
  title: 'T',
  imageUrl: '',
  artistName: 'A',
  listingType: listingType,
  chain: chain,
);

void main() {
  late _MockPermissionService permissions;

  setUp(() {
    permissions = _MockPermissionService();
    if (sl.isRegistered<ArtworkPermissionService>()) {
      sl.unregister<ArtworkPermissionService>();
    }
    sl.registerSingleton<ArtworkPermissionService>(permissions);
  });

  tearDown(() {
    if (sl.isRegistered<ArtworkPermissionService>()) {
      sl.unregister<ArtworkPermissionService>();
    }
  });

  void stub({required bool canTransfer}) {
    when(
      () => permissions.checkPermissions(
        any(),
        sessionAddresses: any(named: 'sessionAddresses'),
        listingType: any(named: 'listingType'),
        inGroupedSale: any(named: 'inGroupedSale'),
      ),
    ).thenAnswer(
      (_) async => ArtworkPermissions(
        canTransfer: canTransfer,
        canEdit: false,
        canBurn: false,
        canList: false,
      ),
    );
  }

  // The picker is a `byOwner` query with no chain filter, so a Tezos
  // artwork is listed here and, unfiltered, takes the *Solana* branch of the
  // transfer flow: the field hints "Solana address" and the confirm step throws
  // base58-decoding a `KT1…` mint. The chain arm has to run before the
  // permission check, which is itself a Solana DAS lookup.
  group('chain gate', () {
    test(
      'a Tezos artwork is refused, and never reaches the Solana lookup',
      () async {
        stub(canTransfer: true);
        final reason = await transferBlockedReason(
          _artwork(
            mintAccount: 'KT1TxqZ8QtKvLu3V3JH7Gx58n7Co8pgtpQU5',
            chain: 'tezos',
          ),
        );
        expect(reason, isNotNull);
        expect(reason, contains('Tezos'));
        // The copy names what *is* supported, derived from the flow's own
        // capability set rather than a literal in the screen.
        expect(reason, contains('Solana or Ethereum'));
        verifyNever(
          () => permissions.checkPermissions(
            any(),
            sessionAddresses: any(named: 'sessionAddresses'),
            listingType: any(named: 'listingType'),
            inGroupedSale: any(named: 'inGroupedSale'),
          ),
        );
      },
    );

    test('the gate is derived from the flow capability set, not a literal', () {
      // If EVM burn-style work ever widens or narrows what the transfer
      // builders implement, `AppFlow.nftTransfer.chains` moves and this screen
      // follows it. Tezos being absent is the whole reason the arm exists.
      expect(AppFlow.nftTransfer.chains, contains(Chain.solana));
      expect(AppFlow.nftTransfer.chains, contains(Chain.ethereum));
      expect(AppFlow.nftTransfer.chains, isNot(contains(Chain.tezos)));
    });

    test(
      'an Ethereum artwork passes the chain arm and is checked as usual',
      () async {
        // Guards the other direction: the filter must not swallow a chain the
        // flow does implement.
        stub(canTransfer: true);
        expect(
          await transferBlockedReason(
            _artwork(
              mintAccount: '0x1111111111111111111111111111111111111111-42',
              chain: 'ethereum',
            ),
          ),
          isNull,
        );
      },
    );
  });

  test('a transferable unlisted artwork passes the gate', () async {
    stub(canTransfer: true);
    expect(await transferBlockedReason(_artwork()), isNull);
  });

  test('a listed artwork is refused before the flow opens', () async {
    // Refused on the indexer term alone — no DAS round-trip is needed, and the
    // frozen bit would not have caught a delegate-only listing anyway.
    stub(canTransfer: true);
    final reason = await transferBlockedReason(
      _artwork(listingType: ListingType.buyNow),
    );
    expect(reason, isNotNull);
    expect(reason, contains('listed for sale'));
    verifyNever(
      () => permissions.checkPermissions(
        any(),
        sessionAddresses: any(named: 'sessionAddresses'),
        listingType: any(named: 'listingType'),
        inGroupedSale: any(named: 'inGroupedSale'),
      ),
    );
  });

  test('a frozen / delegated artwork is refused with a reason', () async {
    stub(canTransfer: false);
    final reason = await transferBlockedReason(_artwork());
    expect(reason, isNotNull);
    expect(reason, contains("can't be transferred"));
  });

  test(
    'an explicitly unlisted artwork still runs the on-chain check',
    () async {
      stub(canTransfer: true);
      expect(
        await transferBlockedReason(
          _artwork(listingType: ListingType.unlisted),
        ),
        isNull,
      );
      verify(
        () => permissions.checkPermissions(
          'mint1',
          listingType: ListingType.unlisted,
        ),
      ).called(1);
    },
  );
  // The gate exists to explain a refused tap. Before the `catch`, a throw from
  // the permission check (or its DI lookup) escaped to the zone handler with
  // the result never assigned: the spinner cleared and the tap did nothing at
  // all — the silent failure the whole gate is here to remove.
  testWidgets('a throwing permission check refuses out loud', (tester) async {
    final portfolio = _MockPortfolioRepository();
    when(() => portfolio.getOwnedArtworks()).thenAnswer(
      (_) async => PortfolioArtworksResult(
        artworks: [_artwork(mintAccount: 'mint-throws')],
        total: 1,
      ),
    );
    if (sl.isRegistered<PortfolioRepository>()) {
      sl.unregister<PortfolioRepository>();
    }
    sl.registerSingleton<PortfolioRepository>(portfolio);
    addTearDown(() {
      if (sl.isRegistered<PortfolioRepository>()) {
        sl.unregister<PortfolioRepository>();
      }
    });
    when(
      () => permissions.checkPermissions(
        any(),
        sessionAddresses: any(named: 'sessionAddresses'),
        listingType: any(named: 'listingType'),
        inGroupedSale: any(named: 'inGroupedSale'),
      ),
    ).thenThrow(Exception('DAS down'));

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const TransferArtworkChooserScreen(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('T'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining("Couldn't check this artwork"), findsOneWidget);
  });

  testWidgets('shows artworks from the cross-chain portfolio', (tester) async {
    final portfolio = _MockPortfolioRepository();
    when(() => portfolio.getOwnedArtworks()).thenAnswer(
      (_) async => PortfolioArtworksResult(
        artworks: [
          _artwork(
            mintAccount: '0x1111111111111111111111111111111111111111-42',
            chain: 'ethereum',
          ),
        ],
        total: 1,
      ),
    );
    if (sl.isRegistered<PortfolioRepository>()) {
      sl.unregister<PortfolioRepository>();
    }
    sl.registerSingleton<PortfolioRepository>(portfolio);
    addTearDown(() {
      if (sl.isRegistered<PortfolioRepository>()) {
        sl.unregister<PortfolioRepository>();
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: MallowTheme.lightTheme,
        home: const TransferArtworkChooserScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('T'), findsOneWidget);
    verify(() => portfolio.getOwnedArtworks()).called(1);
  });
}
