import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/config/environment.dart';
import 'package:mallow_wallet/core/services/tx_landed_slots.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import 'package:mallow_wallet/shared/utils/chain.dart';

/// WalletManager stand-in — [SolanaRpcService.simulateWithDelta] never touches
/// the wallet, so a noSuchMethod shell avoids wiring its four real deps.
class _DummyWalletManager implements WalletManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used by simulateWithDelta');
}

/// Overrides the network seams [simulateWithDelta] depends on so the
/// pre→simulate→delta orchestration can be exercised without an RPC.
class _StubRpcService extends SolanaRpcService {
  _StubRpcService({this.preBalance, this.throwOnBalance = false})
    : super(_DummyWalletManager(), TxLandedSlots());

  final int? preBalance;
  final bool throwOnBalance;

  int balanceCalls = 0;
  List<String>? lastInspect;

  @override
  Future<int> getBalanceForAddress(String address) async {
    balanceCalls++;
    if (throwOnBalance) throw Exception('rpc down');
    return preBalance ?? (throw StateError('no preBalance configured'));
  }

  /// A canned simulate closure that records the inspect list it was handed.
  Future<SimulationResult> Function(List<String>) simulateReturning(
    SimulationResult result,
  ) {
    return (inspect) async {
      lastInspect = inspect;
      return result;
    };
  }
}

const _addr = 'HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH';

/// A real Token-2022 mint (PYUSD) and one of its live token accounts — the
/// account is deliberately *not* [_addr]'s ATA, so a builder that re-derives
/// the ATA instead of using the resolved holding fails the assertions.
const _mint = '2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo';
const _token2022Account = '47od2TPRvqJipfPVWZdyenLEngPw8hC36nDxiLyvGsEP';
const _blockhash = '11111111111111111111111111111111';

/// A real (devnet) Core burn-collection tx that fails simulation — one zeroed
/// signature + v0 message. The debug-mode inspect log parses these bytes with
/// [SignedTx.fromBytes], so the fixture must be structurally valid.
const _failingBurnTxBase64 =
    'AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAACAAQADBudhkKhd4nKO65LbGPx4g21k7EuLROTG97+yq9oeFtoiBS/DbaMy'
    's5YuPzLeC/W2d6BuyAVcWYAbBVhD7d8I9b0HH2PGVgER9+etZMoUvdamkyKjTLFxV/ORkfyz'
    'KQJKBgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwZGb+UhFzL/7K26csOb57yM'
    '5bvF9xJrLEObOkAAAACvVKsQvZelQqCe97OYid0M05SkzOnfps3Jfr4tI1unSOYfGh2FRsr3'
    'cq6BMrqg1kiZ0pWgzqsW7CzZ0xGMTV2/BAQABQIQJwAABAAJA2DjFgAAAAAABQQCAAAFAg0A'
    'AwIAAQwCAAAAAAAAAAAAAAAA';

