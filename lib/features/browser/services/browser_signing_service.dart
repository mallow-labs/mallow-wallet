import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:ledger_ethereum/ledger_ethereum.dart'
    show Eip712LedgerException;
import 'package:ledger_flutter_plus/ledger_flutter_plus.dart'
    show LedgerDeviceException;
import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/transaction_ledger.dart';
import '../../../core/config/remote_config.dart';
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart' show WalletType;
import '../../../core/models/simulation_review.dart';
import '../../../core/security/transaction_auth_gate.dart';
import '../../../core/services/keystone_sign_service.dart'
    show KeystoneSigningCancelledException;
import '../../../core/services/ledger_service.dart'
    show LedgerNotConnectedException, LedgerSigningCancelledException;
import '../../../core/services/signing_copy.dart';
import '../../../core/services/token_price_service.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/simulation_review_sheet.dart';
import '../../../shared/widgets/transaction_expiry.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../send/widgets/edit_gas_fee_sheet.dart';
import '../models/dapp_request.dart';
import '../widgets/browser_send_sheet.dart';
import '../widgets/browser_site_tile.dart';
import '../widgets/ethereum_fee_affordance.dart';
import '../widgets/message_signing_review.dart';
import '../widgets/typed_data_signing_review.dart';
import 'browser_session.dart';
import 'ethereum_dapp_adapter.dart';
import 'tezos_dapp_adapter.dart';
import '../../../core/network/tezos_rpc_service.dart';
import '../../../core/data/mallow_tokens.dart' show xtzMint;
import 'solana_dapp_adapter.dart';
import 'solana_dapp_transaction.dart';
import 'solana_expiry_clock.dart';
import 'solana_slot_time.dart';

/// One serial native review and authentication boundary per website request.
/// Signing is explicitly pinned even though the browser follows the active
/// global wallet; asynchronous UI/hardware work cannot resolve a newer signer.
class BrowserSigningService {
  BrowserSigningService({
    SolanaDappAdapter? adapter,
    EthereumDappAdapter? ethereumAdapter,
    TezosDappAdapter? tezosAdapter,
    TransactionAuthGate? authGate,
    TokenPriceService? prices,
    BrowserSession? session,
    Future<void> Function(Uri url)? openExternal,
    SolanaSlotTimeSource? slotTime,
  }) : _session = session,
       _slotTime = slotTime ?? SolanaSlotTimeSource.instance,
       _ethereumOverride = ethereumAdapter,
       _tezosOverride = tezosAdapter,
       _openExternal = openExternal,
       _adapter =
           adapter ??
           SolanaDappAdapter(walletManager: GetIt.I<WalletManager>()),
       _authGate = authGate ?? GetIt.I<TransactionAuthGate>(),
       _prices = prices ?? GetIt.I<TokenPriceService>();
  final SolanaDappAdapter _adapter;
  final EthereumDappAdapter? _ethereumOverride;
  late final EthereumDappAdapter _ethereum =
      _ethereumOverride ??
      EthereumDappAdapter(walletManager: GetIt.I<WalletManager>());
  final TezosDappAdapter? _tezosOverride;
  late final TezosDappAdapter _tezos =
      _tezosOverride ??
      TezosDappAdapter(
        walletManager: GetIt.I<WalletManager>(),
        rpc: GetIt.I<TezosRpcService>(),
      );
  final TransactionAuthGate _authGate;
  final TokenPriceService _prices;
  final BrowserSession? _session;
  final Future<void> Function(Uri url)? _openExternal;
  final SolanaSlotTimeSource _slotTime;

  Future<Map<String, Object?>> execute(
    BuildContext context,
    DappSigningRequest request,
  ) async {
    request.ensureActive();
    if (request.chain == tezosMainnet) return _executeTezos(context, request);
    if (request.chain == ethereumMainnet)
      return _executeEthereum(context, request);
    if (!request.wallet.canSign) return _reviewViewOnly(context, request);
    if (request.method == 'signMessage') {
      final review = _adapter.prepareMessage(
        bytes: request.payloads.single,
        origin: request.context.canonicalOrigin,
        address: request.wallet.address,
        walletId: request.wallet.id,
        chain: request.chain,
      );
      if (!context.mounted)
        throw const DappException(4001, 'Request cancelled.');
      final approved = await _showReview(
        context,
        request,
        (reject, approve) => MessageSigningReview(
          review: review,
          iconUrl: _iconUrl(request.context),
          onReject: reject,
          onApprove: approve,
        ),
      );
      request.ensureActive();
      if (!approved) throw const DappException(4001, 'Signature rejected.');
      await _authorize(request, AppFlow.browserMessage, null);
      final signature = await _onHardware(
        context,
        request,
        ledgerSublabel:
            'Check the message on your Ledger, then approve it there.',
        sign: () => _adapter.signMessage(
          review,
          ensureActive: request.ensureActive,
          cancelled: request.cancelled,
        ),
      );
      request.ensureActive();
      return {
        'signature': base64Encode(signature),
        'publicKey': request.wallet.address,
      };
    }
    if (!const [
      'signTransaction',
      'signAllTransactions',
      'signAndSendTransaction',
    ].contains(request.method))
      throw const DappException(4200, 'Unsupported signing method.');
    if (request.method == 'signAndSendTransaction')
      return _signAndSend(context, request);
    // A batch is reviewed, approved and authorized once, as a whole.
    final count = request.payloads.length;
    final title = _batchTitle(count);
    final approveLabel = count > 1 ? 'Sign all' : 'Sign';
    final expiry = _expiryFor(request);
    final sheet = _presentPrepared<PreparedSolanaBatch>(
      context,
      request,
      prepare: () => _prepareBatch(request).then((batch) {
        expiry.clock.reviewed(batch.review.simulatedAt);
        return batch;
      }),
      signable: () async => _unsimulatedBatch(request),
      title: title,
      approveLabel: approveLabel,
      expiry: expiry,
      review: (batch, reject, approve) => _transactionReview(
        request,
        batch.review,
        reject,
        approve,
        title: title,
        approveLabel: approveLabel,
        expiry: expiry.view,
      ),
    );
    final _Approval<PreparedSolanaBatch> approval;
    try {
      approval = await sheet.approval;
    } finally {
      expiry.clock.stop();
    }
    final approvedAt = DateTime.now().toUtc();
    await _authorize(
      request,
      AppFlow.browserTransaction,
      await _approvedUsd(approval, (batch) => batch.review),
    );
    final batch = await approval.prepared;
    final total = batch.transactions.length;
    // A batch takes one device approval per transaction; say which one.
    String progress(int index) => total > 1
        ? '$kExternalSigningLabel (${index + 1} of $total)'
        : kExternalSigningLabel;
    final label = ValueNotifier(progress(0));
    final signed = await _onHardware(
      context,
      request,
      label: label,
      sign: () async {
        final signed = <Uint8List>[];
        for (final prepared in batch.transactions) {
          request.ensureActive();
          label.value = progress(signed.length);
          signed.add(
            await _adapter.signPrepared(
              prepared,
              ensureActive: request.ensureActive,
              cancelled: request.cancelled,
              approvedAt: approvedAt,
            ),
          );
          request.ensureActive();
        }
        return signed;
      },
    );
    // The website broadcasts these itself; follow them so they still show
    // in the recent transactions once they land.
    for (final bytes in signed) {
      try {
        _adapter.watchSigned(bytes, request.chain);
      } catch (_) {
        // Following a receipt is cosmetic; the signed result still returns.
      }
      try {
        final tx = parseDappTransaction(bytes);
        if (tx.signatures.isNotEmpty &&
            tx.signatures.first.bytes.any((b) => b != 0)) {
          _record(request, tx.id, TxConfirmation.dapp);
        }
      } catch (_) {
        // As above: reporting never blocks the signed result.
      }
    }
    return request.method == 'signAllTransactions'
        ? {'transactions': signed.map(base64Encode).toList()}
        : {'transaction': base64Encode(signed.single)};
  }

