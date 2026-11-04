import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:wallet/wallet.dart' show EtherAmount, EthereumAddress;
import 'package:web3dart/web3dart.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/transaction_ledger.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/ethereum_rpc_service.dart';
import '../../../core/network/evm_simulation_decoder.dart';
import '../../../core/network/evm_transfer_core.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/security/transaction_auth_gate.dart';
import '../../../core/services/pending_evm_tx_tracker.dart';
import '../../../core/session/session_manager.dart';
import '../../../shared/utils/chain.dart';
import '../../artwork/services/artwork_bloc.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../portfolio/services/portfolio_received_reporter.dart';
import '../../portfolio/services/portfolio_refresh_signal.dart';

const _tag = 'OpenSeaPurchase';

const _seaportAddresses = {
  '0x00000000000000adc04c56bf30ac9d3c0aaf14dc',
  '0x0000000000000068f116a894984e2db1123eb395',
};

BigInt openSeaWei(String raw) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(raw)) {
    throw const AppFailure.validation('Invalid purchase amount.');
  }
  return BigInt.parse(raw);
}

String formatOpenSeaEth(String raw) {
  final amount = openSeaWei(raw);
  final unit = BigInt.from(10).pow(18);
  final fraction = (amount % unit)
      .toString()
      .padLeft(18, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '${amount ~/ unit}' : '${amount ~/ unit}.$fraction';
}

bool _sameAddress(String a, String b) =>
    RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(a) &&
    a.toLowerCase() == b.toLowerCase();

void validateOpenSeaQuote(
  OpenSeaPurchaseQuote q, {
  required String mintAccount,
  required String buyer,
  required String? tokenStandard,
}) {
  final parts = mintAccount.split('-');
  final total =
      openSeaWei(q.sellerProceedsWei) +
      q.marketplaceFees.fold(
        BigInt.zero,
        (sum, fee) => sum + openSeaWei(fee.amountWei),
      ) +
      q.creatorFees.fold(
        BigInt.zero,
        (sum, fee) => sum + openSeaWei(fee.amountWei),
      ) +
      openSeaWei(q.buyerPaidExtraWei);
  openSeaWei(q.estimatedGas);
  openSeaWei(q.estimatedGasWei);
  if (parts.length != 2 ||
      !_sameAddress(q.contractAddress, parts.first) ||
      q.tokenId != parts.last ||
      !_sameAddress(q.buyerAddress, buyer) ||
      q.chainId != 1 ||
      !{'erc721', 'erc1155'}.contains(tokenStandard) ||
      q.tokenStandard.value != tokenStandard ||
      q.quantity.value != '1' ||
      q.marketplace.value != 'opensea' ||
      openSeaWei(q.listedCopies) < BigInt.one ||
      (tokenStandard == 'erc721' && q.listedCopies != '1') ||
      q.referral.enabled != false ||
      q.referral.buyerCostWei.value != '0' ||
      !_seaportAddresses.contains(q.protocolAddress.toLowerCase()) ||
      !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(q.orderHash) ||
      total != openSeaWei(q.totalWei)) {
    throw const AppFailure.validation(
      'The quote does not match this artwork or wallet. Refresh the quote.',
    );
  }
}

void validateOpenSeaPrepared(
  OpenSeaPurchaseQuote q,
  OpenSeaPurchasePrepareResponse$Result p,
) {
  if (p.chainId != 1 ||
      p.quoteId != q.quoteId ||
      p.orderHash.toLowerCase() != q.orderHash.toLowerCase() ||
      !_sameAddress(p.from, q.buyerAddress) ||
      !_sameAddress(p.to, q.protocolAddress) ||
      openSeaWei(p.value) != openSeaWei(q.totalWei) ||
      !RegExp(r'^0x(?:[0-9a-fA-F]{2}){4,}$').hasMatch(p.data)) {
    throw const AppFailure.validation(
      'The transaction no longer matches the reviewed purchase. Refresh the quote.',
    );
  }
}

bool _isPurchasedAsset(EvmAssetChange change, OpenSeaPurchaseQuote q) =>
    !change.isApprove &&
    change.assetType.toLowerCase() == q.tokenStandard.value &&
    _sameAddress(change.to ?? '', q.buyerAddress) &&
    _sameAddress(change.contractAddress ?? '', q.contractAddress) &&
    change.tokenId == q.tokenId &&
    (q.tokenStandard.value == 'erc721' || change.rawAmount == '1');

/// No approvals or non-ETH outflows are allowed; the intended copy must arrive.
void validateOpenSeaSimulation(
  OpenSeaPurchaseQuote q,
  EvmSimulationResult sim,
) {
  if (sim.error != null || !sim.changes.any((c) => _isPurchasedAsset(c, q))) {
    throw const AppFailure.validation(
      'This purchase would not transfer the artwork to your wallet.',
    );
  }
  var debit = BigInt.zero;
  for (final c in sim.changes) {
    if (!_sameAddress(c.from ?? '', q.buyerAddress)) continue;
    if (c.isApprove || c.assetType != 'NATIVE' || c.rawAmount == null) {
      throw const AppFailure.validation(
        'This purchase would move an unexpected asset or grant an approval.',
      );
    }
    debit += openSeaWei(c.rawAmount!);
  }
  if (debit != openSeaWei(q.totalWei)) {
    throw const AppFailure.validation(
      'The simulated payment differs from the reviewed total.',
    );
  }
}

String openSeaPurchaseError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    final code = data is Map
        ? (data['error'] is Map ? data['error']['code'] : data['code'])
        : null;
    if (code is String && code.startsWith('UNSUPPORTED_')) {
      return 'This listing cannot be bought in the app yet. You can view it on OpenSea.';
    }
    return switch (code) {
      'QUOTE_CHANGED' =>
        'The price or fees changed. Refresh the quote before buying.',
      'STALE_QUOTE' => 'The quote expired. Refresh the quote.',
      'ORDER_UNAVAILABLE' ||
      'STALE_ORDER' ||
      'UNAVAILABLE' => 'This listing changed or sold. Refresh the listing.',
      'INSUFFICIENT_BALANCE' =>
        'Insufficient ETH for this purchase and its network fee.',
      'RPC_UNAVAILABLE' || 'OPENSEA_UNAVAILABLE' =>
        'OpenSea or Ethereum is temporarily unavailable. Try again shortly.',
      _ => 'The purchase could not be completed. Try again shortly.',
    };
  }
  return AppFailure.from(error).message;
}

