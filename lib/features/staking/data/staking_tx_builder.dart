import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';
import 'package:jupiter_aggregator/jupiter_aggregator.dart';
import 'package:mallow_api/mallow_api.dart' show NativeStakeBreakdown;
import 'package:solana/dto.dart' hide Instruction;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/network/solana_rpc_service.dart';
import '../../../core/services/tx_landed_slots.dart';
import 'epoch_progress.dart';

/// Lifecycle state of a native stake account, derived from its delegation
/// epochs relative to the current epoch.
enum StakeAccountState {
  /// Delegated this epoch — not yet earning.
  activating,

  /// Earning rewards.
  active,

  /// Deactivation requested this epoch — still cooling down.
  deactivating,

  /// Fully deactivated and withdrawable (claimable).
  inactive,
}

/// A native stake account owned by the user and delegated to a given
/// validator, with the bits the stake/unstake/withdraw flows need.
class StakeAccountInfo {
  const StakeAccountInfo({
    required this.address,
    required this.accountLamports,
    required this.delegatedLamports,
    required this.state,
  });

  /// Base58 address of the stake account.
  final String address;

  /// Total lamports held by the account (what `withdraw` reclaims).
  final int accountLamports;

  /// Lamports actively delegated (`delegation.stake`).
  final int delegatedLamports;

  final StakeAccountState state;
}

/// The lamport movement between native-stake buckets a built transaction will
/// cause, once it lands.
///
/// Derived by the builder rather than guessed by the caller: only the builder
/// knows *which* accounts a tx touches, and the bucket a deactivation lands in
/// depends on the source account's state (deactivating an `active` account
/// leaves it `deactivating` until the epoch boundary; deactivating an
/// `activating` one is the `activationEpoch == deactivationEpoch`
/// short-circuit, so it is `inactive` — claimable — immediately).
///
/// This is what `StakeMutationJournal` overlays on the server's breakdown so
/// the status cells describe the world the user just created, rather than the
/// pre-transaction snapshot `/v1/staking` keeps returning until its own
/// `getProgramAccounts` node catches up.
class NativeStakeDelta {
  const NativeStakeDelta({
    this.activeLamports = 0,
    this.activatingLamports = 0,
    this.deactivatingLamports = 0,
    this.inactiveLamports = 0,
  });

  /// No movement — the liquid (mallowSOL swap) paths, which touch no stake
  /// account at all.
  static const none = NativeStakeDelta();

  final int activeLamports;
  final int activatingLamports;
  final int deactivatingLamports;
  final int inactiveLamports;

  bool get isEmpty =>
      activeLamports == 0 &&
      activatingLamports == 0 &&
      deactivatingLamports == 0 &&
      inactiveLamports == 0;

  NativeStakeDelta operator +(NativeStakeDelta other) => NativeStakeDelta(
    activeLamports: activeLamports + other.activeLamports,
    activatingLamports: activatingLamports + other.activatingLamports,
    deactivatingLamports: deactivatingLamports + other.deactivatingLamports,
    inactiveLamports: inactiveLamports + other.inactiveLamports,
  );

  @override
  String toString() =>
      'NativeStakeDelta(active: $activeLamports, '
      'activating: $activatingLamports, '
      'deactivating: $deactivatingLamports, inactive: $inactiveLamports)';
}

/// An unsigned transaction plus any ephemeral keypairs that must co-sign it
/// (e.g. the new stake account on a native stake, or split destinations on a
/// partial unstake). Hand to `TransactionExecutor` / `MarketplaceActionFlow`
/// with `additionalSigners: extraSigners`.
class BuiltStakeTx {
  const BuiltStakeTx({
    required this.txBase64,
    this.extraSigners = const [],
    this.delta = NativeStakeDelta.none,
  });

  final String txBase64;
  final List<Ed25519HDKeyPair> extraSigners;

  /// What landing this transaction does to the native-stake buckets.
  final NativeStakeDelta delta;
}