  /// Reviews and signs a wallet-broadcast transaction, then closes the sheet.
  /// The website receives the signature at broadcast and handles confirmation.
  Future<Map<String, Object?>> _signAndSend(
    BuildContext context,
    DappSigningRequest request,
  ) async {
    final step = ValueNotifier<BrowserSendStep>(const BrowserSendReview());
    final expiry = _expiryFor(request);
    late final _PresentedReview<PreparedSolanaTransaction> sheet;
    sheet = _presentPrepared(
      context,
      request,
      prepare: () => _adapter
          .prepareTransaction(
            transaction: request.payloads.single,
            walletId: request.wallet.id,
            address: request.wallet.address,
            origin: request.context.canonicalOrigin,
            chain: request.chain,
          )
          .then((prepared) {
            expiry.clock.reviewed(prepared.review.simulatedAt);
            return prepared;
          }),
      signable: () async => _adapter.describeTransaction(
        transaction: request.payloads.single,
        walletId: request.wallet.id,
        address: request.wallet.address,
        origin: request.context.canonicalOrigin,
        chain: request.chain,
      ),
      approveLabel: 'Sign and send',
      expiry: expiry,
      frame: (review) => BrowserSendSheet(
        step: step,
        onClose: () => sheet.close(),
        review: review,
      ),
      review: (prepared, reject, approve) => _transactionReview(
        request,
        prepared.review,
        reject,
        approve,
        approveLabel: 'Sign and send',
        batchNotice: 'Approving signs and broadcasts this transaction.',
        expiry: expiry.view,
      ),
      onApprove: () => step.value = BrowserSendSigning(request.wallet.type),
    );
    final _Approval<PreparedSolanaTransaction> approval;
    try {
      approval = await sheet.approval;
    } finally {
      expiry.clock.stop();
    }
    final Uint8List signed;
    // From approval on, every failure lands on the sheet: it no longer closes
    // itself, so an escape here would leave it spinning.
    try {
      request.ensureActive();
      await _authorize(
        request,
        AppFlow.browserTransaction,
        await _approvedUsd(approval, (prepared) => prepared.review),
      );
      signed = await _adapter.signPrepared(
        await approval.prepared,
        ensureActive: request.ensureActive,
        cancelled: request.cancelled,
      );
      request.ensureActive();
    } on _AuthCancelled {
      // The user backed out of the prompt; there is nothing to report.
      sheet.close();
      rethrow;
    } on DappException catch (error) {
      step.value = BrowserSendFailed(error.message);
      rethrow;
    } catch (_) {
      step.value = const BrowserSendFailed('Signing failed. Nothing was sent.');
      rethrow;
    }
    sheet.close();
    final signature = await _adapter.sendSigned(
      signed,
      request.chain,
      options: request.options,
    );
    _record(request, signature, TxConfirmation.pending);
    // A broadcast has happened. Return its identity even if UI state changed;
    // the coordinator decides whether the original document still exists.
    return {'signature': signature};
  }

  /// A view-only wallet cannot sign, but its review still shows what the
  /// transaction would do, with the Explorer simulation link. Closing it
  /// tells the website the wallet is view-only. Nothing here can sign.
  Future<Never> _reviewViewOnly(
    BuildContext context,
    DappSigningRequest request,
  ) async {
    const viewOnly = DappException(4200, 'This wallet is view-only.');
    if (!const [
      'signTransaction',
      'signAllTransactions',
      'signAndSendTransaction',
    ].contains(request.method))
      throw viewOnly;
    final title = _batchTitle(request.payloads.length);
    final sheet = _presentPrepared<PreparedSolanaBatch>(
      context,
      request,
      prepare: () => _prepareBatch(request),
      title: title,
      rejection: viewOnly,
      review: (batch, reject, _) =>
          _transactionReview(request, batch.review, reject, null, title: title),
    );
    // Nothing here can approve, so this only ever fails.
    await sheet.approval;
    throw viewOnly;
  }

