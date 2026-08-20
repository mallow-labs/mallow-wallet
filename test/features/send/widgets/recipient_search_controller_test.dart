import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/send/models/recipient_suggestion.dart';
import 'package:mallow_wallet/features/send/services/recipient_search_service.dart';
import 'package:mallow_wallet/features/send/widgets/recipient_search_dropdown.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

const _sol1 = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _sol2 = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
const _eth = '0x1234567890123456789012345678901234567890';
const _tez = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

/// The System Program address: exactly 32 characters, and a real 32-byte
/// pubkey. Base58 drops a character per leading zero byte, so this is the
/// shortest a valid Solana address can be — and the one case that clears the
/// controller's 3–32 length window while still being an address.
const _shortSolanaAddress = '11111111111111111111111111111111';

class _FakeSearchService implements RecipientSearchService {
  final queries = <String>[];
  final chains = <Chain>[];

  /// Per-query `(delay, results)`. Anything unlisted resolves immediately with
  /// [defaultResults].
  final Map<String, (Duration, List<RecipientSuggestion>)> scripted = {};
  List<RecipientSuggestion> defaultResults = const [];

  @override
  Future<List<RecipientSuggestion>> search(String query, Chain chain) async {
    queries.add(query);
    chains.add(chain);
    final entry = scripted[query];
    if (entry != null) {
      if (entry.$1 > Duration.zero) await Future<void>.delayed(entry.$1);
      return entry.$2;
    }
    return defaultResults;
  }
}

RecipientSuggestion _suggestion(String address, {String? username}) =>
    RecipientSuggestion(address: address, username: username ?? 'alice');

