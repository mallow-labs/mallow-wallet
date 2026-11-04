import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:solana/encoder.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/transaction_ledger.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/crypto/ed25519_verify.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/data/mallow_tokens.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/result/app_failure.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/security/transaction_auth_gate.dart';
import '../../../core/services/transaction_pipeline.dart';
import '../../../shared/utils/chain.dart';
import '../../artwork/services/artwork_edited_signal.dart';
import '../../portfolio/services/portfolio_refresh_signal.dart';

const _tag = 'MagicEdenPurchase';

/// User-facing copy for the `reason` of an unavailable quote. The backend sends
/// a short code for the expected cases and developer-facing text (simulation
/// logs, raw balances) for the rest, so only the codes are mapped and anything
/// else gets the generic message. The raw reason goes to the debug log only.
String magicEdenUnavailableMessage(String? reason) {
  const generic = 'This listing is not available for in-app purchase.';
  final code = reason?.trim() ?? '';
  if (code == 'disabled') {
    return 'Magic Eden purchases are temporarily unavailable in the app. Try again later.';
  }
  if (code == 'no-active-order') {
    return 'This artwork is no longer listed on Magic Eden. Refresh the listing.';
  }
  if (code.startsWith('STALE_ORDER')) {
    return 'This listing changed or sold. Refresh the listing.';
  }
  if (code == 'Seller cannot buy own order') {
    return 'You cannot buy your own listing.';
  }
  if (code.startsWith('Unsupported Magic Eden')) {
    return 'This listing cannot be bought in the app yet. You can view it on Magic Eden.';
  }
  return generic;
}

/// The `lastValidBlockHeight` of a journal entry that no longer decodes as a
/// whole. That height alone decides whether its transaction can still land.
int? salvageMagicEdenLastValidBlockHeight(String raw) {
  try {
    final json = jsonDecode(raw);
    final height = json is Map ? json['lastValidBlockHeight'] : null;
    return height is int && height >= 0 ? height : null;
  } on Object {
    return null;
  }
}

/// A transaction built from a blockhash fetched now has a
/// `lastValidBlockHeight` of at most the current block height plus 150, and
/// the blockhash may come from a commitment a few dozen blocks ahead of
/// finalized. This margin covers both with room to spare.
const _unreadableReleaseMarginBlocks = 300;

/// Amounts stay as decimal strings on the wire and BigInt in arithmetic.
BigInt magicEdenAmount(String raw) {
  if (!RegExp(r'^\d+$').hasMatch(raw)) {
    throw const FormatException('Invalid purchase amount.');
  }
  return BigInt.parse(raw);
}