  Future<Map<String, Object?>> _executeEthereum(
    BuildContext context,
    DappSigningRequest request,
  ) async {
    final wallet = request.wallet;
    // The coordinator already refuses these; this keeps the signer unreachable.
    if (!wallet.canSign)
      throw const DappException(4200, 'This wallet is view-only.');
    final origin = request.context.canonicalOrigin;
    switch (request.method) {
      case 'personal_sign':
        final review = _ethereum.prepareMessage(
          bytes: request.payloads.single,
          origin: origin,
          address: wallet.address,
          walletId: wallet.id,
        );
        if (!context.mounted)
          throw const DappException(4001, 'Request cancelled.');
        final approved = await _showReview(
          context,
          request,
          (reject, approve) => MessageSigningReview(
            review: review,
            iconUrl: _iconUrl(request.context),
            onReject: reject,
            onApprove: approve,
          ),
        );
        request.ensureActive();
        if (!approved) throw const DappException(4001, 'Signature rejected.');
        await _authorize(request, AppFlow.browserMessage, null);
        if (!context.mounted)
          throw const DappException(4001, 'Request cancelled.');
        final signature = await _onHardware(
          context,
          request,
          ledgerSublabel:
              'Check the message on your Ledger, then approve it there.',
          sign: () => _ethereum.signMessage(
            review,
            ensureActive: request.ensureActive,
            cancelled: request.cancelled,
          ),
        );
        request.ensureActive();
        return {'signature': _hex(signature)};
      case 'eth_signTypedData_v4':
        final review = await _ethereum.prepareTypedData(
          typedData: utf8.decode(request.payloads.single),
          origin: origin,
          address: wallet.address,
          walletId: wallet.id,
        );
        request.ensureActive();
        if (!context.mounted)
          throw const DappException(4001, 'Request cancelled.');
        final approved = await _showReview(
          context,
          request,
          (reject, approve) => TypedDataSigningReview(
            review: review,
            signer: wallet.type,
            iconUrl: _iconUrl(request.context),
            onReject: reject,
            onApprove: approve,
          ),
        );
        request.ensureActive();
        if (!approved) throw const DappException(4001, 'Signature rejected.');
        await _authorize(request, AppFlow.browserMessage, null);
        if (!context.mounted)
          throw const DappException(4001, 'Request cancelled.');
        final signature = await _onHardware(
          context,
          request,
          ledgerSublabel:
              'Your Ledger shows the contract and each field. Check them there, then approve.',
          sign: () => _ethereum.signTypedData(
            review,
            ensureActive: request.ensureActive,
            cancelled: request.cancelled,
          ),
        );
        request.ensureActive();
        return {'signature': _hex(signature)};
      case 'eth_sendTransaction':
        return _sendEthereum(context, request);
    }
    throw const DappException(4200, 'Unsupported signing method.');
  }

  Future<Map<String, Object?>> _executeTezos(
    BuildContext context,
    DappSigningRequest request,
  ) async {
    if (!request.wallet.canSign)
      throw const DappException(4200, 'This Tezos wallet cannot sign.');
    if (request.method == 'signPayload') {
      final review = TezosMessageReview(
        payload: request.payloads.single,
        origin: request.context.canonicalOrigin,
        address: request.wallet.address,
        walletId: request.wallet.id,
        signingType: request.options['signingType'] as String? ?? 'raw',
      );
      if (!context.mounted)
        throw const DappException(4001, 'Request cancelled.');
      final approved = await _showReview(
        context,
        request,
        (reject, approve) => MessageSigningReview(
          review: review,
          iconUrl: _iconUrl(request.context),
          onReject: reject,
          onApprove: approve,
        ),
      );
      request.ensureActive();
      if (!approved) throw const DappException(4001, 'Signature rejected.');
      await _authorize(request, AppFlow.browserMessage, null);
      if (!context.mounted)
        throw const DappException(4001, 'Request cancelled.');
      final signature = await _onHardware(
        context,
        request,
        ledgerSublabel:
            'Review the message in the Tezos Wallet app on your Ledger, then approve.',
        sign: () => _tezos.signMessage(
          review,
          request.ensureActive,
          cancelled: request.cancelled,
        ),
      );
      request.ensureActive();
      return {'signature': signature};
    }
    if (request.method != 'sendOperations')
      throw const DappException(4200, 'Unsupported signing method.');
    // A malformed request fails here, before any sheet opens.
    final operation = TezosDappOperationRequest.parse(
      jsonDecode(utf8.decode(request.payloads.single)),
      account: request.wallet.address,
    );
    final step = ValueNotifier<BrowserSendStep>(const BrowserSendReview());
    Future<PreparedTezosOperation>? preparing;
    Future<PreparedTezosOperation> prepare() =>
        preparing ??= _tezos.prepareOperation(
          request: operation,
          walletId: request.wallet.id,
          address: request.wallet.address,
          origin: request.context.canonicalOrigin,
          ensureActive: request.ensureActive,
          cancelled: request.cancelled,
        );
    late final _PresentedReview<PreparedTezosOperation> sheet;
    sheet = _presentPrepared(
      context,
      request,
      prepare: prepare,
      // The node's run of the operation sets its gas and storage limits, so
      // an early approval still waits for it; it skips only the reading.
      signable: prepare,
      approveLabel: 'Sign and send',
      frame: (review) => BrowserSendSheet(
        step: step,
        onClose: () => sheet.close(),
        review: review,
      ),
      review: (prepared, reject, approve) => SimulationReviewSheet(
        review: prepared.review,
        onReject: reject,
        onApprove: approve,
        priceOf: _prices.priceOf,
        openExternal: _openExternal,
        approveLabel: 'Sign and send',
        operationDetails: prepared.details,
        batchNotice: 'Approving signs and broadcasts this operation group.',
        originIcon: _originIcon(request),
      ),
      onApprove: () => step.value = BrowserSendSigning(request.wallet.type),
    );
    final approval = await sheet.approval;
    final String signed;
    try {
      await _authorize(
        request,
        AppFlow.browserTransaction,
        await _approvedUsd(
          approval,
          (prepared) => prepared.review,
          estimate: (review) =>
              estimateTezosOutgoingUsd(review, _prices.priceOf),
        ),
      );
      signed = await _tezos.signPrepared(
        await approval.prepared,
        request.ensureActive,
        cancelled: request.cancelled,
      );
      request.ensureActive();
    } on _AuthCancelled {
      sheet.close();
      rethrow;
    } on DappException catch (error) {
      step.value = BrowserSendFailed(error.message);
      rethrow;
    } catch (error) {
      step.value = BrowserSendFailed(
        request.wallet.type == WalletType.ledger
            ? ledgerSigningFailure(error, chain: Chain.tezos)
            : 'Signing failed. Nothing was sent.',
      );
      rethrow;
    }
    sheet.close();
    final hash = await _tezos.sendSigned(
      signed,
      recipient: request.wallet.address,
    );
    _record(request, hash, TxConfirmation.pending);
    return {'hash': hash};
  }