/// Builds the staking transactions, mirroring the webapp's `useStakeAction`:
///
/// **Native** — Stake-program account creation/delegation, deactivation (with
/// split for partial amounts), and withdrawal, each tagged with a 0-lamport
/// FEE_ACCOUNT marker.
///
/// **Liquid** — `createJupiterTransaction`:
///
///   [compute price, compute limit] + Jupiter setup + swap + cleanup +
///   0-lamport FEE_ACCOUNT marker → v0 transaction with address lookup tables
///
/// Jupiter's own `computeBudgetInstructions` are deliberately dropped — the
/// webapp ignores them and prepends its own (its
/// `createVersionedTransactionWithTables`).
@lazySingleton
class StakingTxBuilder {
  StakingTxBuilder(
    this._jupiterClient,
    WalletManager walletManager,
    TxLandedSlots txLandedSlots,
  ) : _walletManager = walletManager,
      // Native staking can only target mallow's mainnet validator, so the
      // whole staking tx lifecycle (build, simulate, broadcast) is pinned to
      // mainnet regardless of the app's environment.
      _rpcService = SolanaRpcService.mainnet(walletManager, txLandedSlots);

  /// Test seam for the on-chain reads. A separate constructor rather than an
  /// optional parameter on the default one so injectable cannot resolve the RPC
  /// from the container — that would hand the builder the *environment's*
  /// connection and silently unpin staking from mainnet.
  @visibleForTesting
  StakingTxBuilder.withRpc(
    this._jupiterClient,
    this._walletManager,
    this._rpcService,
  );

  final JupiterSwapInstructionsClient _jupiterClient;
  final SolanaRpcService _rpcService;
  final WalletManager _walletManager;

  /// The mainnet-pinned RPC this builder uses. Exposed so the staking bloc can
  /// broadcast on the same connection the tx was built and simulated against.
  SolanaRpcService get rpcService => _rpcService;

  /// Stake-config account required by `delegateStake` (protocol constant).
  static const _stakeConfigAddress =
      'StakeConfig11111111111111111111111111111111';

  /// Withdrawer/staker authority lives at byte offset 44 in a stake account —
  /// used to filter `getProgramAccounts` to the user's own stake accounts.
  static const _stakeAuthorityOffset = 44;

  /// "Never deactivated" fallback for `delegation.deactivationEpoch`. On the
  /// wire the sentinel is `u64::MAX`, which does not fit Dart's int64 — so any
  /// u64 read that overflows lands here, and epochs can never legitimately
  /// reach it.
  static const _neverDeactivatedEpoch = 9223372036854775807;

  /// Byte offsets into a stake account's raw `StakeStateV2` data (a fixed
  /// [StakeProgram.neededAccountSpace]-byte, little-endian layout):
  ///
  /// ```text
  ///   0   u32   state discriminant (2 == delegated)
  ///   4   u64   meta.rentExemptReserve
  ///   12  [32]  meta.authorized.staker
  ///   44  [32]  meta.authorized.withdrawer   <- _stakeAuthorityOffset
  ///   76  ..    meta.lockup
  ///   124 [32]  stake.delegation.voter
  ///   156 u64   stake.delegation.stake
  ///   164 u64   stake.delegation.activationEpoch
  ///   172 u64   stake.delegation.deactivationEpoch
  /// ```
  ///
  /// The accounts are read as raw bytes rather than `jsonParsed` on purpose:
  /// agave stopped emitting the deprecated `warmupCooldownRate` field, which
  /// the solana package's `Delegation.fromJson` still casts as a required
  /// `num` — so every jsonParsed stake account now throws
  /// `type 'Null' is not a subtype of type 'num'`, killing unstake and claim.
  /// This binary layout is protocol-level and stable.
  static const _delegatedStateDiscriminant = 2;
  static const _voterOffset = 124;
  static const _delegatedStakeOffset = 156;
  static const _activationEpochOffset = 164;
  static const _deactivationEpochOffset = 172;