String formatMagicEdenAmount(String raw, int decimals) {
  final amount = magicEdenAmount(raw);
  final unit = BigInt.from(10).pow(decimals);
  final fraction = (amount % unit)
      .toString()
      .padLeft(decimals, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '${amount ~/ unit}' : '${amount ~/ unit}.$fraction';
}

void validateMagicEdenQuote(MagicEdenBuyQuote quote) {
  final known = tokenByMint(quote.currencyMint);
  if (quote.currencyDecimals < 0 ||
      quote.currencyDecimals > 18 ||
      quote.currencySymbol.isEmpty ||
      (quote.currencyMint == solMint && quote.currencyDecimals != 9) ||
      (known != null && known.decimals != quote.currencyDecimals)) {
    throw const AppFailure.validation(
      'This payment currency is not supported.',
    );
  }
  for (final raw in [
    quote.sellerPrice,
    quote.creatorRoyalty,
    quote.magicEdenFee,
    quote.mallowFeeLamports,
    quote.networkFeeLamports,
    quote.rentLamports,
    quote.totalPaymentAmount,
    quote.totalSolDebitLamports,
    quote.buyerPaymentBalance,
    quote.buyerSolBalanceLamports,
  ]) {
    magicEdenAmount(raw);
  }
}

String? magicEdenShortfall(MagicEdenBuyQuote quote) {
  validateMagicEdenQuote(quote);
  if (quote.currencyMint != solMint &&
      magicEdenAmount(quote.buyerPaymentBalance) <
          magicEdenAmount(quote.totalPaymentAmount)) {
    return 'Insufficient ${quote.currencySymbol} balance';
  }
  if (magicEdenAmount(quote.buyerSolBalanceLamports) <
      magicEdenAmount(quote.totalSolDebitLamports)) {
    return 'Insufficient SOL balance';
  }
  return null;
}

void assertMagicEdenQuoteUnchanged(
  MagicEdenBuyQuote reviewed,
  MagicEdenBuyQuote built,
) {
  final before = reviewed.toJson()
    ..remove('expiresAt')
    ..remove('buyerPaymentBalance')
    ..remove('buyerSolBalanceLamports');
  final after = built.toJson()
    ..remove('expiresAt')
    ..remove('buyerPaymentBalance')
    ..remove('buyerSolBalanceLamports');
  if (!mapEquals(before, after)) {
    throw const AppFailure.validation(
      'The Magic Eden listing or fee quote changed. Review the new total before buying.',
    );
  }
}

class MagicEdenReview {
  const MagicEdenReview(this.quote, this.buyer, this.walletId);
  final MagicEdenBuyQuote quote;
  final String buyer;
  final String? walletId;
}

class PendingMagicEdenPurchase {
  const PendingMagicEdenPurchase({
    required this.signature,
    required this.mintAccount,
    required this.buyer,
    required this.lastValidBlockHeight,
  });
  factory PendingMagicEdenPurchase.decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final height = json['lastValidBlockHeight'];
    if (height is! int ||
        height < 0 ||
        [
          json['signature'],
          json['mintAccount'],
          json['buyer'],
        ].any((v) => v is! String || v.isEmpty)) {
      throw const FormatException('Stored pending purchase is invalid.');
    }
    return PendingMagicEdenPurchase(
      signature: json['signature'] as String,
      mintAccount: json['mintAccount'] as String,
      buyer: json['buyer'] as String,
      lastValidBlockHeight: height,
    );
  }

  final String signature;
  final String mintAccount;
  final String buyer;
  final int lastValidBlockHeight;

  String encode() => jsonEncode({
    'signature': signature,
    'mintAccount': mintAccount,
    'buyer': buyer,
    'lastValidBlockHeight': lastValidBlockHeight,
  });
}

/// [unknown]: the transaction can no longer land (finalized height passed its
/// `lastValidBlockHeight`), but its status could not be read. The journal is
/// released; the user has to check the outcome.
enum MagicEdenResolution { pending, confirmed, failed, expired, unknown }

const magicEdenUnknownMessage =
    'The purchase can no longer land, but its result could not be checked. '
    'Check your activity before buying again.';

/// Shares a submission lock across sheets and keeps unresolved signatures across
/// process restarts. A transport error is never permission to buy again.
@lazySingleton
class MagicEdenPurchaseService {
  MagicEdenPurchaseService(
    this._api,
    this._wallet,
    this._auth,
    this._gate,
    this._rpc,
    this._storage,
    this._pipeline,
  ) : _now = DateTime.now;

  @visibleForTesting
  MagicEdenPurchaseService.withClock(
    this._api,
    this._wallet,
    this._auth,
    this._gate,
    this._rpc,
    this._storage,
    this._pipeline,
    this._now,
  );

  final DateTime Function() _now;
  final MallowApiV2Client _api;
  final WalletManager _wallet;
  final AuthService _auth;
  final TransactionAuthGate _gate;
  final SolanaRpcService _rpc;
  final SecureWalletStorage _storage;
  final TransactionPipeline _pipeline;
  bool _submitting = false;

