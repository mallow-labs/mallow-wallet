import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/features/swap/data/swap_repository.dart';
import 'package:mallow_wallet/features/swap/swap_constants.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/dto.dart';

import 'swap_repository_test.mocks.dart';

const _referralAccount = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';
const _solMint = 'So11111111111111111111111111111111111111112';
const _usdcMint = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

/// Reference associated token accounts of [_referralAccount], derived
/// independently with `@solana/web3.js` `PublicKey.findProgramAddressSync`.
const _solFeeAccount = '87ntzPm3L3GRLzpMrR7SDZA85NCsHDAaHNhcezczDRrX';
const _usdcFeeAccount = 'AmvU9KEJZ2F3u7E3H43k1VU3S5GZPPSKQzJnbJtAJjvN';
const _solFeeAccount2022 = '9DZ4ygT9m8SarcKVZAaovgqcLHYZ52Yw8KRVzbc5QHhW';
const _usdcFeeAccount2022 = 'ApjSgFNZXErFvDS5fS4P2Dhvr76q94rcR4MS1Yx4yvgb';

AccountResult _missing() =>
    AccountResult(context: Context(slot: BigInt.zero), value: null);

AccountResult _present() => AccountResult(
  context: Context(slot: BigInt.zero),
  value: Account(
    lamports: 2039280,
    owner: 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA',
    data: const BinaryAccountData([]),
    executable: false,
    rentEpoch: BigInt.zero,
  ),
);

