import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/offers/data/offers_inbox_repository.dart';
import 'package:mallow_wallet/features/offers/services/offers_inbox_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Api extends Mock implements api.MallowApiV2Client {}

class _Session extends Mock implements SessionManager {}

void main() {
  setUpAll(
    () => registerFallbackValue(const api.GetOffersInboxRequest(owners: [])),
  );

  test(
    'mixed session queries only Solana rows, including a tz-prefix bidder',
    () async {
      final client = _Api();
      final session = _Session();
      const tzSolana = 'tz1111111111111111111111111111111111111111111';
      WalletInfo wallet(String address, String chain) => WalletInfo(
        id: '$address-$chain',
        address: address,
        name: chain,
        chain: chain,
        walletType: WalletType.viewOnly,
      );
      when(() => session.sessionWallets).thenReturn([
        wallet(tzSolana, 'solana'),
        wallet('SOLANA', 'solana'),
        wallet(tzSolana, 'solana'),
        wallet('', 'solana'),
        wallet('0x1234', 'ethereum'),
        wallet('tz1TEZOS', 'tezos'),
      ]);
      when(
        () => session.apiOwnerAddresses,
      ).thenReturn([tzSolana, 'SOLANA', '0x1234', 'tz1TEZOS']);
      when(() => client.getOffersInbox(any())).thenAnswer(
        (_) async =>
            const api.ApiResponse(result: api.OffersInboxPage(result: [])),
      );
      final calls = <String>[];
      when(() => client.getBidRefunds(any())).thenAnswer((invocation) async {
        final bidder = invocation.positionalArguments.single as String;
        calls.add(bidder);
        return api.ApiResponse(
          result: api.BidRefundsResponse(
            refunds: [
              api.BidRefund(claim: bidder, mint: 'CURRENCY', amount: '42'),
            ],
          ),
        );
      });
      final bloc = OffersInboxBloc(OffersInboxRepository(client), session);
      bloc.add(const OffersInboxEvent.load());
      final loaded =
          await bloc.stream.firstWhere(
                (s) => s is OffersInboxLoaded && s.bidRefunds.length == 2,
              )
              as OffersInboxLoaded;
      expect(calls, [tzSolana, 'SOLANA']);
      expect(loaded.bidRefunds.map((b) => b.bidder), calls);
      await bloc.close();
    },
  );

  test(
    'refund repository removes duplicate and empty Solana addresses',
    () async {
      final client = _Api();
      when(() => client.getBidRefunds('BIDDER')).thenAnswer(
        (_) async =>
            const api.ApiResponse(result: api.BidRefundsResponse(refunds: [])),
      );
      final result = await OffersInboxRepository(
        client,
      ).getBidRefunds(['BIDDER', '', 'BIDDER']);
      expect(result, isEmpty);
      verify(() => client.getBidRefunds('BIDDER')).called(1);
      verifyNever(() => client.getBidRefunds(''));
    },
  );
  test(
    'deposit discovery deduplicates wallets and keeps closable claims when releasable is absent',
    () async {
      final client = _Api();
      when(() => client.getBidRefundClaims('PAYER')).thenAnswer(
        (_) async => api.ApiResponse(
          result: api.BidRefundClaimsResponse.fromJson({
            'claims': [
              for (final row in [
                ('EMPTY_SOL', 'PAYER', true),
                ('EMPTY_TOKEN', 'PAYER', true),
                ('PENDING', 'PAYER', false),
                ('OTHER_PAYER', 'OTHER', true),
                ('EMPTY_SOL', 'PAYER', true),
              ])
                {
                  'claim': row.$1,
                  'bidder': 'OTHER_BIDDER',
                  'mint': 'CURRENCY',
                  'rentPayer': row.$2,
                  'amount': row.$3 ? '0' : '42',
                  'closable': row.$3,
                },
            ],
          }),
        ),
      );
      final deposits = await OffersInboxRepository(
        client,
      ).getBidRefundDeposits(['PAYER', '', 'PAYER']);
      expect(deposits.map((d) => d.claim), ['EMPTY_SOL', 'EMPTY_TOKEN']);
      expect(deposits.map((d) => d.rentPayer), ['PAYER', 'PAYER']);
      expect(deposits.last.releasable, isFalse);
      verify(() => client.getBidRefundClaims('PAYER')).called(1);
      verifyNever(() => client.getBidRefundClaims(''));
      verifyNever(() => client.getBidRefunds(any()));
    },
  );

  test(
    'deposit discovery keeps releasable claims but excludes unusable token vaults, SOL and another payer',
    () async {
      final client = _Api();
      when(() => client.getBidRefundClaims('PAYER')).thenAnswer(
        (_) async => api.ApiResponse(
          result: api.BidRefundClaimsResponse.fromJson({
            'claims': [
              for (final row in [
                (
                  'SOL',
                  'PAYER',
                  'So11111111111111111111111111111111111111112',
                  '42',
                ),
                (
                  'UNRELEASABLE_SOL',
                  'PAYER',
                  'So11111111111111111111111111111111111111112',
                  '42',
                ),
                ('FROZEN_VAULT', 'PAYER', 'TOKEN_MINT', '42'),
                ('SHORT_VAULT', 'PAYER', 'TOKEN_MINT', '42'),
                ('MISSING_VAULT', 'PAYER', 'TOKEN_MINT', '42'),
                ('RELEASABLE_TOKEN', 'PAYER', 'TOKEN_MINT', '42'),
                (
                  'OTHER',
                  'OTHER_PAYER',
                  'So11111111111111111111111111111111111111112',
                  '42',
                ),
                (
                  'ZERO',
                  'PAYER',
                  'So11111111111111111111111111111111111111112',
                  '0',
                ),
                (
                  'INVALID',
                  'PAYER',
                  'So11111111111111111111111111111111111111112',
                  'invalid',
                ),
              ])
                {
                  'claim': row.$1,
                  'bidder': 'ORIGINAL_BIDDER',
                  'rentPayer': row.$2,
                  'mint': row.$3,
                  'amount': row.$4,
                  'closable': false,
                  'releasable': row.$1 == 'SOL' || row.$1 == 'RELEASABLE_TOKEN',
                },
            ],
          }),
        ),
      );
      final deposits = await OffersInboxRepository(
        client,
      ).getBidRefundDeposits(['PAYER', 'PAYER']);
      expect(deposits.map((d) => d.claim), ['SOL', 'RELEASABLE_TOKEN']);
      expect(deposits.every((d) => d.releasable), isTrue);
      expect(deposits.last.releasable, isTrue);
      expect(deposits.last.mint, 'TOKEN_MINT');
      expect(deposits.last.isSol, isFalse);
      expect(deposits.first.bidder, 'ORIGINAL_BIDDER');
      expect(deposits.first.amount, '42');
      expect(deposits.first.needsRelease, isTrue);
      verify(() => client.getBidRefundClaims('PAYER')).called(1);
    },
  );

  test(
    'deposit read failure propagates instead of reporting no recoverable funds',
    () async {
      final client = _Api();
      when(
        () => client.getBidRefundClaims('PAYER'),
      ).thenThrow(Exception('Unavailable'));
      await expectLater(
        OffersInboxRepository(client).getBidRefundDeposits(['PAYER']),
        throwsException,
      );
    },
  );
}
