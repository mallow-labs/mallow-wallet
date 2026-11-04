import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/network/auth_service.dart';
import 'package:mallow_wallet/core/realtime/account_realtime_service.dart';
import 'package:mallow_wallet/features/artwork/data/artwork_repository.dart';
import 'package:mallow_wallet/features/artwork/data/auction_live_repository.dart';
import 'package:mallow_wallet/features/artwork/data/market_account_repository.dart';
import 'package:mallow_wallet/features/artwork/services/artwork_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockArtworkRepository extends Mock implements ArtworkRepository {}

class _MockAuthService extends Mock implements AuthService {}

class _MockAccountRealtimeService extends Mock
    implements AccountRealtimeService {}

class _MockAuctionLiveRepository extends Mock
    implements AuctionLiveRepository {}

class _MockMarketAccountRepository extends Mock
    implements MarketAccountRepository {}

ArtworkDetails _auctionArtwork({
  required double currentBidAmount,
  required String currentBidder,
  required DateTime endsAt,
  int bidCount = 1,
  DateTime? startsAt,
}) {
  return ArtworkDetails(
    mintAccount: 'MINT1',
    title: 'Test',
    imageUrl: 'https://x/img.png',
    description: null,
    artistName: 'Artist',
    artistAddress: 'ART1',
    listingType: ListingType.auction,
    auctionMetadata: AuctionMetadata(
      auctionAccount: 'AUCPDA',
      startsAt: startsAt,
      currentBidAmount: currentBidAmount,
      currentBidder: currentBidder,
      bidCount: bidCount,
      endsAt: endsAt,
    ),
  );
}

ArtworkDetails _unlistedArtwork() => const ArtworkDetails(
  mintAccount: 'MINT1',
  title: 'Test',
  imageUrl: 'https://x/img.png',
  description: null,
  artistName: 'Artist',
  artistAddress: 'ART1',
);

ArtworkDetails _buyNowArtwork({double amount = 1000000000}) => ArtworkDetails(
  mintAccount: 'MINT1',
  title: 'Test',
  imageUrl: 'https://x/img.png',
  description: null,
  artistName: 'Artist',
  artistAddress: 'ART1',
  listingType: ListingType.buyNow,
  price: amount,
  buyNowMetadata: BuyNowMetadata(amount: amount, listingAccount: 'LISTPDA'),
);

/// The flat `/v2/accounts/market/listing/...` record (u64 amounts are
/// decimal strings on the wire, times are raw unix ints).
AccountUpdate _listingAccount({
  required String price,
  String currencyMint = 'So11111111111111111111111111111111111111112',
  int editionsLimit = 0,
  bool buyerSetsPrice = false,
  int slot = 500,
}) => AccountUpdate.fromJson({
  'accountType': 'listing',
  'pubkey': 'LISTPDA',
  'program': 'mallow-market',
  'price': price,
  'currencyMint': currencyMint,
  'endTime': 0,
  'startTime': 0,
  'editionsLimit': editionsLimit,
  'buyerSetsPrice': buyerSetsPrice,
  'slot': slot,
});

/// The flat `/v2/accounts/auction/auction-config/...` record.
AccountUpdate _auctionConfigAccount({
  required String reservePrice,
  String? highestBidAmount,
  String? highestBidder,
  bool? cnftRefunded,
  int endTime = 0,
  int slot = 500,
}) => AccountUpdate.fromJson({
  'accountType': 'auctionConfig',
  'slot': slot,
  'pubkey': 'AUCPDA',
  'program': 'mallow-auction',
  'seller': 'SELLER',
  'bidMint': 'So11111111111111111111111111111111111111112',
  'reservePrice': reservePrice,
  'highestBidAmount': highestBidAmount ?? '0',
  'highestBidder': highestBidder ?? '11111111111111111111111111111111',
  'cnftRefunded': ?cnftRefunded,
  'minBidIncrementBps': 250,
  'minBidIncrement': '0',
  'timeExtPeriod': 900,
  'timeExtDelta': 900,
  'duration': 604800,
  'startTime': 0,
  'endTime': endTime,
});

/// A LISTED master/limited edition: same single `["listing", mint]` PDA as a
/// 1/1 (so we're subscribed to it via `buyNowMetadata.listingAccount`), but
/// ineligible for existence SYNTH/drift (`supplyType != oneOfOne`).
ArtworkDetails _editionBuyNowArtwork({double amount = 1000000000}) =>
    ArtworkDetails(
      mintAccount: 'MINT1',
      title: 'Test',
      imageUrl: 'https://x/img.png',
      description: null,
      artistName: 'Artist',
      artistAddress: 'ART1',
      supplyType: SupplyType.limitedEdition,
      isMasterEdition: true,
      listingType: ListingType.buyNow,
      price: amount,
      buyNowMetadata: BuyNowMetadata(
        amount: amount,
        listingAccount: 'LISTPDA',
        editionsLimit: 5,
      ),
    );

/// The flat `{ closed: true }` tombstone the listener pushes when a market /
/// auction PDA is closed on-chain (auction settled, listing sold/cancelled) —
/// no `accountType`, identified by [pubkey].
AccountUpdate _closedAccount(
  String pubkey, {
  String program = 'mallow-auction',
}) => AccountUpdate.fromJson({
  'pubkey': pubkey,
  'program': program,
  'closed': true,
  'slot': 123,
});

