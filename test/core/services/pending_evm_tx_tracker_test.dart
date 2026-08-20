import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/database/database.dart';
import 'package:mallow_wallet/core/models/account.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/network/evm_transfer_core.dart';
import 'package:mallow_wallet/core/services/pending_evm_tx_tracker.dart';
import 'package:mallow_wallet/core/session/session_manager.dart';
import 'package:mallow_wallet/features/portfolio/data/token_repository.dart';
import 'package:mallow_wallet/features/send/models/eth_gas.dart';
import 'package:mallow_wallet/shared/utils/chain.dart' show Chain;
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:web3dart/web3dart.dart';

import 'pending_evm_tx_tracker_test.mocks.dart';

const _wallet = '0x1111111111111111111111111111111111111111';
const _recipient = '0x2222222222222222222222222222222222222222';

/// EIP-55 casing, as wallets are stored — the tracker lowercases addresses for
/// nonce matching, so anything it hands to a portfolio consumer has to come
/// from the session instead.
const _mixedCaseWallet = '0xAbCdEf3333333333333333333333333333333333';

/// Records the balance-invalidation signals the tracker announces on the way
/// out. Only [notifyBalancesChanged] is reached from that path.
class _SpyTokenRepository extends Fake implements TokenRepository {
  final signalled = <String>[];

  @override
  void notifyBalancesChanged(String walletAddress) =>
      signalled.add(walletAddress);
}

