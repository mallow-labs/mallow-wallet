import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/data/mallow_market.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/features/sale/services/marketplace_config_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:solana/dto.dart';

class _MockSolanaRpcService extends Mock implements SolanaRpcService {}

/// Build an AccountResult whose data encodes [primary]/[secondary]/[printFee]
/// at the canonical fee offsets.
AccountResult _accountWithFees({
  required int primary,
  required int secondary,
  int printFee = 11000000,
}) {
  // Pad to cover the offset range (the print fee u64 runs 80..88).
  final bytes = Uint8List(128);
  final view = ByteData.sublistView(bytes);
  view.setUint16(kPrimaryBpsOffset, primary, Endian.little);
  view.setUint16(kSecondaryBpsOffset, secondary, Endian.little);
  view.setUint64(kPrintFeeOffset, printFee, Endian.little);
  return AccountResult(
    context: Context(slot: BigInt.zero),
    value: Account(
      lamports: 1_000_000,
      owner: kMallowMarketProgramId,
      data: BinaryAccountData(bytes.toList()),
      executable: false,
      rentEpoch: BigInt.zero,
    ),
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(Encoding.base64);
  });

  group('MarketplaceConfigService.get', () {
    late _MockSolanaRpcService rpc;
    late Duration fakeElapsed;
    late MarketplaceConfigService service;

    setUp(() {
      rpc = _MockSolanaRpcService();
      fakeElapsed = Duration.zero;
      service = MarketplaceConfigService(rpc, elapsed: () => fakeElapsed);
    });

    test('decodes primary/secondary bps and print fee from the PDA '
        'bytes', () async {
      when(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).thenAnswer(
        (_) async =>
            _accountWithFees(primary: 500, secondary: 250, printFee: 12345678),
      );

      final fees = await service.get();

      expect(fees.primaryBps, 500);
      expect(fees.secondaryBps, 250);
      expect(fees.printFeeLamports, 12345678);
      // RPC was requested with binary encoding (required for BinaryAccountData).
      final captured = verify(
        () => rpc.getAccountInfo(
          captureAny(),
          encoding: captureAny(named: 'encoding'),
        ),
      ).captured;
      expect(captured[1], Encoding.base64);
    });

    test('caches successful result within the TTL — second call hits '
        'the cache', () async {
      when(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).thenAnswer((_) async => _accountWithFees(primary: 500, secondary: 250));

      await service.get();
      await service.get();

      verify(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).called(1);
    });

    test(
      'refetches after the TTL expires so on-chain fee updates surface',
      () async {
        var primary = 600;
        when(
          () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
        ).thenAnswer(
          (_) async => _accountWithFees(primary: primary, secondary: 300),
        );

        final initial = await service.get();
        expect(initial.primaryBps, 600);

        // Simulate an on-chain fee bump and step past the TTL boundary.
        primary = 700;
        fakeElapsed =
            MarketplaceConfigService.cacheTtl + const Duration(seconds: 1);

        final refreshed = await service.get();
        expect(refreshed.primaryBps, 700);
        verify(
          () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
        ).called(2);
      },
    );

    test('RPC throws → returns hardcoded defaults without poisoning the '
        'cache, and recovers on the next call', () async {
      // The new contract (aligned with the webapp): a transient failure must
      // NOT pin the session to fallback fees. We return defaults so the
      // listing flow never blocks, but leave the cache empty so the next
      // call retries the RPC.
      when(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).thenThrow(StateError('network down'));

      final fallback = await service.get();
      expect(fallback.primaryBps, kDefaultPrimaryFeeBps);
      expect(fallback.secondaryBps, kDefaultSecondaryFeeBps);
      expect(fallback.printFeeLamports, kDefaultPrintFeeLamports);

      // Next call must retry the RPC instead of returning a cached fallback.
      when(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).thenAnswer((_) async => _accountWithFees(primary: 600, secondary: 300));

      final recovered = await service.get();
      expect(recovered.primaryBps, 600);
      expect(recovered.secondaryBps, 300);
      verify(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).called(2);
    });

    test('account missing → falls back to defaults without caching', () async {
      when(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).thenAnswer(
        (_) async =>
            AccountResult(context: Context(slot: BigInt.zero), value: null),
      );

      final fees = await service.get();
      expect(fees.primaryBps, kDefaultPrimaryFeeBps);
      expect(fees.secondaryBps, kDefaultSecondaryFeeBps);

      // A missing account is a failure, not a success — it must not be cached.
      await service.get();
      verify(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).called(2);
    });

    test('non-binary account data → falls back to defaults', () async {
      // Empty account data is not BinaryAccountData; the parser bails.
      when(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).thenAnswer(
        (_) async => AccountResult(
          context: Context(slot: BigInt.zero),
          value: Account(
            lamports: 0,
            owner: kMallowMarketProgramId,
            data: const EmptyAccountData(),
            executable: false,
            rentEpoch: BigInt.zero,
          ),
        ),
      );

      final fees = await service.get();
      expect(fees.primaryBps, kDefaultPrimaryFeeBps);
      expect(fees.secondaryBps, kDefaultSecondaryFeeBps);
    });

    test('coalesces concurrent reads into a single RPC call', () async {
      when(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).thenAnswer((_) async => _accountWithFees(primary: 600, secondary: 300));

      final results = await Future.wait([
        service.get(),
        service.get(),
        service.get(),
      ]);

      for (final r in results) {
        expect(r.primaryBps, 600);
      }
      verify(
        () => rpc.getAccountInfo(any(), encoding: any(named: 'encoding')),
      ).called(1);
    });
  });
}