void main() {
  // The SolanaRpcService constructor resolves Config.solanaRpcUrl. Point it at
  // an unroutable host so a test that forgets to stub fails fast instead of
  // reaching the real rpc.example.com default; tests that serve a local fake
  // overwrite this with their own ephemeral port.
  setUpAll(() {
    Config.debugOverrides['RPC_PROXY_BASE_URL'] = 'https://rpc.test';
  });

  tearDownAll(Config.debugOverrides.clear);

  // The priority-fee ceiling is a *ceiling* on the network's recommendation,
  // not the fee itself: raising it lets a congested network charge more, it
  // does not unconditionally spend more. These pin that, and that the global
  // Settings -> Priority Fee value is what feeds it — a setting that doesn't
  // reach `setComputeUnitPrice` is a setting that does nothing.
  group('SolanaRpcService.computeBudgetIxs', () {
    /// microLamports/CU carried by the ComputeBudget unit-price instruction.
    int unitPriceOf(List<Instruction> ixs) {
      final data = ixs.first.data.toList();
      // Layout: [3 (SetComputeUnitPrice), u64 little-endian microLamports].
      expect(data.first, 3);
      var value = 0;
      for (var i = 8; i >= 1; i--) {
        value = (value << 8) | data[i];
      }
      return value;
    }

    test('clamps the recommendation to the ceiling', () {
      // 200k CU budget, 50 000-lamport ceiling => 250 000 microLamports/CU max.
      final ixs = SolanaRpcService.computeBudgetIxs(
        computeBudget: 200000,
        recommendedMicroLamports: 5000000,
        maxPriorityFeeLamports: 50000,
      );
      expect(unitPriceOf(ixs), 250000);
    });

    test('a raised ceiling raises what the network may charge', () {
      // Turbo (10 000 000 lamports) over the same budget lifts the cap 200x,
      // so the same recommendation now passes through untouched.
      final ixs = SolanaRpcService.computeBudgetIxs(
        computeBudget: 200000,
        recommendedMicroLamports: 5000000,
        maxPriorityFeeLamports: 10000000,
      );
      expect(unitPriceOf(ixs), 5000000);
    });

    test('a raised ceiling does not raise a quiet network', () {
      // No recommendation (Helius unavailable / devnet) floors at the 15 000
      // lamport minimum regardless of the ceiling — the ceiling is not a bid.
      final auto = SolanaRpcService.computeBudgetIxs(
        computeBudget: 200000,
        maxPriorityFeeLamports: 50000,
      );
      final turbo = SolanaRpcService.computeBudgetIxs(
        computeBudget: 200000,
        maxPriorityFeeLamports: 10000000,
      );
      expect(unitPriceOf(auto), unitPriceOf(turbo));
    });

    // A ceiling below the 15 000-lamport floor makes `minMicro > maxMicro`,
    // and `num.clamp` THROWS ArgumentError on inverted bounds — this call is
    // outside every try/catch on the tx-build path, so a user typing
    // 0.00001 SOL into the priority-fee field would break *every* client-built
    // Solana transaction until they changed the setting back.
    test('a ceiling under the 15 000-lamport floor still builds', () {
      // Defensive bound-ordering guard. `PriorityFeeService` floors what it
      // resolves (see its test for the pref path), but a caller passing the
      // ceiling directly must not be able to invert the clamp window:
      // `num.clamp` THROWS ArgumentError when min > max, and this call sits
      // outside every try/catch on the tx-build path — it would break every
      // client-built Solana transaction, not just this one.
      final ixs = SolanaRpcService.computeBudgetIxs(
        computeBudget: 200000,
        recommendedMicroLamports: 5000000,
        maxPriorityFeeLamports: 10000,
      );
      // Floored to the 15 000-lamport window: 75 000 microLamports/CU.
      expect(unitPriceOf(ixs), 75000);
    });

    test('emits a unit-limit ix only when the budget is non-default', () {
      expect(
        SolanaRpcService.computeBudgetIxs(
          computeBudget: 200000,
          maxPriorityFeeLamports: 50000,
        ),
        hasLength(1),
      );
      expect(
        SolanaRpcService.computeBudgetIxs(
          computeBudget: 300000,
          maxPriorityFeeLamports: 50000,
        ),
        hasLength(2),
      );
    });
  });

  group('SolanaRpcService.simulateWithDelta', () {
    test('computes the signed post−pre delta on success', () async {
      final rpc = _StubRpcService(preBalance: 1_000_000_000);
      final sim = await rpc.simulateWithDelta(
        address: _addr,
        simulate: rpc.simulateReturning(
          const SimulationResult(
            success: true,
            inspectedAccountLamports: {_addr: 1_001_995_000},
          ),
        ),
      );
      // Burn refund (rent reclaimed) net of fee: +1_995_000.
      expect(sim.lamportsDelta, 1_995_000);
      expect(rpc.lastInspect, [_addr]);
    });

    test('preserves a negative delta (the payer spends SOL)', () async {
      final rpc = _StubRpcService(preBalance: 1_000_000_000);
      final sim = await rpc.simulateWithDelta(
        address: _addr,
        simulate: rpc.simulateReturning(
          const SimulationResult(
            success: true,
            inspectedAccountLamports: {_addr: 999_995_000},
          ),
        ),
      );
      expect(sim.lamportsDelta, -5000);
    });

    test('returns a null delta when the simulation fails', () async {
      final rpc = _StubRpcService(preBalance: 1_000_000_000);
      final sim = await rpc.simulateWithDelta(
        address: _addr,
        simulate: rpc.simulateReturning(
          const SimulationResult(
            success: false,
            error: 'Insufficient funds',
            inspectedAccountLamports: {_addr: 999_995_000},
          ),
        ),
      );
      expect(sim.lamportsDelta, isNull);
      expect(sim.result.success, isFalse);
    });

    test('returns a null delta when the account is not returned', () async {
      final rpc = _StubRpcService(preBalance: 1_000_000_000);
      final sim = await rpc.simulateWithDelta(
        address: _addr,
        simulate: rpc.simulateReturning(const SimulationResult(success: true)),
      );
      expect(sim.lamportsDelta, isNull);
    });

    test('skips the pre-balance roundtrip for a null address', () async {
      final rpc = _StubRpcService();
      final sim = await rpc.simulateWithDelta(
        address: null,
        simulate: rpc.simulateReturning(const SimulationResult(success: true)),
      );
      expect(rpc.balanceCalls, 0);
      expect(rpc.lastInspect, isEmpty);
      expect(sim.lamportsDelta, isNull);
      expect(sim.result.success, isTrue);
    });

    test(
      'tolerates a pre-balance fetch failure — still simulates, null delta',
      () async {
        final rpc = _StubRpcService(throwOnBalance: true);
        final sim = await rpc.simulateWithDelta(
          address: _addr,
          simulate: rpc.simulateReturning(
            const SimulationResult(success: true),
          ),
        );
        expect(rpc.balanceCalls, 1);
        // No inspection once the pre-balance is unavailable.
        expect(rpc.lastInspect, isEmpty);
        expect(sim.lamportsDelta, isNull);
        // The simulation result is still surfaced to the caller.
        expect(sim.result.success, isTrue);
      },
    );

    test(
      'rethrows a pre-balance fetch failure when requirePreBalance is set',
      () async {
        // The send flow treats a pre-balance RPC failure as a failed
        // simulation rather than degrading to a null delta, so the error must
        // propagate instead of being swallowed.
        final rpc = _StubRpcService(throwOnBalance: true);
        await expectLater(
          rpc.simulateWithDelta(
            address: _addr,
            simulate: rpc.simulateReturning(
              const SimulationResult(success: true),
            ),
            requirePreBalance: true,
          ),
          throwsA(isA<Exception>()),
        );
        expect(rpc.balanceCalls, 1);
        // The simulation never runs once the pre-balance fetch fails hard.
        expect(rpc.lastInspect, isNull);
      },
    );
  });

  group('SolanaRpcService.simulateEncodedTransaction', () {
    test(
      'a failed sim with inspect accounts surfaces the program error — the '
      'RPC returns `accounts: [null]` when the tx fails, which the SDK '
      'decoder throws on; the service must retry without inspection instead '
      'of reporting the decode TypeError (burn-collection sheet regression)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final sawAccountsConfig = <bool>[];
        server.listen((req) async {
          final body =
              jsonDecode(await utf8.decoder.bind(req).join())
                  as Map<String, dynamic>;
          final params = body['params'] as List<dynamic>;
          final config = params.length > 1
              ? params[1] as Map<String, dynamic>
              : const <String, dynamic>{};
          final hasAccounts = config.containsKey('accounts');
          sawAccountsConfig.add(hasAccounts);
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'context': {'slot': 1},
                'value': {
                  'err': {
                    'InstructionError': [
                      2,
                      {'Custom': 42},
                    ],
                  },
                  'logs': ['Program log: Error: Custom program error: 0x2a'],
                  // Failed sims carry no post-execution state — the real RPC
                  // nulls each requested account, not the whole array.
                  'accounts': hasAccounts ? [null] : null,
                  'unitsConsumed': 3047,
                },
              },
            }),
          );
          await req.response.close();
        });

        Config.debugOverrides['RPC_PROXY_BASE_URL'] =
            'http://127.0.0.1:${server.port}';
        final rpc = SolanaRpcService(_DummyWalletManager(), TxLandedSlots());

        final result = await rpc.simulateEncodedTransaction(
          _failingBurnTxBase64,
          inspectAccounts: const [_addr],
        );

        expect(result.success, isFalse);
        expect(result.error, contains('Instruction 2 failed'));
        expect(result.error, isNot(contains('Simulation request failed')));
        // First attempt carried the accounts config; the retry dropped it.
        expect(sawAccountsConfig, [true, false]);
      },
    );
  });

  group('SolanaRpcService.transactionStatus', () {
    /// Serves one canned `getSignatureStatuses` value and points the service's
    /// RPC URL at it.
    Future<SolanaRpcService> serving(
      Map<String, dynamic>? value, {
      required TxLandedSlots slots,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': {
              'context': {'slot': 400},
              'value': [value],
            },
          }),
        );
        await req.response.close();
      });
      Config.debugOverrides['RPC_PROXY_BASE_URL'] =
          'http://127.0.0.1:${server.port}';
      return SolanaRpcService(_DummyWalletManager(), slots);
    }

    test('decodes a bare-string TransactionError — Solana serializes the unit '
        'variants of TransactionError as plain strings, and the solana '
        "package's DTO casts `err` to Map<String, dynamic>?, so this status "
        'threw a TypeError that the confirmation poll could only read as "tx '
        'not seen yet"', () async {
      final rpc = await serving({
        'slot': 321,
        'confirmations': null,
        'confirmationStatus': 'finalized',
        'err': 'InsufficientFundsForFee',
      }, slots: TxLandedSlots());

      final status = await rpc.transactionStatus('sig');

      expect(status, isNotNull);
      expect(status!.landed, isTrue);
      expect(status.err, 'InsufficientFundsForFee');
    });

    test('records the landed slot of a successful tx and leaves a failed one '
        'unrecorded — the slot is the ordering floor for reads, and a tx that '
        'mutated nothing must not raise it', () async {
      final slots = TxLandedSlots();
      final ok = await serving({
        'slot': 321,
        'confirmations': null,
        'confirmationStatus': 'confirmed',
        'err': null,
      }, slots: slots);
      expect((await ok.transactionStatus('good'))!.landed, isTrue);
      expect(slots.slotFor('good'), 321);

      final bad = await serving({
        'slot': 322,
        'confirmations': null,
        'confirmationStatus': 'confirmed',
        'err': {
          'InstructionError': [
            2,
            {'Custom': 6003},
          ],
        },
      }, slots: slots);
      expect((await bad.transactionStatus('bad'))!.err, isNotNull);
      expect(slots.slotFor('bad'), isNull);
    });

    test('a signature the cluster has never seen is null, not an error — the '
        'confirmation poll reads null as "still in the mempool"', () async {
      final rpc = await serving(null, slots: TxLandedSlots());
      expect(await rpc.transactionStatus('sig'), isNull);
    });
  });

  group('SolanaRpcService.awaitConfirmationOrThrow', () {
    final tx = _rebroadcastFixture();

    test('a transient RPC error mid-poll is treated as "not seen yet", '
        'not a tx failure — the tx is already broadcast, so throwing here '
        'would surface a spurious failure for an edit/burn that actually '
        'landed on-chain', () async {
      final rpc = _ConfirmStubRpcService(
        statuses: [
          () => throw Exception('429 too many requests'),
          () => null,
          () => const SolanaTxStatus(landed: true),
        ],
      );
      await rpc.awaitConfirmationOrThrow(
        'sig',
        rebroadcast: tx,
        pollInterval: Duration.zero,
      );
      expect(rpc.statusCalls, 3);
    });

    test('never returns for a tx that stays unconfirmed until the blockhash '
        'expires — returning normally is what let the send flow report '
        '"Transaction sent" for a tx still sitting in the mempool, so the '
        'user sent it again and both landed', () async {
      final rpc = _ConfirmStubRpcService(
        statuses: [() => null],
        blockhashValid: false,
      );
      await expectLater(
        rpc.awaitConfirmationOrThrow(
          'sig',
          rebroadcast: tx,
          pollInterval: Duration.zero,
          expiryProbeAfter: Duration.zero,
        ),
        throwsA(isA<SolanaTransactionUnconfirmedException>()),
      );
    });

    test(
      're-broadcasts on every poll while the tx is unseen — a first '
      'broadcast dropped by a loaded leader is never retried otherwise '
      '(sends carry no priority fee), so the tx would expire in silence',
      () async {
        final rpc = _ConfirmStubRpcService(
          statuses: [
            () => null,
            () => null,
            () => null,
            () => const SolanaTxStatus(landed: true),
          ],
        );
        await rpc.awaitConfirmationOrThrow(
          'sig',
          rebroadcast: tx,
          pollInterval: Duration.zero,
        );
        // Three unseen polls → three re-sends before the fourth poll confirmed.
        expect(rpc.resends, 3);
        // Nothing probed expiry: the default 15 s grace hasn't elapsed.
        expect(rpc.blockhashChecks, 0);
      },
    );

    test('a poll that got a live `processed` status back re-sends nothing and '
        'probes nothing — the tx is already in a block, so the extra two RPCs '
        'per poll were pure waste against the rate-limited proxy', () async {
      final rpc = _ConfirmStubRpcService(
        statuses: [
          // Seen, but not yet at `confirmed` commitment.
          () => const SolanaTxStatus(landed: false),
          () => const SolanaTxStatus(landed: true),
        ],
      );
      await rpc.awaitConfirmationOrThrow(
        'sig',
        rebroadcast: tx,
        pollInterval: Duration.zero,
        // Probing is due from the first poll — only the "seen" gate can
        // suppress it.
        expiryProbeAfter: Duration.zero,
      );
      expect(rpc.resends, 0);
      expect(rpc.blockhashChecks, 0);
    });

    test('the expiry probe runs on a coarse cadence, not once per poll — a '
        'blockhash lives ~60–90 s, so asking every 2 s tripled the RPC cost of '
        'a slow confirmation for no extra information', () async {
      final rpc = _ConfirmStubRpcService(
        statuses: [
          ...List<SolanaTxStatus? Function()>.filled(11, () => null),
          () => const SolanaTxStatus(landed: true),
        ],
      );
      await rpc.awaitConfirmationOrThrow(
        'sig',
        rebroadcast: tx,
        pollInterval: Duration.zero,
        expiryProbeAfter: Duration.zero,
      );
      // 11 unseen polls, probing on the 1st, 6th and 11th (every 5th).
      expect(rpc.resends, 11);
      expect(rpc.blockhashChecks, 3);
    });

    test('a bare-string TransactionError is a terminal failure, not "not seen '
        'yet" — Solana serializes its unit error variants as plain strings, and '
        'a status decode that only accepted objects threw on every poll, so a '
        'landed-and-failed tx was reported as unconfirmed for the full '
        'blockhash lifetime while being re-broadcast', () async {
      final rpc = _ConfirmStubRpcService(
        statuses: [
          () => const SolanaTxStatus(landed: true, err: 'AccountInUse'),
        ],
      );
      await expectLater(
        rpc.awaitConfirmationOrThrow(
          'sig',
          rebroadcast: tx,
          pollInterval: Duration.zero,
        ),
        throwsA(
          isA<SolanaTransactionFailedException>().having(
            (e) => e.reason,
            'reason',
            'AccountInUse',
          ),
        ),
      );
      expect(rpc.resends, 0);
    });

    test('the hard maxWait cap ends the wait even when the node keeps '
        'reporting the blockhash as valid — an indeterminate result, never '
        'a success', () async {
      final rpc = _ConfirmStubRpcService(statuses: [() => null]);
      await expectLater(
        rpc.awaitConfirmationOrThrow(
          'sig',
          rebroadcast: tx,
          pollInterval: const Duration(milliseconds: 1),
          maxWait: const Duration(milliseconds: 20),
        ),
        throwsA(isA<SolanaTransactionUnconfirmedException>()),
      );
    });

    test('a landed tx whose runtime returned an error is a failure, not a '
        'success — the old poller only looked at confirmationStatus, so a '
        'reverted transfer reported "sent"', () async {
      final rpc = _ConfirmStubRpcService(
        statuses: [
          () => const SolanaTxStatus(
            landed: true,
            err: {
              'InstructionError': [
                2,
                {'Custom': 6003},
              ],
            },
          ),
        ],
      );
      await expectLater(
        rpc.awaitConfirmationOrThrow(
          'sig',
          rebroadcast: tx,
          pollInterval: Duration.zero,
        ),
        throwsA(
          isA<SolanaTransactionFailedException>().having(
            (e) => e.reason,
            'reason',
            contains('Instruction 2 failed'),
          ),
        ),
      );
    });
  });

  group('SolanaRpcService.buildBurnAndCloseTx', () {
    test('addresses burn + close to the program that owns the wallet\'s token '
        'account, not a re-derived ATA — a Token-2022 holding burned through '
        'the classic SPL program fails on-chain with IncorrectProgramId after '
        'the user has already signed', () async {
      final rpc = _BurnStubRpcService(
        holding: (
          address: _token2022Account,
          program: TokenProgramType.token2022Program,
          amount: 1500,
        ),
      );

      final txBase64 = await rpc.buildBurnAndCloseTx(tokenMint: _mint);
      final message = SignedTx.fromBytes(
        base64Decode(txBase64),
      ).compiledMessage;
      final keys = message.accountKeys.map((k) => k.toBase58()).toList();

      // Both ixs (burn, then close) target Token-2022...
      expect(message.instructions.map((i) => keys[i.programIdIndex]), [
        Token2022Program.programId,
        Token2022Program.programId,
      ]);
      // ...and operate on the account the wallet actually holds.
      for (final ix in message.instructions) {
        expect(keys[ix.accountKeyIndexes.first], _token2022Account);
      }
    });

    test('skips the burn ix when the account is already empty — close alone '
        'reclaims the rent', () async {
      final rpc = _BurnStubRpcService(
        holding: (
          address: _token2022Account,
          program: TokenProgramType.token2022Program,
          amount: 0,
        ),
      );

      final txBase64 = await rpc.buildBurnAndCloseTx(tokenMint: _mint);
      final message = SignedTx.fromBytes(
        base64Decode(txBase64),
      ).compiledMessage;
      expect(message.instructions, hasLength(1));
    });

    test('harvests withheld transfer fees to the mint before closing a '
        'Token-2022 account that has them — the burn leaves the withheld '
        'balance untouched, and Token-2022 rejects the close while any '
        'remains (AccountHasWithheldTransferFees, custom error 35)', () async {
      final rpc = _BurnStubRpcService(
        holding: (
          address: _token2022Account,
          program: TokenProgramType.token2022Program,
          amount: 1500,
        ),
        withheld: 42,
      );

      final txBase64 = await rpc.buildBurnAndCloseTx(tokenMint: _mint);
      final message = SignedTx.fromBytes(
        base64Decode(txBase64),
      ).compiledMessage;
      final keys = message.accountKeys.map((k) => k.toBase58()).toList();

      expect(message.instructions, hasLength(3));
      final harvest = message.instructions[1];
      expect(keys[harvest.programIdIndex], Token2022Program.programId);
      // TransferFee extension ix (26), HarvestWithheldTokensToMint variant (4).
      expect(harvest.data.toList(), [26, 4]);
      // Mint first, then the account to harvest from — both writable, neither
      // a signer (the instruction is permissionless).
      expect(harvest.accountKeyIndexes.map((i) => keys[i]), [
        _mint,
        _token2022Account,
      ]);
    });

    test('leaves the harvest ix out when nothing is withheld — the extra ix '
        'would cost compute on every ordinary burn', () async {
      final rpc = _BurnStubRpcService(
        holding: (
          address: _token2022Account,
          program: TokenProgramType.token2022Program,
          amount: 1500,
        ),
      );

      final txBase64 = await rpc.buildBurnAndCloseTx(tokenMint: _mint);
      expect(
        SignedTx.fromBytes(base64Decode(txBase64)).compiledMessage.instructions,
        hasLength(2),
      );
    });

    test('throws before signing when the wallet holds no account for the mint '
        '— closing a non-existent account fails on-chain with the same opaque '
        'IncorrectProgramId', () async {
      final rpc = _BurnStubRpcService(holding: null);
      expect(
        () => rpc.buildBurnAndCloseTx(tokenMint: _mint),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('SolanaRpcService.buildSplTransferTx', () {
    test('resolves the token program from the wallet\'s actual holding, not a '
        'getTokenProgramTypeForMint guess — a Token-2022 transfer must address '
        'the transfer ix AND derive the recipient ATA with Token-2022, or it '
        'fails on-chain with IncorrectProgramId after the user has signed', () async {
      // findOwnedTokenAccount + getLatestBlockhash are overridden below, so the
      // destination-ATA existence probe is the only call left to the real RPC.
      // Answer it with `value: null` so the ATA is treated as not-yet-created
      // (the create-ATA ix is then prepended with the resolved program).
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': {
              'context': {'slot': 1},
              'value': null,
            },
          }),
        );
        await req.response.close();
      });

      Config.debugOverrides['RPC_PROXY_BASE_URL'] =
          'http://127.0.0.1:${server.port}';
      final rpc = _TransferStubRpcService(
        holding: (
          address: _token2022Account,
          program: TokenProgramType.token2022Program,
          amount: 5000,
        ),
      );

      final txBase64 = await rpc.buildSplTransferTx(
        destination: _addr,
        tokenMint: _mint,
        amount: 1500,
      );
      final message = SignedTx.fromBytes(
        base64Decode(txBase64),
      ).compiledMessage;
      final keys = message.accountKeys.map((k) => k.toBase58()).toList();

      // The recipient ATA the tx must credit, derived with the SAME program the
      // mint uses — distinct from the source account the wallet actually holds.
      final expectedDestAta = (await findAssociatedTokenAddress(
        owner: Ed25519HDPublicKey.fromBase58(_addr),
        mint: Ed25519HDPublicKey.fromBase58(_mint),
        tokenProgramType: TokenProgramType.token2022Program,
      )).toBase58();

      // The transfer ix (last) is addressed to Token-2022...
      final transferIx = message.instructions.last;
      expect(keys[transferIx.programIdIndex], Token2022Program.programId);
      // ...spends from the account the wallet actually holds (not a re-derived
      // classic-seed ATA)...
      expect(keys[transferIx.accountKeyIndexes[0]], _token2022Account);
      // ...and credits the Token-2022 destination ATA.
      expect(keys[transferIx.accountKeyIndexes[1]], expectedDestAta);
    });

    test('propagates an RPC failure during program resolution instead of '
        'falling back to classic SPL — getTokenProgramTypeForMint would have '
        'swallowed the failure and guessed classic SPL, silently addressing a '
        'Token-2022 mint to the wrong program', () async {
      // The resolution read (getTokenAccountsByOwner, inside
      // findOwnedTokenAccount) fails at the RPC. The build must surface that,
      // not degrade to a classic-SPL guess and return a broken tx.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final body =
            jsonDecode(await utf8.decoder.bind(req).join())
                as Map<String, dynamic>;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'error': {'code': -32000, 'message': 'rpc down'},
          }),
        );
        await req.response.close();
      });

      Config.debugOverrides['RPC_PROXY_BASE_URL'] =
          'http://127.0.0.1:${server.port}';
      final rpc = SolanaRpcService(_BurnWalletManager(), TxLandedSlots());

      await expectLater(
        rpc.buildSplTransferTx(
          destination: _addr,
          tokenMint: _mint,
          amount: 1500,
        ),
        throwsA(anything),
      );
    });
  });
}