const openSeaUnverifiedMessage =
    'The transaction confirmed, but it did not show this artwork arriving in '
    'your wallet. Check your activity before buying again.';

class OpenSeaReview {
  const OpenSeaReview(
    this.quote,
    this.mintAccount,
    this.walletId,
    this.balance,
    this.networkFeeWei,
  );
  final OpenSeaPurchaseQuote quote;
  final String mintAccount;
  final String walletId;
  final BigInt balance;
  final BigInt networkFeeWei;
  String get buyer => quote.buyerAddress;
  String? get shortfall => balance < openSeaWei(quote.totalWei) + networkFeeWei
      ? 'Insufficient ETH balance'
      : null;
}

class PendingOpenSeaPurchase {
  const PendingOpenSeaPurchase(
    this.quote,
    this.mintAccount,
    this.hash,
    this.nonce, {
    this.candidateHashes = const [],
    this.resolution,
  });
  factory PendingOpenSeaPurchase.decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final entry = PendingOpenSeaPurchase(
      OpenSeaPurchaseQuote.fromJson(json['quote'] as Map<String, dynamic>),
      json['mintAccount'] as String,
      json['hash'] as String,
      json['nonce'] as int,
      candidateHashes: (json['candidateHashes'] as List? ?? []).cast<String>(),
      resolution: json['resolution'] as String?,
    );
    validateOpenSeaQuote(
      entry.quote,
      mintAccount: entry.mintAccount,
      buyer: entry.quote.buyerAddress,
      tokenStandard: entry.quote.tokenStandard.value,
    );
    if ([
          entry.hash,
          ...entry.candidateHashes,
        ].any((h) => !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(h)) ||
        entry.nonce < 0) {
      throw const FormatException('Invalid pending purchase.');
    }
    return entry;
  }
  final OpenSeaPurchaseQuote quote;
  final String mintAccount;
  final String hash;
  final int nonce;
  final List<String> candidateHashes;
  final String? resolution;
  String get buyer => quote.buyerAddress;
  String encode() => jsonEncode({
    'quote': quote.toJson(),
    'mintAccount': mintAccount,
    'hash': hash,
    'nonce': nonce,
    'candidateHashes': candidateHashes,
    'resolution': resolution,
  });
}