  /// Runs [sign] behind an "awaiting approval" sheet when the request's
  /// signer is a Ledger or a Keystone. The review sheet has already closed by
  /// then, and a review on the device can take many screens, so without it the
  /// app would show nothing while it waits. A Ledger's connect prompt and a
  /// Keystone's QR exchange open over this sheet and leave it showing when
  /// they close, until the signature is back; if the device fails, the same
  /// sheet says why. [label] replaces the title, as a batch's progress does.
  /// Any other signer signs without it.
  Future<T> _onHardware<T>(
    BuildContext context,
    DappSigningRequest request, {
    String ledgerSublabel = kLedgerSigningSublabel,
    ValueListenable<String>? label,
    required Future<T> Function() sign,
  }) async {
    final type = request.wallet.type;
    if (type != WalletType.ledger && type != WalletType.keystone) return sign();
    if (!context.mounted) throw const DappException(4001, 'Request cancelled.');
    final navigator = Navigator.of(context, rootNavigator: true);
    final failure = ValueNotifier<String?>(null);
    final title = label ?? ValueNotifier(kExternalSigningLabel);
    late final ModalBottomSheetRoute<void> route;
    void close() {
      if (route.isActive && navigator.mounted) navigator.removeRoute(route);
    }

    route = mallowSheetRoute<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ListenableBuilder(
        listenable: Listenable.merge([failure, title]),
        builder: (_, _) => TransactionPipelineSheet(
          phase: failure.value == null
              ? TransactionPipelinePhase.progress
              : TransactionPipelinePhase.error,
          label: title.value,
          sublabel: type == WalletType.ledger
              ? ledgerSublabel
              : kKeystoneSigningSublabel,
          sublabelCycle: const [],
          errorTitle: 'Not signed',
          errorSublabel: failure.value,
          onClose: close,
        ),
      ),
    );
    unawaited(request.cancelled.then((_) => close()));
    unawaited(navigator.push(route));
    try {
      final result = await sign();
      close();
      return result;
    } on LedgerSigningCancelledException {
      close();
      rethrow;
    } on LedgerNotConnectedException {
      // The user closed the connect prompt, or it could not connect and said
      // so itself; a second sheet saying it again is one more to dismiss.
      close();
      rethrow;
    } on KeystoneSigningCancelledException {
      close();
      rethrow;
    } catch (error) {
      if (route.isActive) {
        failure.value = type == WalletType.ledger
            ? ledgerSigningFailure(error, chain: _chainOf(request))
            : error is DappException
            ? error.message
            : 'Your Keystone did not sign this. Nothing was signed.';
      }
      rethrow;
    }
  }

  /// [_signAndSend] for an Ethereum transaction: closes after signing and
  /// returns the hash to the website at broadcast.
  Future<Map<String, Object?>> _sendEthereum(
    BuildContext context,
    DappSigningRequest request,
  ) async {
    final transaction = EthereumDappTransactionRequest.parse(
      jsonDecode(utf8.decode(request.payloads.single)),
      account: request.wallet.address,
    );
    final step = ValueNotifier<BrowserSendStep>(const BrowserSendReview());
    final preparation = _ethereum.startTransaction(
      request: transaction,
      walletId: request.wallet.id,
      address: request.wallet.address,
      origin: request.context.canonicalOrigin,
    );
    // The fee can change while the review is up (Edit Gas Fee); everything
    // after approval reads the version the user approved.
    late final _PresentedReview<ValueNotifier<PreparedEthereumTransaction>>
    sheet;
    sheet = _presentPrepared(
      context,
      request,
      prepare: () async => ValueNotifier(await preparation.reviewed),
      // Nonce, gas and fee are needed to sign; the simulation is not.
      signable: () async => ValueNotifier(await preparation.signable),
      approveLabel: 'Sign and send',
      frame: (review) => BrowserSendSheet(
        step: step,
        onClose: () => sheet.close(),
        review: review,
      ),
      review: (current, reject, approve) =>
          ValueListenableBuilder<PreparedEthereumTransaction>(
            valueListenable: current,
            builder: (reviewContext, prepared, _) => SimulationReviewSheet(
              review: prepared.review,
              onReject: reject,
              onApprove: approve,
              priceOf: _prices.priceOf,
              openExternal: _openExternal,
              originIcon: _originIcon(request),
              approveLabel: 'Sign and send',
              batchNotice: 'Approving signs and broadcasts this transaction.',
              networkFeeAction: prepared.canEditFee
                  ? EthereumFeeAffordance(
                      prepared: prepared,
                      onTap: () => _editGas(reviewContext, request, current),
                    )
                  : null,
            ),
          ),
      onApprove: () => step.value = BrowserSendSigning(request.wallet.type),
    );
    final approval = await sheet.approval;
    late final PreparedEthereumTransaction prepared;
    final Uint8List signed;
    try {
      request.ensureActive();
      await _authorize(
        request,
        AppFlow.browserTransaction,
        await _approvedUsd(
          approval,
          (current) => current.value.review,
          estimate: (review) =>
              estimateEthereumOutgoingUsd(review, _prices.priceOf),
        ),
      );
      prepared = (await approval.prepared).value;
      signed = await _ethereum.signPrepared(
        prepared,
        ensureActive: request.ensureActive,
        cancelled: request.cancelled,
      );
      request.ensureActive();
    } on _AuthCancelled {
      sheet.close();
      rethrow;
    } on DappException catch (error) {
      step.value = BrowserSendFailed(error.message);
      rethrow;
    } catch (_) {
      step.value = const BrowserSendFailed('Signing failed. Nothing was sent.');
      rethrow;
    }
    sheet.close();
    final hash = await _ethereum.sendSigned(signed, prepared);
    _record(request, hash, TxConfirmation.pending);
    return {'hash': hash};
  }

  /// Opens the app's Edit Gas Fee sheet over the review and re-prices the
  /// transaction with the user's choice. Site-priced fees stay specific to this
  /// transaction; other choices are saved as the default, as they are in-app.
  Future<void> _editGas(
    BuildContext context,
    DappSigningRequest request,
    ValueNotifier<PreparedEthereumTransaction> current,
  ) async {
    final prepared = current.value;
    final market = prepared.market;
    final selection = prepared.selection;
    if (market == null || selection == null) return;
    final navigator = Navigator.of(context);
    final pending = showEditGasFeeSheet(
      context,
      market: market,
      selection: selection,
      estimatedGasUsed: prepared.estimatedGas,
      defaultGasLimit: prepared.defaultGasLimit,
      ethPriceUsd: _prices.priceOf(evmNativeAssetId),
      persist:
          prepared.request.maxFeePerGas == null &&
          prepared.request.gasPrice == null,
    );
    // The launcher pushes synchronously. Capture that route without popping
    // anything so cancellation removes only this editor, even below newer UI.
    late final Route<dynamic> gasRoute;
    navigator.popUntil((route) {
      gasRoute = route;
      return true;
    });
    unawaited(
      request.cancelled.then((_) {
        if (gasRoute.isActive && navigator.mounted) {
          navigator.removeRoute(gasRoute);
        }
      }),
    );
    final result = await pending;
    // A request cancelled while the sheet was up has nothing left to price.
    if (result == null || !identical(current.value, prepared)) return;
    try {
      request.ensureActive();
      current.value = _ethereum.applyGas(prepared, result);
    } on DappException catch (error) {
      if (context.mounted) {
        AppSnackBar.show(context, error.message, type: AppSnackBarType.error);
      }
    }
  }

  /// Every transaction of [request], each prepared for signing, plus one
  /// review combining them. Up to [kMaxSimulatedSolanaBatch] are simulated,
  /// side by side; a larger batch is not simulated at all, and its review
  /// says so.
  Future<PreparedSolanaBatch> _prepareBatch(DappSigningRequest request) async {
    final payloads = request.payloads;
    final simulate = payloads.length <= kMaxSimulatedSolanaBatch;
    final prepared = simulate
        ? await Future.wait([
            for (final payload in payloads)
              _adapter.prepareTransaction(
                transaction: payload,
                walletId: request.wallet.id,
                address: request.wallet.address,
                origin: request.context.canonicalOrigin,
                chain: request.chain,
              ),
          ])
        : [
            for (final payload in payloads)
              SolanaDappAdapter.describeUnsimulated(
                transaction: payload,
                walletId: request.wallet.id,
                address: request.wallet.address,
                origin: request.context.canonicalOrigin,
                chain: request.chain,
              ),
          ];
    return PreparedSolanaBatch(
      prepared,
      combineSolanaReviews(
        [for (final p in prepared) p.review],
        error: simulate
            ? null
            : 'This batch has ${payloads.length} transactions. mallow simulates batches of up to $kMaxSimulatedSolanaBatch, so the effects and cost of these could not be checked.',
      ),
    );
  }

  /// [request]'s transactions as received, unsimulated: what an approval
  /// given before the review signs.
  PreparedSolanaBatch _unsimulatedBatch(DappSigningRequest request) {
    final prepared = [
      for (final payload in request.payloads)
        _adapter.describeTransaction(
          transaction: payload,
          walletId: request.wallet.id,
          address: request.wallet.address,
          origin: request.context.canonicalOrigin,
          chain: request.chain,
        ),
    ];
    return PreparedSolanaBatch(
      prepared,
      combineSolanaReviews([for (final p in prepared) p.review]),
    );
  }

  static String _batchTitle(int count) =>
      count > 1 ? 'Review $count transactions' : 'Review transaction';

  Widget _transactionReview(
    DappSigningRequest request,
    SimulationReview review,
    VoidCallback reject,
    VoidCallback? approve, {
    String approveLabel = 'Approve',
    String title = 'Review transaction',
    String? batchNotice,
    TransactionExpiryView? expiry,
  }) => SimulationReviewSheet(
    review: review,
    onReject: reject,
    onApprove: approve,
    priceOf: _prices.priceOf,
    openExternal: _openExternal,
    originIcon: _originIcon(request),
    title: title,
    approveLabel: approveLabel,
    batchNotice: batchNotice,
    expiry: expiry,
  );

  /// Starts the expiry countdown for a Solana request's transactions. The
  /// caller stops it once the sheet is decided.
  _Expiry _expiryFor(DappSigningRequest request) {
    final clock = SolanaExpiryClock(
      payloads: request.payloads,
      chain: request.chain,
      // Read per call, so a failure reaches the clock, which only ever
      // degrades to an unmeasured expiry, never the signing flow.
      rpc: (chain, method, params) => _adapter.rpc(chain, method, params),
      slotTime: _slotTime,
    )..start();
    return (
      clock: clock,
      view: TransactionExpiryView(
        state: clock.state,
        origin: request.context.origin.host,
        // A hardware signature takes long enough to use up most of a
        // blockhash's half minute, so its warning shows from the start.
        slowSigner: switch (request.wallet.type) {
          WalletType.ledger => 'Ledger',
          WalletType.keystone => 'Keystone',
          _ => null,
        },
        siteSubmits: request.method != 'signAndSendTransaction',
      ),
    );
  }

  Widget _originIcon(DappSigningRequest request) => BrowserSiteTile(
    host: request.context.origin.host,
    iconUrl: _iconUrl(request.context),
    size: 22,
  );

  Future<void> _authorize(
    DappSigningRequest request,
    AppFlow flow,
    double? usd,
  ) async {
    request.ensureActive();
    final outcome = await _authGate.authorize(
      usdValue: usd,
      flow: FlowKey(_chainOf(request), flow),
    );
    request.ensureActive();
    if (outcome == TransactionAuthOutcome.cancelled)
      throw const _AuthCancelled();
    if (outcome != TransactionAuthOutcome.allowed)
      throw DappException(
        4001,
        outcome.disabledMessage ??
            'Authentication was cancelled or unavailable.',
      );
  }

  static Chain _chainOf(DappSigningRequest request) =>
      request.chain == tezosMainnet
      ? Chain.tezos
      : request.chain == ethereumMainnet
      ? Chain.ethereum
      : Chain.solana;

  /// Report a website transaction to the analytics transaction ledger. The
  /// network comes from the request, not the build: a non-production build
  /// serves sites on either Solana cluster.
  void _record(
    DappSigningRequest request,
    String signature,
    TxConfirmation confirmation,
  ) => recordSubmittedTransaction(
    chain: _chainOf(request),
    flow: AppFlow.browserTransaction,
    signature: signature,
    walletAddress: () => request.wallet.address,
    confirmation: confirmation,
    network: request.chain == 'solana:devnet' ? 'devnet' : 'mainnet',
  );

  /// The icon the request came with, else the requesting tab's, only while
  /// that tab still shows the same host.
  Uri? _iconUrl(DappFrameContext frame) {
    if (frame.iconUrl case final icon?) return icon;
    final tab = (_session ?? BrowserSession.instance).tabs
        .where((t) => t.id == frame.tabId)
        .firstOrNull;
    return tab?.url?.host == frame.origin.host ? tab?.iconUrl : null;
  }

  double? _outgoingUsd(SimulationReview review) =>
      estimateBrowserOutgoingUsd(review, _prices.priceOf);

  /// The outgoing value step-up auth judges [approval] by. Approved before
  /// its review, a transaction's effects were never seen, so its value is
  /// unknown, which the gate counts as over any threshold.
  Future<double?> _approvedUsd<T>(
    _Approval<T> approval,
    SimulationReview Function(T prepared) reviewOf, {
    double? Function(SimulationReview review)? estimate,
  }) async {
    if (!approval.reviewed) return null;
    return (estimate ?? _outgoingUsd)(reviewOf(await approval.prepared));
  }

  Future<bool> _showReview(
    BuildContext context,
    DappSigningRequest request,
    Widget Function(VoidCallback, VoidCallback) builder,
  ) => _present(context, request, builder).decision;

  /// Pushes a review sheet. Rejecting or dismissing it resolves the decision
  /// false and closes it. Approving resolves true and closes it too, unless
  /// [onApprove] is given: then the sheet stays up for the caller to drive and
  /// close.
  _Presented _present(
    BuildContext context,
    DappSigningRequest request,
    Widget Function(VoidCallback, VoidCallback) builder, {
    VoidCallback? onApprove,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final decision = Completer<bool>();
    // A popup route keeps the website's page current; a page route would
    // suspend it and cancel this request. Dismissing the sheet rejects.
    late final ModalBottomSheetRoute<void> route;
    void decide(bool approved) {
      if (decision.isCompleted || !route.isCurrent) return;
      decision.complete(approved);
      if (approved && onApprove != null) {
        onApprove();
      } else {
        navigator.pop();
      }
    }

    route = mallowSheetRoute<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) =>
          builder(() => decide(false), () => decide(true)),
    );
    // Remove this exact route; cancellation must never pop a newer auth or app
    // route. Guarding the signature alone would leave stale approval UI alive.
    unawaited(
      request.cancelled.then((_) {
        if (route.isActive && navigator.mounted) navigator.removeRoute(route);
      }),
    );
    unawaited(
      navigator.push(route).then((_) {
        if (!decision.isCompleted) decision.complete(false);
      }),
    );
    return (
      decision: decision.future,
      close: () {
        if (!route.isActive || !navigator.mounted) return;
        if (route.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(route);
        }
      },
    );
  }

  /// [_present] for a transaction, opened at once rather than after its
  /// simulation. Until [prepare] returns, the sheet shows what is already
  /// known; then the [review] built from its result.
  ///
  /// The user need not wait for the review: approving the placeholder
  /// approves the transaction as [signable] makes it, without the simulation.
  /// Such an approval comes back with `reviewed` false, and its caller must
  /// then treat the value as unknown. Without [signable] the placeholder
  /// offers only Close, as a view-only review does.
  ///
  /// `approval` fails with [rejection] when the user rejects, and with the
  /// error of a failed [prepare]; the sheet then says why until it is closed.
  /// [frame] wraps the sheet's content, as [BrowserSendSheet] does.
  _PresentedReview<T> _presentPrepared<T>(
    BuildContext context,
    DappSigningRequest request, {
    required Future<T> Function() prepare,
    required Widget Function(
      T prepared,
      VoidCallback reject,
      VoidCallback approve,
    )
    review,
    Future<T> Function()? signable,
    Widget Function(Widget content)? frame,
    VoidCallback? onApprove,
    _Expiry? expiry,
    String title = 'Review transaction',
    String approveLabel = 'Approve',
    DappException rejection = const DappException(
      4001,
      'Transaction rejected.',
    ),
  }) {
    final state = ValueNotifier<_Preparation<T>>(_Preparing<T>());
    var approvedEarly = false;
    final sheet = _present(context, request, (reject, approve) {
      final content = ValueListenableBuilder<_Preparation<T>>(
        valueListenable: state,
        builder: (_, preparation, _) => SheetStepSwitcher(
          child: switch (preparation) {
            _Preparing() => KeyedSubtree(
              key: const ValueKey('preparing'),
              child: SimulationPendingSheet(
                origin: request.context.canonicalOrigin,
                originIcon: _originIcon(request),
                address: request.wallet.address,
                chain: request.chain,
                title: title,
                approveLabel: approveLabel,
                expiry: expiry?.view,
                onReject: reject,
                onApprove: signable == null
                    ? null
                    : () {
                        approvedEarly = true;
                        approve();
                      },
              ),
            ),
            _Prepared(:final value) => KeyedSubtree(
              key: const ValueKey('review'),
              child: review(value, reject, approve),
            ),
            _Unprepared(:final message) => KeyedSubtree(
              key: const ValueKey('unprepared'),
              child: SimulationUnavailableSheet(
                origin: request.context.canonicalOrigin,
                originIcon: _originIcon(request),
                message: message,
                onClose: reject,
              ),
            ),
          },
        ),
      );
      return frame == null ? content : frame(content);
    }, onApprove: onApprove);

    Future<_Approval<T>> run() async {
      final first = await Future.any<Object>([
        prepare().then<Object>(
          (value) => _Ready(value),
          onError: (Object error, StackTrace stack) => _Failed(error, stack),
        ),
        sheet.decision.then<Object>((approved) => approved),
      ]);
      if (first case final bool approved) {
        // Decided on the placeholder.
        request.ensureActive();
        if (!approved) throw _rejection(rejection, expiry);
        // Awaited by the caller after step-up auth, which may fail first.
        return (prepared: signable!()..ignore(), reviewed: false);
      }
      if (first case _Failed(:final error, :final stack)) {
        var active = context.mounted;
        try {
          request.ensureActive();
        } on DappException {
          active = false;
        }
        if (active) {
          state.value = _Unprepared(
            error is DappException
                ? error.message
                : 'This transaction could not be prepared for review.',
          );
        } else {
          sheet.close();
        }
        Error.throwWithStackTrace(error, stack);
      }
      final value = (first as _Ready<T>).value;
      try {
        request.ensureActive();
        if (!context.mounted) {
          throw const DappException(4001, 'Request cancelled.');
        }
      } catch (_) {
        sheet.close();
        rethrow;
      }
      state.value = _Prepared(value);
      final approved = await sheet.decision;
      request.ensureActive();
      if (!approved) throw _rejection(rejection, expiry);
      // A placeholder approval that raced the review in still saw no review.
      return (prepared: Future.value(value), reviewed: !approvedEarly);
    }

    return (approval: run(), close: sheet.close);
  }
}