/// Stubs the two network seams [SolanaRpcService.buildBurnAndCloseTx] uses —
/// the holding lookup and the blockhash — so the built message can be decoded
/// and inspected without an RPC.
class _BurnStubRpcService extends SolanaRpcService {
  _BurnStubRpcService({required this.holding, this.withheld = 0})
    : super(_BurnWalletManager(), TxLandedSlots());

  final ({String address, TokenProgramType program, int amount})? holding;

  /// Transfer-fee tokens withheld on [holding], as the extension read would
  /// report them.
  final int withheld;

  @override
  Future<({String address, TokenProgramType program, int amount})?>
  findOwnedTokenAccount({required String owner, required String mint}) async =>
      holding;

  @override
  Future<int> withheldTransferFees(String tokenAccount) async => withheld;

  @override
  Future<String> getLatestBlockhash() async => _blockhash;
}

/// Stubs the two network seams [SolanaRpcService.buildSplTransferTx] resolves
/// through — the owned-account lookup and the blockhash — so the built message
/// can be decoded and inspected. The destination-ATA existence probe still hits
/// the (test-local) RPC.
class _TransferStubRpcService extends SolanaRpcService {
  _TransferStubRpcService({required this.holding})
    : super(_BurnWalletManager(), TxLandedSlots());