  /// Classify a stake account's lifecycle [StakeAccountState] from its
  /// delegation epochs relative to [currentEpoch]. Pure function; exposed for
  /// testing the epoch-boundary rules that gate stake/unstake/withdraw.
  ///
  /// Rules (mirrors the webapp's withdrawable filter in
  /// `useWithdrawStake`):
  /// - A stake delegated and deactivated in the *same* epoch is inactive
  ///   immediately. Solana's stake program short-circuits this case
  ///   (`Delegation::stake_and_activating`: "activated but instantly
  ///   deactivated; no stake at all regardless of target_epoch"), so the
  ///   account has 0 effective / 0 activating / 0 deactivating stake and its
  ///   full lamports are withdrawable right away — no epoch wait.
  /// - Otherwise a deactivation epoch that is set (not the never-deactivated
  ///   sentinel) and has been reached marks the account as deactivating
  ///   (cooling down this epoch) or inactive (fully withdrawable thereafter).
  /// - Otherwise, an activation epoch at or after the current epoch is still
  ///   activating; anything earlier is active and earning.
  static StakeAccountState classifyStakeState({
    required int activationEpoch,
    required int deactivationEpoch,
    required int currentEpoch,
  }) {
    if (deactivationEpoch != _neverDeactivatedEpoch &&
        deactivationEpoch <= currentEpoch) {
      // Stake→unstake inside one epoch — a state the app can produce itself.
      // Treating it as `deactivating` made Claim dead for ~2 days while the
      // backend (and the "X SOL claimable" card it drives) already counted the
      // funds as claimable, so the button returned "Nothing to claim".
      if (deactivationEpoch == activationEpoch) {
        return StakeAccountState.inactive;
      }
      return deactivationEpoch == currentEpoch
          ? StakeAccountState.deactivating
          : StakeAccountState.inactive;
    }
    return activationEpoch >= currentEpoch
        ? StakeAccountState.activating
        : StakeAccountState.active;
  }

  /// Decode one raw stake account into a [StakeAccountInfo], or null when it is
  /// not a delegated stake account pointing at [validatorVoteAddress] (an
  /// uninitialized/initialized account, or one delegated elsewhere). Pure
  /// function; exposed for testing the byte layout the unstake/claim flows
  /// depend on.
  static StakeAccountInfo? decodeStakeAccount({
    required String address,
    required int accountLamports,
    required List<int> data,
    required String validatorVoteAddress,
    required int currentEpoch,
  }) {
    if (data.length < StakeProgram.neededAccountSpace) return null;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(0, Endian.little) != _delegatedStateDiscriminant) {
      return null;
    }

    final voter = Ed25519HDPublicKey.fromBase58(validatorVoteAddress).bytes;
    for (var i = 0; i < voter.length; i++) {
      if (bytes[_voterOffset + i] != voter[i]) return null;
    }