/// What the site is told when the sheet closes unapproved: that the
/// transaction expired, when it had, so it can build a new one.
DappException _rejection(DappException rejection, _Expiry? expiry) =>
    expiry?.clock.expired ?? false
    ? const DappException(4001, 'Transaction expired. Request a new one.')
    : rejection;

/// A Solana review's expiry countdown and what its sheet shows of it.
typedef _Expiry = ({SolanaExpiryClock clock, TransactionExpiryView view});

/// Where a transaction sheet opened by `_presentPrepared` stands.
sealed class _Preparation<T> {
  const _Preparation();
}

final class _Preparing<T> extends _Preparation<T> {
  const _Preparing();
}

final class _Prepared<T> extends _Preparation<T> {
  const _Prepared(this.value);
  final T value;
}

final class _Unprepared<T> extends _Preparation<T> {
  const _Unprepared(this.message);
  final String message;
}

typedef _PresentedReview<T> = ({
  Future<_Approval<T>> approval,
  VoidCallback close,
});

/// An approved transaction, ready for step-up auth and signing once
/// [prepared] completes. [reviewed] is false when the user approved before the
/// review showed: its effects were never seen, so its value counts as unknown.
typedef _Approval<T> = ({Future<T> prepared, bool reviewed});

final class _Ready<T> {
  const _Ready(this.value);
  final T value;
}

