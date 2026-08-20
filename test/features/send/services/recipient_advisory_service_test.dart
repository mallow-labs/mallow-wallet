import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/ethereum_rpc_service.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/features/send/models/recipient_advisory.dart';
import 'package:mallow_wallet/features/send/services/recipient_advisory_service.dart';
import 'package:mallow_wallet/shared/utils/chain.dart' show Chain;
import 'package:mocktail/mocktail.dart';
import 'package:solana/dto.dart';
import 'package:solana/solana.dart';

class _MockSolanaRpcService extends Mock implements SolanaRpcService {}

class _MockEthereumRpcService extends Mock implements EthereumRpcService {}

/// The detector is the only thing standing between a pasted token account and
/// an irreversible transfer, so these tests pin both halves of its contract:
/// it fires on the account classes that lose funds, and — just as important —
/// it stays silent on ordinary wallets and on RPC failure. A warning that
/// appears on routine sends is a warning users learn to dismiss.
void main() {
  const systemProgram = '11111111111111111111111111111111';

  late _MockSolanaRpcService solana;
  late _MockEthereumRpcService ethereum;
  late RecipientAdvisoryService service;

  /// A wallet address (on the ed25519 curve, i.e. keypair-backed).
  late String wallet;

  /// A program-derived address — off the curve by construction.
  late String pda;

  AccountResult account(String owner) => AccountResult(
    context: Context(slot: BigInt.one),
    value: Account(
      lamports: 2039280,
      owner: owner,
      data: null,
      executable: false,
      rentEpoch: BigInt.zero,
    ),
  );

  AccountResult missingAccount() =>
      AccountResult(context: Context(slot: BigInt.one), value: null);

  setUpAll(() async {
    wallet = (await Ed25519HDKeyPair.random()).address;
    pda = (await Ed25519HDPublicKey.findProgramAddress(
      seeds: [
        [1, 2, 3],
      ],
      programId: Ed25519HDPublicKey.fromBase58(systemProgram),
    )).toBase58();
  });

  setUp(() {
    solana = _MockSolanaRpcService();
    ethereum = _MockEthereumRpcService();
    service = RecipientAdvisoryService(solana, ethereum);
  });

  Future<RecipientAdvisory?> detect(Chain chain, String address) =>
      service.detect(chain: chain, address: address);

  group('Solana', () {
    void stubAccount(AccountResult result) {
      when(
        () => solana.getAccountInfo(
          any(),
          encoding: any(named: 'encoding'),
          dataSlice: any(named: 'dataSlice'),
        ),
      ).thenAnswer((_) async => result);
    }

    test('a funded wallet produces no advisory', () async {
      stubAccount(account(systemProgram));
      expect(await detect(Chain.solana, wallet), isNull);
    });

    test('the read asks for no account data — only the owner is used, and '
        'a pasted program id would otherwise be hundreds of KB', () async {
      stubAccount(account(systemProgram));
      await detect(Chain.solana, wallet);

      final slice =
          verify(
                () => solana.getAccountInfo(
                  any(),
                  encoding: any(named: 'encoding'),
                  dataSlice: captureAny(named: 'dataSlice'),
                ),
              ).captured.single
              as DataSlice?;
      expect(slice?.length, 0);
    });

    test('an account owned by the SPL Token program reads as a token '
        'account — the pasted-ATA case, which is a total loss', () async {
      stubAccount(account(TokenProgram.programId));

      final advisory = await detect(Chain.solana, pda);
      expect(advisory?.kind, RecipientAdvisoryKind.tokenAccount);
      expect(advisory!.message, contains('token account'));
    });

    test('Token-2022 token accounts are detected too', () async {
      stubAccount(account(Token2022Program.programId));
      expect(
        (await detect(Chain.solana, pda))?.kind,
        RecipientAdvisoryKind.tokenAccount,
      );
    });

    test('an off-curve address is flagged as a program address', () async {
      stubAccount(account(systemProgram));
      expect(
        (await detect(Chain.solana, pda))?.kind,
        RecipientAdvisoryKind.programAddress,
      );
    });

    test('a missing account reads as unfunded, not as a program '
        'address — the two ask the user for different things', () async {
      stubAccount(missingAccount());

      final advisory = await detect(Chain.solana, wallet);
      expect(advisory?.kind, RecipientAdvisoryKind.unfunded);
      expect(advisory!.message, contains('empty'));
    });

    test('a token account outranks its own off-curve-ness — one banner, '
        'the most severe', () async {
      stubAccount(account(TokenProgram.programId));
      // An ATA is itself a PDA, so both signals fire on the same address.
      expect(
        (await detect(Chain.solana, pda))?.kind,
        RecipientAdvisoryKind.tokenAccount,
      );
    });

    test('an RPC failure suppresses the network signal but keeps the '
        'local one — a timeout is not evidence of danger', () async {
      when(
        () => solana.getAccountInfo(
          any(),
          encoding: any(named: 'encoding'),
          dataSlice: any(named: 'dataSlice'),
        ),
      ).thenThrow(Exception('boom'));

      expect(await detect(Chain.solana, wallet), isNull);
      expect(
        (await detect(Chain.solana, pda))?.kind,
        RecipientAdvisoryKind.programAddress,
      );
    });
  });

  group('Ethereum', () {
    const address = '0x1234567890123456789012345678901234567890';

    void stub({bool isContract = false, BigInt? balance, int nonce = 3}) {
      when(
        () => ethereum.hasContractCode(any()),
      ).thenAnswer((_) async => isContract);
      when(
        () => ethereum.getBalance(any()),
      ).thenAnswer((_) async => balance ?? BigInt.from(1000));
      when(() => ethereum.getNonce(any())).thenAnswer((_) async => nonce);
    }

    test('a funded EOA produces no advisory', () async {
      stub();
      expect(await detect(Chain.ethereum, address), isNull);
    });

    test('deployed code reads as a contract', () async {
      stub(isContract: true);

      final advisory = await detect(Chain.ethereum, address);
      expect(advisory?.kind, RecipientAdvisoryKind.contract);
      expect(
        advisory!.message,
        isNot(contains('NFT')),
        reason:
            'an ERC-20/native send to a contract fails differently than '
            'safeTransferFrom does — the NFT flow copy must not be reused',
      );
    });

    test('zero balance alone is not unfunded — plenty of live wallets '
        'hold only tokens', () async {
      stub(balance: BigInt.zero, nonce: 7);
      expect(await detect(Chain.ethereum, address), isNull);
    });

    test('zero balance AND zero nonce reads as unfunded', () async {
      stub(balance: BigInt.zero, nonce: 0);
      expect(
        (await detect(Chain.ethereum, address))?.kind,
        RecipientAdvisoryKind.unfunded,
      );
    });

    test('every read failing produces no advisory', () async {
      when(() => ethereum.hasContractCode(any())).thenThrow(Exception('boom'));
      when(() => ethereum.getBalance(any())).thenThrow(Exception('boom'));
      when(() => ethereum.getNonce(any())).thenThrow(Exception('boom'));

      expect(await detect(Chain.ethereum, address), isNull);
    });

    test('all three reads are dispatched before any is awaited, so this '
        'costs one round-trip of latency and not three', () async {
      final gate = Completer<void>();
      final dispatched = <String>[];

      when(() => ethereum.hasContractCode(any())).thenAnswer((_) async {
        dispatched.add('code');
        await gate.future;
        return false;
      });
      when(() => ethereum.getBalance(any())).thenAnswer((_) async {
        dispatched.add('balance');
        return BigInt.from(1);
      });
      when(() => ethereum.getNonce(any())).thenAnswer((_) async {
        dispatched.add('nonce');
        return 1;
      });

      final pending = detect(Chain.ethereum, address);
      // The first read is still blocked; if detection were serial the other
      // two would not have been called yet.
      await pumpEventQueue();
      expect(dispatched, containsAll(<String>['code', 'balance', 'nonce']));

      gate.complete();
      expect(await pending, isNull);
    });
  });

  group('Tezos', () {
    // Real Base58Check addresses — tezosAddressKind verifies the checksum.
    const tz1 = 'tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb';
    const kt1 = 'KT1LN4LPSqTMS7Sd2CJw4bbDGRkMv2t68Fy9';

    test('an implicit account produces no advisory', () async {
      expect(await detect(Chain.tezos, tz1), isNull);
    });

    test('a KT1 origination reads as a contract, with no RPC read', () async {
      expect(
        (await detect(Chain.tezos, kt1))?.kind,
        RecipientAdvisoryKind.contract,
      );
      verifyZeroInteractions(solana);
      verifyZeroInteractions(ethereum);
    });
  });
}