void main() {
  late _MockArtworkRepository repo;
  late _MockAuthService auth;
  late _MockAccountRealtimeService accountRealtime;
  late _MockAuctionLiveRepository auctionLive;
  late _MockMarketAccountRepository marketAccounts;

  final endsAt = DateTime.now().add(const Duration(hours: 1));

  setUpAll(() => registerFallbackValue(ContentType.nft));

  setUp(() {
    repo = _MockArtworkRepository();
    auth = _MockAuthService();
    accountRealtime = _MockAccountRealtimeService();
    auctionLive = _MockAuctionLiveRepository();
    marketAccounts = _MockMarketAccountRepository();

    when(() => auth.isLiked(any(), any())).thenReturn(false);
    // No real WS / snapshot in these tests — the overlay is driven directly
    // via events so we isolate the reconciliation logic.
    when(
      () => accountRealtime.watchAccount(any()),
    ).thenAnswer((_) => const Stream<AccountUpdate>.empty());
    when(() => auctionLive.getState(any())).thenAnswer((_) async => null);
    // Existence reconciliation reads the chain — default both to "undetermined"
    // so it's a no-op here and these tests stay focused on the field overlay.
    when(() => marketAccounts.readListing(any())).thenAnswer(
      (_) async => (
        status: OnChainReadStatus.unknown,
        account: null,
        pda: '',
        viewSlot: null,
      ),
    );
    when(() => marketAccounts.readAuctionConfig(any())).thenAnswer(
      (_) async => (
        status: OnChainReadStatus.unknown,
        account: null,
        pda: '',
        viewSlot: null,
      ),
    );
    // Subscribe-first derives the Listing / AuctionConfig PDAs at load;
    // stub them so the early subscription opens against the same watched keys.
    when(
      () => marketAccounts.deriveListingPda(any()),
    ).thenAnswer((_) async => 'LISTPDA');
    when(
      () => marketAccounts.deriveAuctionConfigPda(any()),
    ).thenAnswer((_) async => 'AUCPDA');
  });

  ArtworkBloc build() =>
      ArtworkBloc(repo, auth, accountRealtime, auctionLive, marketAccounts);

  Future<ArtworkBloc> loaded(ArtworkDetails details) async {
    when(() => repo.getArtworkDetail(any())).thenAnswer((_) async => details);
    final bloc = build();
    bloc.add(const ArtworkEvent.load(mintAccount: 'MINT1'));
    await Future<void>.delayed(Duration.zero);
    return bloc;
  }

  test(
    'refund clears stale winning bid and survives refresh and late bids',
    () async {
      final detail = _auctionArtwork(
        currentBidAmount: 1000000000,
        currentBidder: 'WINNER',
        endsAt: DateTime.utc(2028),
        startsAt: DateTime.utc(2027),
      );
      final bloc = await loaded(detail);
      final refunded = bloc.stream.firstWhere(
        (s) => s is ArtworkLoaded && s.artwork.auctionMetadata!.refunded,
      );
      bloc.add(
        const ArtworkEvent.auctionLiveUpdate(
          auctionAccount: 'AUCPDA',
          refunded: true,
        ),
      );
      await refunded;
      var metadata = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
      expect(metadata.currentBidder, isNull);
      expect(metadata.currentBidAmount, isNull);
      expect(metadata.bidCount, 0);
      bloc.add(
        const ArtworkEvent.auctionLiveUpdate(
          auctionAccount: 'AUCPDA',
          currentBidAmount: 2000000000,
          currentBidder: 'LATE',
        ),
      );
      final reloaded = bloc.stream.firstWhere(
        (s) => s is ArtworkLoaded && s.revision > 0,
      );
      bloc.add(const ArtworkEvent.refresh());
      await reloaded;
      metadata = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
      expect(metadata.refunded, isTrue);
      expect(metadata.currentBidder, isNull);
      expect(metadata.bidCount, 0);
      // Drain the mocked refresh reconciliation before closing its event sink.
      await Future<void>(() {});
      await bloc.close();
    },
  );

  test('legacy account refund fallback overrides an indexed auction', () async {
    final detail = _auctionArtwork(
      currentBidAmount: 1000000000,
      currentBidder: 'WINNER',
      endsAt: DateTime.utc(2028),
    );
    when(() => marketAccounts.readAuctionConfig(any())).thenAnswer(
      (_) async => (
        status: OnChainReadStatus.present,
        account: AccountUpdate.fromJson({
          'pubkey': 'AUCPDA',
          'accountType': 'auctionConfig',
          'seller': 'SELLER',
          'highestBidAmount': '0',
          'highestBidder': 'WINNER',
        }),
        pda: 'AUCPDA',
        viewSlot: 500,
      ),
    );
    when(() => repo.getArtworkDetail(any())).thenAnswer((_) async => detail);
    final bloc = build();
    final refunded = bloc.stream.firstWhere(
      (s) => s is ArtworkLoaded && s.artwork.auctionMetadata!.refunded,
    );
    bloc.add(const ArtworkEvent.load(mintAccount: 'MINT1'));
    await refunded;
    final metadata = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
    expect(metadata.currentBidder, isNull);
    expect(metadata.currentBidAmount, isNull);
    await bloc.close();
  });

  test(
    'refund parsing supports the old decoder without mislabeling no-bid auctions',
    () {
      AccountUpdate account(Map<String, dynamic> fields) =>
          AccountUpdate.fromJson({
            'pubkey': 'AUCPDA',
            'accountType': 'auctionConfig',
            ...fields,
          });
      expect(account({'cnftRefunded': true}).cnftRefunded, isTrue);
      for (final bidder in ['WINNER', '11111111111111111111111111111111']) {
        expect(
          account({
            'cnftRefunded': true,
            'highestBidAmount': '0',
            'highestBidder': bidder,
          }).cnftRefunded,
          isTrue,
        );
      }
      expect(
        account({
          'highestBidAmount': '0',
          'highestBidder': 'WINNER',
        }).cnftRefunded,
        isTrue,
      );
      expect(
        account({
          'highestBidAmount': '0',
          'highestBidder': '11111111111111111111111111111111',
        }).cnftRefunded,
        isFalse,
      );
      expect(
        account({
          'highestBidAmount': '1',
          'highestBidder': 'WINNER',
        }).cnftRefunded,
        isFalse,
      );
      expect(account({'highestBidder': 'WINNER'}).cnftRefunded, isFalse);
      expect(
        account({
          'cnftRefunded': false,
          'highestBidAmount': '0',
          'highestBidder': 'WINNER',
        }).cnftRefunded,
        isFalse,
      );
    },
  );

  void stubReads({MarketAccountRead? listing, MarketAccountRead? auction}) {
    when(() => marketAccounts.readListing(any())).thenAnswer(
      (_) async =>
          listing ??
          (
            status: OnChainReadStatus.unknown,
            account: null,
            pda: 'LISTPDA',
            viewSlot: null,
          ),
    );
    when(() => marketAccounts.readAuctionConfig(any())).thenAnswer(
      (_) async =>
          auction ??
          (
            status: OnChainReadStatus.unknown,
            account: null,
            pda: 'AUCPDA',
            viewSlot: null,
          ),
    );
  }

  ArtworkDetails refundedArtwork() => _unlistedArtwork().copyWith(
    auctionMetadata: AuctionMetadata(
      auctionAccount: 'AUCPDA',
      refunded: true,
      startsAt: DateTime.utc(2026, 10),
    ),
  );

  Future<void> refreshWith(ArtworkBloc bloc, ArtworkDetails detail) async {
    when(() => repo.getArtworkDetail(any())).thenAnswer((_) async => detail);
    final revision = (bloc.state as ArtworkLoaded).revision;
    final refreshed = bloc.stream.firstWhere(
      (s) => s is ArtworkLoaded && s.revision > revision,
    );
    bloc.add(const ArtworkEvent.refresh());
    await refreshed;
    // Drain the mocked account reads and the reconcile they dispatch.
    await Future<void>(() {});
  }

  test('an absent cold read clears an unlisted refunded auction', () async {
    stubReads(
      auction: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'AUCPDA',
        viewSlot: 600,
      ),
    );
    final bloc = await loaded(refundedArtwork());
    addTearDown(bloc.close);
    await Future<void>(() {});
    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.auctionMetadata, isNull);
  });

  test(
    'an auction-close tombstone clears unlisted refunded metadata',
    () async {
      final frames = StreamController<AccountUpdate>.broadcast();
      addTearDown(frames.close);
      when(
        () => accountRealtime.watchAccount('AUCPDA'),
      ).thenAnswer((_) => frames.stream);
      final bloc = await loaded(refundedArtwork());
      addTearDown(bloc.close);
      frames.add(_closedAccount('AUCPDA'));
      await Future<void>(() {});
      final artwork = (bloc.state as ArtworkLoaded).artwork;
      expect(artwork.listingType, ListingType.unlisted);
      expect(artwork.auctionMetadata, isNull);
    },
  );

  test(
    'refund then close allows a live relist on the same auction PDA',
    () async {
      final frames = StreamController<AccountUpdate>.broadcast();
      addTearDown(frames.close);
      when(
        () => accountRealtime.watchAccount('AUCPDA'),
      ).thenAnswer((_) => frames.stream);
      final bloc = await loaded(refundedArtwork());
      addTearDown(bloc.close);
      frames.add(_auctionConfigAccount(reservePrice: '0', cnftRefunded: true));
      await Future<void>(() {});
      frames.add(_closedAccount('AUCPDA'));
      await Future<void>(() {});
      final relisted = _auctionArtwork(
        currentBidAmount: 2000000000,
        currentBidder: 'NEW_BIDDER',
        endsAt: endsAt,
      );
      await refreshWith(bloc, relisted);
      final artwork = (bloc.state as ArtworkLoaded).artwork;
      expect(artwork.listingType, ListingType.auction);
      expect(artwork.auctionMetadata!.refunded, isFalse);
      expect(artwork.auctionMetadata!.currentBidder, 'NEW_BIDDER');
      expect(artwork.auctionMetadata!.bidCount, 1);
    },
  );

  test(
    'a close retires the refund overlay even during local-action grace',
    () async {
      final frames = StreamController<AccountUpdate>.broadcast();
      addTearDown(frames.close);
      when(
        () => accountRealtime.watchAccount('AUCPDA'),
      ).thenAnswer((_) => frames.stream);
      final original = refundedArtwork();
      final bloc = await loaded(original);
      addTearDown(bloc.close);
      bloc.add(
        const ArtworkEvent.auctionLiveUpdate(
          auctionAccount: 'AUCPDA',
          refunded: true,
        ),
      );
      bloc.add(
        const ArtworkEvent.optimisticListingUpdate(
          cancelled: true,
          signature: 'LOCAL_ACTION',
        ),
      );
      await Future<void>(() {});
      frames.add(_closedAccount('AUCPDA'));
      await Future<void>(() {});
      // Grace still protects the displayed metadata, but the closed account's
      // cached overlay must be retired independently of that guard.
      expect(
        (bloc.state as ArtworkLoaded).artwork.auctionMetadata?.refunded,
        isTrue,
      );
      await refreshWith(bloc, _unlistedArtwork());
      final relisted = _auctionArtwork(
        currentBidAmount: 2000000000,
        currentBidder: 'NEW_BIDDER',
        endsAt: endsAt,
      );
      await refreshWith(bloc, relisted);
      expect(
        (bloc.state as ArtworkLoaded).artwork.auctionMetadata,
        relisted.auctionMetadata,
      );
    },
  );

  test(
    'a newer indexed auction supersedes a refund overlay after a missed close',
    () async {
      final original = refundedArtwork();
      final bloc = await loaded(original);
      addTearDown(bloc.close);
      bloc.add(
        const ArtworkEvent.auctionLiveUpdate(
          auctionAccount: 'AUCPDA',
          refunded: true,
        ),
      );
      await Future<void>(() {});
      final relisted = _auctionArtwork(
        currentBidAmount: 2000000000,
        currentBidder: 'NEW_BIDDER',
        endsAt: endsAt,
      );
      final newer = relisted.copyWith(
        auctionMetadata: relisted.auctionMetadata!.copyWith(
          startsAt: original.auctionMetadata!.startsAt!.add(
            const Duration(days: 1),
          ),
        ),
      );
      await refreshWith(bloc, newer);
      expect(
        (bloc.state as ArtworkLoaded).artwork.auctionMetadata,
        newer.auctionMetadata,
      );
      // The stale refund must also be gone from the cache for later refreshes.
      await refreshWith(bloc, newer);
      expect(
        (bloc.state as ArtworkLoaded).artwork.auctionMetadata,
        newer.auctionMetadata,
      );
    },
  );

  for (final missingStart in ['indexed', 'overlay']) {
    test(
      'unknown $missingStart start retires refund overlay after a missed close',
      () async {
        var original = refundedArtwork();
        if (missingStart == 'overlay') {
          original = original.copyWith(
            auctionMetadata: original.auctionMetadata!.copyWith(startsAt: null),
          );
        }
        final bloc = await loaded(original);
        addTearDown(bloc.close);
        bloc.add(
          const ArtworkEvent.auctionLiveUpdate(
            auctionAccount: 'AUCPDA',
            refunded: true,
          ),
        );
        await Future<void>(() {});
        var relisted = _auctionArtwork(
          currentBidAmount: 2000000000,
          currentBidder: 'NEW',
          endsAt: endsAt,
        );
        if (missingStart == 'overlay') {
          relisted = relisted.copyWith(
            auctionMetadata: relisted.auctionMetadata!.copyWith(
              startsAt: DateTime.utc(2026, 10, 2),
            ),
          );
        }
        await refreshWith(bloc, relisted);
        expect(
          (bloc.state as ArtworkLoaded).artwork.auctionMetadata,
          relisted.auctionMetadata,
        );
        await refreshWith(bloc, relisted);
        expect(
          (bloc.state as ArtworkLoaded).artwork.auctionMetadata,
          relisted.auctionMetadata,
        );
      },
    );
  }

  test(
    'present non-refunded account replaces terminal metadata and cached overlay',
    () async {
      final original = refundedArtwork();
      final bloc = await loaded(original);
      addTearDown(bloc.close);
      bloc.add(
        const ArtworkEvent.auctionLiveUpdate(
          auctionAccount: 'AUCPDA',
          refunded: true,
        ),
      );
      await Future<void>(() {});
      stubReads(
        auction: (
          status: OnChainReadStatus.present,
          account: _auctionConfigAccount(
            reservePrice: '1000000000',
            highestBidAmount: '2000000000',
            highestBidder: 'NEW',
            cnftRefunded: false,
          ),
          pda: 'AUCPDA',
          viewSlot: 500,
        ),
      );
      // The indexer still serves terminal metadata; the account read is authoritative.
      await refreshWith(bloc, original);
      var auction = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
      expect(auction.refunded, isFalse);
      expect(auction.currentBidder, 'NEW');
      expect(auction.currentBidAmount, 2000000000);
      final live = (bloc.state as ArtworkLoaded).artwork;
      stubReads();
      await refreshWith(bloc, live);
      auction = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
      expect(auction.refunded, isFalse);
      expect(auction.currentBidder, 'NEW');
    },
  );

  for (final viewSlot in <int?>[null, 400, 600]) {
    test(
      'unlisted refunded auction respects non-refunded account view $viewSlot',
      () async {
        final frames = StreamController<AccountUpdate>.broadcast();
        addTearDown(frames.close);
        when(
          () => accountRealtime.watchAccount('AUCPDA'),
        ).thenAnswer((_) => frames.stream);
        final original = refundedArtwork();
        final bloc = await loaded(original);
        addTearDown(bloc.close);
        frames.add(
          _auctionConfigAccount(
            reservePrice: '0',
            cnftRefunded: true,
            slot: 500,
          ),
        );
        await Future<void>(() {});
        stubReads(
          auction: (
            status: OnChainReadStatus.present,
            account: _auctionConfigAccount(
              reservePrice: '1000000000',
              highestBidAmount: '2000000000',
              highestBidder: 'OLD',
              cnftRefunded: false,
            ),
            pda: 'AUCPDA',
            viewSlot: viewSlot,
          ),
        );
        await refreshWith(bloc, original);
        final artwork = (bloc.state as ArtworkLoaded).artwork;
        if (viewSlot == 600) {
          expect(artwork.listingType, ListingType.auction);
          expect(artwork.auctionMetadata!.refunded, isFalse);
          expect(artwork.auctionMetadata!.currentBidder, 'OLD');
        } else {
          expect(artwork.listingType, ListingType.unlisted);
          expect(artwork.auctionMetadata!.refunded, isTrue);
          expect(artwork.auctionMetadata!.currentBidder, isNull);
          expect(artwork.auctionMetadata!.bidCount, 0);
        }
      },
    );
  }

  test(
    'refund overlay survives a stale indexed auction with the same start',
    () async {
      final original = refundedArtwork();
      final bloc = await loaded(original);
      addTearDown(bloc.close);
      bloc.add(
        const ArtworkEvent.auctionLiveUpdate(
          auctionAccount: 'AUCPDA',
          refunded: true,
        ),
      );
      await Future<void>(() {});
      await refreshWith(
        bloc,
        original.copyWith(
          listingType: ListingType.auction,
          auctionMetadata: original.auctionMetadata!.copyWith(
            refunded: false,
            currentBidAmount: 1000000000,
            currentBidder: 'STALE',
            bidCount: 1,
          ),
        ),
      );
      final metadata = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
      expect(metadata.refunded, isTrue);
      expect(metadata.currentBidder, isNull);
      expect(metadata.bidCount, 0);
    },
  );

  for (final viewSlot in <int?>[null, 400, 600]) {
    test(
      'refunded metadata respects auction presence for absent view $viewSlot',
      () async {
        final frames = StreamController<AccountUpdate>.broadcast();
        addTearDown(frames.close);
        when(
          () => accountRealtime.watchAccount('AUCPDA'),
        ).thenAnswer((_) => frames.stream);
        final bloc = await loaded(refundedArtwork());
        addTearDown(bloc.close);
        frames.add(
          _auctionConfigAccount(reservePrice: '0', cnftRefunded: true),
        );
        await Future<void>(() {});
        stubReads(
          auction: (
            status: OnChainReadStatus.absent,
            account: null,
            pda: 'AUCPDA',
            viewSlot: viewSlot,
          ),
        );
        await refreshWith(bloc, refundedArtwork());
        final metadata = (bloc.state as ArtworkLoaded).artwork.auctionMetadata;
        if (viewSlot == 600) {
          expect(metadata, isNull);
          stubReads();
          await refreshWith(
            bloc,
            _auctionArtwork(
              currentBidAmount: 2000000000,
              currentBidder: 'NEW_BIDDER',
              endsAt: endsAt,
            ),
          );
          expect(
            (bloc.state as ArtworkLoaded).artwork.auctionMetadata!.refunded,
            isFalse,
          );
        } else {
          expect(metadata?.refunded, isTrue);
        }
      },
    );
  }

  test(
    'auction absence preserves a fixed-price relist while clearing its old refund',
    () async {
      stubReads(
        auction: (
          status: OnChainReadStatus.absent,
          account: null,
          pda: 'AUCPDA',
          viewSlot: 600,
        ),
      );
      final detail = _buyNowArtwork().copyWith(
        auctionMetadata: refundedArtwork().auctionMetadata,
      );
      final bloc = await loaded(detail);
      addTearDown(bloc.close);
      await Future<void>(() {});
      final artwork = (bloc.state as ArtworkLoaded).artwork;
      expect(artwork.auctionMetadata, isNull);
      expect(artwork.listingType, ListingType.buyNow);
      expect(artwork.price, detail.price);
      expect(artwork.buyNowMetadata, detail.buyNowMetadata);
    },
  );

  for (final hasBids in [false, true]) {
    final bidder = hasBids ? 'WINNER' : '11111111111111111111111111111111';
    for (final indexed in [false, true]) {
      test('explicit account refund is terminal with bids=$hasBids, '
          'indexed=$indexed', () async {
        stubReads(
          auction: (
            status: OnChainReadStatus.present,
            account: _auctionConfigAccount(
              reservePrice: '500000000',
              highestBidAmount: '0',
              highestBidder: bidder,
              cnftRefunded: true,
            ),
            pda: 'AUCPDA',
            viewSlot: 500,
          ),
        );
        when(() => repo.getArtworkDetail(any())).thenAnswer(
          (_) async => indexed
              ? _auctionArtwork(
                  currentBidAmount: 1000000000,
                  currentBidder: 'STALE',
                  endsAt: endsAt,
                )
              : _unlistedArtwork(),
        );
        final bloc = build();
        addTearDown(bloc.close);
        final refunded = bloc.stream.firstWhere(
          (s) =>
              s is ArtworkLoaded && s.artwork.auctionMetadata?.refunded == true,
        );
        bloc.add(const ArtworkEvent.load(mintAccount: 'MINT1'));
        final state = await refunded as ArtworkLoaded;
        expect(state.artwork.auctionMetadata!.currentBidAmount, isNull);
        expect(state.artwork.auctionMetadata!.currentBidder, isNull);
        expect(state.artwork.auctionMetadata!.bidCount, 0);
      });
    }

    test(
      'websocket explicit refund clears stale bids with bids=$hasBids',
      () async {
        final frames = StreamController<AccountUpdate>.broadcast();
        addTearDown(frames.close);
        when(
          () => accountRealtime.watchAccount('AUCPDA'),
        ).thenAnswer((_) => frames.stream);
        final bloc = await loaded(
          _auctionArtwork(
            currentBidAmount: 1000000000,
            currentBidder: 'STALE',
            endsAt: endsAt,
          ),
        );
        addTearDown(bloc.close);
        final refunded = bloc.stream.firstWhere(
          (s) =>
              s is ArtworkLoaded && s.artwork.auctionMetadata?.refunded == true,
        );
        frames.add(
          _auctionConfigAccount(
            reservePrice: '500000000',
            highestBidAmount: '0',
            highestBidder: bidder,
            cnftRefunded: true,
          ),
        );
        final state = await refunded as ArtworkLoaded;
        expect(state.artwork.auctionMetadata!.currentBidAmount, isNull);
        expect(state.artwork.auctionMetadata!.currentBidder, isNull);
        expect(state.artwork.auctionMetadata!.bidCount, 0);
      },
    );

    test(
      'live snapshot explicit refund clears stale bids with bids=$hasBids',
      () async {
        when(() => auctionLive.getState(any())).thenAnswer(
          (_) async => AuctionLiveState.fromJson({
            'auctionAccount': 'AUCPDA',
            'seller': 'SELLER',
            'bidMint': 'SOL',
            'reservePrice': 500000000,
            'refunded': true,
            'currentBidAmount': 0,
            'currentBidder': bidder,
            'bidCount': hasBids ? 1 : 0,
          }),
        );
        when(() => repo.getArtworkDetail(any())).thenAnswer(
          (_) async => _auctionArtwork(
            currentBidAmount: 1000000000,
            currentBidder: 'STALE',
            endsAt: endsAt,
          ),
        );
        final bloc = build();
        addTearDown(bloc.close);
        final refunded = bloc.stream.firstWhere(
          (s) =>
              s is ArtworkLoaded && s.artwork.auctionMetadata?.refunded == true,
        );
        bloc.add(const ArtworkEvent.load(mintAccount: 'MINT1'));
        final state = await refunded as ArtworkLoaded;
        expect(state.artwork.auctionMetadata!.currentBidAmount, isNull);
        expect(state.artwork.auctionMetadata!.currentBidder, isNull);
        expect(state.artwork.auctionMetadata!.bidCount, 0);
      },
    );
  }

  test('a higher live bid overlays bid amount, bidder and extended end '
      'time without bumping revision', () async {
    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 1.0,
        currentBidder: 'OLD_BIDDER',
        endsAt: endsAt,
      ),
    );
    final loadedState = bloc.state as ArtworkLoaded;
    expect(loadedState.revision, 0);

    final extended = endsAt.add(const Duration(minutes: 5));
    bloc.add(
      ArtworkEvent.auctionLiveUpdate(
        auctionAccount: 'AUCPDA',
        currentBidAmount: 2.0,
        currentBidder: 'NEW_BIDDER',
        endsAt: extended,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final state = bloc.state as ArtworkLoaded;
    final auction = state.artwork.auctionMetadata!;
    expect(auction.currentBidAmount, 2.0);
    expect(auction.currentBidder, 'NEW_BIDDER');
    expect(auction.endsAt, extended);
    // A live overlay is not an indexer refresh — paged sections must not
    // re-mount, so the revision is preserved.
    expect(state.revision, 0);

    await bloc.close();
  });

  test('an out-of-order lower bid is ignored', () async {
    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 2.0,
        currentBidder: 'WINNER',
        endsAt: endsAt,
      ),
    );

    bloc.add(
      const ArtworkEvent.auctionLiveUpdate(
        auctionAccount: 'AUCPDA',
        currentBidAmount: 1.0,
        currentBidder: 'STALE',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final auction = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
    expect(auction.currentBidAmount, 2.0);
    expect(auction.currentBidder, 'WINNER');

    await bloc.close();
  });

  test('a frame for a stale auction account is ignored', () async {
    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 1.0,
        currentBidder: 'WINNER',
        endsAt: endsAt,
      ),
    );

    bloc.add(
      const ArtworkEvent.auctionLiveUpdate(
        auctionAccount: 'DIFFERENT_PDA',
        currentBidAmount: 9.0,
        currentBidder: 'IMPOSTER',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final auction = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
    expect(auction.currentBidAmount, 1.0);
    expect(auction.currentBidder, 'WINNER');

    await bloc.close();
  });

  test('snapshot prime preserves the raw on-chain bid amount', () async {
    // The GET /v2/auctions/:mint snapshot returns the bid in raw atomic units
    // (bidMint's smallest unit) — the same unit the indexed byMint value and
    // every price widget expect (the widget divides by the token's decimals).
    // The overlay must pass it through unscaled; dividing by 1e9 (a legacy
    // SOL-only assumption) showed the highest bid ~1e9x too small and broke
    // non-SOL auctions outright. Matches the reference web client's
    // `auctionConfigToAuctionMetadata` (raw `highestBidAmount.toNumber()`).
    when(() => auctionLive.getState(any())).thenAnswer(
      (_) async => const AuctionLiveState(
        auctionAccount: 'AUCPDA',
        seller: 'SELLER',
        bidMint: 'So11111111111111111111111111111111111111112',
        reservePrice: 500000000,
        currentBidAmount: 2000000000, // 2 SOL, raw lamports
        currentBidder: 'SNAP_BIDDER',
        bidCount: 3,
      ),
    );

    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 1.0,
        currentBidder: 'OLD_BIDDER',
        endsAt: endsAt,
      ),
    );
    // Let the unawaited prime resolve and dispatch its overlay event.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final auction = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
    expect(auction.currentBidAmount, 2000000000); // raw, not scaled to 2.0
    expect(auction.currentBidder, 'SNAP_BIDDER');
    expect(auction.bidCount, 3);

    await bloc.close();
  });

  test('optimisticClaimOwnership flips to owner + unlisted and clears the '
      'auction without bumping revision', () async {
    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 2.0,
        currentBidder: 'ME',
        endsAt: endsAt,
      ),
    );
    expect((bloc.state as ArtworkLoaded).revision, 0);

    bloc.add(const ArtworkEvent.optimisticClaimOwnership(owner: 'ME'));
    await Future<void>.delayed(Duration.zero);

    final state = bloc.state as ArtworkLoaded;
    final artwork = state.artwork;
    // The connected wallet is now the owner so the resolver routes to the
    // "List artwork" sheet immediately.
    expect(artwork.ownerAddress, 'ME');
    expect(artwork.ownerAddresses, ['ME']);
    // The settled auction is gone — no claim sheet should resolve any more.
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.auctionMetadata, isNull);
    expect(artwork.price, isNull);
    // Optimistic, not an indexer refresh — paged sections must not re-mount.
    expect(state.revision, 0);

    await bloc.close();
  });

  test('a just-confirmed claim survives a stale byMint refresh (durable '
      'optimism journal)', () async {
    // After the claim the artwork is owned + unlisted on chain. A lagging
    // byMint refresh that still returns the ended auction must NOT revert the
    // claim (the pre-journal bug: the sheet bounced back to "Claim NFT"). The
    // journal re-applies the owner-unlisted flip on every refresh until byMint
    // reports the new owner, so the claim is durable — and the stale higher-bid
    // overlay is gone with it.
    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 2.0,
        currentBidder: 'ME',
        endsAt: endsAt,
      ),
    );
    // Seed an overlay with a DISTINCT higher bid (as a live WS frame would).
    bloc.add(
      const ArtworkEvent.auctionLiveUpdate(
        auctionAccount: 'AUCPDA',
        currentBidAmount: 5.0,
        currentBidder: 'OTHER',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      (bloc.state as ArtworkLoaded).artwork.auctionMetadata!.currentBidAmount,
      5.0,
    );

    bloc.add(
      const ArtworkEvent.optimisticClaimOwnership(
        owner: 'ME',
        signature: 'CLAIM_SIG',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    // A lagging refresh that still reports the pre-settlement auction — byMint
    // has NOT caught up to the transfer yet (owner still absent, listing live).
    when(() => repo.getArtworkDetail(any())).thenAnswer(
      (_) async => _auctionArtwork(
        currentBidAmount: 2.0,
        currentBidder: 'ME',
        endsAt: endsAt,
      ),
    );
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(Duration.zero);

    // The claim is NOT reverted: owner + unlisted persist, the auction (and its
    // stale overlay) stay cleared, because the journal entry hasn't been
    // satisfied by byMint yet.
    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.ownerAddress, 'ME');
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.auctionMetadata, isNull);

    await bloc.close();
  });

  test('an optimistic claim journal entry self-drops once byMint reflects the '
      'new owner + unlisted state', () async {
    // Once the indexer catches up (owner = ME, unlisted), the journal entry is
    // redundant and dropped so it can no longer override server truth.
    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 2.0,
        currentBidder: 'ME',
        endsAt: endsAt,
      ),
    );
    bloc.add(
      const ArtworkEvent.optimisticClaimOwnership(
        owner: 'ME',
        signature: 'CLAIM_SIG',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    // byMint now reports the settled truth: ME owns it, unlisted.
    when(() => repo.getArtworkDetail(any())).thenAnswer(
      (_) async => const ArtworkDetails(
        mintAccount: 'MINT1',
        title: 'Test',
        imageUrl: 'https://x/img.png',
        description: null,
        artistName: 'Artist',
        artistAddress: 'ART1',
        ownerAddress: 'ME',
        ownerAddresses: ['ME'],
      ),
    );
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(Duration.zero);
    expect((bloc.state as ArtworkLoaded).artwork.ownerAddress, 'ME');

    // A subsequent refresh that (hypothetically) reports a NEW listing must now
    // win — the claim entry is gone, so it no longer forces unlisted.
    when(
      () => repo.getArtworkDetail(any()),
    ).thenAnswer((_) async => _buyNowArtwork());
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(Duration.zero);
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.buyNow,
    );

    await bloc.close();
  });

  test('a cancelled listing stays unlisted across a stale refresh, then '
      'self-drops once byMint reads unlisted', () async {
    final bloc = await loaded(_buyNowArtwork());
    bloc.add(
      const ArtworkEvent.optimisticListingUpdate(
        cancelled: true,
        signature: 'CANCEL_SIG',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.unlisted,
    );

    // A lagging refresh that STILL shows the listing must not bounce it back.
    when(
      () => repo.getArtworkDetail(any()),
    ).thenAnswer((_) async => _buyNowArtwork());
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(Duration.zero);
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.unlisted,
    );

    // Once byMint agrees (unlisted), the entry self-drops — a later refresh
    // that shows a fresh listing is honored.
    when(
      () => repo.getArtworkDetail(any()),
    ).thenAnswer((_) async => _unlistedArtwork());
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(Duration.zero);
    when(
      () => repo.getArtworkDetail(any()),
    ).thenAnswer((_) async => _buyNowArtwork(amount: 2000000000));
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(Duration.zero);
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.buyNow,
    );
    await bloc.close();
  });

  test('an optimistic price update applies the RAW amount and survives a '
      'stale refresh (findings 1 + 7)', () async {
    // 5 USDC = 5_000_000 raw (6 decimals). The raw amount must pass through
    // unscaled — the pre-fix ×1e9 round-trip rendered it 1000× too large.
    final bloc = await loaded(_buyNowArtwork());
    bloc.add(
      const ArtworkEvent.optimisticListingUpdate(
        newPriceRaw: 5000000,
        signature: 'PRICE_SIG',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    var artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.price, 5000000);
    expect(artwork.buyNowMetadata?.amount, 5000000);

    // A lagging refresh still reporting the OLD price must not revert it.
    when(
      () => repo.getArtworkDetail(any()),
    ).thenAnswer((_) async => _buyNowArtwork());
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(Duration.zero);
    artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.buyNowMetadata?.amount, 5000000);

    // byMint catches up to the new price → entry self-drops.
    when(
      () => repo.getArtworkDetail(any()),
    ).thenAnswer((_) async => _buyNowArtwork(amount: 5000000));
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(Duration.zero);
    expect(
      (bloc.state as ArtworkLoaded).artwork.buyNowMetadata?.amount,
      5000000,
    );
    await bloc.close();
  });

  test('an in-flight existence read cannot resurrect a just-cancelled listing '
      '(grace + journal)', () async {
    // byMint keeps showing the listing AND the chain read still returns it
    // present (RPC lagging the user\'s own cancel). Neither may resurrect it.
    stubReads(
      listing: (
        status: OnChainReadStatus.present,
        account: _listingAccount(price: '1000000000'),
        pda: 'LISTPDA',
        viewSlot: null,
      ),
    );
    final bloc = await loaded(_buyNowArtwork());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    bloc.add(
      const ArtworkEvent.optimisticListingUpdate(
        cancelled: true,
        signature: 'CANCEL_SIG',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    // Stale refresh: byMint still lists it; reconcile reads the still-present
    // chain account. The grace window suppresses the synth and the journal
    // re-applies unlisted — so it stays unlisted.
    when(
      () => repo.getArtworkDetail(any()),
    ).thenAnswer((_) async => _buyNowArtwork());
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.unlisted,
    );
    await bloc.close();
  });

  test('a live listing frame with no indexed metadata synthesizes the missed '
      'listing via an existence read', () async {
    // At load the chain read is undetermined, so nothing synthesizes — the
    // artwork stays unlisted. Then a derived-PDA frame arrives for a listing
    // byMint never indexed; with no matching metadata the handler must
    // reconcile (not drop the frame), synthesizing the on-chain listing.
    final bloc = await loaded(_unlistedArtwork());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.unlisted,
    );

    // The listing now exists on chain; a live frame with no indexed metadata
    // triggers the synth path.
    stubReads(
      listing: (
        status: OnChainReadStatus.present,
        account: _listingAccount(price: '1500000000'),
        pda: 'LISTPDA',
        viewSlot: null,
      ),
    );
    bloc.add(
      const ArtworkEvent.listingLiveUpdate(
        listingAccount: 'LISTPDA',
        price: 1500000000,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.buyNow);
    expect(artwork.buyNowMetadata?.amount, 1500000000);
    await bloc.close();
  });

  test(
    'a live WS bid with no bidCount still registers as "has bids"',
    () async {
      // A fresh auction (bidCount 0) receives its first bid over the WS, which
      // carries no bidCount. The "has bids" gate (bidCount > 0) must still flip
      // so the sheet shows the live bid instead of the reserve price.
      final bloc = await loaded(
        _auctionArtwork(
          currentBidAmount: 0,
          currentBidder: '',
          endsAt: endsAt,
          bidCount: 0,
        ),
      );

      bloc.add(
        const ArtworkEvent.auctionLiveUpdate(
          auctionAccount: 'AUCPDA',
          currentBidAmount: 3.0,
          currentBidder: 'FIRST_BIDDER',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final auction = (bloc.state as ArtworkLoaded).artwork.auctionMetadata!;
      expect(auction.currentBidAmount, 3.0);
      expect(auction.currentBidder, 'FIRST_BIDDER');
      expect(auction.bidCount, 1); // synthesized from the applied bid
      await bloc.close();
    },
  );

  // ── On-chain existence reconciliation (synthesize / clear) ───────────────

  test(
    'absent Mallow listing PDA preserves an external buy-now listing',
    () async {
      stubReads(
        listing: (
          status: OnChainReadStatus.absent,
          account: null,
          pda: 'LISTPDA',
          viewSlot: null,
        ),
      );
      final bloc = await loaded(
        _buyNowArtwork().copyWith(lastSource: MarketSource.magicEden),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final artwork = (bloc.state as ArtworkLoaded).artwork;
      expect(artwork.listingType, ListingType.buyNow);
      expect(artwork.lastSource, MarketSource.magicEden);
      expect(artwork.price, 1000000000);
      await bloc.close();
    },
  );

  test(
    'a live Mallow listing outranks stale external marketplace provenance',
    () async {
      stubReads(
        listing: (
          status: OnChainReadStatus.present,
          account: _listingAccount(price: '1500000000'),
          pda: 'LISTPDA',
          viewSlot: null,
        ),
      );
      final bloc = await loaded(
        _buyNowArtwork().copyWith(lastSource: MarketSource.magicEden),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final artwork = (bloc.state as ArtworkLoaded).artwork;
      expect(artwork.lastSource, MarketSource.mallow);
      expect(artwork.price, 1500000000);
      await bloc.close();
    },
  );

  test(
    'an on-chain listing the indexer missed is synthesized into a buy CTA',
    () async {
      // byMint says unlisted, but the chain has a live fixed-price Listing — the
      // source of truth. The reconcile must flip the artwork to buyNow so the
      // sheet shows "Buy" instead of "Make offer".
      stubReads(
        listing: (
          status: OnChainReadStatus.present,
          account: _listingAccount(price: '1500000000'),
          pda: 'LISTPDA',
          viewSlot: null,
        ),
      );
      final bloc = await loaded(_unlistedArtwork());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final artwork = (bloc.state as ArtworkLoaded).artwork;
      expect(artwork.listingType, ListingType.buyNow);
      expect(artwork.price, 1500000000);
      expect(artwork.buyNowMetadata?.amount, 1500000000);
      expect(artwork.buyNowMetadata?.listingAccount, 'LISTPDA');
      expect(artwork.currency, 'So11111111111111111111111111111111111111112');
      await bloc.close();
    },
  );

  test('an on-chain auction the indexer missed is synthesized', () async {
    stubReads(
      auction: (
        status: OnChainReadStatus.present,
        account: _auctionConfigAccount(
          reservePrice: '500000000',
          highestBidAmount: '900000000',
          highestBidder: 'BIDDER1',
        ),
        pda: 'AUCPDA',
        viewSlot: null,
      ),
    );
    final bloc = await loaded(_unlistedArtwork());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.auction);
    final auction = artwork.auctionMetadata!;
    expect(auction.auctionAccount, 'AUCPDA');
    expect(auction.reservePrice, 500000000);
    expect(auction.currentBidAmount, 900000000);
    expect(auction.currentBidder, 'BIDDER1');
    // Increment fields come from the full AuctionConfig read, so the bid sheet
    // can compute the next valid bid even for a fully-synthesized auction.
    expect(auction.minBidIncrementBps, 250);
    expect(artwork.currency, 'So11111111111111111111111111111111111111112');
    await bloc.close();
  });

  test('a stale listing the chain no longer has is cleared', () async {
    // byMint still shows a buyNow listing, but the chain returns 404 — the
    // listing was cancelled/bought. Clear it so the user can't try to buy a
    // sold item.
    stubReads(
      listing: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'LISTPDA',
        viewSlot: null,
      ),
    );
    final bloc = await loaded(_buyNowArtwork());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.buyNowMetadata, isNull);
    expect(artwork.price, isNull);
    await bloc.close();
  });

  test('a stale auction the chain no longer has is cleared', () async {
    stubReads(
      auction: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'AUCPDA',
        viewSlot: null,
      ),
    );
    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 1.0,
        currentBidder: 'B',
        endsAt: endsAt,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.auctionMetadata, isNull);
    await bloc.close();
  });

  test('an undetermined (error) read never clears a real listing', () async {
    // A 5xx/transport failure must NOT be mistaken for "no account" — clearing
    // on a flaky network would hide a genuinely buyable listing.
    stubReads(
      listing: (
        status: OnChainReadStatus.unknown,
        account: null,
        pda: 'LISTPDA',
        viewSlot: null,
      ),
    );
    final bloc = await loaded(_buyNowArtwork());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.buyNow,
    );
    await bloc.close();
  });

  // ── Account-close tombstones (instant clear off the WS push) ─────────────

  test('an auction-close tombstone clears the auction instantly', () async {
    // The listener pushes `{ closed: true }` the instant the auction account
    // is settled. Matched by pubkey against the watched AUCPDA, it must clear
    // the auction without waiting for an on-chain re-read.
    final frames = StreamController<AccountUpdate>.broadcast();
    addTearDown(frames.close);
    when(
      () => accountRealtime.watchAccount('AUCPDA'),
    ).thenAnswer((_) => frames.stream);

    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 1.0,
        currentBidder: 'B',
        endsAt: endsAt,
      ),
    );

    frames.add(_closedAccount('AUCPDA'));
    await Future<void>.delayed(Duration.zero);

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.auctionMetadata, isNull);
    await bloc.close();
  });

  test('a listing-close tombstone clears the listing instantly', () async {
    final frames = StreamController<AccountUpdate>.broadcast();
    addTearDown(frames.close);
    when(
      () => accountRealtime.watchAccount('LISTPDA'),
    ).thenAnswer((_) => frames.stream);

    final bloc = await loaded(_buyNowArtwork());

    frames.add(_closedAccount('LISTPDA', program: 'mallow-market'));
    await Future<void>.delayed(Duration.zero);

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.buyNowMetadata, isNull);
    expect(artwork.price, isNull);
    await bloc.close();
  });

  test('an edition listing close clears it even though existence-recon skips '
      'editions (a closed Listing PDA is an unambiguous delist)', () async {
    // The Listing PDA is shared across all prints and only closes on delist
    // (a single edition-print buy bumps a separate BuyEditionHistory, not the
    // Listing). So the close is safe to clear despite the synth/drift gate
    // excluding editions.
    final frames = StreamController<AccountUpdate>.broadcast();
    addTearDown(frames.close);
    when(
      () => accountRealtime.watchAccount('LISTPDA'),
    ).thenAnswer((_) => frames.stream);

    final bloc = await loaded(_editionBuyNowArtwork());
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.buyNow,
    );

    frames.add(_closedAccount('LISTPDA', program: 'mallow-market'));
    await Future<void>.delayed(Duration.zero);

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.buyNowMetadata, isNull);
    await bloc.close();
  });

  test(
    'a live present frame suppresses a lagging absent cold read — a 404 '
    'from an RPC behind the listener must not clear a real listing',
    () async {
      // Incident regression: a just-created listing's decoded frame arrives on
      // the account socket, but the REST accounts endpoint (lagging RPC node)
      // keeps 404ing for seconds. An UNORDERED absence (legacy 404, no view
      // slot) must NOT clear the listing while the socket frame stands — only
      // a provably-newer view, the close tombstone, or a socket reconnect
      // outrank it.
      final frames = StreamController<AccountUpdate>.broadcast();
      addTearDown(frames.close);
      when(
        () => accountRealtime.watchAccount('LISTPDA'),
      ).thenAnswer((_) => frames.stream);

      final bloc = await loaded(_buyNowArtwork());

      // Live decoded frame: the listing exists on-chain as of slot 500.
      frames.add(_listingAccount(price: '1000000000'));
      await Future<void>.delayed(Duration.zero);

      // A refresh whose reconcile read hits a legacy backend → absent, no slot.
      stubReads(
        listing: (
          status: OnChainReadStatus.absent,
          account: null,
          pda: 'LISTPDA',
          viewSlot: null,
        ),
      );
      bloc.add(const ArtworkEvent.refresh());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final artwork = (bloc.state as ArtworkLoaded).artwork;
      expect(artwork.listingType, ListingType.buyNow);
      expect(artwork.buyNowMetadata, isNotNull);
      await bloc.close();
    },
  );

  test('an absent read with a view slot OLDER than the frame write slot is '
      'rejected as a lagging node', () async {
    // Slot arithmetic replaces heuristics: "not found as of slot 400" cannot
    // outrank "written at slot 500" — the serving node is provably behind.
    final frames = StreamController<AccountUpdate>.broadcast();
    addTearDown(frames.close);
    when(
      () => accountRealtime.watchAccount('LISTPDA'),
    ).thenAnswer((_) => frames.stream);

    final bloc = await loaded(_buyNowArtwork());
    frames.add(_listingAccount(price: '1000000000'));
    await Future<void>.delayed(Duration.zero);

    stubReads(
      listing: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'LISTPDA',
        viewSlot: 400,
      ),
    );
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.buyNow,
    );
    await bloc.close();
  });

  test('an absent read with a view slot AT/PAST the frame write slot clears '
      'despite presence evidence', () async {
    // The account existed at slot 500 but a node at view slot 600 no longer
    // sees it — it was genuinely closed in between. The newer view must win
    // even without a tombstone (covers a missed-tombstone stale listing).
    final frames = StreamController<AccountUpdate>.broadcast();
    addTearDown(frames.close);
    when(
      () => accountRealtime.watchAccount('LISTPDA'),
    ).thenAnswer((_) => frames.stream);

    final bloc = await loaded(_buyNowArtwork());
    frames.add(_listingAccount(price: '1000000000'));
    await Future<void>.delayed(Duration.zero);

    stubReads(
      listing: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'LISTPDA',
        viewSlot: 600,
      ),
    );
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.buyNowMetadata, isNull);
    await bloc.close();
  });

  test('an absent read older than the chain floor is rejected even with no '
      'socket frame (own action landed at a known slot)', () async {
    // A list tx landed at slot 550 (chainActionLanded — from TxLandedSlots or
    // an invalidation's slot). No account frame arrived yet. An absent read
    // at view slot 520 predates the action → must not clear the listing.
    final bloc = await loaded(_buyNowArtwork());
    bloc.add(const ArtworkEvent.chainActionLanded(slot: 550));
    await Future<void>.delayed(Duration.zero);

    stubReads(
      listing: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'LISTPDA',
        viewSlot: 520,
      ),
    );
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.buyNow,
    );

    // A read at/past the floor IS trusted — the listing really is gone.
    stubReads(
      listing: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'LISTPDA',
        viewSlot: 560,
      ),
    );
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.unlisted,
    );
    await bloc.close();
  });

  test('a close tombstone still clears a listing that had presence '
      'evidence', () async {
    // The tombstone rides the same ordered stream as the present frame, so it
    // authoritatively rescinds the evidence — the clear must go through.
    final frames = StreamController<AccountUpdate>.broadcast();
    addTearDown(frames.close);
    when(
      () => accountRealtime.watchAccount('LISTPDA'),
    ).thenAnswer((_) => frames.stream);

    final bloc = await loaded(_buyNowArtwork());

    frames.add(_listingAccount(price: '1000000000'));
    await Future<void>.delayed(Duration.zero);
    frames.add(_closedAccount('LISTPDA', program: 'mallow-market'));
    await Future<void>.delayed(Duration.zero);

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.buyNowMetadata, isNull);
    await bloc.close();
  });

  test('a live present auction frame suppresses a lagging absent cold '
      'read', () async {
    final frames = StreamController<AccountUpdate>.broadcast();
    addTearDown(frames.close);
    when(
      () => accountRealtime.watchAccount('AUCPDA'),
    ).thenAnswer((_) => frames.stream);

    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 1.0,
        currentBidder: 'B',
        endsAt: endsAt,
      ),
    );

    frames.add(
      _auctionConfigAccount(
        reservePrice: '500000000',
        highestBidAmount: '1000000000',
        highestBidder: 'B',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    stubReads(
      auction: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'AUCPDA',
        viewSlot: null,
      ),
    );
    bloc.add(const ArtworkEvent.refresh());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.auction);
    expect(artwork.auctionMetadata, isNotNull);
    await bloc.close();
  });

  test('a close tombstone for an unwatched pubkey leaves the artwork '
      'intact', () async {
    // Defensive: a tombstone whose pubkey matches neither the auction nor the
    // listing account must not blind-clear a live auction.
    final frames = StreamController<AccountUpdate>.broadcast();
    addTearDown(frames.close);
    when(
      () => accountRealtime.watchAccount('AUCPDA'),
    ).thenAnswer((_) => frames.stream);

    final bloc = await loaded(
      _auctionArtwork(
        currentBidAmount: 1.0,
        currentBidder: 'B',
        endsAt: endsAt,
      ),
    );

    frames.add(_closedAccount('SOME_OTHER_PDA'));
    await Future<void>.delayed(Duration.zero);

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.auction);
    expect(artwork.auctionMetadata, isNotNull);
    await bloc.close();
  });

  test('a master-edition listing is not synthesized as a 1/1 buy', () async {
    // editionsLimit != 0 marks a multi-print master-edition listing whose
    // lifecycle this 1/1 reconcile can't safely model — leave it unlisted.
    stubReads(
      listing: (
        status: OnChainReadStatus.present,
        account: _listingAccount(price: '1000000000', editionsLimit: 5),
        pda: 'LISTPDA',
        viewSlot: null,
      ),
    );
    final bloc = await loaded(_unlistedArtwork());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.unlisted,
    );
    await bloc.close();
  });

  test('a stale edition listing the chain no longer has is cleared via the '
      'cold read path', () async {
    // A listed edition whose Listing PDA returns 404 (delisted) must clear even
    // though existence-recon won't *synthesize* editions — the read path is now
    // scoped to verify already-listed editions, not just 1/1s.
    stubReads(
      listing: (
        status: OnChainReadStatus.absent,
        account: null,
        pda: 'LISTPDA',
        viewSlot: null,
      ),
    );
    final bloc = await loaded(_editionBuyNowArtwork());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.listingType, ListingType.unlisted);
    expect(artwork.buyNowMetadata, isNull);
    await bloc.close();
  });

  test('a live edition listing present on chain is left intact by the cold '
      'read (no false clear, no 1/1 drift)', () async {
    // The listing is still live on chain (editionsLimit != 0 → downgraded to
    // `unknown`), so the cold read must be a no-op — neither cleared nor
    // drifted into a 1/1 buy.
    stubReads(
      listing: (
        status: OnChainReadStatus.present,
        account: _listingAccount(price: '1000000000', editionsLimit: 5),
        pda: 'LISTPDA',
        viewSlot: null,
      ),
    );
    final bloc = await loaded(_editionBuyNowArtwork());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      (bloc.state as ArtworkLoaded).artwork.listingType,
      ListingType.buyNow,
    );
    await bloc.close();
  });
}
