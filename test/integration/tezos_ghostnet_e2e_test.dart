/// Shadownet end-to-end verification of the Tezos send stack.
///
/// This drives the **real** client-side money-movement code — the local forge
/// ([forgeOperationGroup]), the ed25519 operation signer
/// ([MultiChainDerivation.signTezosOperation] / `…WithSeed`), and the node
/// client ([TezosRpcService]) — through the full
/// `forge → estimate → ed25519 sign → inject → confirm` flow that
/// [TezosTransferService] performs in the app, then asserts on-chain inclusion.
/// It proves that the client-side stack, and the fee/reveal logic the
/// chain-aware send flow relies on, actually move funds.
///
/// Two groups:
///
///  - **`forge/sign (offline)`** — always runs (incl. in the normal
///    `flutter test` / CI suite). Exercises forge → sign for both a
///    reveal+XTZ group (non-revealed source shape) and an FA2 `transfer`,
///    asserting the signed payload is a well-formed, injectable
///    `forgedHex ++ 64-byte-signature`. No network.
///
///  - **`shadownet live`** — tagged `live-ghostnet`, **skipped unless a funded
///    source is supplied** via environment. Performs real transfers on
///    shadownet and asserts inclusion. Requires a funded `tz1` source (and,
///    for the FA2 leg, that source holding the token). See the env block below.
///
/// Naming note: Ghostnet is decommissioned (dead DNS); the live network is now
/// **Shadownet** (`rpc.shadownet.teztnets.com`). The `TEZOS_GHOSTNET_*` env
/// names, the `live-ghostnet` tag, and this filename are kept for continuity
/// with existing runner configs — the values they carry are Shadownet's.
///
/// Run the live legs (from a host/runner with shadownet network egress):
///
/// ```bash
/// TEZOS_GHOSTNET_FUNDING_MNEMONIC="word1 word2 … word15" \
/// TEZOS_GHOSTNET_FA2_CONTRACT=KT1Xn4hDXpTfRoVvVhWpRvKrR8iV1ATQF3qJ \
/// TEZOS_GHOSTNET_FA2_TOKEN_ID=0 \
///   flutter test test/integration/tezos_ghostnet_e2e_test.dart --tags live-ghostnet
/// ```
///
/// `KT1Xn4hDXpTfRoVvVhWpRvKrR8iV1ATQF3qJ` is the canonical shadownet FA2
/// fixture (token 0, admin = the funded source used by the live legs). To
/// originate a fresh copy — e.g. after a testnet reset — see
/// `test/integration/fa2_origination_setup_test.dart`.
///
/// Running the first outgoing operation of a freshly-funded (never-revealed)
/// source proves **reveal-on-first-op**; the second operation from the
/// now-revealed source proves the **revealed-source** path — the harness runs
/// the XTZ leg first and the FA2 leg second so a single funded account covers
/// both reveal states in one run.
@Tags(['live-ghostnet'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/derivation.dart';
import 'package:mallow_wallet/core/crypto/tezos_forge.dart';
import 'package:mallow_wallet/core/network/tezos_rpc_service.dart';

// --- Simulation / fee constants (kept in lock-step with TezosTransferService,
// which is the app code path D this harness verifies against a live node). ---
const int _simGasCap = 500000;
const int _simStorageCap = 60000;
const int _feeBufferMutez = 100;
const int _storageSafetyMargin = 10;

/// A signer over a locally-forged operation group: hides whether the source key
/// comes from a BIP39 mnemonic (HD path, index) or a raw imported ed25519 seed.
class _Signer {
  _Signer({
    required this.tz1,
    required this.edpk,
    required Future<({String signature, String signedOperationHex})> Function(
      String forgedHex,
    )
    sign,
  }) : _sign = sign;

  final String tz1;
  final String edpk;
  final Future<({String signature, String signedOperationHex})> Function(
    String forgedHex,
  )
  _sign;

  Future<String> signToInjectable(String forgedHex) async =>
      (await _sign(forgedHex)).signedOperationHex;

  /// Build a signer from the environment, or null when no funded source is set.
  static Future<_Signer?> fromEnv() async {
    final mnemonic = Platform.environment['TEZOS_GHOSTNET_FUNDING_MNEMONIC']
        ?.trim();
    final seedHex = Platform.environment['TEZOS_GHOSTNET_FUNDING_SEED_HEX']
        ?.trim();

    if (mnemonic != null && mnemonic.isNotEmpty) {
      final index =
          int.tryParse(
            Platform.environment['TEZOS_GHOSTNET_FUNDING_INDEX'] ?? '0',
          ) ??
          0;
      final tz1 = await MultiChainDerivation.getTezosAddressAtIndex(
        mnemonic,
        index,
      );
      final edpk = await MultiChainDerivation.getTezosPublicKeyAtIndex(
        mnemonic,
        index,
      );
      return _Signer(
        tz1: tz1,
        edpk: edpk,
        sign: (hex) =>
            MultiChainDerivation.signTezosOperation(mnemonic, index, hex),
      );
    }

    if (seedHex != null && seedHex.length == 64) {
      final seed = _hexToBytes(seedHex);
      final tz1 = await MultiChainDerivation.tezosAddressFromSeed(seed);
      final edpk = await MultiChainDerivation.tezosPublicKeyFromSeed(seed);
      return _Signer(
        tz1: tz1,
        edpk: edpk,
        sign: (hex) =>
            MultiChainDerivation.signTezosOperationWithSeed(seed, hex),
      );
    }

    return null;
  }
}

/// A forged, ready-to-sign operation group plus its display estimate — the
/// live-harness mirror of `TezosTransferService._buildPlan`.
class _Plan {
  _Plan(this.branch, this.contents, this.estimate);
  final String branch;
  final List<TezosOperationContent> contents;
  final ({BigInt feeMutez, int gasLimit, int storageLimit, bool includesReveal})
  estimate;
}

/// Fetch chain state, simulate at protocol caps for per-content gas/storage,
/// then rebuild each content with real limits + the minimal fee. Prepends a
/// `reveal` when [source] has never revealed its manager key. [parameters] is
/// null for a native XTZ transfer and set for an FA2 `transfer` contract call.
Future<_Plan> _buildPlan(
  TezosRpcService rpc, {
  required String source,
  required String edpk,
  required String destination,
  required BigInt amountMutez,
  TezosTransactionParameters? parameters,
}) async {
  final branch = await rpc.getBranchHash();
  final chainId = await rpc.getChainId();
  final counter = await rpc.nextCounter(source);
  final revealed = await rpc.isRevealed(source);
  final hasReveal = !revealed;

  var nextCounter = counter;
  final sim = <TezosOperationContent>[];
  if (hasReveal) {
    sim.add(
      TezosReveal(
        source: source,
        publicKey: edpk,
        fee: BigInt.zero,
        counter: BigInt.from(nextCounter),
        gasLimit: BigInt.from(_simGasCap),
        storageLimit: BigInt.zero,
      ),
    );
    nextCounter += 1;
  }
  sim.add(
    TezosTransaction(
      source: source,
      destination: destination,
      amount: amountMutez,
      fee: BigInt.zero,
      counter: BigInt.from(nextCounter),
      gasLimit: BigInt.from(_simGasCap),
      storageLimit: BigInt.from(_simStorageCap),
      parameters: parameters,
    ),
  );

  final response = await rpc.runOperation(
    branch: branch,
    contents: [for (final c in sim) c.toJson()],
    chainId: chainId,
  );
  final overall = TezosRpcService.parseEstimate(response);
  if (!overall.success) {
    throw StateError('run_operation reported failure: ${overall.errors}');
  }
  final perContent = _perContentEstimates(response);
  expect(
    perContent.length,
    sim.length,
    reason: 'simulation returned one result per content',
  );

  final revealIndex = hasReveal ? 0 : -1;
  final txIndex = sim.length - 1;
  final revealGas = hasReveal
      ? perContent[revealIndex].gas + TezosRpcService.gasSafetyMargin
      : 0;
  final revealStorage = hasReveal ? perContent[revealIndex].storage : 0;
  final txGas = perContent[txIndex].gas + TezosRpcService.gasSafetyMargin;
  final txStorage = perContent[txIndex].storage == 0
      ? 0
      : perContent[txIndex].storage + _storageSafetyMargin;
  final totalGas = revealGas + txGas;
  final totalStorage = revealStorage + txStorage;

  List<TezosOperationContent> build(BigInt txFee) {
    var c = counter;
    final out = <TezosOperationContent>[];
    if (hasReveal) {
      out.add(
        TezosReveal(
          source: source,
          publicKey: edpk,
          fee: BigInt.zero,
          counter: BigInt.from(c),
          gasLimit: BigInt.from(revealGas),
          storageLimit: BigInt.from(revealStorage),
        ),
      );
      c += 1;
    }
    out.add(
      TezosTransaction(
        source: source,
        destination: destination,
        amount: amountMutez,
        fee: txFee,
        counter: BigInt.from(c),
        gasLimit: BigInt.from(txGas),
        storageLimit: BigInt.from(txStorage),
        parameters: parameters,
      ),
    );
    return out;
  }

  final sizingHex = forgeOperationGroup(branch, build(BigInt.zero));
  final opSizeBytes = sizingHex.length ~/ 2 + 64;
  final feeMutez =
      TezosRpcService.minimalFeeMutez(
        gasLimit: totalGas,
        operationSizeBytes: opSizeBytes,
      ) +
      _feeBufferMutez;

  return _Plan(branch, build(BigInt.from(feeMutez)), (
    feeMutez: BigInt.from(feeMutez),
    gasLimit: totalGas,
    storageLimit: totalStorage,
    includesReveal: hasReveal,
  ));
}

/// Per-content `(gas, storage)` from a `run_operation` response, folding in the
/// fresh-account allocation burn — mirrors `TezosTransferService`.
List<({int gas, int storage})> _perContentEstimates(
  Map<String, dynamic> response,
) {
  final out = <({int gas, int storage})>[];
  final contents = response['contents'];
  if (contents is! List) return out;
  for (final content in contents) {
    var gas = 0;
    var storage = 0;
    void accumulate(Map<String, dynamic> result) {
      final milligas = result['consumed_milligas'];
      if (milligas is String) gas += (int.parse(milligas) / 1000).ceil();
      final paid = result['paid_storage_size_diff'];
      if (paid is String) storage += int.parse(paid);
      if (result['allocated_destination_contract'] == true) {
        storage += TezosRpcService.allocationBurnBytes;
      }
      final originated = result['originated_contracts'];
      if (originated is List) {
        storage += TezosRpcService.allocationBurnBytes * originated.length;
      }
    }

    if (content is Map) {
      final metadata = content['metadata'];
      if (metadata is Map) {
        final result = metadata['operation_result'];
        if (result is Map) accumulate(result.cast<String, dynamic>());
        final internal = metadata['internal_operation_results'];
        if (internal is List) {
          for (final entry in internal) {
            final r = entry is Map ? entry['result'] : null;
            if (r is Map) accumulate(r.cast<String, dynamic>());
          }
        }
      }
    }
    out.add((gas: gas, storage: storage));
  }
  return out;
}

/// Forge → sign → inject [plan], wait for inclusion, and assert it landed.
Future<String> _sendAndConfirm(
  TezosRpcService rpc,
  _Signer signer,
  _Plan plan,
  String label,
) async {
  final forgedHex = forgeOperationGroup(plan.branch, plan.contents);
  final signedHex = await signer.signToInjectable(forgedHex);
  expect(
    signedHex,
    startsWith(forgedHex),
    reason: 'injectable payload is forgedHex ++ signature',
  );
  final opHash = await rpc.injectOperation(signedHex);
  // ignore: avoid_print
  print(
    '[$label] injected $opHash '
    '(fee ${plan.estimate.feeMutez} mutez, gas ${plan.estimate.gasLimit}, '
    'storage ${plan.estimate.storageLimit}, '
    'reveal ${plan.estimate.includesReveal}) '
    '→ https://shadownet.tzkt.io/$opHash',
  );
  final included = await rpc.waitForConfirmation(opHash);
  expect(
    included,
    isTrue,
    reason: '[$label] operation not included before timeout',
  );
  return opHash;
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  // A fixed 32-byte ed25519 seed — offline-only, never funded, never touches a
  // network. Deterministic so the forged/signed bytes are reproducible.
  final testSeed = Uint8List.fromList(
    List<int>.generate(32, (i) => (i * 7 + 1) & 0xff),
  );

  group('forge/sign (offline — always runs)', () {
    late String tz1;
    late String edpk;

    setUp(() async {
      tz1 = await MultiChainDerivation.tezosAddressFromSeed(testSeed);
      edpk = await MultiChainDerivation.tezosPublicKeyFromSeed(testSeed);
    });

    test('derived source is a well-formed tz1 + edpk', () {
      expect(tz1, startsWith('tz1'));
      expect(edpk, startsWith('edpk'));
    });

    test('reveal + XTZ group signs to an injectable payload', () async {
      final contents = <TezosOperationContent>[
        TezosReveal(
          source: tz1,
          publicKey: edpk,
          fee: BigInt.from(374),
          counter: BigInt.from(1),
          gasLimit: BigInt.from(169),
          storageLimit: BigInt.zero,
        ),
        TezosTransaction(
          source: tz1,
          destination: tz1,
          amount: BigInt.from(1000),
          fee: BigInt.from(400),
          counter: BigInt.from(2),
          gasLimit: BigInt.from(1000),
          storageLimit: BigInt.zero,
        ),
      ];
      final forged = forgeOperationGroup(
        'BMXTnznPZDFf3TbpmdXptcTqcEuTHiCTgjxZaWif3YgVVPpp4Nq',
        contents,
      );
      // Sanity: reveal (0x6b) then transaction (0x6c) tags follow the 32-byte
      // branch (64 hex chars).
      expect(forged.substring(64, 66), '6b');

      final signed = await MultiChainDerivation.signTezosOperationWithSeed(
        testSeed,
        forged,
      );
      expect(signed.signature, startsWith('edsig'));
      expect(signed.signedOperationHex, startsWith(forged));
      // 64-byte ed25519 signature appended as 128 hex chars.
      expect(signed.signedOperationHex.length, forged.length + 128);
    });

    test('FA2 transfer signs to an injectable payload', () async {
      final params = fa2TransferParameters(
        from: tz1,
        to: tz1,
        tokenId: BigInt.zero,
        amount: BigInt.one,
      );
      final contents = <TezosOperationContent>[
        TezosTransaction(
          source: tz1,
          destination: 'KT1SjXiUX63QvdNMcM2m492f7kuf8JxXRLp4',
          amount: BigInt.zero,
          fee: BigInt.from(500),
          counter: BigInt.from(3),
          gasLimit: BigInt.from(4000),
          storageLimit: BigInt.from(100),
          parameters: params,
        ),
      ];
      final forged = forgeOperationGroup(
        'BMXTnznPZDFf3TbpmdXptcTqcEuTHiCTgjxZaWif3YgVVPpp4Nq',
        contents,
      );
      // The `transfer` entrypoint forges as a named entrypoint (0xff) — assert
      // the parameters blob is present (0xff appears after the destination).
      expect(forged.contains('ff'), isTrue);

      final signed = await MultiChainDerivation.signTezosOperationWithSeed(
        testSeed,
        forged,
      );
      expect(signed.signature, startsWith('edsig'));
      expect(signed.signedOperationHex, startsWith(forged));
      expect(signed.signedOperationHex.length, forged.length + 128);
    });
  });

  group('shadownet live', () {
    late TezosRpcService rpc;
    late _Signer? signer;

    setUpAll(() async {
      final url =
          Platform.environment['TEZOS_GHOSTNET_RPC_URL'] ??
          'https://rpc.shadownet.teztnets.com';
      rpc = TezosRpcService.forBaseUrl(url);
      signer = await _Signer.fromEnv();
    });

    // Synchronous skip decision (evaluated at collection time): the live legs
    // run only when a funded source is supplied via environment.
    final hasFunding =
        (Platform.environment['TEZOS_GHOSTNET_FUNDING_MNEMONIC']?.trim() ?? '')
            .isNotEmpty ||
        (Platform.environment['TEZOS_GHOSTNET_FUNDING_SEED_HEX']
                    ?.trim()
                    .length ??
                0) ==
            64;
    final Object skipReason = hasFunding
        ? false
        : 'set TEZOS_GHOSTNET_FUNDING_MNEMONIC (or _SEED_HEX) to a funded '
              'shadownet source to run live';

    test('XTZ transfer — reveal-on-first-op / non-revealed source', () async {
      final s = signer!;
      final dest = Platform.environment['TEZOS_GHOSTNET_DEST'] ?? s.tz1;
      final amount = BigInt.parse(
        Platform.environment['TEZOS_GHOSTNET_AMOUNT_MUTEZ'] ?? '1000',
      );

      final revealedBefore = await rpc.isRevealed(s.tz1);
      final plan = await _buildPlan(
        rpc,
        source: s.tz1,
        edpk: s.edpk,
        destination: dest,
        amountMutez: amount,
      );
      expect(
        plan.estimate.includesReveal,
        !revealedBefore,
        reason: 'reveal is bundled iff the source has not revealed its key',
      );
      await _sendAndConfirm(rpc, s, plan, 'XTZ');

      // The source is now revealed on-chain — proves reveal-on-first-op.
      expect(await rpc.isRevealed(s.tz1), isTrue);
    }, skip: skipReason);

    test('FA2 token transfer — revealed source', () async {
      final s = signer!;
      final contract = Platform.environment['TEZOS_GHOSTNET_FA2_CONTRACT'];
      if (contract == null || contract.isEmpty) {
        markTestSkipped('set TEZOS_GHOSTNET_FA2_CONTRACT to run the FA2 leg');
        return;
      }
      final tokenId = BigInt.parse(
        Platform.environment['TEZOS_GHOSTNET_FA2_TOKEN_ID'] ?? '0',
      );
      final fa2Amount = BigInt.parse(
        Platform.environment['TEZOS_GHOSTNET_FA2_AMOUNT'] ?? '1',
      );
      final dest = Platform.environment['TEZOS_GHOSTNET_FA2_DEST'] ?? s.tz1;

      // A revealed source is required to prove the non-reveal path; if the
      // account has not revealed yet, run the XTZ leg first.
      expect(
        await rpc.isRevealed(s.tz1),
        isTrue,
        reason: 'run the XTZ leg first so the source is revealed',
      );

      final plan = await _buildPlan(
        rpc,
        source: s.tz1,
        edpk: s.edpk,
        destination: contract,
        amountMutez: BigInt.zero,
        parameters: fa2TransferParameters(
          from: s.tz1,
          to: dest,
          tokenId: tokenId,
          amount: fa2Amount,
        ),
      );
      expect(plan.estimate.includesReveal, isFalse);
      await _sendAndConfirm(rpc, s, plan, 'FA2');
    }, skip: skipReason);
  });
}
