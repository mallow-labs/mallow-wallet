import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:solana/solana.dart';

/// Pins the webapp-parity rules for the compute-budget prefix
/// (the server's shared kit + Solana helpers)
/// and the classic Jupiter swap-instructions parsing. If someone changes the
/// fee window, multiplier, or instruction set/order, these fail.
void main() {
  group('resolveComputeBudget', () {
    // Values like 220001 (not 220000) are deliberate: `200000 * 1.1` is
    // 220000.00000000003 in IEEE-754, and JS `Math.ceil` rounds it up the
    // same way — so this is bit-for-bit what the webapp computes.
    test('falls back to 200k default ×1.1 when simulation failed', () {
      expect(SolanaRpcService.resolveComputeBudget(null), 220001);
    });

    test('floors simulated units at 10k before padding', () {
      expect(SolanaRpcService.resolveComputeBudget(5000), 11000);
    });

    test('pads ×1.1 and caps at 1.4M', () {
      expect(SolanaRpcService.resolveComputeBudget(100000), 110001);
      expect(SolanaRpcService.resolveComputeBudget(2000000), 1400000);
    });
  });

  group('computeBudgetIxs', () {
    const budget = 220000;
    // Webapp clamp window for a 220k budget:
    //   min = ceil(15_000 / 220_000 * 1e6), max = ceil(50_000 / 220_000 * 1e6)
    final minMicro = (15000 / budget * 1e6).ceil();
    final maxMicro = (50000 / budget * 1e6).ceil();

    ComputeBudgetInstruction priceIx(int micro) =>
        ComputeBudgetInstruction.setComputeUnitPrice(microLamports: micro);

    test('emits [price, limit] in that order for a non-default budget', () {
      final ixs = SolanaRpcService.computeBudgetIxs(computeBudget: budget);
      expect(ixs, hasLength(2));
      expect(ixs[0].data.toList(), priceIx(minMicro).data.toList());
      expect(
        ixs[1].data.toList(),
        ComputeBudgetInstruction.setComputeUnitLimit(
          units: budget,
        ).data.toList(),
      );
      expect(ixs[0].programId, ComputeBudgetProgram.id);
    });

    test('omits the limit ix at exactly the 200k default budget', () {
      final ixs = SolanaRpcService.computeBudgetIxs(computeBudget: 200000);
      expect(ixs, hasLength(1));
    });

    test('clamps the Helius recommendation into the fee window', () {
      final tooHigh = SolanaRpcService.computeBudgetIxs(
        computeBudget: budget,
        recommendedMicroLamports: 100000000,
      );
      expect(tooHigh[0].data.toList(), priceIx(maxMicro).data.toList());

      final tooLow = SolanaRpcService.computeBudgetIxs(
        computeBudget: budget,
        recommendedMicroLamports: 1,
      );
      expect(tooLow[0].data.toList(), priceIx(minMicro).data.toList());
    });

    test('floors the final unit price at 15k microlamports', () {
      // A tiny budget makes the window exceed 15k, so the floor only binds
      // for very large budgets where the window drops below 15k.
      final ixs = SolanaRpcService.computeBudgetIxs(
        computeBudget: 1400000,
        recommendedMicroLamports: 2,
      );
      // min window = ceil(15_000/1_400_000*1e6) = 10_715 → floored to 15_000.
      expect(ixs[0].data.toList(), priceIx(15000).data.toList());
    });
  });

  group('classic Jupiter parsing', () {
    const ixJson = {
      'programId': 'ComputeBudget111111111111111111111111111111',
      'accounts': [
        {
          'pubkey': 'So11111111111111111111111111111111111111112',
          'isSigner': true,
          'isWritable': false,
        },
      ],
      'data': 'AwQABg==',
    };

    test('quote round-trips the raw map verbatim', () {
      final raw = {
        'inAmount': '100',
        'outAmount': '99',
        'routePlan': [
          {'unknownField': 'must survive'},
        ],
      };
      final quote = JupiterClassicQuote(raw);
      expect(quote.inAmount, '100');
      expect(quote.outAmount, '99');
      // The exact map instance is what gets POSTed back as quoteResponse.
      expect(identical(quote.raw, raw), isTrue);
    });

    test('swap-instructions response parses all sections', () {
      final parsed = JupSwapInstructions.fromJson({
        'computeBudgetInstructions': [ixJson, ixJson],
        'setupInstructions': [ixJson],
        'swapInstruction': ixJson,
        'cleanupInstruction': ixJson,
        'addressLookupTableAddresses': ['table1', 'table2'],
      });
      expect(parsed.computeBudgetInstructions, hasLength(2));
      expect(parsed.setupInstructions, hasLength(1));
      expect(parsed.cleanupInstruction, isNotNull);
      expect(parsed.addressLookupTableAddresses, ['table1', 'table2']);
      expect(parsed.swapInstruction.dataBase64, 'AwQABg==');
      expect(parsed.swapInstruction.accounts.single.isSigner, isTrue);
      expect(parsed.swapInstruction.accounts.single.isWritable, isFalse);
    });

    test('cleanup instruction is optional', () {
      final parsed = JupSwapInstructions.fromJson({
        'setupInstructions': const <Map<String, dynamic>>[],
        'swapInstruction': ixJson,
        'addressLookupTableAddresses': const <String>[],
      });
      expect(parsed.cleanupInstruction, isNull);
      expect(parsed.setupInstructions, isEmpty);
    });
  });
}
