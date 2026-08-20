import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart'
    show SolanaTransactionUnconfirmedException;
import 'package:mallow_wallet/core/result/app_failure.dart';
import 'package:mallow_wallet/core/result/result.dart';
import 'package:solana/solana.dart';

void main() {
  group('Result', () {
    test('success carries value and reports isSuccess', () {
      const r = Result<int, AppFailure>.success(42);
      expect(r.isSuccess, isTrue);
      expect(r.isFailure, isFalse);
      expect(r.valueOrNull, 42);
      expect(r.errorOrNull, isNull);
    });

    test('failure carries error and reports isFailure', () {
      const failure = AppFailure.network('boom');
      const r = Result<int, AppFailure>.failure(failure);
      expect(r.isFailure, isTrue);
      expect(r.isSuccess, isFalse);
      expect(r.valueOrNull, isNull);
      expect(r.errorOrNull, failure);
    });

    test('when branches to the right arm', () {
      const ok = Result<int, AppFailure>.success(7);
      const err = Result<int, AppFailure>.failure(AppFailure.unknown('x'));

      expect(
        ok.when(success: (v) => 'ok:$v', failure: (e, _) => 'err'),
        'ok:7',
      );
      expect(
        err.when(success: (v) => 'ok', failure: (e, _) => 'err:${e.message}'),
        'err:x',
      );
    });

    test('map transforms success and leaves failure untouched', () {
      const ok = Result<int, AppFailure>.success(3);
      const err = Result<int, AppFailure>.failure(AppFailure.network('n'));

      expect(ok.map((v) => v * 2).valueOrNull, 6);
      expect(err.map((v) => v * 2).errorOrNull?.message, 'n');
    });

    test('mapError transforms failure type', () {
      const err = Result<int, AppFailure>.failure(AppFailure.network('n'));
      final mapped = err.mapError((e) => e.message);
      expect(mapped.errorOrNull, 'n');
    });

    test('equality is value-based', () {
      const a = Result<int, AppFailure>.success(1);
      const b = Result<int, AppFailure>.success(1);
      const c = Result<int, AppFailure>.success(2);
      expect(a, b);
      expect(a, isNot(c));

      const f1 = Result<int, AppFailure>.failure(AppFailure.unknown('x'));
      const f2 = Result<int, AppFailure>.failure(AppFailure.unknown('x'));
      expect(f1, f2);
    });

    group('guard', () {
      test('returns success when block completes', () async {
        final r = await Result.guard(() async => 'hi');
        expect(r.valueOrNull, 'hi');
      });

      test('maps TransactionAuthCancelledException to cancelled', () async {
        final r = await Result.guard<int>(() async {
          throw TransactionAuthCancelledException('user backed out');
        });
        expect(r.isFailure, isTrue);
        expect(r.errorOrNull?.kind, AppFailureKind.cancelled);
        expect(r.errorOrNull?.message, 'user backed out');
      });

      test('maps arbitrary throwables to unknown', () async {
        final r = await Result.guard<int>(() async {
          throw StateError('whoops');
        });
        expect(r.errorOrNull?.kind, AppFailureKind.unknown);
        expect(r.errorOrNull?.message, contains('whoops'));
      });

      test('preserves a pre-classified AppFailure', () async {
        final r = await Result.guard<int>(() async {
          throw const AppFailure.validation('bad input');
        });
        expect(r.errorOrNull?.kind, AppFailureKind.validation);
        expect(r.errorOrNull?.message, 'bad input');
      });

      test('captures stack trace on failure', () async {
        final r = await Result.guard<int>(() async {
          throw StateError('fail');
        });
        // ignore: pattern_never_matches_value_type
        if (r case ResultFailure(:final stackTrace)) {
          expect(stackTrace, isNotNull);
        } else {
          fail('expected ResultFailure');
        }
      });
    });
  });

  group('AppFailure.from', () {
    test('classifies SigningException as signing', () {
      final f = AppFailure.from(SigningException('ledger off'));
      expect(f.kind, AppFailureKind.signing);
      expect(f.message, 'ledger off');
    });

    test('classifies social-wallet limitation as signing', () {
      final f = AppFailure.from(
        SocialTransactionSigningNotSupportedException(),
      );
      expect(f.kind, AppFailureKind.signing);
    });

    test('classifies view-only wallet as signing', () {
      final f = AppFailure.from(ViewOnlyWalletException());
      expect(f.kind, AppFailureKind.signing);
    });

    test('classifies InvalidMnemonicException as validation', () {
      final f = AppFailure.from(InvalidMnemonicException('bad words'));
      expect(f.kind, AppFailureKind.validation);
      expect(f.message, 'bad words');
    });

    test('classifies InvalidPrivateKeyException as validation', () {
      final f = AppFailure.from(InvalidPrivateKeyException('bad key'));
      expect(f.kind, AppFailureKind.validation);
      expect(f.message, 'bad key');
    });

    test('classifies JsonRpcException as rpc with raw message', () {
      const e = JsonRpcException('Blockhash not found', -32002, null);
      final f = AppFailure.from(e);
      expect(f.kind, AppFailureKind.rpc);
      expect(f.message, 'Blockhash not found');
    });

    test('classifies DioException with server JSON message as network', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/v1/listings'),
        response: Response(
          requestOptions: RequestOptions(path: '/v1/listings'),
          statusCode: 404,
          data: {'message': 'Listing not found'},
        ),
        type: DioExceptionType.badResponse,
      );
      final f = AppFailure.from(e);
      expect(f.kind, AppFailureKind.network);
      expect(f.message, 'Listing not found');
    });

    test('classifies DioException with no response as network', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/v1/foo'),
        type: DioExceptionType.connectionError,
      );
      final f = AppFailure.from(e);
      expect(f.kind, AppFailureKind.network);
      expect(f.message, 'Could not reach the server');
    });

    test('falls through to unknown for plain throwables', () {
      final f = AppFailure.from(StateError('boom'));
      expect(f.kind, AppFailureKind.unknown);
    });

    test('returns the same AppFailure when re-classified', () {
      const original = AppFailure.signing('already classified');
      expect(AppFailure.from(original), same(original));
    });

    // An expired-unconfirmed broadcast is indeterminate: the transaction may
    // still land. Every pipeline surface branches on `isUnconfirmed` to drop
    // its retry affordance, so the flag has to survive classification — a
    // dropped `cause` here silently re-arms the double-send trap on every
    // flow at once.
    test('preserves the unconfirmed marker through classification', () {
      final f = AppFailure.from(
        const SolanaTransactionUnconfirmedException('sigSTUCK'),
      );
      expect(f.isUnconfirmed, isTrue);
      // Deliberately NOT its own kind — the exception's own toString is the
      // user-facing copy and must reach the user verbatim.
      expect(f.message, contains('may still land'));
    });

    test('does not mark ordinary failures as unconfirmed', () {
      expect(AppFailure.from(StateError('boom')).isUnconfirmed, isFalse);
      expect(const AppFailure.rpc('blockhash expired').isUnconfirmed, isFalse);
    });
  });

  group('AppFailure.prefixedWith', () {
    test('wraps the message with the prefix', () {
      const f = AppFailure.network('timeout');
      final prefixed = f.prefixedWith('Swap failed');
      expect(prefixed.message, 'Swap failed: timeout');
    });

    test('preserves kind and cause', () {
      final cause = Exception('root');
      final f = AppFailure.rpc('blockhash expired', cause);
      final prefixed = f.prefixedWith('Transaction failed');
      expect(prefixed.kind, AppFailureKind.rpc);
      expect(prefixed.cause, same(cause));
    });

    test('passes cancellations through untouched so a dismissed prompt never '
        'reads as a generic failure', () {
      const f = AppFailure.cancelled('User cancelled');
      final prefixed = f.prefixedWith('Listing failed');
      // Identity — no new object, no prefix.
      expect(prefixed, same(f));
      expect(prefixed.message, 'User cancelled');
      expect(prefixed.kind, AppFailureKind.cancelled);
    });

    // "Listing failed: This transaction may still land" contradicts itself,
    // and `signSendConfirm`'s contract requires the exception's own copy to
    // reach the user verbatim rather than be restated as a caller's failure.
    test('passes an unconfirmed broadcast through untouched', () {
      final f = AppFailure.from(
        const SolanaTransactionUnconfirmedException('sigSTUCK'),
      );
      final prefixed = f.prefixedWith('Listing failed');
      expect(prefixed, same(f));
      expect(prefixed.message, isNot(startsWith('Listing failed')));
    });

    test('composes with AppFailure.from for raw thrown errors', () {
      final prefixed = AppFailure.from(
        StateError('boom'),
      ).prefixedWith('Listing failed');
      expect(prefixed.kind, AppFailureKind.unknown);
      expect(prefixed.message, startsWith('Listing failed: '));
    });
  });
}
