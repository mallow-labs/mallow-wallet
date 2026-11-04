import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/portfolio/services/portfolio_received_reporter.dart';
import 'package:mocktail/mocktail.dart';

class _Api extends Mock implements api.MallowApiV2Client {}

const _hash = 'ooNsRAKZ8dQpB9Zg8mQ2ZqcQxkq8wjF7pB3rGqz3n9Wvw2XyZ4a';
const _address = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

api.ApiResponse<api.PortfolioReceivedResult> _answer(
  api.PortfolioReceivedStatus status,
) => api.ApiResponse(
  result: api.PortfolioReceivedResult(
    status: status,
    mintAccounts: const <String>[],
  ),
);

void main() {
  late _Api client;
  late List<Duration> waits;
  late int refreshes;
  late PortfolioReceivedReporter reporter;

  setUpAll(() {
    registerFallbackValue(
      const api.PortfolioReceivedRequest(
        chain: api.PortfolioReceivedChain.tezos,
        txHash: '',
        address: '',
      ),
    );
  });

  setUp(() {
    client = _Api();
    waits = [];
    refreshes = 0;
    reporter = PortfolioReceivedReporter.test(
      client,
      delay: (wait) async => waits.add(wait),
      refresh: () => refreshes++,
    );
  });

  test('sends an Ethereum transaction hash on the ethereum chain', () async {
    const txHash =
        '0x7d4f5c6a8a0f6c3b2e1d0c9b8a7f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d5';
    const wallet = '0x1111111111111111111111111111111111111111';
    when(
      () => client.postPortfolioReceived(any()),
    ).thenAnswer((_) async => _answer(api.PortfolioReceivedStatus.queued));

    await reporter.reportEthereum(txHash: txHash, address: wallet);

    final request =
        verify(() => client.postPortfolioReceived(captureAny())).captured.single
            as api.PortfolioReceivedRequest;
    expect(request.chain, api.PortfolioReceivedChain.ethereum);
    expect(request.txHash, txHash);
    expect(request.address, wallet);
    expect(refreshes, PortfolioReceivedReporter.refreshSchedule.length);
  });

  test('sends the Tezos operation hash and the receiving address', () async {
    when(
      () => client.postPortfolioReceived(any()),
    ).thenAnswer((_) async => _answer(api.PortfolioReceivedStatus.none));

    await reporter.reportTezos(opHash: _hash, address: _address);

    final request =
        verify(() => client.postPortfolioReceived(captureAny())).captured.single
            as api.PortfolioReceivedRequest;
    expect(request.chain, api.PortfolioReceivedChain.tezos);
    expect(request.txHash, _hash);
    expect(request.address, _address);
    expect(refreshes, 0);
  });

  test(
    'a queued refresh refetches the portfolio across the backend retry window',
    () async {
      when(
        () => client.postPortfolioReceived(any()),
      ).thenAnswer((_) async => _answer(api.PortfolioReceivedStatus.queued));

      await reporter.reportTezos(opHash: _hash, address: _address);

      expect(waits, PortfolioReceivedReporter.refreshSchedule);
      expect(refreshes, PortfolioReceivedReporter.refreshSchedule.length);
    },
  );

  test('pending asks again with backoff until the backend sees it', () async {
    final answers = [
      api.PortfolioReceivedStatus.pending,
      api.PortfolioReceivedStatus.pending,
      api.PortfolioReceivedStatus.queued,
    ];
    when(
      () => client.postPortfolioReceived(any()),
    ).thenAnswer((_) async => _answer(answers.removeAt(0)));

    await reporter.reportTezos(opHash: _hash, address: _address);

    verify(() => client.postPortfolioReceived(any())).called(3);
    expect(waits, [
      ...PortfolioReceivedReporter.pendingBackoff.take(2),
      ...PortfolioReceivedReporter.refreshSchedule,
    ]);
  });

  test('stops after the backoff runs out while still pending', () async {
    when(
      () => client.postPortfolioReceived(any()),
    ).thenAnswer((_) async => _answer(api.PortfolioReceivedStatus.pending));

    await reporter.reportTezos(opHash: _hash, address: _address);

    verify(
      () => client.postPortfolioReceived(any()),
    ).called(PortfolioReceivedReporter.pendingBackoff.length + 1);
    expect(refreshes, 0);
  });

  test('a failed call is swallowed', () async {
    when(
      () => client.postPortfolioReceived(any()),
    ).thenThrow(Exception('offline'));

    await expectLater(
      reporter.reportTezos(opHash: _hash, address: _address),
      completes,
    );
    expect(refreshes, 0);
  });
}