/// The wallet and nonce of a journal entry that no longer decodes as a whole.
/// That pair alone decides whether the signed purchase can still land.
({String buyer, int nonce})? salvageOpenSeaPurchaseSlot(String raw) {
  try {
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    final quote = json['quote'];
    final nonce = json['nonce'];
    final buyer = quote is Map ? quote['buyerAddress'] : null;
    if (nonce is! int ||
        nonce < 0 ||
        buyer is! String ||
        !RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(buyer)) {
      return null;
    }
    return (buyer: buyer, nonce: nonce);
  } on Object {
    return null;
  }
}

/// [unverified]: a transaction on the purchase nonce mined, so nothing signed
/// for this purchase can land any more, but its logs do not show the artwork
/// arriving. The journal is released; the user has to check the outcome.
enum OpenSeaResolution { pending, confirmed, failed, unverified }

/// The durable submission journal blocks a second purchase even when the RPC
/// accepted the bytes but its response was lost. Signing never leaves the device.
@lazySingleton
class OpenSeaPurchaseService {
  OpenSeaPurchaseService(
    this._api,
    this._rpc,
    this._wallet,
    this._session,
    this._gate,
    this._storage,
    this._tracker,
  ) {
    _tracker.addResolutionObserver(_saveResolution);
  }

  @disposeMethod
  void dispose() => _tracker.removeResolutionObserver(_saveResolution);

  Future<void> _saveResolution(PendingTxResolution resolution) =>
      _updateJournal(() async {
        final tx = resolution.tx;
        if (tx.metadata.title != _trackerTitle) return;
        final entry = await _readPending();
        if (entry == null ||
            tx.chainId != 1 ||
            tx.nonce != entry.nonce ||
            !_sameAddress(tx.walletAddress, entry.buyer)) {
          return;
        }
        await _storage.storePendingOpenSeaPurchase(
          PendingOpenSeaPurchase(
            entry.quote,
            entry.mintAccount,
            entry.hash,
            entry.nonce,
            candidateHashes: tx.candidates.map((c) => c.hash).toList(),
            resolution: resolution.kind.name,
          ).encode(),
        );
      });
  final MallowApiClient _api;
  final EthereumRpcService _rpc;
  final WalletManager _wallet;
  final SessionManager _session;
  final TransactionAuthGate _gate;
  final SecureWalletStorage _storage;
  final PendingEvmTxTracker _tracker;
  bool _submitting = false;
  static const _trackerTitle = 'OpenSea purchase';
  String? _confirmedHash;
  String? get confirmedHash => _confirmedHash;

  Future<void> _journalTail = Future<void>.value();

  Future<void> _updateJournal(Future<void> Function() update) {
    final task = _journalTail.then((_) => update());
    _journalTail = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return task;
  }

