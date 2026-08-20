import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/core/network/solana_rpc_service.dart';
import 'package:mallow_wallet/features/staking/data/staking_tx_builder.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:solana/dto.dart';
import 'package:solana/solana.dart' show StakeProgram;

import 'fetch_user_stake_accounts_test.mocks.dart';

/// Pins the *wire* half of stake-account enumeration, which
/// `staking_tx_builder_test.dart` cannot reach: it exercises
/// `decodeStakeAccount` on bytes handed to it directly, so both lines that
/// actually get the bytes off the RPC — the `Encoding.base64` argument and the
/// `BinaryAccountData` branch — are invisible to it.
///
/// That pair is exactly what broke: reading stake accounts as `jsonParsed`
/// throws inside the solana package's `Delegation.fromJson` (agave stopped
/// emitting the deprecated `warmupCooldownRate` it casts as a required `num`),
/// and the guard here then drops every account on the floor. The user-visible
/// result is "Nothing to claim" and "Not enough active stake" with funds
/// plainly staked — and with no test on this method, the whole staking suite
/// stays green while it happens.
@GenerateNiceMocks([
  MockSpec<SolanaRpcService>(),
  MockSpec<WalletManager>(),
  MockSpec<JupiterSwapInstructionsClient>(),
])
void main() {
  const ownerAddress = 'FunE84BqYUn8XjELWb3EuHhquLMasfo8Urm976muaWx2';
  const stakeAddress = 'HFMCJhan9UZwmhCLn89aqF4S7Kukc4gjpumC18VApKX';
  const mallowVote = 'mALLoAbdQrgsnm7kWJyPrhcQcmxfT73t8DaqEkpZNd6';

  /// The same real mainnet stake account `staking_tx_builder_test.dart`
  /// decodes: delegated to mallow's validator at epoch 908, never deactivated.
  const accountBase64 =
      'AgAAAIDVIgAAAAAA3Yj03bPl2YA0dF1tnReVRJ2RrtXwF4f37LX8BZrAMbPdiPTd'
      's+XZgDR0XW2dF5VEnZGu1fAXh/fstfwFmsAxswAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAtQG+aqo3p4avRS8jub0ORotihH'
      'rCIc+sEPCusiBV8xW8kSAwAAAACMAwAAAAAAAP//////////AAAAAAAA0D8KM7BO'
      'AAAAAAAAAAA=';

  late MockSolanaRpcService rpc;
  late StakingTxBuilder builder;

  ProgramAccount programAccount(AccountData? data) => ProgramAccount(
    pubkey: stakeAddress,
    account: Account(
      lamports: 53845723,
      owner: StakeProgram.programId,
      data: data,
      executable: false,
      rentEpoch: BigInt.zero,
    ),
  );

  setUp(() {
    rpc = MockSolanaRpcService();
    final wallet = MockWalletManager();
    when(wallet.getAddress()).thenAnswer((_) async => ownerAddress);
    when(rpc.getCurrentEpoch()).thenAnswer((_) async => 1000);
    builder = StakingTxBuilder.withRpc(
      MockJupiterSwapInstructionsClient(),
      wallet,
      rpc,
    );
  });

  test('requests base64 and decodes the account the RPC returns', () async {
    when(
      rpc.getProgramAccounts(
        any,
        encoding: anyNamed('encoding'),
        filters: anyNamed('filters'),
      ),
    ).thenAnswer(
      (_) async => [
        programAccount(BinaryAccountData(base64Decode(accountBase64))),
      ],
    );

    final accounts = await builder.fetchUserStakeAccounts(
      validatorVoteAddress: mallowVote,
    );

    // The encoding is the contract with the RPC, not an implementation detail:
    // `jsonParsed` is the exact value that made this call throw, and it is a
    // one-word edit away.
    final captured = verify(
      rpc.getProgramAccounts(
        StakeProgram.programId,
        encoding: captureAnyNamed('encoding'),
        filters: anyNamed('filters'),
      ),
    ).captured.single;
    expect(captured, Encoding.base64);

    expect(accounts, hasLength(1));
    expect(accounts.single.address, stakeAddress);
    expect(accounts.single.delegatedLamports, 51562843);
    expect(accounts.single.state, StakeAccountState.active);
  });

  test('drops accounts the RPC did not return as binary', () async {
    // The `is! BinaryAccountData` guard. If the encoding ever regresses this is
    // the branch every account falls into — silently, so unstake and claim
    // report "nothing there" rather than surfacing the decode failure.
    when(
      rpc.getProgramAccounts(
        any,
        encoding: anyNamed('encoding'),
        filters: anyNamed('filters'),
      ),
    ).thenAnswer((_) async => [programAccount(null)]);

    expect(
      await builder.fetchUserStakeAccounts(validatorVoteAddress: mallowVote),
      isEmpty,
    );
  });

  test('filters the query to stake accounts this wallet can withdraw', () async {
    // dataSize + the withdrawer authority at offset 44 (webapp parity). Without
    // the memcmp the call enumerates every stake account on the network.
    when(
      rpc.getProgramAccounts(
        any,
        encoding: anyNamed('encoding'),
        filters: anyNamed('filters'),
      ),
    ).thenAnswer((_) async => []);

    await builder.fetchUserStakeAccounts(validatorVoteAddress: mallowVote);

    final filters =
        verify(
              rpc.getProgramAccounts(
                any,
                encoding: anyNamed('encoding'),
                filters: captureAnyNamed('filters'),
              ),
            ).captured.single
            as List<ProgramDataFilter>;
    expect(filters.map((f) => f.toJson()), [
      const ProgramDataFilter.dataSize(
        StakeProgram.neededAccountSpace,
      ).toJson(),
      ProgramDataFilter.memcmpBase58(offset: 44, bytes: ownerAddress).toJson(),
    ]);
  });

  test('drops accounts delegated to a different validator', () async {
    when(
      rpc.getProgramAccounts(
        any,
        encoding: anyNamed('encoding'),
        filters: anyNamed('filters'),
      ),
    ).thenAnswer(
      (_) async => [
        programAccount(BinaryAccountData(base64Decode(accountBase64))),
      ],
    );

    expect(
      await builder.fetchUserStakeAccounts(
        validatorVoteAddress: 'FunE84BqYUn8XjELWb3EuHhquLMasfo8Urm976muaWx2',
      ),
      isEmpty,
    );
  });
}