/// The tracker's watcher: which broadcasts get recorded, how a consumed nonce
/// is classified, and how a replacement is shaped.
///
/// The classification rules are the part with teeth. A slot resolves only when
/// the chain says the nonce is gone, and *which* of the live hashes mined
/// decides what the user is told — assuming the newest one won would report a
/// cancel that actually lost the race as "cancelled", and a transport blip
/// misread as "no receipt" would delete a still-pending transaction the user
/// can no longer speed up.
@GenerateMocks([EthereumRpcService, SessionManager, WalletManager])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    provideDummy<BigInt>(BigInt.zero);
  });

  late MallowDatabase db;
  late MockEthereumRpcService rpc;
  late MockSessionManager session;
  late MockWalletManager walletManager;
  late PendingEvmTxTracker tracker;

  /// `latest` (mined) and `pending` (mempool) nonce counts the pass reads.
  void nonces({required int latest, required int pending}) {
    when(rpc.getLatestNonce(any)).thenAnswer((_) async => latest);
    when(rpc.getNonce(any)).thenAnswer((_) async => pending);
  }

  /// An Infura `suggestedGasFees` payload; gwei-decimal strings.
  Map<String, dynamic> feeMarket({
    String baseFee = '10',
    String marketMaxFee = '30',
    String marketTip = '2',
  }) => {
    'low': {
      'suggestedMaxPriorityFeePerGas': '1',
      'suggestedMaxFeePerGas': '20',
      'minWaitTimeEstimate': 15000,
      'maxWaitTimeEstimate': 30000,
    },
    'medium': {
      'suggestedMaxPriorityFeePerGas': marketTip,
      'suggestedMaxFeePerGas': marketMaxFee,
      'minWaitTimeEstimate': 15000,
      'maxWaitTimeEstimate': 30000,
    },
    'estimatedBaseFee': baseFee,
    'networkCongestion': 0.5,
    'latestPriorityFeeRange': ['1', '2'],
    'historicalBaseFeeRange': ['8', '12'],
    'historicalPriorityFeeRange': ['1', '3'],
  };

  /// The caps the Cancel sheet would quote for [entry] right now — the same
  /// value `promptCancel` hands to `cancel`.
  Future<EvmFeeCaps> quotedCancelCaps(PendingEvmTx entry) async =>
      cancelCapsFor(entry, await EthGasMarket.fetch(rpc));

  TransactionReceipt receipt({required bool success}) => TransactionReceipt(
    transactionHash: Uint8List(32),
    transactionIndex: 0,
    blockHash: Uint8List(32),
    cumulativeGasUsed: BigInt.from(21000),
    status: success,
  );

  Future<void> registerBroadcast({
    int nonce = 5,
    String hash = '0xoriginal',
    PendingTxCandidateRole role = PendingTxCandidateRole.original,
    PendingEvmTxKind kind = PendingEvmTxKind.send,
    int maxFee = 100,
    int tip = 10,
    String wallet = _wallet,
  }) => tracker.register(
    PendingEvmBroadcast(
      walletAddress: wallet,
      nonce: nonce,
      chainId: 1,
      kind: kind,
      role: role,
      toAddress: _recipient,
      valueWei: BigInt.from(1000),
      data: '0xa9059cbb',
      gasLimit: 90000,
      maxFeePerGas: BigInt.from(maxFee),
      maxPriorityFeePerGas: BigInt.from(tip),
      hash: hash,
      metadata: const PendingTxMetadata(title: 'Send'),
    ),
  );

  setUp(() {
    db = MallowDatabase.forTesting(NativeDatabase.memory());
    rpc = MockEthereumRpcService();
    session = MockSessionManager();
    walletManager = MockWalletManager();
    tracker = PendingEvmTxTracker(db, rpc, session, walletManager);

    when(rpc.chainId).thenReturn(1);
    when(session.sessionWalletsForChain(Chain.ethereum)).thenReturn(const [
      WalletInfo(
        id: 'w1',
        address: _wallet,
        name: 'EVM',
        walletType: WalletType.hd,
        chain: 'ethereum',
      ),
    ]);
    when(rpc.getTransactionReceipt(any)).thenAnswer((_) async => null);
  });

  tearDown(() async {
    tracker.stop();
    // Registration is fire-and-forget; let the in-flight writes land before the
    // database goes away.
    await pumpEventQueue();
    await db.close();
    if (GetIt.instance.isRegistered<PendingEvmTxTracker>()) {
      await GetIt.instance.unregister<PendingEvmTxTracker>();
    }
  });

  group('registration', () {
    test('an original broadcast opens a nonce slot', () async {
      await registerBroadcast();

      expect(tracker.entries, hasLength(1));
      final entry = tracker.entries.single;
      expect(entry.nonce, 5);
      expect(entry.kind, PendingEvmTxKind.send);
      expect(entry.status, PendingEvmTxStatus.pending);
      expect(entry.gasLimit, 90000);
      expect(entry.candidates.single.hash, '0xoriginal');
    });

    test(
      'the wallet address is lowercased so it matches the RPC reads',
      () async {
        await tracker.register(
          PendingEvmBroadcast(
            walletAddress: '0xAbCdEf1111111111111111111111111111111111',
            nonce: 1,
            chainId: 1,
            kind: PendingEvmTxKind.send,
            role: PendingTxCandidateRole.original,
            toAddress: _recipient,
            valueWei: BigInt.zero,
            data: '',
            gasLimit: 21000,
            maxFeePerGas: BigInt.from(1),
            maxPriorityFeePerGas: BigInt.from(1),
            hash: '0x1',
          ),
        );

        final stored = await db.getPendingEvmTransaction(
          '0xabcdef1111111111111111111111111111111111',
          1,
        );
        expect(stored, isNotNull);
      },
    );

    test(
      'a speed-up appends a candidate instead of adding a second entry',
      () async {
        await registerBroadcast();
        await registerBroadcast(
          hash: '0xfaster',
          role: PendingTxCandidateRole.speedup,
          maxFee: 150,
        );

        expect(tracker.entries, hasLength(1));
        final entry = tracker.entries.single;
        expect(entry.candidates.map((c) => c.hash), ['0xoriginal', '0xfaster']);
        expect(entry.status, PendingEvmTxStatus.pending);
        // The floor for the *next* replacement follows the highest bid.
        expect(
          tracker.replacementFloorOf(entry)!.maxFeePerGas,
          BigInt.from(165),
        );
      },
    );

    test('a cancel candidate flips the slot to cancelling', () async {
      await registerBroadcast();
      await registerBroadcast(
        hash: '0xcancel',
        role: PendingTxCandidateRole.cancel,
      );

      expect(tracker.entries.single.status, PendingEvmTxStatus.cancelling);
    });

    test('a broadcast with no metadata is still tracked', () async {
      // Every EVM broadcast must be recoverable, even from a flow that has not
      // been taught to describe itself yet.
      await tracker.register(
        PendingEvmBroadcast(
          walletAddress: _wallet,
          nonce: 2,
          chainId: 1,
          kind: PendingEvmTxKind.other,
          role: PendingTxCandidateRole.original,
          toAddress: _recipient,
          valueWei: BigInt.zero,
          data: '',
          gasLimit: 21000,
          maxFeePerGas: BigInt.from(1),
          maxPriorityFeePerGas: BigInt.from(1),
          hash: '0x1',
        ),
      );

      expect(tracker.entries.single.metadata.title, 'Transaction');
    });
  });

  group('resolution', () {
    test('a mined non-cancel candidate resolves as confirmed', () async {
      await registerBroadcast();
      nonces(latest: 6, pending: 6);
      when(
        rpc.getTransactionReceipt('0xoriginal'),
      ).thenAnswer((_) async => receipt(success: true));

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      await tracker.refreshNow();
      await pumpEventQueue();

      expect(resolutions.single.kind, PendingTxResolutionKind.confirmed);
      expect(resolutions.single.tx.nonce, 5);
      expect(tracker.entries, isEmpty);
      expect(await db.getPendingEvmTransactions(), isEmpty);
    });

    // WHY: a resolution is the only proof in the EVM pipeline that a
    // transaction actually mined — the transfer funnel returns its hash on an
    // inclusion-wait timeout too, so the send flow's success step cannot be the
    // trigger (refetching then writes the *pre-send* balance back into the
    // cache and announces it as post-send). Nothing else re-reads balances:
    // the portfolio signal fired here reloads the art portfolio only.
    test(
      'a resolved slot refreshes the session wallets\' token balances',
      () async {
        final repo = _SpyTokenRepository();
        GetIt.instance.registerSingleton<TokenRepository>(repo);
        addTearDown(() => GetIt.instance.unregister<TokenRepository>());
        // Mixed case on purpose: the balance cache and the portfolio blocs' scopes
        // are keyed by the wallet's own casing, so signalling the lowercased
        // address the nonce reads use would be dropped by every subscriber.
        when(session.sessionWalletsForChain(Chain.ethereum)).thenReturn(const [
          WalletInfo(
            id: 'w1',
            address: _mixedCaseWallet,
            name: 'EVM',
            walletType: WalletType.hd,
            chain: 'ethereum',
          ),
        ]);
        await registerBroadcast(wallet: _mixedCaseWallet);
        nonces(latest: 6, pending: 6);
        when(
          rpc.getTransactionReceipt('0xoriginal'),
        ).thenAnswer((_) async => receipt(success: true));

        await tracker.refreshNow();
        await pumpEventQueue();

        expect(repo.signalled, [_mixedCaseWallet]);
      },
    );

    test('an unresolved pass leaves the balances alone', () async {
      final repo = _SpyTokenRepository();
      GetIt.instance.registerSingleton<TokenRepository>(repo);
      addTearDown(() => GetIt.instance.unregister<TokenRepository>());
      await registerBroadcast();
      // The nonce is still in the mempool — nothing mined, nothing to re-read.
      nonces(latest: 5, pending: 6);

      await tracker.refreshNow();
      await pumpEventQueue();

      expect(repo.signalled, isEmpty);
    });

    test('a receipt with status 0x0 resolves as reverted', () async {
      await registerBroadcast();
      nonces(latest: 6, pending: 6);
      when(
        rpc.getTransactionReceipt('0xoriginal'),
      ).thenAnswer((_) async => receipt(success: false));

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      await tracker.refreshNow();
      await pumpEventQueue();

      expect(resolutions.single.kind, PendingTxResolutionKind.reverted);
    });

    test('classification follows the hash that mined, not the newest', () async {
      // After a cancel, both hashes are live. If the *original* wins the race
      // the user's funds moved — reporting "cancelled" because a cancel was the
      // last thing broadcast would be a lie about where their money went.
      await registerBroadcast();
      await registerBroadcast(
        hash: '0xcancel',
        role: PendingTxCandidateRole.cancel,
      );
      nonces(latest: 6, pending: 6);
      when(
        rpc.getTransactionReceipt('0xoriginal'),
      ).thenAnswer((_) async => receipt(success: true));

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      await tracker.refreshNow();
      await pumpEventQueue();

      expect(resolutions.single.kind, PendingTxResolutionKind.confirmed);
    });

    test('a mined cancel candidate resolves as cancelled', () async {
      await registerBroadcast();
      await registerBroadcast(
        hash: '0xcancel',
        role: PendingTxCandidateRole.cancel,
      );
      nonces(latest: 6, pending: 6);
      when(
        rpc.getTransactionReceipt('0xcancel'),
      ).thenAnswer((_) async => receipt(success: true));

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      await tracker.refreshNow();
      await pumpEventQueue();

      expect(resolutions.single.kind, PendingTxResolutionKind.cancelled);
    });

    test(
      'a consumed nonce with no matching receipt resolves as replaced',
      () async {
        await registerBroadcast();
        nonces(latest: 6, pending: 6);
        // No candidate has a receipt: some transaction we never saw took the slot.

        final resolutions = <PendingTxResolution>[];
        final sub = tracker.resolutions.listen(resolutions.add);
        addTearDown(sub.cancel);

        await tracker.refreshNow();
        await pumpEventQueue();

        expect(resolutions.single.kind, PendingTxResolutionKind.replaced);
        expect(tracker.entries, isEmpty);
      },
    );

    test('a still-unmined nonce is left alone', () async {
      await registerBroadcast();
      nonces(latest: 5, pending: 6);

      await tracker.refreshNow();

      expect(tracker.entries, hasLength(1));
    });

    test('a row with a corrupt candidates blob still resolves', () async {
      // The decode runs on every pass *before* the row's delete: a throw there
      // aborts the pass, so the poisoned row can never be removed — and no
      // other entry ever resolves either, because the pass dies with it.
      await db.upsertPendingEvmTransaction(
        PendingEvmTransactionsCompanion.insert(
          walletAddress: _wallet,
          nonce: 5,
          chainId: 1,
          kind: PendingEvmTxKind.send.name,
          status: PendingEvmTxStatus.pending.name,
          toAddress: _recipient,
          valueWei: '1000',
          data: '',
          gasLimit: 21000,
          metadataJson: '{truncated',
          candidatesJson: '[{"hash": "0xor',
          createdAt: 0,
        ),
      );
      nonces(latest: 6, pending: 6);

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      await tracker.refreshNow();
      await pumpEventQueue();

      // No candidate hash survived the corruption, so the slot can only be
      // reported as taken by a transaction we don't know.
      expect(resolutions.single.kind, PendingTxResolutionKind.replaced);
      expect(await db.getPendingEvmTransactions(), isEmpty);
    });

    test('a failed receipt read leaves the row for the next pass', () async {
      // A transport blip is not evidence the transaction did not mine; deleting
      // on it would strand a still-replaceable transaction.
      await registerBroadcast();
      nonces(latest: 6, pending: 6);
      when(
        rpc.getTransactionReceipt('0xoriginal'),
      ).thenThrow(const EthereumRpcException('connection reset'));

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      await tracker.refreshNow();
      await pumpEventQueue();

      expect(resolutions, isEmpty);
      expect(tracker.entries, hasLength(1));
    });
  });

  // WHY: the app-wide toast exists for a transaction that outlived the flow that
  // sent it. Every normal send also registers here and then waits out its own
  // confirmation behind the pipeline's success step, so announcing every
  // resolution puts "Transaction confirmed" on top of the screen that just said
  // it — on every send. A claim moves the notice to whoever is actually able to
  // report, and the two orderings below (watcher first / flow first) must each
  // produce exactly one report and leave no row behind.
  group('resolution claims', () {
    /// A confirmed receipt for the tracked hash and a chain that has consumed
    /// the slot — what both orderings resolve against.
    void slotMined() {
      nonces(latest: 6, pending: 6);
      when(
        rpc.getTransactionReceipt('0xoriginal'),
      ).thenAnswer((_) async => receipt(success: true));
    }

    test(
      'the flow reporting first retires the row without announcing',
      () async {
        await registerBroadcast();
        tracker.claimResolution(_wallet, 5);
        slotMined();

        final resolutions = <PendingTxResolution>[];
        final sub = tracker.resolutions.listen(resolutions.add);
        addTearDown(sub.cancel);

        // The funnel's own waitForConfirmation returned while the user is still
        // looking at the pipeline: it shows the success step itself.
        await tracker.resolutionReported(_wallet, 5);
        await pumpEventQueue();

        expect(resolutions, isEmpty);
        // Reported does not mean "forget it": the row is retired by the pass
        // resolutionReported triggers, so nothing lingers in Pending.
        expect(tracker.entries, isEmpty);
        expect(await db.getPendingEvmTransactions(), isEmpty);
      },
    );

    test(
      'a watcher pass while the flow is still waiting withholds the toast',
      () async {
        await registerBroadcast();
        tracker.claimResolution(_wallet, 5);
        slotMined();

        final resolutions = <PendingTxResolution>[];
        final sub = tracker.resolutions.listen(resolutions.add);
        addTearDown(sub.cancel);

        // The 8 s pass beats waitForConfirmation. The user is still in the flow,
        // so the toast must not fire — but the slot still resolves.
        await tracker.refreshNow();
        await pumpEventQueue();

        expect(resolutions, isEmpty);
        expect(tracker.entries, isEmpty);

        // …and the flow reporting afterwards must not re-announce it either.
        await tracker.resolutionReported(_wallet, 5);
        await pumpEventQueue();

        expect(resolutions, isEmpty);
      },
    );

    test('an early exit hands the toast back to the tracker', () async {
      await registerBroadcast();
      tracker.claimResolution(_wallet, 5);
      slotMined();

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      // "Done" tapped while the inclusion wait was still running: the success
      // step will never render, so the toast is the user's only report.
      tracker.releaseResolutionClaim(_wallet, 5);
      await tracker.refreshNow();
      await pumpEventQueue();

      expect(resolutions.single.kind, PendingTxResolutionKind.confirmed);
      expect(tracker.entries, isEmpty);

      // The funnel's wait returns long after the user left; it must not be able
      // to un-report what the toast already said.
      await tracker.resolutionReported(_wallet, 5);
      await pumpEventQueue();

      expect(resolutions, hasLength(1));
    });

    test(
      'an early exit after the pass announces the withheld resolution',
      () async {
        await registerBroadcast();
        tracker.claimResolution(_wallet, 5);
        slotMined();

        final resolutions = <PendingTxResolution>[];
        final sub = tracker.resolutions.listen(resolutions.add);
        addTearDown(sub.cancel);

        // Pass resolves (withheld), *then* the user leaves before the flow could
        // report. Dropping the withheld resolution here would tell the user
        // nothing at all about a transaction that has already confirmed.
        await tracker.refreshNow();
        await pumpEventQueue();
        expect(resolutions, isEmpty);

        tracker.releaseResolutionClaim(_wallet, 5);
        await pumpEventQueue();

        expect(resolutions.single.kind, PendingTxResolutionKind.confirmed);
      },
    );

    test('a revert still announces after the flow reported success', () async {
      // waitForConfirmation only waits for a *receipt*, so the pipeline can show
      // success for a transaction that reverted. The claim mutes the duplicate
      // confirmation, never a contradiction of it.
      await registerBroadcast();
      tracker.claimResolution(_wallet, 5);
      nonces(latest: 6, pending: 6);
      when(
        rpc.getTransactionReceipt('0xoriginal'),
      ).thenAnswer((_) async => receipt(success: false));

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      await tracker.resolutionReported(_wallet, 5);
      await pumpEventQueue();

      expect(resolutions.single.kind, PendingTxResolutionKind.reverted);
    });

    test('an unclaimed slot announces as before', () async {
      // The claim is opt-in: a replacement (awaitInclusion: false) and a
      // transaction restored from a previous app run have no flow to report for
      // them, so the toast stays their only report.
      await registerBroadcast();
      slotMined();

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      await tracker.refreshNow();
      await pumpEventQueue();

      expect(resolutions.single.kind, PendingTxResolutionKind.confirmed);
    });
  });

  group('nonce gaps', () {
    test('a gap is surfaced only after two consecutive passes', () async {
      // publicnode's mempool view is partial, so a gap can flicker for a pass;
      // surfacing it immediately would flash a phantom pending cell.
      nonces(latest: 5, pending: 7);

      await tracker.refreshNow();
      expect(
        tracker.entries,
        isEmpty,
        reason: 'debounced on the first sighting',
      );

      await tracker.refreshNow();
      expect(tracker.entries.map((e) => e.nonce), [5, 6]);
      expect(tracker.entries.every((e) => e.isExternal), isTrue);
    });

    test('only the lowest gap nonce is cancellable', () async {
      // Replacements mine in nonce order, so cancelling 6 while 5 is stuck
      // achieves nothing.
      nonces(latest: 5, pending: 7);
      await tracker.refreshNow();
      await tracker.refreshNow();

      expect(tracker.entries.map((e) => e.canCancelNow), [true, false]);
    });

    test('a gap that flickers away never surfaces', () async {
      nonces(latest: 5, pending: 7);
      await tracker.refreshNow();
      nonces(latest: 5, pending: 5);
      await tracker.refreshNow();
      nonces(latest: 5, pending: 7);
      await tracker.refreshNow();

      expect(tracker.entries, isEmpty);
    });

    test('a closed gap is removed and reported', () async {
      nonces(latest: 5, pending: 6);
      await tracker.refreshNow();
      await tracker.refreshNow();
      expect(tracker.entries, hasLength(1));

      final resolutions = <PendingTxResolution>[];
      final sub = tracker.resolutions.listen(resolutions.add);
      addTearDown(sub.cancel);

      nonces(latest: 6, pending: 6);
      await tracker.refreshNow();
      await pumpEventQueue();

      expect(tracker.entries, isEmpty);
      expect(resolutions.single.kind, PendingTxResolutionKind.confirmed);
    });

    test(
      'a gap that closes without the chain advancing is not a confirmation',
      () async {
        // pendingCount falling back to latest means the external transaction
        // left the mempool without mining — an eviction, not an inclusion. We
        // have no hash and no receipt for it, so announcing "Transaction
        // confirmed" (plus a portfolio and activity refresh) would tell the user
        // funds moved that never did.
        nonces(latest: 5, pending: 6);
        await tracker.refreshNow();
        await tracker.refreshNow();
        expect(tracker.entries, hasLength(1));

        final resolutions = <PendingTxResolution>[];
        final sub = tracker.resolutions.listen(resolutions.add);
        addTearDown(sub.cancel);

        nonces(latest: 5, pending: 5);
        await tracker.refreshNow();
        await pumpEventQueue();

        expect(tracker.entries, isEmpty, reason: 'the cell stops being shown');
        expect(resolutions, isEmpty);
      },
    );

    test('a nonce this app already tracks is not also a gap', () async {
      await registerBroadcast();
      nonces(latest: 5, pending: 6);
      await tracker.refreshNow();
      await tracker.refreshNow();

      expect(tracker.entries, hasLength(1));
      expect(tracker.entries.single.isExternal, isFalse);
    });
  });

  group('polling', () {
    test('an idle wallet is not polled', () async {
      // Nothing pending and no gap in sight: an 8 s tick is two nonce reads
      // that can only answer "nothing changed" — ~900 requests an hour per
      // wallet, paid by every user who never sends on EVM.
      nonces(latest: 5, pending: 5);

      tracker.start();
      await pumpEventQueue();

      expect(tracker.entries, isEmpty);
      expect(tracker.isPolling, isFalse);
    });

    test('registering a broadcast resumes polling', () async {
      nonces(latest: 5, pending: 5);
      tracker.start();
      await pumpEventQueue();
      expect(tracker.isPolling, isFalse);

      // A send must start being watched on the same turn it is recorded, not on
      // whatever tick happens to come next.
      await registerBroadcast();

      expect(tracker.isPolling, isTrue);
    });

    test(
      'a first gap sighting keeps polling so the debounce can finish',
      () async {
        // The gap is deliberately not surfaced yet; dropping the timer here would
        // strand it, because the second sighting only ever comes from a pass.
        nonces(latest: 5, pending: 6);

        tracker.start();
        await pumpEventQueue();

        expect(tracker.entries, isEmpty);
        expect(tracker.isPolling, isTrue);
      },
    );

    test('resolving the last entry stops polling', () async {
      await registerBroadcast();
      nonces(latest: 6, pending: 6);
      when(
        rpc.getTransactionReceipt('0xoriginal'),
      ).thenAnswer((_) async => receipt(success: true));

      tracker.start();
      await pumpEventQueue();

      expect(tracker.entries, isEmpty);
      expect(tracker.isPolling, isFalse);
    });
  });

  group('replacement broadcast', () {
    late Transaction signed;

    void stubSigning() {
      when(session.sessionWalletForAddressCaseInsensitive(any)).thenReturn(
        const WalletInfo(
          id: 'w1',
          address: _wallet,
          name: 'EVM',
          walletType: WalletType.hd,
          chain: 'ethereum',
        ),
      );
      when(
        walletManager.signEthereumTransaction(
          any,
          any,
          chainId: anyNamed('chainId'),
        ),
      ).thenAnswer((invocation) async {
        signed = invocation.positionalArguments[1] as Transaction;
        return Uint8List(1);
      });
      when(
        rpc.sendRawTransaction(any),
      ).thenAnswer((_) async => '0xreplacement');
      when(
        rpc.getBalance(any),
      ).thenAnswer((_) async => BigInt.from(10).pow(20));
      when(rpc.getSuggestedGasFees()).thenAnswer((_) async => feeMarket());
      // The funnel records the replacement through the locator.
      if (GetIt.instance.isRegistered<PendingEvmTxTracker>()) {
        GetIt.instance.unregister<PendingEvmTxTracker>();
      }
      GetIt.instance.registerSingleton<PendingEvmTxTracker>(tracker);
    }

    test('a speed-up reuses the nonce, payload and gas limit', () async {
      stubSigning();
      await registerBroadcast();

      await tracker.speedUp(
        tracker.entries.single,
        EthGasSelection(
          mode: EthGasMode.market,
          maxFeePerGas: BigInt.from(500),
          maxPriorityFeePerGas: BigInt.from(50),
          // A replacement must not change the gas limit; the sheet's value is
          // ignored in favour of the signed one.
          gasLimit: 21000,
        ),
      );

      expect(signed.nonce, 5);
      expect(signed.to!.with0x.toLowerCase(), _recipient);
      expect(signed.value!.getInWei, BigInt.from(1000));
      expect(signed.maxGas, 90000);
      expect(signed.maxFeePerGas!.getInWei, BigInt.from(500));
    });

    test('a speed-up below the 110% floor is raised to it', () async {
      // The node rejects anything under the bump, so a stale sheet value must
      // never reach the wire as-is.
      stubSigning();
      await registerBroadcast();

      await tracker.speedUp(
        tracker.entries.single,
        EthGasSelection(
          mode: EthGasMode.low,
          maxFeePerGas: BigInt.from(101),
          maxPriorityFeePerGas: BigInt.from(1),
          gasLimit: 90000,
        ),
      );

      expect(signed.maxFeePerGas!.getInWei, BigInt.from(110));
      expect(signed.maxPriorityFeePerGas!.getInWei, BigInt.from(11));
    });

    test(
      'a cancel is a self-send of zero at 21000 gas, floored at 110%',
      () async {
        stubSigning();
        // 100 gwei original: well above the 30 gwei market tier, so the floor is
        // what decides the cancel's fee.
        await registerBroadcast(maxFee: 100000000000, tip: 10000000000);

        final entry = tracker.entries.single;
        await tracker.cancel(entry, await quotedCancelCaps(entry));

        expect(signed.nonce, 5);
        expect(signed.to!.with0x.toLowerCase(), _wallet);
        expect(signed.value!.getInWei, BigInt.zero);
        expect(signed.data, isNull);
        expect(signed.maxGas, 21000);
        expect(signed.maxFeePerGas!.getInWei, BigInt.from(110000000000));
        expect(signed.maxPriorityFeePerGas!.getInWei, BigInt.from(11000000000));
      },
    );

    test(
      'a cancel appends the candidate and flips the slot to cancelling',
      () async {
        stubSigning();
        await registerBroadcast();

        final before = tracker.entries.single;
        await tracker.cancel(before, await quotedCancelCaps(before));
        await pumpEventQueue();

        final entry = tracker.entries.single;
        expect(entry.status, PendingEvmTxStatus.cancelling);
        expect(entry.candidates.map((c) => c.role), ['original', 'cancel']);
      },
    );

    test(
      'speeding up a cancelling slot bumps the cancel, not the original',
      () async {
        stubSigning();
        await registerBroadcast();
        final before = tracker.entries.single;
        await tracker.cancel(before, await quotedCancelCaps(before));
        await pumpEventQueue();

        await tracker.speedUp(
          tracker.entries.single,
          EthGasSelection(
            mode: EthGasMode.market,
            maxFeePerGas: BigInt.from(10).pow(12),
            maxPriorityFeePerGas: BigInt.from(10).pow(11),
            gasLimit: 90000,
          ),
        );

        // Resurrecting the original payload here would send the funds the user
        // just asked to cancel.
        expect(signed.to!.with0x.toLowerCase(), _wallet);
        expect(signed.value!.getInWei, BigInt.zero);
        expect(signed.maxGas, 21000);
      },
    );

    test('a blind cancel escalates x1.25 until the node accepts', () async {
      stubSigning();
      nonces(latest: 5, pending: 6);
      await tracker.refreshNow();
      await tracker.refreshNow();
      final external = tracker.entries.single;
      expect(external.isExternal, isTrue);
      final caps = await quotedCancelCaps(external);

      final bids = <BigInt>[];
      when(rpc.sendRawTransaction(any)).thenAnswer((_) async {
        bids.add(signed.maxFeePerGas!.getInWei);
        if (bids.length < 3) {
          throw const EthereumRpcException(
            'replacement transaction underpriced',
          );
        }
        return '0xcancel';
      });

      await tracker.cancel(external, caps);

      // Market tier is 30 gwei; each rejection lifts the bid by a quarter.
      expect(bids.map((b) => b.toString()), [
        '30000000000',
        '37500000000',
        '46875000000',
      ]);
    });

    test('a blind cancel gives up after 5 signatures', () async {
      stubSigning();
      nonces(latest: 5, pending: 6);
      await tracker.refreshNow();
      await tracker.refreshNow();
      final external = tracker.entries.single;
      final caps = await quotedCancelCaps(external);

      var attempts = 0;
      when(rpc.sendRawTransaction(any)).thenAnswer((_) async {
        attempts++;
        throw const EthereumRpcException('replacement transaction underpriced');
      });

      await expectLater(
        tracker.cancel(external, caps),
        throwsA(isA<EthereumRpcException>()),
      );
      expect(attempts, 5);
    });

    test('a cancel signs exactly the caps the sheet quoted', () async {
      // The Cancel sheet prices the fee and gates it against the balance from
      // this one value. Re-deriving it at signing time would sign a fee the user
      // never saw — and on a near-empty wallet, one they cannot cover, which
      // surfaces as the send funnel's insufficient-funds error on a transaction
      // they were told they could cancel.
      stubSigning();
      await registerBroadcast();
      final entry = tracker.entries.single;
      final quoted = await quotedCancelCaps(entry);

      // The user reads the sheet while the base fee runs away.
      when(
        rpc.getSuggestedGasFees(),
      ).thenAnswer((_) async => feeMarket(baseFee: '900', marketMaxFee: '950'));

      final result = await tracker.cancel(entry, quoted);

      expect(result, PendingTxReplacementResult.broadcast);
      expect(signed.maxFeePerGas!.getInWei, quoted.maxFeePerGas);
      expect(
        signed.maxPriorityFeePerGas!.getInWei,
        quoted.maxPriorityFeePerGas,
      );
    });

    test(
      'a nonce-too-low rejection reports that nothing was broadcast',
      () async {
        // The transaction the user tried to replace just confirmed. That is a
        // resolution to report, not a failure to show — and not a submission to
        // claim, because no replacement reached the wire and no second fee is due.
        stubSigning();
        await registerBroadcast();
        when(
          rpc.sendRawTransaction(any),
        ).thenThrow(const EthereumRpcException('nonce too low'));
        nonces(latest: 6, pending: 6);
        when(
          rpc.getTransactionReceipt('0xoriginal'),
        ).thenAnswer((_) async => receipt(success: true));

        final resolutions = <PendingTxResolution>[];
        final sub = tracker.resolutions.listen(resolutions.add);
        addTearDown(sub.cancel);

        final result = await tracker.speedUp(
          tracker.entries.single,
          EthGasSelection(
            mode: EthGasMode.market,
            maxFeePerGas: BigInt.from(1000),
            maxPriorityFeePerGas: BigInt.from(100),
            gasLimit: 90000,
          ),
        );
        await pumpEventQueue();

        expect(result, PendingTxReplacementResult.alreadyResolved);
        expect(resolutions.single.kind, PendingTxResolutionKind.confirmed);
        expect(tracker.entries, isEmpty);
      },
    );

    test('an already-known rebroadcast is treated as success', () async {
      stubSigning();
      await registerBroadcast();
      when(
        rpc.sendRawTransaction(any),
      ).thenThrow(const EthereumRpcException('already known'));

      // The identical raw transaction is already in the mempool, so a
      // replacement *is* on the wire — reporting it as submitted is honest.
      final result = await tracker.speedUp(
        tracker.entries.single,
        EthGasSelection(
          mode: EthGasMode.market,
          maxFeePerGas: BigInt.from(1000),
          maxPriorityFeePerGas: BigInt.from(100),
          gasLimit: 90000,
        ),
      );

      expect(result, PendingTxReplacementResult.broadcast);
    });

    test('a view-only wallet cannot broadcast a replacement', () async {
      stubSigning();
      await registerBroadcast();
      final entry = tracker.entries.single;
      final caps = await quotedCancelCaps(entry);
      when(session.sessionWalletForAddressCaseInsensitive(any)).thenReturn(
        const WalletInfo(
          id: 'w1',
          address: _wallet,
          name: 'Watched',
          walletType: WalletType.viewOnly,
          chain: 'ethereum',
        ),
      );

      await expectLater(
        tracker.cancel(entry, caps),
        throwsA(isA<EvmTransferBlockedException>()),
      );
      verifyNever(
        walletManager.signEthereumTransaction(
          any,
          any,
          chainId: anyNamed('chainId'),
        ),
      );
    });
  });
}