  /// The journal entry that blocks another purchase, or null when there is
  /// none. An entry that no longer decodes is released once its transaction
  /// can no longer land (see [_releaseUnreadable]) and blocks until then.
  Future<PendingOpenSeaPurchase?> pending() async {
    await _journalTail;
    final raw = await _storage.loadPendingOpenSeaPurchase();
    if (raw == null) return null;
    try {
      return PendingOpenSeaPurchase.decode(raw);
    } on Object catch (e) {
      await _releaseUnreadable(raw, e);
      return null;
    }
  }

  /// The decoded entry, or null when the slot is empty or unreadable. For the
  /// journal's own bookkeeping, which must never throw on a corrupt entry: the
  /// tracker's resolution observer failing would stop it retiring the slot.
  Future<PendingOpenSeaPurchase?> _readPending() async {
    final raw = await _storage.loadPendingOpenSeaPurchase();
    if (raw == null) return null;
    try {
      return PendingOpenSeaPurchase.decode(raw);
    } on Object {
      return null;
    }
  }

  /// Delete an undecodable journal entry once the purchase it recorded can no
  /// longer land, and throw while it still might.
  ///
  /// The journal exists to stop a second purchase while the first may still
  /// mine, so time is never the release signal: an EVM transaction can sit in
  /// a mempool indefinitely. The nonce is. When the wallet and nonce survive,
  /// the `latest` (mined) nonce moving past it proves that slot is consumed,
  /// by this purchase or a replacement, and nothing else signed for it can
  /// land. When even those are gone, release only when no session Ethereum
  /// wallet has any transaction waiting (`pending` nonce == `latest`) and the
  /// tracker holds no unresolved OpenSea purchase.
  Future<void> _releaseUnreadable(String raw, Object error) async {
    AppLogger.warn(
      _tag,
      'stored purchase record is unreadable (${error.runtimeType})',
    );
    const blocked = AppFailure.validation(
      'A stored OpenSea purchase could not be read, and its transaction may '
      'still confirm. Wait for it to confirm, or cancel it from your pending '
      'transactions, before buying again.',
    );
    if (_rpc.chainId != 1) throw blocked;
    final slot = salvageOpenSeaPurchaseSlot(raw);
    if (slot != null) {
      if (await _rpc.getLatestNonce(slot.buyer) <= slot.nonce) throw blocked;
    } else {
      final wallets = _session.sessionWalletsForChain(Chain.ethereum);
      if (wallets.isEmpty ||
          _tracker.entries.any((e) => e.metadata.title == _trackerTitle)) {
        throw blocked;
      }
      for (final wallet in wallets) {
        final latest = await _rpc.getLatestNonce(wallet.address);
        if (await _rpc.getNonce(wallet.address) > latest) throw blocked;
      }
    }
    await _updateJournal(() async {
      if (await _storage.loadPendingOpenSeaPurchase() == raw) {
        await _storage.deletePendingOpenSeaPurchase();
      }
    });
    AppLogger.warn(_tag, 'released an unreadable purchase record');
  }

  Future<OpenSeaReview> review(ArtworkDetails artwork) async {
    if (_submitting || await pending() != null) {
      throw const AppFailure.validation(
        'Resolve the pending OpenSea purchase before buying again.',
      );
    }
    final wallet = _session.sessionWalletForChain(Chain.ethereum);
    if (wallet == null) {
      throw const AppFailure.validation(
        'Connect a signing Ethereum wallet to buy.',
      );
    }
    if (_rpc.chainId != 1) {
      throw const AppFailure.validation(
        'This purchase requires Ethereum mainnet.',
      );
    }
    final quote = (await _api.quoteOpenSeaPurchase(
      OpenSeaPurchaseQuoteRequest(
        artworkId: artwork.mintAccount,
        buyerAddress: wallet.address,
      ),
    )).result;
    validateOpenSeaQuote(
      quote,
      mintAccount: artwork.mintAccount,
      buyer: wallet.address,
      tokenStandard: artwork.tokenStandard,
    );
    _assertLive(quote);
    final values = await Future.wait<Object>([
      _rpc.getBalance(wallet.address),
      _rpc.getFeeData(),
    ]);
    final fee = values[1] as EthFeeData;
    final cap =
        openSeaWei(quote.estimatedGas) *
        BigInt.from(12) ~/
        BigInt.from(10) *
        fee.maxFeePerGas;
    final review = OpenSeaReview(
      quote,
      artwork.mintAccount,
      wallet.id,
      values[0] as BigInt,
      cap > openSeaWei(quote.estimatedGasWei)
          ? cap
          : openSeaWei(quote.estimatedGasWei),
    );
    _assertBuyer(review);
    _assertLive(quote);
    return review;
  }

