import 'package:flutter/foundation.dart';

import '../../../core/network/solana_rpc_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/utils/chain.dart';
import '../data/confirmed_tx_balances.dart';
import '../data/ethereum_token_service.dart';
import '../data/tezos_token_service.dart';
import '../data/token_repository.dart';
import '../models/token_balance.dart';

/// Post-confirmation, best-effort optimistic balance updates. Writes the
/// known deltas to the cached balances table and signals the listening
/// [TokenBalanceBloc] to rehydrate from cache while the authoritative
/// Helius refetch runs in the background.
///
/// All entry points swallow errors — an optimistic update failure must
/// never bubble up and turn a successful transaction into a perceived
/// failure. The next refresh will reconcile any divergence.
class BalanceOptimisticUpdater {
  const BalanceOptimisticUpdater._();

  /// Applies the sender + recipient deltas for a confirmed transfer.
  ///
  /// - SOL transfer: pass `token = null` and `solTotalOutLamports` covering
  ///   the principal plus fees (i.e. `simulatedNetSolLamports`, or
  ///   `amount + estimatedFee` fallback). The recipient is credited only
  ///   the principal in `amountLamports`.
  /// - SPL transfer: pass the SPL `token`, `amountRaw` in the mint's units,
  ///   and `solFeeLamports` for the sender's SOL outflow (network fee +
  ///   any ATA rent — `simulatedNetSolLamports` is exact when available).
  ///   The recipient is credited only the token amount, never SOL.
  ///
  /// `recipientAddress` is credited only when it belongs to a wallet known
  /// in the local DB (sibling wallet) — external recipients are skipped.
  static Future<void> recordTransfer({
    required String senderAddress,
    required String recipientAddress,
    required TokenBalance? token,
    int amountLamports = 0,
    int amountRaw = 0,
    int solTotalOutLamports = 0,
    int solFeeLamports = 0,
  }) async {
    final tokenRepo = sl.isRegistered<TokenRepository>()
        ? sl<TokenRepository>()
        : null;
    if (tokenRepo == null) return;

    try {
      if (token == null) {
        if (solTotalOutLamports > 0) {
          await tokenRepo.applyOptimisticDelta(
            walletAddress: senderAddress,
            mint: TokenBalance.solMint,
            rawDelta: -solTotalOutLamports,
            isNative: true,
          );
        }
      } else {
        if (amountRaw > 0) {
          await tokenRepo.applyOptimisticDelta(
            walletAddress: senderAddress,
            mint: token.mint,
            rawDelta: -amountRaw,
            isNative: token.isNative,
          );
        }
        if (solFeeLamports > 0) {
          await tokenRepo.applyOptimisticDelta(
            walletAddress: senderAddress,
            mint: TokenBalance.solMint,
            rawDelta: -solFeeLamports,
            isNative: true,
          );
        }
      }

      final recipientIsSibling =
          await _siblingWalletAddress(recipientAddress) != null;
      if (recipientIsSibling) {
        if (token == null) {
          if (amountLamports > 0) {
            await tokenRepo.applyOptimisticDelta(
              walletAddress: recipientAddress,
              mint: TokenBalance.solMint,
              rawDelta: amountLamports,
              isNative: true,
            );
          }
        } else if (amountRaw > 0) {
          await tokenRepo.applyOptimisticDelta(
            walletAddress: recipientAddress,
            mint: token.mint,
            rawDelta: amountRaw,
            isNative: token.isNative,
          );
        }
      }
    } catch (e, st) {
      debugPrint('[BalanceOptimisticUpdater] transfer delta failed: $e\n$st');
    }
  }

  /// Applies the sender-side SOL deduction for a confirmed mint/edit.
  /// `lamports` is the total cost paid (mallow fee + protocol fee + rent
  /// + tx fee), preferably sourced from the simulated post-balance delta.
  static Future<void> recordMintCost({
    required String senderAddress,
    required int lamports,
  }) async {
    if (lamports <= 0) return;
    final tokenRepo = sl.isRegistered<TokenRepository>()
        ? sl<TokenRepository>()
        : null;
    if (tokenRepo == null) return;
    try {
      await tokenRepo.applyOptimisticDelta(
        walletAddress: senderAddress,
        mint: TokenBalance.solMint,
        rawDelta: -lamports,
        isNative: true,
      );
    } catch (e, st) {
      debugPrint('[BalanceOptimisticUpdater] mint delta failed: $e\n$st');
    }
  }

  /// Reconciles [address]'s cached balances against a *confirmed* transaction
  /// by reading that transaction's own post-balance metadata — exact (fees,
  /// rent, actual filled amounts and all) and readable one RPC round-trip
  /// after confirmation, where the Helius-backed refetch can still be serving
  /// pre-transaction numbers for seconds.
  ///
  /// `getTransaction` can briefly 404 at `confirmed` right after the tx lands,
  /// so the read is retried [attempts] times [retryDelay] apart. Best-effort
  /// throughout: an unreadable transaction still signals the portfolio to
  /// refetch, which is exactly what the caller would have done anyway.
  static Future<void> recordConfirmedTx({
    required String signature,
    required String address,
    int attempts = 3,
    Duration retryDelay = const Duration(milliseconds: 400),
  }) async {
    final tokenRepo = sl.isRegistered<TokenRepository>()
        ? sl<TokenRepository>()
        : null;
    if (tokenRepo == null) return;

    var balances = const <ConfirmedBalance>[];
    try {
      final rpc = sl<SolanaRpcService>();
      for (var attempt = 0; attempt < attempts; attempt++) {
        if (attempt > 0) await Future<void>.delayed(retryDelay);
        final transaction = await rpc.getTransactionJson(signature);
        if (transaction == null) continue;
        balances = parseOwnerPostBalances(transaction, address);
        break;
      }
    } catch (e, st) {
      debugPrint(
        '[BalanceOptimisticUpdater] confirmed-tx read failed: $e\n$st',
      );
    }

    try {
      await tokenRepo.applyConfirmedBalances(
        walletAddress: address,
        balances: balances,
      );
    } catch (e, st) {
      debugPrint(
        '[BalanceOptimisticUpdater] confirmed-tx write failed: $e\n$st',
      );
    }
  }

