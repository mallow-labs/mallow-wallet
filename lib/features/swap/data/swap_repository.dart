import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:solana/dto.dart' show Encoding;
import 'package:solana/solana.dart'
    show Ed25519HDPublicKey, TokenProgramType, findAssociatedTokenAddress;

import '../../../core/config/environment.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/services/tx_landed_slots.dart';
import '../swap_constants.dart';

/// A classic (`/swap/v1`) quote plus the fee account its platform fee goes
/// to — `null` when the quote was taken without a fee.
class ClassicSwapQuote {
  const ClassicSwapQuote({required this.quote, this.feeAccount});

  final JupiterClassicQuote quote;
  final String? feeAccount;
}

@lazySingleton
class SwapRepository {
  SwapRepository(
    this._jupiterClient,
    this._classicClient,
    WalletManager walletManager,
    TxLandedSlots txLandedSlots,
  ) : // Jupiter routes mainnet liquidity only, so the classic route's fee
      // account check and its broadcast are pinned to mainnet regardless of
      // the app's environment — the same reason staking pins its RPC.
      _rpcService = SolanaRpcService.mainnet(walletManager, txLandedSlots);

  /// Test seam for the on-chain reads. A separate constructor so injectable
  /// cannot hand the repository the environment's RPC — see [StakingTxBuilder].
  @visibleForTesting
  SwapRepository.withRpc(
    this._jupiterClient,
    this._classicClient,
    this._rpcService,
  );

  final JupiterAggregatorClient _jupiterClient;
  final JupiterSwapInstructionsClient _classicClient;
  final SolanaRpcService _rpcService;

  /// The mainnet RPC a classic swap is checked and broadcast on.
  SolanaRpcService get rpcService => _rpcService;

  /// How long a referral token account found missing stays assumed missing.
  /// Existing accounts are cached for the session: they are never closed.
  static const _missingFeeAccountTtl = Duration(minutes: 10);

  final Map<String, DateTime> _missingFeeAccounts = {};
  final Set<String> _existingFeeAccounts = {};

  /// Fetch an order (quote + unsigned tx) from the Jupiter Ultra API.
  ///
  /// [slippageBps] / [priorityFeeLamports] are the user's saved settings;
  /// `null` lets Jupiter auto-pick. mallow's 0.5% integrator fee is attached
  /// whenever a referral account is configured.
  Future<UltraOrderResponseDto> getOrder({
    required String inputMint,
    required String outputMint,
    required int amount,
    required String taker,
    int? slippageBps,
    int? priorityFeeLamports,
  }) {
    final referralAccount = Config.jupiterReferralAccount;
    return _jupiterClient.getOrder(
      UltraOrderRequestDto(
        inputMint: inputMint,
        outputMint: outputMint,
        amount: amount,
        taker: taker,
        slippageBps: slippageBps,
        priorityFeeLamports: priorityFeeLamports,
        referralAccount: referralAccount.isEmpty ? null : referralAccount,
        referralFee: referralAccount.isEmpty
            ? null
            : SwapConstants.referralFeeBps,
      ),
    );
  }

  /// Submit the signed order transaction — Jupiter broadcasts and confirms.
  Future<UltraExecuteResponseDto> executeOrder({
    required String signedTransaction,
    required String requestId,
  }) {
    return _jupiterClient.executeOrder(
      UltraExecuteRequestDto(
        signedTransaction: signedTransaction,
        requestId: requestId,
      ),
    );
  }

  /// Quote from the classic swap API — the route for a signer too slow for an
  /// Ultra order. An Ultra order is signed verbatim (it may carry a market
  /// maker's signature, so its blockhash cannot be refreshed) and is valid for
  /// seconds; a Keystone's QR round trip takes far longer. A classic swap is
  /// signed by the user alone and has no server-side expiry, so the shared
  /// signing path can refresh its blockhash and re-sign it after a slow
  /// signature.
  ///
  /// mallow's fee is charged when the referral account holds a token account
  /// for the input or output mint. Ultra skips the fee on its own when that
  /// account is missing; the classic API instead fails the swap on-chain, so
  /// it is checked here and the quote is taken fee-free rather than
  /// unswappable.
  Future<ClassicSwapQuote> getClassicQuote({
    required String inputMint,
    required String outputMint,
    required int amount,
    int? slippageBps,
  }) async {
    final feeAccount = await _resolveFeeAccount([inputMint, outputMint]);
    final quote = await _classicClient.getQuote(
      inputMint: inputMint,
      outputMint: outputMint,
      amount: amount,
      slippageBps: slippageBps ?? 50,
      platformFeeBps: feeAccount == null ? 0 : SwapConstants.referralFeeBps,
    );
    return ClassicSwapQuote(quote: quote, feeAccount: feeAccount);
  }

  /// The unsigned v0 transaction for [quote], compiled for [taker].
  ///
  /// [slippageBps] `null` (Auto) lets Jupiter pick the slippage at build time;
  /// an explicit setting keeps the one the quote was taken with.
  Future<String> buildClassicSwapTx({
    required ClassicSwapQuote quote,
    required String taker,
    int? slippageBps,
    int? priorityFeeLamports,
  }) => _classicClient.getSwapTransaction(
    quote: quote.quote,
    userPublicKey: taker,
    feeAccount: quote.feeAccount,
    dynamicSlippage: slippageBps == null,
    maxPriorityFeeLamports: priorityFeeLamports,
  );

  /// The token accounts that can collect the fee in [mint] for
  /// [referralAccount]: its associated token account under the classic token
  /// program, then under Token-2022. These are where the referral account
  /// holds the fees Ultra already collects for it.
  static Future<List<String>> referralFeeAccounts({
    required String referralAccount,
    required String mint,
  }) async {
    final owner = Ed25519HDPublicKey.fromBase58(referralAccount);
    final mintKey = Ed25519HDPublicKey.fromBase58(mint);
    return [
      for (final program in [
        TokenProgramType.tokenProgram,
        TokenProgramType.token2022Program,
      ])
        (await findAssociatedTokenAddress(
          owner: owner,
          mint: mintKey,
          tokenProgramType: program,
        )).toBase58(),
    ];
  }

  /// The first existing fee account for [mints], in order, or null when no
  /// referral account is configured or none exists. An RPC failure reads as
  /// missing: losing the fee on one swap beats a swap that cannot land.
  Future<String?> _resolveFeeAccount(List<String> mints) async {
    final referralAccount = Config.jupiterReferralAccount;
    if (referralAccount.isEmpty) return null;
    for (final mint in mints) {
      final candidates = await referralFeeAccounts(
        referralAccount: referralAccount,
        mint: mint,
      );
      for (final address in candidates) {
        if (await _feeAccountExists(address)) return address;
      }
    }
    return null;
  }

  Future<bool> _feeAccountExists(String address) async {
    if (_existingFeeAccounts.contains(address)) return true;
    final missingAt = _missingFeeAccounts[address];
    if (missingAt != null &&
        DateTime.now().difference(missingAt) < _missingFeeAccountTtl) {
      return false;
    }
    try {
      // base64: the RPC's base58 default rejects a 165-byte token account.
      final info = await _rpcService.getAccountInfo(
        address,
        encoding: Encoding.base64,
      );
      if (info.value != null) {
        _existingFeeAccounts.add(address);
        _missingFeeAccounts.remove(address);
        return true;
      }
      _missingFeeAccounts[address] = DateTime.now();
      return false;
    } catch (_) {
      return false;
    }
  }
}