  void _assertBuyer(OpenSeaReview review) {
    final wallet = _session.sessionWalletForChain(Chain.ethereum);
    if (wallet?.id != review.walletId ||
        !_sameAddress(wallet?.address ?? '', review.buyer) ||
        _rpc.chainId != 1) {
      throw const AppFailure.validation(
        'The Ethereum wallet or network changed. Refresh the quote.',
      );
    }
  }

  void _assertLive(
    OpenSeaPurchaseQuote q, [
    OpenSeaPurchasePrepareResponse$Result? p,
    bool walletWindow = false,
  ]) {
    final now = DateTime.now();
    if (!q.expiresAt.isAfter(now) ||
        (p?.submitBy != null &&
            !p!.submitBy!.isAfter(
              now.add(Duration(seconds: walletWindow ? 60 : 0)),
            ))) {
      throw const AppFailure.validation(
        'The purchase quote or authorization expired. Refresh the quote.',
      );
    }
  }

  Future<String> buy(OpenSeaReview review, {VoidCallback? onSigned}) async {
    if (_submitting) {
      throw const AppFailure.validation('A purchase is already in progress.');
    }
    _submitting = true;
    try {
      if (await pending() != null) {
        throw const AppFailure.validation(
          'Resolve the pending purchase before buying again.',
        );
      }
      _assertBuyer(review);
      _assertLive(review.quote);
      final prepared = (await _api.prepareOpenSeaPurchase(
        OpenSeaPurchasePrepareRequest(
          quoteId: review.quote.quoteId,
          buyerAddress: review.buyer,
        ),
      )).result;
      validateOpenSeaPrepared(review.quote, prepared);
      final data = evmHexToBytes(prepared.data);
      final value = openSeaWei(prepared.value);
      final results = await Future.wait<Object>([
        _rpc.estimateGas(
          from: review.buyer,
          to: prepared.to,
          valueWei: value,
          data: data,
        ),
        _rpc.getFeeData(),
        _rpc.getBalance(review.buyer),
        _rpc.simulateAssetChanges(
          from: review.buyer,
          to: prepared.to,
          value: '0x${value.toRadixString(16)}',
          data: prepared.data,
        ),
      ]);
      validateOpenSeaSimulation(
        review.quote,
        results[3] as EvmSimulationResult,
      );
      final gas = ((results[0] as BigInt) * BigInt.from(12) ~/ BigInt.from(10))
          .toInt();
      final fees = results[1] as EthFeeData;
      if (gas <= 0 ||
          value + BigInt.from(gas) * fees.maxFeePerGas >
              (results[2] as BigInt)) {
        throw const AppFailure.validation(
          'Insufficient ETH for this purchase and its network fee.',
        );
      }
      // A changed gas estimate also requires another review. Never silently
      // replace the network-fee budget the user just approved.
      if (BigInt.from(gas) * fees.maxFeePerGas > review.networkFeeWei) {
        throw const AppFailure.validation(
          'The network fee increased. Refresh the quote before buying.',
        );
      }
      final nonce = await _rpc.getNonce(review.buyer);
      _assertBuyer(review);
      _assertLive(review.quote, prepared, true);
      final outcome = await _gate.authorize(
        usdValue: null,
        flow: const FlowKey(Chain.ethereum, AppFlow.fixedPriceBuy),
      );
      if (outcome != TransactionAuthOutcome.allowed) {
        throw TransactionAuthCancelledException(outcome);
      }
      _assertBuyer(review);
      _assertLive(review.quote, prepared, true);
      final signed = await _wallet.signEthereumTransaction(
        review.walletId,
        Transaction(
          to: EthereumAddress.fromHex(prepared.to),
          value: EtherAmount.inWei(value),
          data: data,
          maxGas: gas,
          nonce: nonce,
          maxFeePerGas: EtherAmount.inWei(fees.maxFeePerGas),
          maxPriorityFeePerGas: EtherAmount.inWei(fees.maxPriorityFeePerGas),
        ),
        chainId: 1,
        ensureActive: () => _assertBuyer(review),
      );
      _assertBuyer(review);
      _assertLive(review.quote, prepared);
      final hash = evmBytesToHex(keccak256(signed));
      final entry = PendingOpenSeaPurchase(
        review.quote,
        review.mintAccount,
        hash,
        nonce,
      );
      await _updateJournal(
        () => _storage.storePendingOpenSeaPurchase(entry.encode()),
      );
      // No bytes have been sent yet, so a wallet change can safely clear
      // the journal. After registration, ambiguous sends stay recoverable.
      try {
        _assertBuyer(review);
        _assertLive(review.quote, prepared);
      } catch (_) {
        await _clear(entry);
        rethrow;
      }
      try {
        await _tracker.register(
          PendingEvmBroadcast(
            walletAddress: review.buyer,
            nonce: nonce,
            chainId: 1,
            kind: PendingEvmTxKind.other,
            role: PendingTxCandidateRole.original,
            toAddress: prepared.to,
            valueWei: value,
            data: prepared.data,
            gasLimit: gas,
            maxFeePerGas: fees.maxFeePerGas,
            maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
            hash: hash,
            metadata: PendingTxMetadata(
              title: _trackerTitle,
              tokenSymbol: 'ETH',
              amountRaw: '-${prepared.value}',
              decimals: 18,
              artworkMint: review.mintAccount,
            ),
          ),
        );
      } catch (_) {
        await _clear(entry);
        rethrow;
      }
      onSigned?.call();
      try {
        final returned = await _rpc.sendRawTransaction(signed);
        if (returned.toLowerCase() != hash) {
          throw const AppFailure.validation(
            'RPC returned a different transaction hash.',
          );
        }
        await _rpc.waitForConfirmation(hash);
      } catch (_) {
        // A send error is ambiguous. Receipt recovery alone unlocks another buy.
      }
      final resolution = await _resolve(entry);
      // Signs and broadcasts outside the shared EVM funnel, so it reports
      // itself to the analytics transaction ledger. A revert is not recorded.
      void record(String signature, TxConfirmation confirmation) =>
          recordSubmittedTransaction(
            chain: Chain.ethereum,
            flow: AppFlow.fixedPriceBuy,
            signature: signature,
            walletAddress: () => review.buyer,
            confirmation: confirmation,
          );
      if (resolution == OpenSeaResolution.confirmed) {
        final confirmed = _confirmedHash ?? hash;
        record(confirmed, TxConfirmation.confirmed);
        return confirmed;
      }
      if (resolution == OpenSeaResolution.failed) {
        throw const AppFailure.validation(
          'The purchase reverted on Ethereum. Refresh the listing.',
        );
      }
      if (resolution == OpenSeaResolution.unverified) {
        throw const AppFailure.validation(openSeaUnverifiedMessage);
      }
      record(hash, TxConfirmation.pending);
      throw const AppFailure.validation(
        'The purchase is pending or its status is unknown. Check its status before buying again.',
      );
    } finally {
      _submitting = false;
    }
  }