  final ({String address, TokenProgramType program, int amount})? holding;

  @override
  Future<({String address, TokenProgramType program, int amount})?>
  findOwnedTokenAccount({required String owner, required String mint}) async =>
      holding;

  @override
  Future<String> getLatestBlockhash() async => _blockhash;
}

/// [WalletManager] stand-in that answers only `getAddress` — the burn builder
/// needs the owner/fee-payer and nothing else.
class _BurnWalletManager implements WalletManager {
  @override
  Future<String> getAddress({Chain chain = Chain.solana}) async => _addr;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used by buildBurnAndCloseTx');
}

/// Stubs the three network seams [SolanaRpcService.awaitConfirmationOrThrow]
/// depends on — the status poll, the blockhash-expiry probe and the
/// re-broadcast — so the loop's terminal states can be exercised without an
/// RPC. [statuses] is a script; the last entry repeats once exhausted.
class _ConfirmStubRpcService extends SolanaRpcService {
  _ConfirmStubRpcService({required this.statuses, this.blockhashValid = true})
    : super(_DummyWalletManager(), TxLandedSlots());

  final List<SolanaTxStatus? Function()> statuses;

  /// What the expiry probe answers. Flip to false to expire the blockhash.
  bool blockhashValid;

  int statusCalls = 0;
  int resends = 0;
  int blockhashChecks = 0;

  @override
  Future<SolanaTxStatus?> transactionStatus(String signature) async {
    final i = statusCalls < statuses.length ? statusCalls : statuses.length - 1;
    statusCalls++;
    return statuses[i]();
  }

  @override
  Future<bool> isBlockhashStillValid(String blockhash) async {
    blockhashChecks++;
    return blockhashValid;
  }

  @override
  Future<void> rebroadcastTransaction(SignedTx signedTx) async {
    resends++;
  }
}

/// A one-signer transfer tx, only ever used for its `recentBlockhash` and as
/// the payload handed to the (stubbed) re-broadcast.
SignedTx _rebroadcastFixture() {
  final signer = Ed25519HDPublicKey.fromBase58(_addr);
  final compiled = Message.only(
    SystemInstruction.transfer(
      fundingAccount: signer,
      recipientAccount: signer,
      lamports: 1,
    ),
  ).compile(recentBlockhash: _blockhash, feePayer: signer);
  return SignedTx(
    signatures: [Signature(List<int>.filled(64, 0), publicKey: signer)],
    compiledMessage: compiled,
  );
}
