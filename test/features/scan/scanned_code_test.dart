import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/router/app_router.dart';
import 'package:mallow_wallet/core/services/deep_link_handler_registry.dart';
import 'package:mallow_wallet/features/browser/models/browser_open_link.dart';
import 'package:mallow_wallet/features/scan/models/scanned_code.dart';
import 'package:mallow_wallet/features/scan/services/scanned_code_router.dart';
import 'package:mallow_wallet/features/send/models/payment_request.dart';
import 'package:mallow_wallet/features/send/models/recipient_address.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

void main() {
  const topic =
      '7f6e504bfad60b485450578e05678ed3e8e8c4751d3c6160be17160d63ec90f9';
  const key =
      '587d5484ce2a2a6ee3ba1962fdd7e8588e06200c46823bd18fbd67def96ad303';
  const pairing = 'wc:$topic@2?relay-protocol=irn&symKey=$key';
  const solana = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const ethereum = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
  const tezos = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

  group('ScannedCode.parse', () {
    test('a WalletConnect pairing, trimmed', () {
      final code = ScannedCode.parse('  $pairing\n');
      expect(code, isA<WalletConnectCode>());
      expect((code as WalletConnectCode).text, pairing);
    });

    test("the app's WalletConnect wrapper is WalletConnect, not a link", () {
      final code = ScannedCode.parse(
        'mallowwallet://wc?uri=${Uri.encodeComponent(pairing)}',
      );
      expect(code, isA<WalletConnectCode>());
    });

    test('a malformed wc: link still goes to WalletConnect', () {
      expect(ScannedCode.parse('wc:nonsense'), isA<WalletConnectCode>());
    });

    test('a link to the website or a subdomain is a mallow link', () {
      for (final text in [
        'https://mallow.art/artwork/abc',
        'https://www.mallow.art/example/page',
        'mallowwallet://browser/open?url=https%3A%2F%2Fexample.com',
      ]) {
        expect(ScannedCode.parse(text), isA<MallowLinkCode>(), reason: text);
      }
    });

    test('any other HTTPS website is for the browser', () {
      final code = ScannedCode.parse('https://example.com/page?q=1');
      expect(code, isA<WebsiteCode>());
      expect(
        (code as WebsiteCode).url,
        Uri.parse('https://example.com/page?q=1'),
      );
    });

    test('a look-alike host is a plain website, not a mallow link', () {
      expect(
        ScannedCode.parse('https://evilmallow.art/artwork/abc'),
        isA<WebsiteCode>(),
      );
    });

    test('plain HTTP is refused as insecure', () {
      final code = ScannedCode.parse('http://example.com');
      expect(code, isA<UnsupportedCode>());
      expect((code as UnsupportedCode).message, contains('HTTPS'));
    });

    RecipientAddress? recipientOf(String text) =>
        switch (ScannedCode.parse(text)) {
          WalletAddressCode(:final recipient) => recipient,
          _ => null,
        };

    test('a bare wallet address names its chain', () {
      expect(
        recipientOf(' $solana\n'),
        const RecipientAddress(address: solana, chain: Chain.solana),
      );
      expect(
        recipientOf(ethereum),
        const RecipientAddress(address: ethereum, chain: Chain.ethereum),
      );
      expect(
        recipientOf(tezos),
        const RecipientAddress(address: tezos, chain: Chain.tezos),
      );
    });

    test('an address behind its chain scheme is the address', () {
      expect(
        recipientOf('solana:$solana'),
        const RecipientAddress(address: solana, chain: Chain.solana),
      );
      expect(
        recipientOf('ethereum:$ethereum'),
        const RecipientAddress(address: ethereum, chain: Chain.ethereum),
      );
      expect(
        recipientOf('tezos:$tezos'),
        const RecipientAddress(address: tezos, chain: Chain.tezos),
      );
    });

    test('an EVM address keeps its case, so the field can check it', () {
      // A failed checksum still opens the flow: the recipient field is what
      // explains it, rather than a scanner that silently ignores the code.
      final mistyped = ethereum.replaceFirst('aA', 'Aa');
      expect(recipientOf(mistyped)?.address, mistyped);
    });

    test('a payment request is a payment, not a bare address', () {
      for (final text in [
        'solana:$solana?amount=1',
        'solana:$solana?spl-token=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
        'ethereum:$ethereum?value=1e18',
        'ethereum:$ethereum@1?value=1e18',
      ]) {
        expect(
          ScannedCode.parse(text),
          isA<PaymentRequestCode>(),
          reason: text,
        );
      }
    });

    test('a request that cannot be paid says why', () {
      final code = ScannedCode.parse('ethereum:$ethereum@137?value=1');
      expect(code, isA<UnsupportedCode>());
      expect((code as UnsupportedCode).message, contains('another network'));
      // A scheme that names another chain than the address is on.
      expect(ScannedCode.parse('ethereum:$solana'), isA<UnsupportedCode>());
    });

    test('text, credentials and other schemes are refused', () {
      for (final text in [
        '',
        'hello world',
        // Base58, but too short to be an address on any chain.
        '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsG',
        'https://user:pass@example.com',
        'javascript:alert(1)',
        'mallowwallet://auth?code=x',
      ]) {
        expect(ScannedCode.parse(text), isA<UnsupportedCode>(), reason: text);
      }
    });
  });

  group('ScannedCodeRouter', () {
    late DeepLinkHandlerRegistry handlers;
    late List<String> connected;
    late List<RecipientAddress> sentTo;
    late List<PaymentRequest> paid;
    late List<(String, Object?)> pushed;
    late List<String> messages;
    late bool browserOn;

    ScannedCodeRouter router() => ScannedCodeRouter(
      handlers: handlers,
      connect: (text) {
        connected.add(text);
        return true;
      },
      sendTo: sentTo.add,
      pay: paid.add,
      push: (location, {extra}) => pushed.add((location, extra)),
      browserEnabled: () => browserOn,
      showMessage: messages.add,
    );

    void open(String text) => router().open(ScannedCode.parse(text));

    Uri? browserUrl() {
      expect(pushed, hasLength(1));
      expect(pushed.single.$1, AppRoutes.browserOpen);
      return (pushed.single.$2! as BrowserOpenRequest).url;
    }

    setUp(() {
      handlers = DeepLinkHandlerRegistry();
      connected = [];
      sentTo = [];
      paid = [];
      pushed = [];
      messages = [];
      browserOn = true;
    });

    test('WalletConnect goes to WalletConnect and nowhere else', () {
      handlers.register((_, {required replay}) => fail('offered to handler'));
      open(pairing);
      expect(connected, [pairing]);
      expect(pushed, isEmpty);
    });

    test('a wallet address offers a send, and is never a link', () {
      handlers.register((_, {required replay}) => fail('offered to handler'));
      open(ethereum);
      expect(sentTo, [
        const RecipientAddress(address: ethereum, chain: Chain.ethereum),
      ]);
      expect(pushed, isEmpty);
      expect(messages, isEmpty);
    });

    test('a payment request goes straight to paying it', () {
      open('solana:$solana?amount=0.5&label=Shop');
      expect(paid.single.recipient.address, solana);
      expect(sentTo, isEmpty, reason: 'no "what to send" question');
      expect(pushed, isEmpty);
    });

    test('a link a feature claims goes to it, as a fresh scan', () {
      final seen = <(Uri, bool)>[];
      handlers.register((uri, {required replay}) {
        if (uri.pathSegments.firstOrNull != 'example') return false;
        seen.add((uri, replay));
        return true;
      });
      open('https://mallow.art/example/page');
      expect(seen, [(Uri.parse('https://mallow.art/example/page'), false)]);
      expect(pushed, isEmpty);
      expect(messages, isEmpty);
    });

    test('a website is never offered to the link handlers', () {
      handlers.register((_, {required replay}) => fail('offered to handler'));
      open('https://example.com/');
      expect(browserUrl(), Uri.parse('https://example.com/'));
    });

    test('an artwork link opens its screen', () {
      open('https://mallow.art/artwork/abc');
      expect(pushed.single.$1, AppRoutes.artworkDetailPath('abc'));
    });

    test('a browser handoff opens the page it carries', () {
      open('mallowwallet://browser/open?url=https%3A%2F%2Fexample.com%2Fx');
      expect(browserUrl(), Uri.parse('https://example.com/x'));
    });

    test('a page of the website with no screen opens in the browser', () {
      open('https://mallow.art/example/page');
      expect(browserUrl(), Uri.parse('https://mallow.art/example/page'));
    });

    test('an unknown custom-scheme link says it cannot be opened', () {
      open('mallowwallet://nothing/here');
      expect(pushed, isEmpty);
      expect(messages, hasLength(1));
    });

    test('with the browser off, a website says so instead of opening', () {
      browserOn = false;
      open('https://example.com/');
      expect(pushed, isEmpty);
      expect(messages.single, contains('browser'));
    });

    test('a refused code shows its reason', () {
      open('http://example.com');
      expect(messages.single, contains('HTTPS'));
    });
  });
}