  /// The journal entry that blocks another purchase, or null when there is
  /// none. An entry that no longer decodes is released once its transaction
  /// can no longer land (see [_releaseUnreadable]) and blocks until then.
  Future<PendingMagicEdenPurchase?> pending() async {
    final raw = await _storage.loadPendingMagicEdenPurchase();
    if (raw == null) return null;
    try {
      return PendingMagicEdenPurchase.decode(raw);
    } on Object catch (e) {
      await _releaseUnreadable(raw, e);
      return null;
    }
  }

  /// Delete an undecodable journal entry once the transaction it recorded can
  /// no longer land, and throw while it still might.
  ///
  /// The release signal is the chain, never the clock: a blockhash stays valid
  /// for a block-height window, and a cluster halt stops block height, so a
  /// wall-clock timeout could release a transaction that still lands after
  /// the restart. When the entry's `lastValidBlockHeight` survives, that is
  /// the bound. When it does not, the entry is rewritten as a tombstone whose
  /// bound is the current finalized height plus [_unreadableReleaseMarginBlocks],
  /// which no transaction signed before now can outlive.
  Future<void> _releaseUnreadable(String raw, Object error) async {
    AppLogger.warn(
      _tag,
      'stored purchase record is unreadable (${error.runtimeType})',
    );
    const blocked = AppFailure.validation(
      'A stored Magic Eden purchase could not be read. Buying unlocks in a few '
      'minutes, once its transaction can no longer land.',
    );
    final finalized = await _rpc.finalizedBlockHeight();
    final bound = salvageMagicEdenLastValidBlockHeight(raw);
    if (bound == null) {
      await _storage.storePendingMagicEdenPurchase(
        jsonEncode({
          'unreadable': true,
          'lastValidBlockHeight': finalized + _unreadableReleaseMarginBlocks,
        }),
      );
      throw blocked;
    }
    if (finalized <= bound) throw blocked;
    if (await _storage.loadPendingMagicEdenPurchase() == raw) {
      await _storage.deletePendingMagicEdenPurchase();
    }
    AppLogger.warn(_tag, 'released an unreadable purchase record');
  }

  /// The decoded entry, or null when the slot is empty or unreadable.
  Future<PendingMagicEdenPurchase?> _readPending() async {
    final raw = await _storage.loadPendingMagicEdenPurchase();
    if (raw == null) return null;
    try {
      return PendingMagicEdenPurchase.decode(raw);
    } on Object {
      return null;
    }
  }

  Future<MagicEdenReview> review(String mintAccount) async {
    if (_submitting || await pending() != null) {
      throw const AppFailure.validation(
        'Resolve the pending Magic Eden purchase before buying again.',
      );
    }
    final buyer = _auth.currentAddress;
    if (buyer == null) {
      throw const AppFailure.validation('Connect a Solana wallet to buy.');
    }
    final walletId = await _storage.loadSelectedWalletId();
    final result = (await _api.quoteMagicEdenBuy(mintAccount, buyer)).result;
    final quote = result.quote;
    if (!result.available || quote == null) {
      AppLogger.info(_tag, 'quote unavailable: ${result.reason}');
      throw AppFailure.validation(magicEdenUnavailableMessage(result.reason));
    }
    if (quote.mintAccount != mintAccount) {
      throw const AppFailure.validation(
        'The quote belongs to another artwork.',
      );
    }
    validateMagicEdenQuote(quote);
    final review = MagicEdenReview(quote, buyer, walletId);
    await _assertBuyer(review);
    _assertLive(quote);
    return review;
  }

  void _assertLive(MagicEdenBuyQuote quote) {
    final expiry = quote.expiresAt;
    if (expiry == null || !expiry.isAfter(_now())) {
      throw const AppFailure.validation(
        'The purchase quote expired. Refresh the quote.',
      );
    }
  }

  void _ensureActive(MagicEdenReview review) {
    if (_auth.currentAddress != review.buyer) {
      throw const AppFailure.validation(
        'The connected wallet changed. Refresh the quote.',
      );
    }
  }