  Future<OpenSeaResolution> resolve(PendingOpenSeaPurchase entry) async {
    if (_submitting) {
      throw const AppFailure.validation('A purchase is already in progress.');
    }
    _submitting = true;
    try {
      return await _resolve(entry);
    } finally {
      _submitting = false;
    }
  }

  Future<OpenSeaResolution> _resolve(PendingOpenSeaPurchase entry) async {
    if (_rpc.chainId != 1) {
      throw const AppFailure.validation(
        'This purchase requires Ethereum mainnet.',
      );
    }
    await _journalTail;
    final saved = await _readPending();
    final hashes = <String>{
      entry.hash,
      ...entry.candidateHashes,
      if (saved?.hash == entry.hash) ...saved!.candidateHashes,
    };
    for (final tx in _tracker.entries) {
      if (tx.nonce == entry.nonce &&
          _sameAddress(tx.walletAddress, entry.buyer)) {
        hashes.addAll(tx.candidates.map((c) => c.hash));
      }
    }
    TransactionReceipt? receipt;
    String minedHash = entry.hash;
    for (final hash in hashes) {
      final candidate = await _rpc.getTransactionReceipt(hash);
      if (candidate?.status != null) {
        receipt = candidate;
        minedHash = hash;
        break;
      }
    }
    if (receipt == null) {
      if (saved?.hash == entry.hash &&
          {'cancelled', 'replaced'}.contains(saved?.resolution)) {
        await _clear(entry);
        return OpenSeaResolution.failed;
      }
      return OpenSeaResolution.pending;
    }
    if (!receipt.status!) {
      await _clear(entry);
      return OpenSeaResolution.failed;
    }
    final effects = decodeSimulateV1([
      {
        'calls': [
          {
            'status': '0x1',
            'logs': receipt.logs
                .where((l) => l.removed != true)
                .map(
                  (l) => {
                    'address': l.address?.with0x,
                    'data': l.data,
                    'topics': l.topics,
                  },
                )
                .toList(),
          },
        ],
      },
    ]);
    if (!_sameAddress(receipt.from?.with0x ?? '', entry.buyer) ||
        !_sameAddress(receipt.to?.with0x ?? '', entry.quote.protocolAddress) ||
        !effects.changes.any((c) => _isPurchasedAsset(c, entry.quote))) {
      await _clear(entry);
      if (saved?.hash == entry.hash && saved?.resolution == 'cancelled') {
        return OpenSeaResolution.failed;
      }
      // A transaction on this nonce mined, so nothing else signed for the
      // purchase can land: the journal has done its job. Keeping it would
      // block every future purchase on a receipt that can never change.
      AppLogger.warn(
        _tag,
        'purchase nonce mined without the expected artwork transfer',
      );
      return OpenSeaResolution.unverified;
    }
    _confirmedHash = minedHash;
    await _clear(entry);
    notifyPortfolioRefresh();
    notifyArtworkEdited(entry.mintAccount);
    // The listing confirm below refreshes the listing only; ownership moves on
    // the backend when the transaction is reported.
    reportEthereumReceived(
      txHash: minedHash,
      address: entry.buyer.toLowerCase(),
    );
    // Listing refresh is best effort: a reporting failure cannot undo a mined purchase.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _api.confirmOpenSeaPurchase(
          OpenSeaPurchaseConfirmRequest(
            artworkId: entry.mintAccount,
            buyerAddress: entry.buyer,
            transactionHash: minedHash,
          ),
        );
        break;
      } on DioException catch (e) {
        final body = e.response?.data;
        final code = body is Map
            ? (body['error'] is Map ? body['error']['code'] : body['code'])
            : null;
        if (code != 'TRANSACTION_NOT_FOUND' || attempt == 2) break;
        await Future<void>.delayed(const Duration(seconds: 3));
      } catch (_) {
        break;
      }
    }
    notifyArtworkEdited(entry.mintAccount);
    return OpenSeaResolution.confirmed;
  }

  Future<void> _clear(PendingOpenSeaPurchase entry) => _updateJournal(() async {
    if ((await _readPending())?.hash == entry.hash) {
      await _storage.deletePendingOpenSeaPurchase();
    }
  });
}
