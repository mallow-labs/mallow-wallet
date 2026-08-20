import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/v2_fallback.dart';

/// Guards the v2→v1 handoff policy. Getting this wrong is silent in both
/// directions: too narrow and a holder-gated raffle stops being buyable, too
/// wide and every ordinary v2 rejection is replayed against the stale v1
/// builder, so the user is told whatever v1 says instead of the real reason.
void main() {
  DioException error(int status, Object? data) => DioException(
    requestOptions: RequestOptions(path: '/v2/tx/raffles/buy-tickets'),
    response: Response(
      requestOptions: RequestOptions(path: '/v2/tx/raffles/buy-tickets'),
      statusCode: status,
      data: data,
    ),
  );

  /// The envelope every v2 route renders, from the backend's shared error
  /// type.
  Object envelope(String message) => {
    'error': {'message': message},
  };

  group('is a deferral', () {
    // The three v2 raffle branches that hand off to the older service end in
    // "— use v1"; matching the stem keeps the em dash out of the comparison.
    for (final message in const [
      'Holder-only raffles not yet supported in v2 — use v1',
      'pNFT raffle cancel not yet supported in v2 — use v1',
      'pNFT raffle claim-prize not yet supported in v2 — use v1',
    ]) {
      test(message, () {
        expect(error(400, envelope(message)).isV2DeferralFallback, isTrue);
      });
    }

    test('an off-chain-Merkle-gated edition', () {
      // v2 gates on the request's `buyer`, v1 on the session address, so the
      // v1 plural builder can still serve a buy v2 refuses.
      expect(
        error(400, envelope('User is not whitelisted')).isV2DeferralFallback,
        isTrue,
      );
    });
  });

  group('propagates instead of falling back', () {
    // Every one of these is a real answer from the v2 builder. Replaying it
    // against v1 costs a round-trip and swaps the message the user sees.
    for (final message in const [
      'Raffle sold out',
      'Raffle has ended',
      'Max allowable tickets reached',
      'quantity must be >= 1',
      'Listing not found',
      'Prize already claimed',
    ]) {
      test(message, () {
        expect(error(400, envelope(message)).isV2DeferralFallback, isFalse);
      });
    }

    test('a 400 with no v2 envelope — a proxy or a malformed request', () {
      expect(error(400, 'Bad Request').isV2DeferralFallback, isFalse);
      expect(error(400, null).isV2DeferralFallback, isFalse);
      expect(error(400, {'message': 'flat'}).isV2DeferralFallback, isFalse);
    });

    test('a non-400 carrying the marker text', () {
      // The status is half the signal; a 500 is never a deferral branch.
      expect(
        error(
          500,
          envelope('Holder-only raffles not yet supported in v2 — use v1'),
        ).isV2DeferralFallback,
        isFalse,
      );
    });

    test('a transport failure with no response at all', () {
      expect(
        DioException(
          requestOptions: RequestOptions(path: '/v2/tx/raffles/buy-tickets'),
          type: DioExceptionType.connectionError,
        ).isV2DeferralFallback,
        isFalse,
      );
    });
  });
}