@GenerateMocks([
  JupiterAggregatorClient,
  JupiterSwapInstructionsClient,
  SolanaRpcService,
])
void main() {
  late MockJupiterSwapInstructionsClient classic;
  late MockSolanaRpcService rpc;
  late SwapRepository repository;

  const quote = JupiterClassicQuote({'inAmount': '1', 'outAmount': '2'});

  setUp(() {
    classic = MockJupiterSwapInstructionsClient();
    rpc = MockSolanaRpcService();
    repository = SwapRepository.withRpc(
      MockJupiterAggregatorClient(),
      classic,
      rpc,
    );
    Config.debugOverrides['JUPITER_REFERRAL_ACCOUNT'] = _referralAccount;
    when(
      classic.getQuote(
        inputMint: anyNamed('inputMint'),
        outputMint: anyNamed('outputMint'),
        amount: anyNamed('amount'),
        slippageBps: anyNamed('slippageBps'),
        platformFeeBps: anyNamed('platformFeeBps'),
      ),
    ).thenAnswer((_) async => quote);
  });

  tearDown(Config.debugOverrides.clear);

  void stubAccount(String address, AccountResult Function() result) => when(
    rpc.getAccountInfo(address, encoding: anyNamed('encoding')),
  ).thenAnswer((_) async => result());

  test('fee accounts are the referral account ATAs, classic then '
      'Token-2022', () async {
    expect(
      await SwapRepository.referralFeeAccounts(
        referralAccount: _referralAccount,
        mint: _solMint,
      ),
      [_solFeeAccount, _solFeeAccount2022],
    );
    expect(
      await SwapRepository.referralFeeAccounts(
        referralAccount: _referralAccount,
        mint: _usdcMint,
      ),
      [_usdcFeeAccount, _usdcFeeAccount2022],
    );
  });

  group('getClassicQuote', () {
    test(
      'charges the fee into the input mint fee account when it exists',
      () async {
        stubAccount(_solFeeAccount, _present);

        final result = await repository.getClassicQuote(
          inputMint: _solMint,
          outputMint: _usdcMint,
          amount: 1000,
          slippageBps: 75,
        );

        expect(result.feeAccount, _solFeeAccount);
        verify(
          classic.getQuote(
            inputMint: _solMint,
            outputMint: _usdcMint,
            amount: 1000,
            slippageBps: 75,
            platformFeeBps: SwapConstants.referralFeeBps,
          ),
        ).called(1);
      },
    );

    test('falls back to a Token-2022 fee account', () async {
      stubAccount(_solFeeAccount, _missing);
      stubAccount(_solFeeAccount2022, _present);

      final result = await repository.getClassicQuote(
        inputMint: _solMint,
        outputMint: _usdcMint,
        amount: 1000,
      );

      expect(result.feeAccount, _solFeeAccount2022);
    });

    test('falls back to the output mint fee account', () async {
      stubAccount(_solFeeAccount, _missing);
      stubAccount(_solFeeAccount2022, _missing);
      stubAccount(_usdcFeeAccount, _present);

      final result = await repository.getClassicQuote(
        inputMint: _solMint,
        outputMint: _usdcMint,
        amount: 1000,
      );

      expect(result.feeAccount, _usdcFeeAccount);
    });

    // The classic API fails the swap on-chain when the fee account does not
    // exist, so a missing one must mean a fee-free quote, never a fee.
    test('quotes fee-free when no fee account exists', () async {
      stubAccount(_solFeeAccount, _missing);
      stubAccount(_solFeeAccount2022, _missing);
      stubAccount(_usdcFeeAccount, _missing);
      stubAccount(_usdcFeeAccount2022, _missing);

      final result = await repository.getClassicQuote(
        inputMint: _solMint,
        outputMint: _usdcMint,
        amount: 1000,
      );

      expect(result.feeAccount, isNull);
      verify(
        classic.getQuote(
          inputMint: _solMint,
          outputMint: _usdcMint,
          amount: 1000,
          slippageBps: 50,
          platformFeeBps: 0,
        ),
      ).called(1);
    });

    test('quotes fee-free when the existence check fails', () async {
      when(
        rpc.getAccountInfo(any, encoding: anyNamed('encoding')),
      ).thenThrow(Exception('rpc down'));

      final result = await repository.getClassicQuote(
        inputMint: _solMint,
        outputMint: _usdcMint,
        amount: 1000,
      );

      expect(result.feeAccount, isNull);
    });

    test('quotes fee-free without reading the chain when no referral '
        'account is configured', () async {
      Config.debugOverrides['JUPITER_REFERRAL_ACCOUNT'] = '';

      final result = await repository.getClassicQuote(
        inputMint: _solMint,
        outputMint: _usdcMint,
        amount: 1000,
      );

      expect(result.feeAccount, isNull);
      verifyNever(rpc.getAccountInfo(any, encoding: anyNamed('encoding')));
    });

    test('reads an existing fee account once per session', () async {
      stubAccount(_solFeeAccount, _present);

      for (var i = 0; i < 3; i++) {
        await repository.getClassicQuote(
          inputMint: _solMint,
          outputMint: _usdcMint,
          amount: 1000,
        );
      }

      verify(
        rpc.getAccountInfo(_solFeeAccount, encoding: anyNamed('encoding')),
      ).called(1);
    });
  });

  group('buildClassicSwapTx', () {
    setUp(() {
      when(
        classic.getSwapTransaction(
          quote: anyNamed('quote'),
          userPublicKey: anyNamed('userPublicKey'),
          feeAccount: anyNamed('feeAccount'),
          dynamicSlippage: anyNamed('dynamicSlippage'),
          maxPriorityFeeLamports: anyNamed('maxPriorityFeeLamports'),
        ),
      ).thenAnswer((_) async => 'dHg=');
    });

    test('lets Jupiter pick the slippage on Auto', () async {
      await repository.buildClassicSwapTx(
        quote: const ClassicSwapQuote(quote: quote, feeAccount: _solFeeAccount),
        taker: _referralAccount,
      );

      verify(
        classic.getSwapTransaction(
          quote: quote,
          userPublicKey: _referralAccount,
          feeAccount: _solFeeAccount,
          dynamicSlippage: true,
          maxPriorityFeeLamports: null,
        ),
      ).called(1);
    });

    test('keeps an explicit slippage and caps the priority fee', () async {
      await repository.buildClassicSwapTx(
        quote: const ClassicSwapQuote(quote: quote),
        taker: _referralAccount,
        slippageBps: 75,
        priorityFeeLamports: 50000,
      );

      verify(
        classic.getSwapTransaction(
          quote: quote,
          userPublicKey: _referralAccount,
          feeAccount: null,
          dynamicSlippage: false,
          maxPriorityFeeLamports: 50000,
        ),
      ).called(1);
    });
  });
}
