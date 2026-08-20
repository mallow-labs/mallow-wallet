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

/// A like that fails used to revert the heart and the count and say nothing
/// but a `debugPrint` — from the user's side that is indistinguishable from a
/// tap that never registered, and they retry into the same silence. The webapp
/// (`useLikeNft`) raises "Failed to like" / "Failed to unlike" on exactly this
/// path.
void main() {
  late _MockArtworkRepository repo;
  late _MockAuthService auth;
  late _MockAccountRealtimeService accountRealtime;
  late _MockAuctionLiveRepository auctionLive;
  late _MockMarketAccountRepository marketAccounts;

  const details = ArtworkDetails(
    mintAccount: 'MINT1',
    title: 'Test',
    imageUrl: 'https://x/img.png',
    description: null,
    artistName: 'Artist',
    artistAddress: 'ART1',
    likeCount: 7,
  );

  setUpAll(() => registerFallbackValue(ContentType.nft));

  setUp(() {
    repo = _MockArtworkRepository();
    auth = _MockAuthService();
    accountRealtime = _MockAccountRealtimeService();
    auctionLive = _MockAuctionLiveRepository();
    marketAccounts = _MockMarketAccountRepository();

    when(() => auth.isLiked(any(), any())).thenReturn(false);
    when(
      () => accountRealtime.watchAccount(any()),
    ).thenAnswer((_) => const Stream<AccountUpdate>.empty());
    when(() => auctionLive.getState(any())).thenAnswer((_) async => null);
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
  });

  Future<ArtworkBloc> loaded({bool alreadyLiked = false}) async {
    when(() => auth.isLiked(any(), any())).thenReturn(alreadyLiked);
    when(() => repo.getArtworkDetail(any())).thenAnswer((_) async => details);
    final bloc = ArtworkBloc(
      repo,
      auth,
      accountRealtime,
      auctionLive,
      marketAccounts,
    );
    bloc.add(const ArtworkEvent.load(mintAccount: 'MINT1'));
    await Future<void>.delayed(Duration.zero);
    return bloc;
  }

  test('a successful like moves the heart and the count', () async {
    when(() => repo.likeArtwork(any())).thenAnswer((_) async {});
    final bloc = await loaded();
    final errors = <String>[];
    final sub = bloc.transientErrors.listen(errors.add);

    bloc.add(const ArtworkEvent.toggleLike());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.isLiked, isTrue);
    expect(artwork.likeCount, 8);
    expect(errors, isEmpty);

    await sub.cancel();
    await bloc.close();
  });

  test('a failed like reverts and reports the failure', () async {
    when(() => repo.likeArtwork(any())).thenThrow(Exception('offline'));
    final bloc = await loaded();
    final errors = <String>[];
    final sub = bloc.transientErrors.listen(errors.add);

    bloc.add(const ArtworkEvent.toggleLike());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.isLiked, isFalse);
    expect(artwork.likeCount, 7);
    expect(errors, ['Failed to like']);

    await sub.cancel();
    await bloc.close();
  });

  test('a failed unlike names the action the user actually took', () async {
    when(() => repo.unlikeArtwork(any())).thenThrow(Exception('offline'));
    final bloc = await loaded(alreadyLiked: true);
    final errors = <String>[];
    final sub = bloc.transientErrors.listen(errors.add);

    bloc.add(const ArtworkEvent.toggleLike());
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final artwork = (bloc.state as ArtworkLoaded).artwork;
    expect(artwork.isLiked, isTrue);
    expect(artwork.likeCount, 7);
    // "Failed to like" after an unlike tap points at the wrong action.
    expect(errors, ['Failed to unlike']);

    await sub.cancel();
    await bloc.close();
  });
}