  Future<void> _assertBuyer(MagicEdenReview review) async {
    _ensureActive(review);
    if (await _storage.loadSelectedWalletId() != review.walletId ||
        await _wallet.getAddress() != review.buyer) {
      throw const AppFailure.validation(
        'The connected wallet changed. Refresh the quote.',
      );
    }
    _ensureActive(review);
  }

  Future<String> buy(MagicEdenReview review, {VoidCallback? onSigned}) async {
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
      await _assertBuyer(review);
      _assertLive(review.quote);
      final shortfall = magicEdenShortfall(review.quote);
      if (shortfall != null) throw AppFailure.validation(shortfall);
      final built = (await _api.buyMagicEdenTx(
        MagicEdenBuyTxRequest(
          buyer: review.buyer,
          orderId: review.quote.orderId,
          revision: review.quote.revision,
          paymentMint: review.quote.currencyMint,
          maxPaymentAmount: review.quote.totalPaymentAmount,
          maxSolDebitLamports: review.quote.totalSolDebitLamports,
        ),
      )).result;
      assertMagicEdenQuoteUnchanged(review.quote, built.quote);
      _assertLive(built.quote);
      if (built.lastValidBlockHeight < 0) {
        throw const AppFailure.validation(
          'Invalid transaction confirmation window.',
        );
      }
      final unsigned = SignedTx.fromBytes(base64Decode(built.tx));
      final message = unsigned.compiledMessage;
      if (message.requiredSignatureCount != 1 ||
          unsigned.signatures.length != 1 ||
          message.accountKeys.first.toBase58() != review.buyer) {
        throw const AppFailure.validation(
          'The purchase transaction has unexpected signers or fee payer.',
        );
      }
      final outcome = await _gate.authorize(
        usdValue: null,
        flow: const FlowKey.solana(AppFlow.fixedPriceBuy),
      );
      if (outcome != TransactionAuthOutcome.allowed) {
        throw TransactionAuthCancelledException(outcome);
      }
      await _assertBuyer(review);
      _assertLive(review.quote);
      _assertLive(built.quote);
      final signed = await _wallet.signCompiledTx(
        unsignedTx: unsigned,
        walletId: review.walletId,
        expectedAddress: review.buyer,
        ensureActive: () => _ensureActive(review),
      );
      await _assertBuyer(review);
      final bytes = message.toByteArray().toList();
      if (!listEquals(bytes, signed.compiledMessage.toByteArray().toList()) ||
          signed.signatures.length != 1 ||
          !await isValidEd25519Signature(
            bytes,
            signed.signatures.first.bytes,
            review.buyer,
          )) {
        throw const AppFailure.validation(
          'The wallet changed or did not sign the purchase transaction.',
        );
      }
      _assertLive(review.quote);
      _assertLive(built.quote);
      if (await _rpc.finalizedBlockHeight() > built.lastValidBlockHeight) {
        throw const AppFailure.validation(
          'The purchase transaction expired. Refresh the quote.',
        );
      }
      await _assertBuyer(review);
      final entry = PendingMagicEdenPurchase(
        signature: signed.signatures.first.toBase58(),
        mintAccount: review.quote.mintAccount,
        buyer: review.buyer,
        lastValidBlockHeight: built.lastValidBlockHeight,
      );
      // Persist before the RPC sees any bytes. Storage failure means no send.
      await _storage.storePendingMagicEdenPurchase(entry.encode());
      try {
        await _assertBuyer(review);
        _assertLive(review.quote);
        _assertLive(built.quote);
        onSigned?.call();
        final sent = await _rpc.sendTransaction(signed);
        if (sent != entry.signature) {
          throw const AppFailure.validation(
            'RPC returned a different transaction signature.',
          );
        }
        await _rpc.awaitConfirmationOrThrow(
          entry.signature,
          rebroadcast: signed,
        );
        await _clear(entry);
        _confirmed(entry);
        _record(review, entry, TxConfirmation.confirmed);
        return entry.signature;
      } catch (_) {
        final resolution = await _resolve(entry);
        if (resolution == MagicEdenResolution.confirmed) {
          _record(review, entry, TxConfirmation.confirmed);
          return entry.signature;
        }
        if (resolution == MagicEdenResolution.failed) {
          throw const AppFailure.validation(
            'The Magic Eden purchase failed on chain.',
          );
        }
        if (resolution == MagicEdenResolution.expired) {
          throw const AppFailure.validation(
            'The purchase expired without landing. Refresh the listing.',
          );
        }
        if (resolution == MagicEdenResolution.unknown) {
          _record(review, entry, TxConfirmation.pending);
          throw const AppFailure.validation(magicEdenUnknownMessage);
        }
        _record(review, entry, TxConfirmation.pending);
        throw const AppFailure.validation(
          'The purchase may have been submitted. Check its status before buying again.',
        );
      }
    } finally {
      _submitting = false;
    }
  }

  /// Report the purchase to the analytics transaction ledger. It signs and
  /// sends outside the shared Solana pipeline, so it reports itself.
  void _record(
    MagicEdenReview review,
    PendingMagicEdenPurchase entry,
    TxConfirmation confirmation,
  ) => recordSubmittedTransaction(
    chain: Chain.solana,
    flow: AppFlow.fixedPriceBuy,
    signature: entry.signature,
    walletAddress: () => review.buyer,
    confirmation: confirmation,
  );

  Future<MagicEdenResolution> resolve(PendingMagicEdenPurchase entry) async {
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

  Future<MagicEdenResolution> _resolve(PendingMagicEdenPurchase entry) async {
    SolanaTxStatus? status;
    Object? lookupError;
    StackTrace? lookupTrace;
    Future<void> lookUp() async {
      try {
        status = await _rpc.transactionStatusWithHistory(entry.signature);
        lookupError = null;
      } on Object catch (e, st) {
        lookupError = e;
        lookupTrace = st;
      }
    }

    await lookUp();
    if (status == null &&
        await _rpc.finalizedBlockHeight() > entry.lastValidBlockHeight) {
      // Re-read: the transaction may have landed just before the window shut.
      await lookUp();
      if (status == null) {
        await _clear(entry);
        if (lookupError != null) {
          // Past its window the transaction cannot land, so the journal has
          // done its job even though the outcome stays unread.
          AppLogger.warn(
            _tag,
            'status unreadable after the purchase window closed '
            '(${lookupError.runtimeType})',
          );
          return MagicEdenResolution.unknown;
        }
        return MagicEdenResolution.expired;
      }
    }
    // Inside the window an unread status is no proof of anything.
    if (lookupError case final error?) {
      Error.throwWithStackTrace(error, lookupTrace!);
    }
    final seen = status;
    if (seen?.err != null) {
      await _clear(entry);
      return MagicEdenResolution.failed;
    }
    if (seen?.landed ?? false) {
      await _clear(entry);
      _confirmed(entry);
      return MagicEdenResolution.confirmed;
    }
    return MagicEdenResolution.pending;
  }

  Future<void> _clear(PendingMagicEdenPurchase entry) async {
    if ((await _readPending())?.signature == entry.signature) {
      await _storage.deletePendingMagicEdenPurchase();
    }
  }

  void _confirmed(PendingMagicEdenPurchase entry) {
    notifyPortfolioRefresh();
    notifyArtworkEdited(entry.mintAccount);
    _pipeline.runIndexerCheck(
      signature: entry.signature,
      isClosed: () => false,
      onAck: (_, ok) {
        if (ok) {
          notifyPortfolioRefresh();
          notifyArtworkEdited(entry.mintAccount);
        }
      },
    );
  }
}