final class _Failed {
  const _Failed(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

String _hex(List<int> bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

typedef _Presented = ({Future<bool> decision, VoidCallback close});

/// Step-up auth the user cancelled. Still a 4001 to the website; the send
/// sheet just closes rather than reporting it.
class _AuthCancelled extends DappException {
  const _AuthCancelled()
    : super(4001, 'Authentication was cancelled or unavailable.');
}

/// Outgoing movements cannot be netted against receipts for step-up auth.
/// Unknown interpretation or pricing stays unknown and triggers the gate.
double? estimateBrowserOutgoingUsd(
  SimulationReview review,
  double? Function(String) priceOf,
) {
  if (review.execution != SimulationExecution.succeeded ||
      review.coverage != SimulationCoverage.complete ||
      review.chain != 'solana:mainnet')
    return null;
  final gross = <String, BigInt>{};
  final net = <String, BigInt>{};
  final assets = <String, ReviewAsset>{};
  for (final fund in review.funds) {
    assets[fund.asset.id] = fund.asset;
    if (!fund.rawAmount.isNegative) continue;
    final amounts = fund.isNet ? net : gross;
    amounts.update(
      fund.asset.id,
      (amount) => amount + fund.rawAmount.abs(),
      ifAbsent: () => fund.rawAmount.abs(),
    );
  }
  if (review.feePayer == review.address) {
    if (review.feeLamports == null) return null;
    assets[solanaNativeMint] = const ReviewAsset(
      id: solanaNativeMint,
      symbol: 'SOL',
      decimals: 9,
    );
    gross.update(
      solanaNativeMint,
      (value) => value + BigInt.from(review.feeLamports!),
      ifAbsent: () => BigInt.from(review.feeLamports!),
    );
  }
  var total = 0.0;
  for (final id in {...gross.keys, ...net.keys}) {
    final outgoing = (gross[id] ?? BigInt.zero) > (net[id] ?? BigInt.zero)
        ? (gross[id] ?? BigInt.zero)
        : (net[id] ?? BigInt.zero);
    final price = priceOf(id);
    final decimals = assets[id]?.decimals;
    if (price == null || !price.isFinite || price < 0 || decimals == null)
      return null;
    final amount = double.tryParse(formatReviewAmount(outgoing, decimals));
    if (amount == null || !amount.isFinite) return null;
    total += amount * price;
    if (!total.isFinite) return null;
  }
  return total;
}

/// [estimateBrowserOutgoingUsd] for an Ethereum review: the value and token
/// amounts leaving the wallet plus the worst-case fee, or null when effects
/// are incomplete or any amount cannot be priced. Null trips the step-up gate:
/// most ERC-20s have no price here, and unknown value counts as over the
/// threshold.
double? estimateEthereumOutgoingUsd(
  SimulationReview review,
  double? Function(String) priceOf,
) {
  if (review.execution != SimulationExecution.succeeded ||
      review.coverage != SimulationCoverage.complete ||
      review.chain != ethereumMainnet)
    return null;
  final fee = review.maxNetworkFee ?? review.networkFee;
  if (fee == null) return null;
  final outgoing = <String, BigInt>{evmNativeAssetId: fee};
  final decimals = <String, int?>{evmNativeAssetId: 18};
  for (final fund in review.funds) {
    if (!fund.isNet || !fund.rawAmount.isNegative) continue;
    outgoing.update(
      fund.asset.id,
      (amount) => amount + fund.rawAmount.abs(),
      ifAbsent: () => fund.rawAmount.abs(),
    );
    decimals[fund.asset.id] = fund.asset.decimals;
  }
  // An NFT leaving the wallet has no price here, and a permission is worth
  // whatever it lets the spender take later; neither can be bounded.
  if (review.nfts.any((nft) => nft.from == review.address.toLowerCase()) ||
      review.accounts.any((a) => a.kind == AccountChangeKind.approve))
    return null;
  var total = 0.0;
  for (final MapEntry(key: id, value: amount) in outgoing.entries) {
    final price = priceOf(id);
    final places = decimals[id];
    if (price == null || !price.isFinite || price < 0 || places == null)
      return null;
    final units = double.tryParse(formatReviewAmount(amount, places));
    if (units == null || !units.isFinite) return null;
    total += units * price;
    if (!total.isFinite) return null;
  }
  return total;
}

/// What to tell the user when their Ledger did not sign a website's request.
/// Status words are the [chain] app's: for Ethereum, 0x6985 is a rejection on
/// the device, 0x6A84 a message too large for its memory, 0x6D00 / 0x6E00 a
/// missing or outdated app.
@visibleForTesting
String ledgerSigningFailure(Object error, {Chain chain = Chain.ethereum}) {
  if (chain == Chain.solana) {
    if (error is LedgerDeviceException) {
      switch (error.errorCode) {
        case 0x6985:
        case 0x6982:
          return 'You rejected it on your Ledger. Nothing was signed.';
        case 0x6A80:
        case 0x6A82:
        case 0xB008:
          // The Solana app refuses instructions it cannot display unless
          // blind signing is allowed.
          return 'Turn on Blind signing in the Solana app settings on your Ledger, then try again. Nothing was signed.';
        case 0x6D00:
        case 0x6E00:
          return 'Open the Solana app on your Ledger, and update it in Ledger Live if it is out of date. Nothing was signed.';
      }
    }
    if (error is DappException) return error.message;
    return 'Your Ledger did not sign this. Check that it is unlocked with the Solana app open, then try again.';
  }
  if (chain == Chain.tezos) {
    if (error is LedgerDeviceException) {
      switch (error.errorCode) {
        case 0x6985:
        case 0x6982:
          return 'You rejected it on your Ledger. Nothing was signed.';
        case 0x6d00:
        case 0x6e00:
          return 'Open the Tezos Wallet app on your Ledger, and update it in Ledger Live if needed. Nothing was signed.';
        case 0x9405:
        case 0x9001:
        case 0x9002:
        case 0x6a80:
          return 'The Tezos Wallet app could not review this request. Update the app in Ledger Live, then try again. Nothing was signed.';
        case 0x9200:
        case 0x6a84:
          return 'This request is too large for your Ledger to review. Nothing was signed.';
      }
    }
    if (error is DappException) return error.message;
    return 'Your Ledger did not sign this. Check that it is unlocked with the Tezos Wallet app open, then try again.';
  }
  if (error is LedgerDeviceException) {
    switch (error.errorCode) {
      case 0x6985:
      case 0x6982:
        return 'You rejected it on your Ledger. Nothing was signed.';
      case 0x6A80:
        // The Ethereum app refuses typed data it has no display metadata for
        // unless one of these settings is on; it shows the same instruction.
        return 'Turn on Raw messages or Blind signing in the Ethereum app settings on your Ledger, then try again. Nothing was signed.';
      case 0x6A84:
        return 'This message is too large for your Ledger to review. Nothing was signed.';
      case 0x6D00:
      case 0x6E00:
        return 'Open the Ethereum app on your Ledger, and update it in Ledger Live if it is out of date. Nothing was signed.';
    }
  }
  if (error is Eip712LedgerException) {
    return '${error.message} Nothing was signed.';
  }
  if (error is DappException) return error.message;
  return 'Your Ledger did not sign this. Check that it is unlocked with the Ethereum app open, then try again.';
}

/// Unknown contract effects keep the step-up value unknown and fail closed.
double? estimateTezosOutgoingUsd(
  SimulationReview review,
  double? Function(String) priceOf,
) {
  if (review.chain != tezosMainnet ||
      review.execution != SimulationExecution.succeeded ||
      review.coverage != SimulationCoverage.complete ||
      review.maxNetworkFee == null)
    return null;
  final price = priceOf(xtzMint);
  if (price == null || !price.isFinite || price < 0) return null;
  final outgoing = review.funds
      .where((f) => f.rawAmount.isNegative)
      .fold<BigInt>(
        review.maxNetworkFee!,
        (amount, fund) => amount + fund.rawAmount.abs(),
      );
  final total = outgoing.toDouble() / 1e6 * price;
  return total.isFinite ? total : null;
}
