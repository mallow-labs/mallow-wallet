import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/solana_pay_tags.dart';
import 'package:mallow_wallet/features/send/models/payment_request.dart';
import 'package:mallow_wallet/features/send/models/recipient_address.dart';
import 'package:mallow_wallet/shared/utils/chain.dart';

void main() {
  const merchant = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
  const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
  const ref1 = 'DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263';
  const ref2 = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const eth = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed';
  const token = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
  const tezos = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';

  PaymentRequest request(String text) {
    final parsed = parsePaymentUri(text);
    expect(parsed, isA<PaymentUriRequest>(), reason: text);
    return (parsed! as PaymentUriRequest).request;
  }

  void refused(String text, [Matcher message = anything]) {
    final parsed = parsePaymentUri(text);
    expect(parsed, isA<PaymentUriRefused>(), reason: text);
    expect((parsed! as PaymentUriRefused).message, message, reason: text);
  }

  test('text without a chain scheme is not a payment URI', () {
    for (final text in ['', merchant, 'https://example.com', 'bitcoin:abc']) {
      expect(parsePaymentUri(text), isNull, reason: text);
    }
  });

  group('Solana Pay', () {
    test('a full transfer request', () {
      final r = request(
        'solana:$merchant?amount=1.5&spl-token=$usdc'
        '&reference=$ref1&reference=$ref2'
        '&label=Coffee%20Shop&message=Thanks%21&memo=order%2042',
      );
      expect(
        r.recipient,
        const RecipientAddress(address: merchant, chain: Chain.solana),
      );
      expect(r.token, usdc);
      expect(r.amount, const DecimalAmount('1.5'));
      expect(
        r.tags,
        const SolanaPayTags(references: [ref1, ref2], memo: 'order 42'),
      );
      expect(r.label, 'Coffee Shop');
      expect(r.message, 'Thanks!');
    });

    test('no spl-token is native SOL, and no amount is left to the payer', () {
      final r = request('solana:$merchant?label=Tips');
      expect(r.token, isNull);
      expect(r.amount, isNull);
      expect(r.tags.isEmpty, isTrue);
    });

    test('the address alone is an address, not a request', () {
      final parsed = parsePaymentUri('solana:$merchant');
      expect(
        (parsed! as PaymentUriAddress).recipient,
        const RecipientAddress(address: merchant, chain: Chain.solana),
      );
    });

    test('a transaction request is refused by name', () {
      refused(
        'solana:https%3A%2F%2Fexample.com%2Fpay',
        contains('transaction requests'),
      );
    });

    test('malformed fields refuse the whole request', () {
      for (final text in [
        'solana:$merchant?amount=-1',
        'solana:$merchant?amount=1e3',
        'solana:$merchant?amount=.5',
        'solana:$merchant?amount=1&amount=2',
        'solana:$merchant?spl-token=nope',
        'solana:$merchant?reference=nope',
        'solana:notanaddress?amount=1',
      ]) {
        refused(text);
      }
    });
  });

  group('EIP-681', () {
    test('ether in wei, with an exponent and the mainnet chain id', () {
      final r = request('ethereum:$eth@1?value=2.014e18');
      expect(
        r.recipient,
        const RecipientAddress(address: eth, chain: Chain.ethereum),
      );
      expect(r.token, isNull);
      expect(r.amount, AtomicAmount(BigInt.parse('2014000000000000000')));
    });

    test('an ERC-20 transfer pays the address parameter in the token', () {
      final r = request(
        'ethereum:$token@1/transfer?address=$eth&uint256=1000000',
      );
      expect(r.recipient.address, eth, reason: 'the payee, not the contract');
      expect(r.token, token.toLowerCase());
      expect(r.amount, AtomicAmount(BigInt.from(1000000)));
    });

    test('the pay- prefix is accepted', () {
      expect(request('ethereum:pay-$eth?value=1').recipient.address, eth);
    });

    test('an address on this network is an address', () {
      for (final text in ['ethereum:$eth', 'ethereum:$eth@1']) {
        expect(parsePaymentUri(text), isA<PaymentUriAddress>(), reason: text);
      }
    });

    test('another network is refused', () {
      refused('ethereum:$eth@137?value=1', contains('another network'));
      expect(
        parsePaymentUri('ethereum:$eth@5?value=1', ethereumChainId: 5),
        isA<PaymentUriRequest>(),
      );
    });

    test('a call other than transfer is refused', () {
      refused(
        'ethereum:$token/approve?address=$eth&uint256=1',
        contains("isn't a payment"),
      );
    });

    test('malformed requests are refused', () {
      for (final text in [
        // A fraction of a wei.
        'ethereum:$eth?value=1.5',
        'ethereum:$eth?value=abc',
        'ethereum:$token/transfer?uint256=1',
        'ethereum:$token/transfer?address=$eth&uint256=1&value=1',
        'ethereum:vitalik.eth?value=1',
        'ethereum:$merchant',
      ]) {
        refused(text);
      }
    });
  });

  test('Tezos has an address form and no request form', () {
    expect(parsePaymentUri('tezos:$tezos'), isA<PaymentUriAddress>());
    refused('tezos:$tezos?amount=1', contains('Tezos'));
  });

  group('RequestedAmount.inDecimals', () {
    test('a whole-token amount is checked against the decimals', () {
      expect(const DecimalAmount('1.50').inDecimals(6), '1.5');
      expect(const DecimalAmount('0.000001').inDecimals(6), '0.000001');
      expect(const DecimalAmount('0.0000001').inDecimals(6), isNull);
    });

    test('an atomic amount is scaled by the decimals', () {
      expect(AtomicAmount(BigInt.from(1500000)).inDecimals(6), '1.5');
      expect(
        AtomicAmount(BigInt.parse('2014000000000000000')).inDecimals(18),
        '2.014',
      );
    });
  });
}