  /// Refreshes the Ethereum/Tezos balances touched by a confirmed transfer,
  /// then signals the tokens tab and the token-detail sheet to re-read.
  ///
  /// Unlike the Solana entry points this applies no delta: those services are
  /// network-first with a write-through cache, so one refetch produces the
  /// post-transaction row exactly — no fee estimation to drift, and no
  /// `applyOptimisticDelta` (whose companion omits `chain`, which is in the
  /// primary key, so it would insert a duplicate `solana`-labelled row beside
  /// the real one rather than update it).
  ///
  /// Call this only once the transfer is receipt-backed — a `ResultSuccess`
  /// alone is not enough. The EVM path reports success on inclusion *timeout*
  /// (the transaction is still in the mempool), so its caller is
  /// [PendingEvmTxTracker]'s resolution pass, not the send path; a refetch
  /// fired on the send path would write the pre-send balance straight back.
  /// A refetch that fails still signals: the blocs' own reload fans out to the
  /// network again, so the miss self-corrects instead of leaving the pre-send
  /// number on screen.
  ///
  /// [recipientAddress] is refreshed only when it is a wallet in the local DB
  /// — the same sibling rule as [recordTransfer], so sending between your own
  /// wallets updates both sides.
  static Future<void> recordNonSolanaTransfer({
    required Chain chain,
    required String senderAddress,
    required String recipientAddress,
  }) async {
    if (chain == Chain.solana) return;
    final tokenRepo = sl.isRegistered<TokenRepository>()
        ? sl<TokenRepository>()
        : null;
    if (tokenRepo == null) return;

    // The recipient arrives in whatever casing the user typed or pasted, but
    // everything downstream is keyed on the *stored* wallet address (EVM
    // wallets are stored EIP-55 checksummed): `EthereumTokenService` caches
    // under the address it is handed, and both invalidation subscribers test
    // raw `addresses.contains(...)` against the session's stored addresses. A
    // lowercase paste would therefore cache a duplicate row set nobody reads
    // and signal an address nobody recognises — so resolve the sibling match
    // back to its stored form and refresh/signal with that.
    final siblingRecipient =
        recipientAddress.isNotEmpty &&
            apiOwnerAddress(recipientAddress) != apiOwnerAddress(senderAddress)
        ? await _siblingWalletAddress(recipientAddress)
        : null;

    final addresses = <String>[
      if (senderAddress.isNotEmpty) senderAddress,
      ?siblingRecipient,
    ];

    for (final address in addresses) {
      try {
        await _refreshChainCache(chain, address);
      } catch (e, st) {
        debugPrint('[BalanceOptimisticUpdater] $chain refetch failed: $e\n$st');
      }
      tokenRepo.notifyBalancesChanged(address);
    }
  }

  /// Network refetch that writes [chain]'s cache through for [address].
  ///
  /// Fetched **twice** on purpose. Both services coalesce on an in-flight fetch
  /// keyed by address, so a single call can hand back a request the tokens tab
  /// started *before* this transaction confirmed — a post-transaction refresh
  /// that writes the pre-transaction rows straight back, after which the
  /// invalidation signal only re-reads that same stale cache. The first call
  /// drains whatever was already in flight (the coalescing entry is cleared
  /// before its future completes), so the second one always opens a request
  /// that began after confirmation. Bypassing the coalescing instead would mean
  /// a force-refresh hook inside both shared services, whose `whenComplete`
  /// bookkeeping is deadlock-sensitive — not worth it for one extra request per
  /// confirmed send.
  static Future<void> _refreshChainCache(Chain chain, String address) async {
    switch (chain) {
      case Chain.ethereum:
        if (!sl.isRegistered<EthereumTokenService>()) return;
        final ethereum = sl<EthereumTokenService>();
        await ethereum.getTokenBalances(address);
        await ethereum.getTokenBalances(address);
      case Chain.tezos:
        if (!sl.isRegistered<TezosTokenService>()) return;
        final tezos = sl<TezosTokenService>();
        await tezos.getTokenBalances(address);
        await tezos.getTokenBalances(address);
      case Chain.solana:
        return;
    }
  }

  /// The locally stored address of the wallet [address] refers to, or null when
  /// it belongs to no wallet in the DB.
  ///
  /// Returns the **stored** form rather than a bool: callers key caches and
  /// invalidation signals off it, and only the stored casing matches what the
  /// readers use.
  static Future<String?> _siblingWalletAddress(String address) async {
    if (!sl.isRegistered<WalletRepository>()) return null;
    try {
      final wallets = await sl<WalletRepository>().getAllWallets();
      // Normalised, not a raw `==`: an EVM sibling is stored EIP-55 checksummed
      // but reaches here in whatever casing the recipient field carried, and a
      // raw compare would report the user's own wallet as external.
      final key = apiOwnerAddress(address);
      for (final wallet in wallets) {
        if (apiOwnerAddress(wallet.address) == key) return wallet.address;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
