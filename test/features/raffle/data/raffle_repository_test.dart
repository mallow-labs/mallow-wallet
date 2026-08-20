import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/services/fee_config.dart';
import 'package:mallow_wallet/features/raffle/data/raffle_repository.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'raffle_repository_test.mocks.dart';

@GenerateMocks([api.MallowApiV2Client])
void main() {
  late MockMallowApiV2Client mockApiV2;
  late RaffleRepository repository;

  const buyer = 'BuyerPubkey1111111111111111111111111111111';
  const creator = 'CreatorPubkey111111111111111111111111111111';
  const raffleKey = 'RaffleKey11111111111111111111111111111111111';
  const v2Tx = 'v2-base64-tx';

  const okResponse = api.ApiResponse<api.UnsignedTxResponse>(
    result: api.UnsignedTxResponse(tx: v2Tx),
  );

  setUpAll(() {
    provideDummy<api.ApiResponse<api.UnsignedTxResponse>>(okResponse);
  });

  setUp(() {
    mockApiV2 = MockMallowApiV2Client();
    repository = RaffleRepository(mockApiV2, const FeeConfig());
  });

  /// A v2 `400` in the envelope every v2 route renders. The default message is
  /// the old deferral marker — the one the repository used to answer by
  /// retrying `/v1/raffle/*`.
  DioException badRequest([
    String message = 'Holder-only raffles not yet supported in v2 — use v1',
  ]) => DioException(
    requestOptions: RequestOptions(path: '/tx/raffles/buy-tickets'),
    response: Response(
      requestOptions: RequestOptions(path: '/tx/raffles/buy-tickets'),
      statusCode: 400,
      data: {
        'error': {'message': message},
      },
    ),
  );

  group('getBuyTicketsTx', () {
    test('builds through the v2 route', () async {
      when(
        mockApiV2.buyRaffleTicketsTx(any),
      ).thenAnswer((_) async => okResponse);

      final tx = await repository.getBuyTicketsTx(
        buyer: buyer,
        raffleKey: raffleKey,
        ticketCount: 2,
      );

      expect(tx, v2Tx);
      final request =
          verify(mockApiV2.buyRaffleTicketsTx(captureAny)).captured.single
              as api.BuyTicketsTxRequest;
      expect(request.buyer, buyer);
      expect(request.raffleKey, raffleKey);
      expect(request.ticketCount, 2);
      expect(
        request.targetPriorityFeeLamports,
        const FeeConfig().priorityFeeLamports,
      );
    });

    // 🛑 The `/v1/raffle/*` routes are deleted. A deferral-shaped 400 used to
    // mean "retry on v1"; there is nowhere left to retry, so it must reach the
    // caller as the real failure instead of being swallowed by a second call.
    test('propagates a deferral-shaped 400 instead of retrying v1', () async {
      when(mockApiV2.buyRaffleTicketsTx(any)).thenThrow(badRequest());

      await expectLater(
        repository.getBuyTicketsTx(
          buyer: buyer,
          raffleKey: raffleKey,
          ticketCount: 1,
        ),
        throwsA(isA<DioException>()),
      );
      verify(mockApiV2.buyRaffleTicketsTx(any)).called(1);
    });

    test('propagates an ordinary 400', () async {
      when(
        mockApiV2.buyRaffleTicketsTx(any),
      ).thenThrow(badRequest('Raffle sold out'));

      await expectLater(
        repository.getBuyTicketsTx(
          buyer: buyer,
          raffleKey: raffleKey,
          ticketCount: 1,
        ),
        throwsA(isA<DioException>()),
      );
    });

    test('propagates a 5xx', () async {
      when(mockApiV2.buyRaffleTicketsTx(any)).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/tx/raffles/buy-tickets'),
          response: Response(
            requestOptions: RequestOptions(path: '/tx/raffles/buy-tickets'),
            statusCode: 500,
          ),
        ),
      );

      await expectLater(
        repository.getBuyTicketsTx(
          buyer: buyer,
          raffleKey: raffleKey,
          ticketCount: 1,
        ),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('getCancelRaffleTx', () {
    test('builds through the v2 route', () async {
      when(mockApiV2.cancelRaffleTx(any)).thenAnswer((_) async => okResponse);

      expect(
        await repository.getCancelRaffleTx(
          creator: creator,
          raffleKey: raffleKey,
        ),
        v2Tx,
      );
      verify(mockApiV2.cancelRaffleTx(any)).called(1);
    });

    test('propagates a deferral-shaped 400 instead of retrying v1', () async {
      when(mockApiV2.cancelRaffleTx(any)).thenThrow(
        badRequest('pNFT raffle cancel not yet supported in v2 — use v1'),
      );

      await expectLater(
        repository.getCancelRaffleTx(creator: creator, raffleKey: raffleKey),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('getClaimNftTx', () {
    test('sends the caller as the v2 `authority`', () async {
      when(
        mockApiV2.claimRafflePrizeTx(any),
      ).thenAnswer((_) async => okResponse);

      expect(
        await repository.getClaimNftTx(caller: creator, raffleKey: raffleKey),
        v2Tx,
      );
      final request =
          verify(mockApiV2.claimRafflePrizeTx(captureAny)).captured.single
              as api.ClaimRafflePrizeTxRequest;
      expect(request.authority, creator);
      expect(request.raffleKey, raffleKey);
    });
  });

  group('getClaimProceedsTx', () {
    test('builds through the v2 route', () async {
      when(
        mockApiV2.claimRaffleProceedsTx(any),
      ).thenAnswer((_) async => okResponse);

      expect(
        await repository.getClaimProceedsTx(
          creator: creator,
          raffleKey: raffleKey,
        ),
        v2Tx,
      );
      verify(mockApiV2.claimRaffleProceedsTx(any)).called(1);
    });
  });
}