/// Long enough for the debounce to elapse and the request to settle.
Future<void> _settle([int ms = 700]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('shouldSearch gate', () {
    test('rejects input below the minimum handle length', () {
      // Two characters match a large slice of the userbase; the request would
      // be spent on a list nobody can pick from.
      expect(
        RecipientSearchController.shouldSearch('al', Chain.solana),
        isFalse,
      );
      expect(
        RecipientSearchController.shouldSearch('ali', Chain.solana),
        isTrue,
      );
    });

    test('rejects input above the maximum handle length', () {
      expect(
        RecipientSearchController.shouldSearch('a' * 32, Chain.solana),
        isTrue,
      );
      expect(
        RecipientSearchController.shouldSearch('a' * 33, Chain.solana),
        isFalse,
      );
    });

    test('rejects anything containing a dot', () {
      // A dot means a domain the field already resolves via SNS/ENS, or a typo.
      // Never a mallow username.
      expect(
        RecipientSearchController.shouldSearch('alice.sol', Chain.solana),
        isFalse,
      );
      expect(
        RecipientSearchController.shouldSearch('alice.eth', Chain.ethereum),
        isFalse,
      );
    });

    test('measures the handle without its leading @', () {
      // '@al' is 3 characters but a 2-character handle, and the service strips
      // the @ before sending. Both ends must agree or the boundary shifts.
      expect(
        RecipientSearchController.shouldSearch('@al', Chain.solana),
        isFalse,
      );
      expect(
        RecipientSearchController.shouldSearch('@ali', Chain.solana),
        isTrue,
      );
    });

    test('rejects an address that already fits the length window', () {
      // Searching for an address the user is holding is a wasted round trip,
      // and the field can validate it directly.
      expect(
        RecipientSearchController.shouldSearch(
          _shortSolanaAddress,
          Chain.solana,
        ),
        isFalse,
      );
    });

    test('judges an address against the active chain, not any chain', () {
      // The same string is an address on one chain and gibberish on another.
      // A Tezos address typed during a Solana send is not a handle either, but
      // it is over the length ceiling, so the length gate is what stops it.
      expect(
        RecipientSearchController.shouldSearch(_tez, Chain.tezos),
        isFalse,
      );
      expect(
        RecipientSearchController.shouldSearch(_eth, Chain.ethereum),
        isFalse,
      );
    });
  });

  group('debounce', () {
    test('coalesces keystrokes inside the debounce window', () async {
      // Three characters typed at speed must cost one request, not three.
      final service = _FakeSearchService();
      final controller = RecipientSearchController(service: service);
      addTearDown(controller.dispose);

      controller.onInput('ali', Chain.solana);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      controller.onInput('alic', Chain.solana);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      controller.onInput('alice', Chain.solana);
      await _settle();

      expect(service.queries, ['alice']);
    });

    test('opens in a loading state before the request is issued', () async {
      // The dropdown appears on the first qualifying character rather than
      // 500ms later, so the field does not look unresponsive.
      final service = _FakeSearchService();
      final controller = RecipientSearchController(service: service);
      addTearDown(controller.dispose);

      controller.onInput('alice', Chain.solana);

      expect(controller.isOpen, isTrue);
      expect(controller.isLoading, isTrue);
      expect(service.queries, isEmpty);

      await _settle();
      expect(controller.isLoading, isFalse);
    });

    test('closes without searching when the gate rejects the input', () async {
      final service = _FakeSearchService();
      final controller = RecipientSearchController(service: service);
      addTearDown(controller.dispose);

      controller.onInput('alice', Chain.solana);
      expect(controller.isOpen, isTrue);

      controller.onInput('alice.sol', Chain.solana);
      expect(controller.isOpen, isFalse);

      await _settle();
      expect(service.queries, isEmpty);
    });

    test('passes the active chain through to the service', () async {
      final service = _FakeSearchService();
      final controller = RecipientSearchController(service: service);
      addTearDown(controller.dispose);

      controller.onInput('alice', Chain.tezos);
      await _settle();

      expect(service.chains, [Chain.tezos]);
      expect(controller.chain, Chain.tezos);
    });
  });

  group('stale responses', () {
    test('drops a slow response that lands after a newer one', () async {
      // The webapp compares query strings, which cannot tell two identical
      // queries apart. A sequence token can, and this is the case that decides
      // which address the user ends up sending to.
      final service = _FakeSearchService()
        ..scripted['alicea'] = (
          const Duration(milliseconds: 800),
          [_suggestion(_sol1, username: 'alicea')],
        )
        ..scripted['aliceb'] = (
          Duration.zero,
          [_suggestion(_sol2, username: 'aliceb')],
        );
      final controller = RecipientSearchController(service: service);
      addTearDown(controller.dispose);

      controller.onInput('alicea', Chain.solana);
      // Let the first request actually dispatch before superseding it.
      await Future<void>.delayed(const Duration(milliseconds: 550));
      controller.onInput('aliceb', Chain.solana);
      await _settle(900);

      expect(service.queries, ['alicea', 'aliceb']);
      expect(controller.results.map((s) => s.username), ['aliceb']);
    });

    test(
      'a response arriving after close() cannot reopen the dropdown',
      () async {
        // Otherwise picking a row, then having the in-flight search land, would
        // pop the dropdown back over the field the user just finished with.
        final service = _FakeSearchService()
          ..scripted['alice'] = (
            const Duration(milliseconds: 300),
            [_suggestion(_sol1)],
          );
        final controller = RecipientSearchController(service: service);
        addTearDown(controller.dispose);

        controller.onInput('alice', Chain.solana);
        await Future<void>.delayed(const Duration(milliseconds: 550));
        controller.close();
        await _settle(500);

        expect(controller.isOpen, isFalse);
        expect(controller.results, isEmpty);
      },
    );
  });

  group('exclusions', () {
    test('hides the user\'s own wallets from the results', () async {
      // Offering a row that would be rejected at Next with "You can't send to
      // your own wallet" is a dead end the user has to discover by tapping.
      final service = _FakeSearchService()
        ..defaultResults = [_suggestion(_sol1), _suggestion(_sol2)];
      final controller = RecipientSearchController(
        service: service,
        isExcluded: (address) => address == _sol1,
      );
      addTearDown(controller.dispose);

      controller.onInput('alice', Chain.solana);
      await _settle();

      expect(controller.results.map((s) => s.address), [_sol2]);
    });
  });
}