    return StakeAccountInfo(
      address: address,
      accountLamports: accountLamports,
      delegatedLamports: _readU64(view, _delegatedStakeOffset),
      state: classifyStakeState(
        activationEpoch: _readU64(view, _activationEpochOffset),
        deactivationEpoch: _readU64(view, _deactivationEpochOffset),
        currentEpoch: currentEpoch,
      ),
    );
  }

  /// Little-endian u64, saturated at [_neverDeactivatedEpoch] (int64 max).
  /// Dart's int cannot hold a u64 above 2^63-1, and the only field that ever
  /// reaches that range is the `u64::MAX` never-deactivated sentinel — which
  /// is exactly what the saturated value means to [classifyStakeState].
  static int _readU64(ByteData data, int offset) {
    final lo = data.getUint32(offset, Endian.little);
    final hi = data.getUint32(offset + 4, Endian.little);
    if (hi >= 0x80000000) return _neverDeactivatedEpoch;
    return (hi << 32) | lo;
  }

  /// Classic quote for a SOL<->mallowSOL swap (raw-map passthrough).
  Future<JupiterClassicQuote> getQuote({
    required String inputMint,
    required String outputMint,
    required int amount,
  }) => _jupiterClient.getQuote(
    inputMint: inputMint,
    outputMint: outputMint,
    amount: amount,
  );

  /// Compose the unsigned v0 liquid-staking transaction for [quote].
  Future<String> buildLiquidSwapTx({
    required JupiterClassicQuote quote,
    required String feeAccountAddress,
  }) async {
    final address = await _walletManager.getAddress();
    final owner = Ed25519HDPublicKey.fromBase58(address);

    final jupIxs = await _jupiterClient.getSwapInstructions(
      quote: quote,
      userPublicKey: address,
    );

    final coreInstructions = <Instruction>[
      ...jupIxs.setupInstructions.map(_toInstruction),
      _toInstruction(jupIxs.swapInstruction),
      if (jupIxs.cleanupInstruction != null)
        _toInstruction(jupIxs.cleanupInstruction!),
      _feeMarker(owner, feeAccountAddress),
    ];

    final lookupTables = await _rpcService.getAddressLookupTableAccounts(
      jupIxs.addressLookupTableAddresses,
    );
    final computePrefix = await _rpcService.buildComputeBudgetPrefix(
      instructions: coreInstructions,
      addressLookupTableAccounts: lookupTables,
    );

    return _rpcService.buildUnsignedV0TxBase64(
      Message(instructions: [...computePrefix, ...coreInstructions]),
      addressLookupTableAccounts: lookupTables,
    );
  }

  /// Build a native stake: create + initialize a fresh stake account funded
  /// with [stakeLamports] (+ rent), delegate it to [validatorVoteAddress], and
  /// append a 0-lamport marker transfer to [feeAccountAddress]. The new stake
  /// account keypair is returned as an extra signer.
  Future<BuiltStakeTx> buildNativeStakeTx({
    required int stakeLamports,
    required String validatorVoteAddress,
    required String feeAccountAddress,
  }) async {
    final ownerAddress = await _walletManager.getAddress();
    final owner = Ed25519HDPublicKey.fromBase58(ownerAddress);
    final rent = await _rpcService.getMinimumBalanceForRentExemption(
      StakeProgram.neededAccountSpace,
    );
    final stakeAccount = await Ed25519HDKeyPair.random();
    final stakePubKey = stakeAccount.publicKey;

    final instructions = <Instruction>[
      ...StakeInstruction.createAndInitializeAccount(
        fundingAccount: owner,
        newAccount: stakePubKey,
        authorized: Authorized(staker: ownerAddress, withdrawer: ownerAddress),
        lamports: stakeLamports + rent,
      ),
      StakeInstruction.delegateStake(
        stake: stakePubKey,
        vote: Ed25519HDPublicKey.fromBase58(validatorVoteAddress),
        config: Ed25519HDPublicKey.fromBase58(_stakeConfigAddress),
        authority: owner,
      ),
      _feeMarker(owner, feeAccountAddress),
    ];

    final tx = await _buildWithComputeBudget(instructions);
    return BuiltStakeTx(
      txBase64: tx,
      extraSigners: [stakeAccount],
      // The rent surcharge funds the account, it is not delegated —
      // `delegation.stake` (which is what every bucket is counted from) will
      // be exactly [stakeLamports].
      delta: NativeStakeDelta(activatingLamports: stakeLamports),
    );
  }

  /// Build a native unstake for [lamports]: deactivate enough active stake
  /// accounts to cover it, splitting the last one when a partial amount
  /// remains. Throws when the user has less active stake than requested.
  Future<BuiltStakeTx> buildNativeUnstakeTx({
    required int lamports,
    required String validatorVoteAddress,
    required String feeAccountAddress,
  }) async {
    final ownerAddress = await _walletManager.getAddress();
    final owner = Ed25519HDPublicKey.fromBase58(ownerAddress);
    final accounts = await fetchUserStakeAccounts(
      validatorVoteAddress: validatorVoteAddress,
    );
    // Deactivate from active AND activating accounts — both are "not yet
    // deactivated" stake the user can unstake. This matches the webapp's
    // `deactivationEpoch === u64::MAX` filter and our own availableLamports
    // (which counts active + activating); selecting only `active` here would
    // reject an unstake of stake delegated in the current epoch. Largest first
    // so we touch the fewest accounts.
    final deactivatable =
        accounts
            .where(
              (a) =>
                  a.state == StakeAccountState.active ||
                  a.state == StakeAccountState.activating,
            )
            .toList()
          ..sort((a, b) => b.delegatedLamports.compareTo(a.delegatedLamports));

    final instructions = <Instruction>[];
    final extraSigners = <Ed25519HDKeyPair>[];
    var remaining = lamports;
    int? splitRent;
    var delta = NativeStakeDelta.none;

    for (final account in deactivatable) {
      if (remaining <= 0) break;
      final stake = Ed25519HDPublicKey.fromBase58(account.address);
      final taken = account.delegatedLamports <= remaining
          ? account.delegatedLamports
          : remaining;
      delta += _deactivationDelta(from: account.state, lamports: taken);
      if (account.delegatedLamports <= remaining) {
        // Whole account fits — deactivate it outright.
        instructions.add(
          StakeInstruction.deactivate(stake: stake, authority: owner),
        );
        remaining -= account.delegatedLamports;
      } else {
        // Partial — split off exactly `remaining` into a new account and
        // deactivate that, leaving the source account staked. The split
        // destination must be rent-exempt, funded by the payer (parity with
        // the webapp's `StakeProgram.split(params, rent)`); funding it with 0
        // would carve the rent reserve out of the unstaked amount.
        final rent = splitRent ??= await _rpcService
            .getMinimumBalanceForRentExemption(StakeProgram.neededAccountSpace);
        final dest = await Ed25519HDKeyPair.random();
        extraSigners.add(dest);
        instructions.addAll([
          SystemInstruction.createAccount(
            fundingAccount: owner,
            newAccount: dest.publicKey,
            lamports: rent,
            space: StakeProgram.neededAccountSpace,
            owner: Ed25519HDPublicKey.fromBase58(StakeProgram.programId),
          ),
          StakeInstruction.split(
            sourceStake: stake,
            destinationStake: dest.publicKey,
            authority: owner,
            amount: remaining,
          ),
          StakeInstruction.deactivate(stake: dest.publicKey, authority: owner),
        ]);
        remaining = 0;
      }
    }

    if (remaining > 0) {
      throw StateError('Not enough active stake to unstake');
    }

    instructions.add(_feeMarker(owner, feeAccountAddress));
    final tx = await _buildWithComputeBudget(instructions);
    return BuiltStakeTx(txBase64: tx, extraSigners: extraSigners, delta: delta);
  }

  /// Where [lamports] land when a stake account in [from] is deactivated.
  ///
  /// An `active` account cools down for the rest of the epoch, so it becomes
  /// `deactivating`. An `activating` one is deactivated in the same epoch it
  /// was delegated, which Solana short-circuits to "no stake at all" — it is
  /// `inactive`, and claimable, the moment the tx lands. Same rule
  /// [classifyStakeState] applies when it re-reads the account.
  static NativeStakeDelta _deactivationDelta({
    required StakeAccountState from,
    required int lamports,
  }) => switch (from) {
    StakeAccountState.active => NativeStakeDelta(
      activeLamports: -lamports,
      deactivatingLamports: lamports,
    ),
    StakeAccountState.activating => NativeStakeDelta(
      activatingLamports: -lamports,
      inactiveLamports: lamports,
    ),
    // Not selected by the unstake builder — already on their way out.
    StakeAccountState.deactivating ||
    StakeAccountState.inactive => NativeStakeDelta.none,
  };

  /// Build a withdraw of all inactive (deactivated, claimable) stake accounts
  /// back to the user's wallet. Returns null when there is nothing to claim.
  /// Caps at [maxAccounts] accounts per tx to stay within size limits.
  ///
  /// Largest first, like the unstake path and the webapp's
  /// `orderBy(inactiveStakeAccounts, "account.lamports", "desc")`. Ordering is
  /// load-bearing once the cap bites: every partial unstake mints a new split
  /// account, so a user can hold more than [maxAccounts] claimable accounts,
  /// and an unordered `take` would claim an arbitrary RPC-ordered 8 — leaving
  /// the big account behind dust and the "X SOL claimable" card barely moved.
  Future<BuiltStakeTx?> buildWithdrawStakeTx({
    required String validatorVoteAddress,
    int maxAccounts = 8,
  }) async {
    final ownerAddress = await _walletManager.getAddress();
    final owner = Ed25519HDPublicKey.fromBase58(ownerAddress);
    final accounts = await fetchUserStakeAccounts(
      validatorVoteAddress: validatorVoteAddress,
    );
    final inactive =
        accounts.where((a) => a.state == StakeAccountState.inactive).toList()
          // `accountLamports`, not `delegatedLamports`: withdraw reclaims the
          // whole account balance, delegation *plus* the rent reserve, so
          // that is the figure the cap should order by.
          ..sort((a, b) => b.accountLamports.compareTo(a.accountLamports));
    if (inactive.isEmpty) return null;

    final withdrawn = inactive.take(maxAccounts).toList();
    final instructions = <Instruction>[
      for (final account in withdrawn)
        StakeInstruction.withdraw(
          stake: Ed25519HDPublicKey.fromBase58(account.address),
          recipient: owner,
          authority: owner,
          lamports: account.accountLamports,
        ),
    ];
    final tx = await _buildWithComputeBudget(instructions);
    return BuiltStakeTx(
      txBase64: tx,
      // Only the accounts this tx actually withdraws. Past [maxAccounts] the
      // claimable cell must keep showing the remainder rather than emptying —
      // the user has another Claim to make.
      delta: NativeStakeDelta(
        inactiveLamports: -withdrawn.fold(
          0,
          (sum, a) => sum + a.delegatedLamports,
        ),
      ),
    );
  }

  /// The user's native-stake lamports bucketed the way `/v1/staking` buckets
  /// them, read straight from chain instead of from the server's own
  /// (independently lagging) `getProgramAccounts` node.
  ///
  /// [minContextSlot] is the staleness guard: pass the slot one of our own
  /// transactions landed in and the RPC refuses — with an error, not with an
  /// old snapshot — to answer from a view that predates it. Callers treat that
  /// throw as "not caught up yet" and keep their optimistic overlay.
  ///
  /// Counted off `delegation.stake`, and skipping the zero-stake accounts, so
  /// the four figures are directly comparable with the payload's
  /// (`mallowSolHelper.fetchStakeAccountBalancesByStatus`). The one basis
  /// difference is the authority: this is [fetchUserStakeAccounts]'s set,
  /// filtered on the *withdrawer* at offset 44, where the backend groups by
  /// the *staker* at offset 12. Every account the app creates sets both to the
  /// owner, and this set is the one unstake and claim can actually act on, so
  /// they agree in practice — and a divergence would only be visible for the
  /// pending window before the payload takes back over.
  Future<NativeStakeBreakdown> fetchNativeStakeBreakdown({
    required String validatorVoteAddress,
    int? minContextSlot,
  }) async {
    final accounts = await fetchUserStakeAccounts(
      validatorVoteAddress: validatorVoteAddress,
      minContextSlot: minContextSlot,
    );
    var active = 0;
    var activating = 0;
    var deactivating = 0;
    var inactive = 0;
    for (final account in accounts) {
      final lamports = account.delegatedLamports;
      if (lamports <= 0) continue;
      switch (account.state) {
        case StakeAccountState.active:
          active += lamports;
        case StakeAccountState.activating:
          activating += lamports;
        case StakeAccountState.deactivating:
          deactivating += lamports;
        case StakeAccountState.inactive:
          inactive += lamports;
      }
    }
    return NativeStakeBreakdown(
      activeLamports: active,
      activatingLamports: activating,
      deactivatingLamports: deactivating,
      inactiveLamports: inactive,
    );
  }

  /// Claimable season rewards for the active wallet, in raw [mint] units.
  ///
  /// Season SMORES are airdropped as ZK-compressed tokens, so they are
  /// invisible to every SPL balance read until `/v1/staking/getClaimTx`
  /// decompresses them into the wallet's ATA. This is the amount that claim
  /// will move — and the gate on the "Your Rewards" cell.
  Future<int> fetchClaimableCompressedBalance({required String mint}) async {
    final owner = await _walletManager.getAddress();
    return _rpcService.getCompressedTokenBalance(owner: owner, mint: mint);
  }

  /// Current epoch progress snapshot for the unstake tab's countdown / progress
  /// cards.
  Future<EpochProgress> getEpochProgress() async {
    final info = await _rpcService.getEpochProgress();
    return EpochProgress(
      epoch: info.epoch,
      slotIndex: info.slotIndex,
      slotsInEpoch: info.slotsInEpoch,
    );
  }

  /// Enumerate the user's stake accounts delegated to [validatorVoteAddress],
  /// classified by [StakeAccountState] against the current epoch. Mirrors the
  /// webapp's `fetchUserStakeAccounts` (getProgramAccounts on the Stake
  /// program, filtered by data size + withdrawer authority).
  ///
  /// [minContextSlot] rejects a node whose view predates that slot — see
  /// [fetchNativeStakeBreakdown].
  Future<List<StakeAccountInfo>> fetchUserStakeAccounts({
    required String validatorVoteAddress,
    int? minContextSlot,
  }) async {
    final [ownerAddress as String, epoch as int] = await Future.wait([
      _walletManager.getAddress(),
      _rpcService.getCurrentEpoch(),
    ]);

    final accounts = await _rpcService.getProgramAccounts(
      StakeProgram.programId,
      encoding: Encoding.base64,
      filters: [
        const ProgramDataFilter.dataSize(StakeProgram.neededAccountSpace),
        ProgramDataFilter.memcmpBase58(
          offset: _stakeAuthorityOffset,
          bytes: ownerAddress,
        ),
      ],
      minContextSlot: minContextSlot,
    );

    final result = <StakeAccountInfo>[];
    for (final account in accounts) {
      final data = account.account.data;
      if (data is! BinaryAccountData) continue;
      final info = decodeStakeAccount(
        address: account.pubkey,
        accountLamports: account.account.lamports,
        data: data.data,
        validatorVoteAddress: validatorVoteAddress,
        currentEpoch: epoch,
      );
      if (info != null) result.add(info);
    }
    return result;
  }

  /// Prepend the simulated compute-budget prefix to [instructions] and compile
  /// to an unsigned legacy transaction (base64).
  Future<String> _buildWithComputeBudget(List<Instruction> instructions) async {
    final computePrefix = await _rpcService.buildComputeBudgetPrefix(
      instructions: instructions,
    );
    return _rpcService.buildUnsignedTxBase64(
      Message(instructions: [...computePrefix, ...instructions]),
    );
  }

  /// 0-lamport transfer to the fee account, used as a backend attribution
  /// marker on stake/unstake txs (parity with the webapp).
  static Instruction _feeMarker(
    Ed25519HDPublicKey owner,
    String feeAccountAddress,
  ) => SystemInstruction.transfer(
    fundingAccount: owner,
    recipientAccount: Ed25519HDPublicKey.fromBase58(feeAccountAddress),
    lamports: 0,
  );

  /// Jupiter's serialized instruction shape → the solana package's
  /// [Instruction] (webapp `deserializeInstruction`).
  static Instruction _toInstruction(JupSerializedInstruction ix) => Instruction(
    programId: Ed25519HDPublicKey.fromBase58(ix.programId),
    accounts: [
      for (final account in ix.accounts)
        account.isWritable
            ? AccountMeta.writeable(
                pubKey: Ed25519HDPublicKey.fromBase58(account.pubkey),
                isSigner: account.isSigner,
              )
            : AccountMeta.readonly(
                pubKey: Ed25519HDPublicKey.fromBase58(account.pubkey),
                isSigner: account.isSigner,
              ),
    ],
    data: ByteArray(base64Decode(ix.dataBase64)),
  );
}
