import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/market/services/token_refund_rent.dart';
import 'package:solana/encoder.dart';

import '../refund_transaction_fixture.dart';

void main() {
  const payer = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
  const account = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';

  for (final versioned in [false, true]) {
    for (final token2022 in [false, true]) {
      test('decodes exact rent with two signatures, priority fee, '
          'v0=$versioned, Token2022=$token2022', () {
        final tx = refundTransactionFixture(
          payerAddress: payer,
          accountAddress: account,
          rent: 1488440,
          versioned: versioned,
          token2022: token2022,
        );
        final message = SignedTx.fromBytes(base64Decode(tx)).compiledMessage;
        expect(message.requiredSignatureCount, 2);
        final rent = TokenRefundRent.decode(tx, payer)!;
        expect(rent.resolve({}, {}), 1488440);
        expect(rent.associatedAccounts, isEmpty);
      });
    }
  }

  test('one signature and priority fee alone quote no rent', () {
    final tx = refundTransactionFixture(
      payerAddress: payer,
      accountAddress: account,
    );
    expect(
      SignedTx.fromBytes(
        base64Decode(tx),
      ).compiledMessage.requiredSignatureCount,
      1,
    );
    expect(TokenRefundRent.decode(tx, payer)!.resolve({}, {}), 0);
  });

  test('does not attribute another funder\'s create to the payer', () {
    final tx = refundTransactionFixture(
      payerAddress: payer,
      accountAddress: account,
      funderAddress: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
      rent: 1488440,
    );
    expect(TokenRefundRent.decode(tx, payer)!.resolve({}, {}), 0);
  });

  for (final token2022 in [false, true]) {
    test(
      'idempotent ATA quote uses only new funding, Token2022=$token2022',
      () {
        final tx = refundTransactionFixture(
          payerAddress: payer,
          accountAddress: account,
          associated: true,
          token2022: token2022,
          versioned: true,
        );
        final rent = TokenRefundRent.decode(tx, payer)!;
        expect(rent.associatedAccounts, [account]);
        expect(rent.resolve({account: 0}, {account: 1488440}), 1488440);
        expect(rent.resolve({account: 1488440}, {account: 1488440}), 0);
        expect(rent.resolve({account: 500000}, {account: 1488440}), 988440);
        expect(rent.resolve({}, {account: 1488440}), isNull);
        expect(rent.resolve({account: 0}, {}), isNull);
      },
    );
  }

  test('unknown transaction cannot support a rent quote', () {
    expect(TokenRefundRent.decode('invalid', payer), isNull);
  });
}
