import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_wallet/core/services/transaction_check.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'transaction_check_test.mocks.dart';

@GenerateMocks([MallowApiClient])
void main() {
  const testSignature = 'sig123';
  late MockMallowApiClient mockApi;

  setUp(() {
    mockApi = MockMallowApiClient();
  });

  group('checkTransaction', () {
    test('returns true on first attempt when response is empty', () async {
      when(mockApi.checkTx(any)).thenAnswer((_) async => <String, dynamic>{});

      final result = await checkTransaction(
        testSignature,
        api: mockApi,
        delay: Duration.zero,
      );

      expect(result, isTrue);
      verify(mockApi.checkTx(any)).called(1);
    });

    test(
      'retries while response.result is a string, then returns true',
      () async {
        var calls = 0;
        when(mockApi.checkTx(any)).thenAnswer((_) async {
          calls++;
          if (calls < 4) {
            return {'result': 'Transaction not yet processed'};
          }
          return <String, dynamic>{};
        });

        final result = await checkTransaction(
          testSignature,
          api: mockApi,
          delay: Duration.zero,
        );

        expect(result, isTrue);
        expect(calls, 4);
      },
    );

    test('returns false after exhausting maxAttempts', () async {
      when(
        mockApi.checkTx(any),
      ).thenAnswer((_) async => {'result': 'Transaction not yet processed'});

      final result = await checkTransaction(
        testSignature,
        api: mockApi,
        maxAttempts: 5,
        delay: Duration.zero,
      );

      expect(result, isFalse);
      verify(mockApi.checkTx(any)).called(5);
    });

    test('swallows transient errors and continues polling', () async {
      var calls = 0;
      when(mockApi.checkTx(any)).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw Exception('network blip');
        if (calls == 2) throw Exception('500 server error');
        return <String, dynamic>{};
      });

      final result = await checkTransaction(
        testSignature,
        api: mockApi,
        delay: Duration.zero,
      );

      expect(result, isTrue);
      expect(calls, 3);
    });

    test('passes 1-indexed attempt number in body', () async {
      final receivedAttempts = <int>[];
      when(mockApi.checkTx(any)).thenAnswer((invocation) async {
        final body =
            invocation.positionalArguments.first as Map<String, dynamic>;
        receivedAttempts.add(body['attempt'] as int);
        if (receivedAttempts.length < 3) {
          return {'result': 'pending'};
        }
        return <String, dynamic>{};
      });

      await checkTransaction(testSignature, api: mockApi, delay: Duration.zero);

      expect(receivedAttempts, [1, 2, 3]);
    });

    test('passes signature as txId in body', () async {
      Map<String, dynamic>? captured;
      when(mockApi.checkTx(any)).thenAnswer((invocation) async {
        captured = invocation.positionalArguments.first as Map<String, dynamic>;
        return <String, dynamic>{};
      });

      await checkTransaction(testSignature, api: mockApi, delay: Duration.zero);

      expect(captured, isNotNull);
      expect(captured!['txId'], testSignature);
    });
  });
}
