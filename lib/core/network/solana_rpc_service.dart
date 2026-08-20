import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:solana/base58.dart';
import 'package:solana/dto.dart' hide Instruction;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../config/environment.dart';
import '../crypto/wallet_manager.dart';
import '../services/fee_config.dart';
import '../services/priority_fee_service.dart';
import '../services/tx_landed_slots.dart';

/// Result of a transaction simulation.
class SimulationResult {
  const SimulationResult({
    required this.success,
    this.error,
    this.logs,
    this.unitsConsumed,
    this.inspectedAccountLamports = const {},
    this.inspectedAccountTokenAmounts = const {},
  });

  /// Whether the simulation succeeded (transaction would execute).
  final bool success;

  /// Error message if simulation failed.
  final String? error;

  /// Program logs from the simulation.
  final List<String>? logs;

  /// Compute units that would be consumed.
  final int? unitsConsumed;

  /// Post-simulation lamport balance for each account passed to
  /// [SolanaRpcService.simulateEncodedTransaction] via `inspectAccounts`.
  /// Keyed by base58 address; unset for non-inspected calls. The simulator
  /// deducts the tx fee from the payer, so subtracting the caller-known
  /// pre-balance yields the net SOL change (rent reclaimed minus fee).
  final Map<String, int> inspectedAccountLamports;

  /// Post-simulation SPL token amount (base units) for each inspected account
  /// that is an SPL / Token-2022 token account, keyed by base58 address.
  /// Parsed from the standard token-account layout (amount at byte offset 64);
  /// absent for inspected accounts that aren't token accounts. Callers compare
  /// against a pre-balance to derive how many tokens an account gained.
  final Map<String, int> inspectedAccountTokenAmounts;

  /// Returns true if this result indicates a warning (simulation failed).
  bool get hasWarning => !success;

  /// Human-readable summary of the simulation result.
  String get summary {
    if (success) {
      final units = unitsConsumed ?? 0;
      return 'Transaction will succeed (~$units compute units)';
    }
    return error ?? 'Transaction simulation failed';
  }
}

/// A [SimulationResult] paired with the inspected payer's net lamport change.
class SimulationDelta {
  const SimulationDelta({required this.result, this.lamportsDelta});

  /// The raw simulation result (success flag, logs, error, etc.).
  final SimulationResult result;

  /// Signed change in the inspected address's lamports under simulation
  /// (`post − pre`). Negative when the tx costs the payer SOL, positive when
  /// it nets a refund (e.g. rent reclaimed on a burn). Null when the delta
  /// can't be derived — no address inspected, the pre-balance fetch failed,
  /// the simulation failed, or the account wasn't returned by the RPC.
  final int? lamportsDelta;
}

/// A token account the wallet actually holds: its address, the token program
/// that owns it (classic SPL vs Token-2022) and its raw balance.
typedef OwnedTokenAccount = ({
  String address,
  TokenProgramType program,
  int amount,
});

/// A compute-budget prefix together with the exact prioritization fee it
/// commits a transaction to paying.
///
/// The pair matters because the two numbers are only meaningful together: the
/// unit price is per compute unit, so the fee cannot be read off either
/// instruction alone, and the runtime charges on the *declared* limit rather
/// than the units consumed.
@immutable
class ComputeBudgetPlan {
  const ComputeBudgetPlan({
    required this.instructions,
    required this.computeUnits,
    required this.microLamportsPerUnit,
  });

  /// `[setComputeUnitPrice, setComputeUnitLimit]`, to prepend to a message.
  final List<Instruction> instructions;

  /// The unit limit declared by the prefix — the figure the fee is charged on.
  final int computeUnits;

  /// The declared price per compute unit, in micro-lamports.
  final int microLamportsPerUnit;

  /// Prioritization fee in lamports: `ceil(units × price ÷ 1e6)`, matching the
  /// runtime's own rounding. Integer arithmetic throughout — a `double`
  /// intermediate would put a lamport of slop into a figure whose whole purpose
  /// is to be exact.
  int get priorityFeeLamports =>
      (computeUnits * microLamportsPerUnit + 999999) ~/ 1000000;
}

/// What a native-SOL transfer will cost, resolved before the transfer exists.
@immutable
class SolTransferFeePlan {
  const SolTransferFeePlan({required this.budget, required this.feeLamports});

  /// The prefix the transfer must be built with for [feeLamports] to hold.
  final ComputeBudgetPlan budget;

  /// Total lamports the sender is charged: base signature fee + priority fee.
  final int feeLamports;
}

/// Service for interacting with Solana blockchain via RPC.
///
/// Provides high-level methods for common operations like:
/// - Getting balances (SOL and SPL tokens)
/// - Sending transactions
/// - Fetching account info
/// - Requesting airdrops (devnet only)
@lazySingleton
class SolanaRpcService {
  /// Default instance, wired to the environment's RPC (devnet in
  /// dev/staging, mainnet in production). This is the DI-registered singleton.
  ///
  /// [txLandedSlots] is deliberately a plain non-nullable parameter rather than
  /// a `this._txLandedSlots` initializing formal: injectable's type equality
  /// includes nullability, so an initializing formal would make this dependency
  /// `TxLandedSlots?` — which never matches the non-nullable `@lazySingleton`
  /// registration, and the config builder then reports it as unregistered.
  SolanaRpcService(this._walletManager, TxLandedSlots txLandedSlots)
    : _txLandedSlots = txLandedSlots,
      _rpcUrl = Config.solanaRpcUrl;

  /// Mainnet-pinned instance, used by the staking feature so native staking
  /// always targets mallow's mainnet validator regardless of the app's
  /// environment. Constructed directly (not via DI) — see [StakingTxBuilder],
  /// which hands it the container's [TxLandedSlots] so a staking tx's landed
  /// slot still becomes the floor its own stake-account re-read is guarded by
  /// (`minContextSlot`).
  SolanaRpcService.mainnet(this._walletManager, this._txLandedSlots)
    : _rpcUrl = Config.solanaMainnetRpcUrl;

  final WalletManager _walletManager;

  /// Records each confirmed signature's landed slot — the per-action ordering
  /// floor consumed by slot-aware reconciliation (see [TxLandedSlots]).
  final TxLandedSlots? _txLandedSlots;

  /// The RPC endpoint this instance talks to.
  final String _rpcUrl;

  /// Client-id header for [_rpcUrl], or empty when that host is not configured
  /// first-party. Every request below builds its own headers — the `RpcClient`
  /// and the one-off `Dio`s bypass the shared client's interceptor chain — so
  /// the host gate has to be applied here instead. See
  /// `Config.clientIdHeadersFor`.
  late final Map<String, String> _rpcHeaders = Config.clientIdHeadersFor(
    Uri.parse(_rpcUrl),
  );

  late final RpcClient _rpcClient = RpcClient(
    _rpcUrl,
    customHeaders: _rpcHeaders,
  );

  /// Get SOL balance for the current wallet in lamports.
  ///
  /// Returns balance in lamports (1 SOL = 1_000_000_000 lamports).
  Future<int> getBalance() async {
    final address = await _walletManager.getAddress();
    return getBalanceForAddress(address);
  }

  /// Get SOL balance for a specific address in lamports.
  Future<int> getBalanceForAddress(String address) async {
    final result = await _rpcClient.getBalance(address);
    return result.value;
  }

  /// Get SOL balance formatted as a double.
  ///
  /// Returns balance in SOL (e.g., 1.5 SOL).
  Future<double> getBalanceInSol() async {
    final lamports = await getBalance();
    return lamportsToSol(lamports);
  }

  /// Convert lamports to SOL.
  static double lamportsToSol(int lamports) {
    return lamports / lamportsPerSol;
  }

  /// Convert SOL to lamports.
  static int solToLamports(double sol) {
    return (sol * lamportsPerSol).round();
  }

  /// Get all SPL token accounts for the current wallet.
  ///
  /// Returns a list of token account results.
  Future<ProgramAccountsResult> getTokenAccounts() async {
    final address = await _walletManager.getAddress();
    return getTokenAccountsForAddress(address);
  }

  /// Get all SPL token accounts for a specific address.
  Future<ProgramAccountsResult> getTokenAccountsForAddress(
    String address,
  ) async {
    return _rpcClient.getTokenAccountsByOwner(
      address,
      const TokenAccountsFilter.byProgramId(TokenProgram.programId),
      encoding: Encoding.jsonParsed,
    );
  }

  /// Get account info for any address.
  ///
  /// Pass [encoding] (e.g. `Encoding.base64`) when you need to decode the
  /// returned `data` as binary; without it some RPCs return jsonParsed
  /// payloads that won't match `BinaryAccountData`.
  ///
  /// Pass [dataSlice] when only the account's metadata (owner, lamports,
  /// executable) is needed — `DataSlice(offset: 0, length: 0)` keeps the
  /// response small no matter how large the account is.
  Future<AccountResult> getAccountInfo(
    String address, {
    Encoding? encoding,
    DataSlice? dataSlice,
  }) async {
    return _rpcClient.getAccountInfo(
      address,
      encoding: encoding,
      dataSlice: dataSlice,
    );
  }

  /// Determines whether [mint] is owned by the classic SPL token program or
  /// the SPL-2022 program by inspecting the mint account's owner. Falls back
  /// to classic SPL on any lookup failure.
  Future<TokenProgramType> getTokenProgramTypeForMint(String mint) async {
    try {
      // base64 required: a Token-2022 mint with extensions exceeds 128 bytes,
      // which the RPC default (base58) rejects — the very mints this detects.
      // Without it the fetch throws, falls through to classic SPL, and the
      // transfer targets the wrong program.
      final info = await _rpcClient.getAccountInfo(
        mint,
        encoding: Encoding.base64,
      );
      if (info.value?.owner == Token2022Program.programId) {
        return TokenProgramType.token2022Program;
      }
    } catch (_) {}
    return TokenProgramType.tokenProgram;
  }

  /// Get the latest blockhash for transaction signing.
  Future<String> getLatestBlockhash() async {
    final result = await _rpcClient.getLatestBlockhash();
    return result.value.blockhash;
  }

  /// Send a signed transaction to the network.
  ///
  /// Returns the transaction signature (tx ID).
  Future<String> sendTransaction(SignedTx signedTx) async {
    final encoded = signedTx.encode();
    try {
      return await _rpcClient.sendTransaction(
        encoded,
        preflightCommitment: Commitment.confirmed,
      );
    } catch (e) {
      // The RPC runs a preflight simulation on submit; a failure surfaces as
      // a jsonrpc -32002 here (not through simulateEncodedTransaction). Log an
      // Explorer tx-inspector link (debug-only) so the failing tx can be
      // decoded in the browser, then rethrow unchanged.
      final inspectUrl = _inspectorUrl(
        signedTx.compiledMessage.toByteArray().toList(),
      );
      if (inspectUrl != null) {
        _debugPrintInspectUrl(
          '[RPC] sendTransaction preflight failed — inspect:',
          inspectUrl,
        );
      }
      rethrow;
    }
  }

  /// Explorer tx-inspector link for the serialized (signature-stripped)
  /// [messageBytes], so a failed simulation's decoded instructions/accounts
  /// can be opened in the browser. Returns null outside debug builds — the
  /// message embeds account addresses and must not reach release logs.
  ///
  /// `cluster` comes first so it survives even if the (long) `message` tail is
  /// truncated, and is derived per-instance from [_rpcUrl] — this service has a
  /// mainnet-pinned variant that runs mainnet even in a devnet build.
  String? _inspectorUrl(List<int> messageBytes) {
    if (!kDebugMode) return null;
    final cluster = _rpcUrl.contains('devnet') ? 'cluster=devnet&' : '';
    return 'https://explorer.solana.com/tx/inspector?$cluster'
        'message=${Uri.encodeComponent(base64.encode(messageBytes))}';
  }

  /// [debugPrint] an inspector [url] in chunks. A large tx's inspector URL
  /// exceeds Android logcat's per-line cap, which silently truncates the tail
  /// — dropping the trailing `message` bytes so the inspector rejects it
  /// ("Reached end of buffer"). Emitting it in sub-cap slices keeps the whole
  /// URL recoverable: join the printed lines back together in order.
  void _debugPrintInspectUrl(String label, String url) {
    const chunkSize = 800;
    if (url.length <= chunkSize) {
      debugPrint('$label $url');
      return;
    }
    final chunks = (url.length / chunkSize).ceil();
    debugPrint('$label (join the next $chunks lines):');
    for (var i = 0; i < url.length; i += chunkSize) {
      debugPrint(url.substring(i, math.min(i + chunkSize, url.length)));
    }
  }

  /// Compile [message] into a base64-encoded *unsigned* transaction (with
  /// placeholder signatures), ready for [TransactionExecutor] / signSendConfirm
  /// to sign and broadcast. Mirrors the placeholder compilation used by
  /// [simulateMessage]. The blockhash is set here but signSendConfirm refreshes
  /// it client-side before signing, since the tx carries no pre-attached
  /// signature.
  Future<String> buildUnsignedTxBase64(Message message) async {
    final blockhash = await getLatestBlockhash();
    final payerAddress = await _walletManager.getAddress();
    final feePayer = Ed25519HDPublicKey.fromBase58(payerAddress);
    final compiledMessage = message.compile(
      recentBlockhash: blockhash,
      feePayer: feePayer,
    );
    final placeholders = List.generate(
      compiledMessage.requiredSignatureCount,
      (_) => Signature(List<int>.filled(64, 0), publicKey: feePayer),
    );
    return SignedTx(
      signatures: placeholders,
      compiledMessage: compiledMessage,
    ).encode();
  }

  /// Build an unsigned SOL-transfer transaction (base64) for [destination] /
  /// [lamports]. The caller routes it through [TransactionExecutor] for the
  /// single shared sign/broadcast path.
  /// [pinnedBudget] is the prefix a Max send already priced its amount
  /// against ([planSolTransferFee]). It MUST be reused rather than re-probed:
  /// `amount = balance − fee` only holds for the fee that plan quoted, and a
  /// fresh probe here would re-price the transaction after the amount was
  /// frozen — leaving the account short of the new fee, or holding dust the
  /// runtime then rejects as rent-paying.
  Future<String> buildSolTransferTx({
    required String destination,
    required int lamports,
    ComputeBudgetPlan? pinnedBudget,
  }) async {
    final sourceAddress = await _walletManager.getAddress();
    final sourceKey = Ed25519HDPublicKey.fromBase58(sourceAddress);
    final destinationKey = Ed25519HDPublicKey.fromBase58(destination);

    final instruction = SystemInstruction.transfer(
      fundingAccount: sourceKey,
      recipientAccount: destinationKey,
      lamports: lamports,
    );

    // A send with no compute-budget prefix bids the network's floor priority
    // fee, which is what leaves it unlanded until its blockhash expires. The
    // webapp puts these instructions on every transaction it builds; so do we.
    final prefix =
        pinnedBudget?.instructions ??
        await buildComputeBudgetPrefix(instructions: [instruction]);

    return buildUnsignedTxBase64(
      Message(instructions: [...prefix, instruction]),
    );
  }

  /// Build an unsigned SPL/SPL-2022 token-transfer transaction (base64),
  /// creating the destination ATA when it doesn't exist yet. The caller routes
  /// it through [TransactionExecutor] for the single shared sign/broadcast path.
  ///
  /// The source account and its owning token program (classic SPL vs
  /// Token-2022) come from one live [findOwnedTokenAccount] read — the same
  /// authoritative resolution the burn path uses. This is deliberately *not*
  /// [getTokenProgramTypeForMint], whose catch-all falls back to classic SPL on
  /// any RPC hiccup and then derives a classic-seed ATA that doesn't exist for a
  /// Token-2022 mint, addressing the ixs to the wrong program — the on-chain
  /// `IncorrectProgramId` failure that only surfaces AFTER the user has signed.
  /// An RPC failure during resolution now propagates (callers wrap it in a
  /// Result) instead of silently guessing the wrong program.
  ///
  /// Throws when the wallet holds no account for [tokenMint] — there is nothing
  /// to transfer, and a transfer from a non-existent source would otherwise
  /// fail on-chain with the same opaque error after signing.
  Future<String> buildSplTransferTx({
    required String destination,
    required String tokenMint,
    required int amount,
  }) async {
    final sourceAddress = await _walletManager.getAddress();
    final sourceKey = Ed25519HDPublicKey.fromBase58(sourceAddress);
    final destinationKey = Ed25519HDPublicKey.fromBase58(destination);
    final mintKey = Ed25519HDPublicKey.fromBase58(tokenMint);

    final holding = await requireOwnedTokenAccount(
      owner: sourceAddress,
      mint: tokenMint,
    );
    final tokenProgramType = holding.program;
    final sourceAta = Ed25519HDPublicKey.fromBase58(holding.address);

    // The recipient's ATA MUST be derived with the same token program the mint
    // uses (from the resolved holding), or a Token-2022 transfer would credit a
    // classic-seed address the program never created.
    final destinationAta = await findAssociatedTokenAddress(
      owner: destinationKey,
      mint: mintKey,
      tokenProgramType: tokenProgramType,
    );

    final instructions = <Instruction>[];

    // base64 required: base58 (the RPC default) rejects the 165-byte token
    // account, so an existing destination ATA would fail this existence check.
    final destAtaInfo = await _rpcClient.getAccountInfo(
      destinationAta.toBase58(),
      encoding: Encoding.base64,
    );
    if (destAtaInfo.value == null) {
      instructions.add(
        AssociatedTokenAccountInstruction.createAccount(
          funder: sourceKey,
          address: destinationAta,
          owner: destinationKey,
          mint: mintKey,
          tokenProgramId: tokenProgramType.id,
        ),
      );
    }

    instructions.add(
      TokenInstruction.transfer(
        source: sourceAta,
        destination: destinationAta,
        owner: sourceKey,
        amount: amount,
        tokenProgram: tokenProgramType,
      ),
    );

    // Same reasoning as [buildSolTransferTx]: simulate, price, and prepend the
    // compute-budget instructions so the transfer competes for block space.
    // The simulation also sizes the budget around the optional ATA creation,
    // which is the expensive half of this transaction.
    final prefix = await buildComputeBudgetPrefix(instructions: instructions);

    return buildUnsignedTxBase64(
      Message(instructions: [...prefix, ...instructions]),
    );
  }

  /// Raw token amount (base units) currently held in [tokenAccount], read live
  /// from the chain. Returns 0 when the account is missing or the balance
  /// can't be parsed — callers treat that as "nothing to burn".
  Future<int> getTokenAccountAmount(String tokenAccount) async {
    try {
      final result = await _rpcClient.getTokenAccountBalance(tokenAccount);
      return int.tryParse(result.value.amount) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Associated token account address for [owner] + [mint], resolving the
  /// mint's token program (classic vs Token-2022) so the derived ATA matches
  /// the one the on-chain program credits. Used to inspect a specific holder's
  /// token balance under simulation (e.g. seller proceeds on auction settle).
  Future<String> resolveAssociatedTokenAccount({
    required String owner,
    required String mint,
  }) async {
    final tokenProgramType = await getTokenProgramTypeForMint(mint);
    final ata = await findAssociatedTokenAddress(
      owner: Ed25519HDPublicKey.fromBase58(owner),
      mint: Ed25519HDPublicKey.fromBase58(mint),
      tokenProgramType: tokenProgramType,
    );
    return ata.toBase58();
  }

  /// Parse the token balance (base units) from a returned [account] when it's
  /// an SPL / Token-2022 token account. The base layout is identical for both
  /// programs — the `amount` is a little-endian u64 at byte offset 64 — and
  /// Token-2022 extensions only append trailing bytes, so the offset holds
  /// regardless. Returns null for non-token accounts so callers can tell
  /// "not a token account" apart from a zero balance.
  static int? _parseTokenAccountAmount(Account account) {
    const tokenProgramId = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
    const token2022ProgramId = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
    if (account.owner != tokenProgramId &&
        account.owner != token2022ProgramId) {
      return null;
    }
    final data = account.data;
    if (data is! BinaryAccountData) return null;
    final bytes = data.data;
    if (bytes.length < 72) return null;
    return ByteData.sublistView(
      Uint8List.fromList(bytes),
    ).getUint64(64, Endian.little);
  }

  /// The wallet's live token account for [mint]: its address, the token
  /// program that owns it, and its raw balance. Resolved with a single
  /// `getTokenAccountsByOwner` mint-filtered read, which spans both the classic
  /// SPL program and Token-2022 — the account's own `owner` field is then the
  /// authoritative program id.
  ///
  /// This is deliberately *not* "derive the ATA + probe the mint's owner": that
  /// pair guesses twice. [getTokenProgramTypeForMint] falls back to classic SPL
  /// whenever the mint read fails (RPC hiccup, proxy 429), which for a
  /// Token-2022 holding derives a classic-seed ATA that doesn't exist and
  /// addresses the ixs to the wrong program — the on-chain
  /// `IncorrectProgramId` failure. Reading the account the wallet actually
  /// holds can't drift from the program that owns it.
  ///
  /// Prefers the ATA when the wallet holds several accounts for the mint
  /// (auxiliary accounts exist), otherwise the largest balance. Returns null
  /// when the wallet holds no account for [mint] — callers that cannot proceed
  /// without one should use [requireOwnedTokenAccount].
  Future<OwnedTokenAccount?> findOwnedTokenAccount({
    required String owner,
    required String mint,
  }) async {
    final accounts = await _rpcClient.getTokenAccountsByOwner(
      owner,
      TokenAccountsFilter.byMint(mint),
      encoding: Encoding.jsonParsed,
      commitment: Commitment.confirmed,
    );

    final holdings = <OwnedTokenAccount>[];
    for (final account in accounts.value) {
      final program = switch (account.account.owner) {
        TokenProgram.programId => TokenProgramType.tokenProgram,
        Token2022Program.programId => TokenProgramType.token2022Program,
        _ => null,
      };
      if (program == null) continue;
      final parsed = switch (account.account.data) {
        ParsedSplTokenProgramAccountData(:final parsed) => parsed,
        ParsedSplToken2022ProgramAccountData(:final parsed) => parsed,
        _ => null,
      };
      if (parsed is! TokenAccountData) continue;
      holdings.add((
        address: account.pubkey,
        program: program,
        amount: int.tryParse(parsed.info.tokenAmount.amount) ?? 0,
      ));
    }
    if (holdings.isEmpty) return null;
    if (holdings.length == 1) return holdings.first;

    final ata = (await findAssociatedTokenAddress(
      owner: Ed25519HDPublicKey.fromBase58(owner),
      mint: Ed25519HDPublicKey.fromBase58(mint),
      tokenProgramType: holdings.first.program,
    )).toBase58();
    return holdings.firstWhere(
      (h) => h.address == ata,
      orElse: () => holdings.reduce((a, b) => b.amount > a.amount ? b : a),
    );
  }

  /// [findOwnedTokenAccount], throwing when the wallet holds no account for
  /// [mint]. Every builder and simulator on the transfer path needs the holding
  /// to address its instructions, so the "no holding" failure is raised once
  /// here rather than restated at each call site — a divergent message between
  /// the simulated and executed paths would read as two different faults.
  Future<OwnedTokenAccount> requireOwnedTokenAccount({
    required String owner,
    required String mint,
  }) async {
    final holding = await findOwnedTokenAccount(owner: owner, mint: mint);
    if (holding == null) {
      throw StateError('This wallet holds no token account for $mint');
    }
    return holding;
  }

  /// Build an unsigned transaction (base64) that burns the wallet's *entire*
  /// balance of [tokenMint] and closes the token account holding it, reclaiming
  /// the account rent to the owner. The caller routes it through
  /// [TransactionExecutor] for the single shared sign/broadcast path.
  ///
  /// The account, its owning token program (classic SPL vs Token-2022) and the
  /// burn amount all come from one live [findOwnedTokenAccount] read, so a
  /// stale balance can't leave dust behind ([TokenInstruction.closeAccount]
  /// only succeeds when the account's token balance is zero) and the ixs can't
  /// be addressed to the wrong token program. When the account already holds
  /// nothing the burn ix is skipped and the tx just closes it.
  ///
  /// A Token-2022 account carrying withheld transfer fees gets a
  /// harvest-to-mint ix between the two: burning the balance
  /// does not touch the withheld amount, and Token-2022 rejects the close while
  /// any remains (`AccountHasWithheldTransferFees`, custom program error 35).
  ///
  /// Throws when the wallet holds no account for [tokenMint] — building a
  /// close against a non-existent account would fail on-chain with an opaque
  /// `IncorrectProgramId` after the user has already signed.
  Future<String> buildBurnAndCloseTx({required String tokenMint}) async {
    final ownerAddress = await _walletManager.getAddress();
    final owner = Ed25519HDPublicKey.fromBase58(ownerAddress);
    final mintKey = Ed25519HDPublicKey.fromBase58(tokenMint);

    final holding = await requireOwnedTokenAccount(
      owner: ownerAddress,
      mint: tokenMint,
    );
    final tokenAccount = Ed25519HDPublicKey.fromBase58(holding.address);

    final withheldFees = holding.program == TokenProgramType.token2022Program
        ? await withheldTransferFees(holding.address)
        : 0;

    final instructions = <Instruction>[
      if (holding.amount > 0)
        TokenInstruction.burn(
          amount: holding.amount,
          accountToBurnFrom: tokenAccount,
          mint: mintKey,
          owner: owner,
          tokenProgram: holding.program,
        ),
      if (withheldFees > 0)
        _harvestWithheldTokensToMint(mint: mintKey, tokenAccount: tokenAccount),
      TokenInstruction.closeAccount(
        accountToClose: tokenAccount,
        destination: owner,
        owner: owner,
        tokenProgram: holding.program,
      ),
    ];

    return buildUnsignedTxBase64(Message(instructions: instructions));
  }

  /// Transfer-fee tokens withheld inside [tokenAccount] by the Token-2022
  /// `TransferFeeAmount` extension, or 0 when the account carries no such
  /// extension. Fees taken out of transfers *into* an account accumulate on the
  /// account itself until somebody harvests them to the mint, and they are held
  /// separately from the spendable `amount` — so an account can read as empty
  /// and still refuse to close.
  ///
  /// Parsed off the raw account rather than `jsonParsed` because the solana
  /// package's parsed token-account model drops the extension list. Layout:
  /// the 165-byte base account, an account-type byte, then TLV entries of
  /// `u16 type | u16 length | data`; `transferFeeAmount` is a single u64.
  Future<int> withheldTransferFees(String tokenAccount) async {
    final info = await _rpcClient.getAccountInfo(
      tokenAccount,
      encoding: Encoding.base64,
      commitment: Commitment.confirmed,
    );
    final data = info.value?.data;
    if (data is! BinaryAccountData) return 0;

    final bytes = Uint8List.fromList(data.data);
    final view = ByteData.sublistView(bytes);
    // 165-byte base token account + 1 account-type byte.
    var offset = 166;
    while (offset + 4 <= bytes.length) {
      final type = view.getUint16(offset, Endian.little);
      final length = view.getUint16(offset + 2, Endian.little);
      offset += 4;
      if (offset + length > bytes.length) return 0;
      if (type == ExtensionType.transferFeeAmount.value && length >= 8) {
        return view.getUint64(offset, Endian.little);
      }
      offset += length;
    }
    return 0;
  }

  /// Token-2022 `TransferFeeInstruction::HarvestWithheldTokensToMint`: moves an
  /// account's withheld transfer fees back to the mint so the account can be
  /// closed. Permissionless — no signer, and the program logs-and-skips any
  /// account without the extension rather than failing the tx.
  ///
  /// Hand-encoded because the solana package exposes no transfer-fee extension
  /// builder: byte 0 is the extension's instruction index (26), byte 1 the
  /// variant index within it (4).
  static Instruction _harvestWithheldTokensToMint({
    required Ed25519HDPublicKey mint,
    required Ed25519HDPublicKey tokenAccount,
  }) => Instruction(
    programId: Token2022Program.id,
    accounts: [
      AccountMeta.writeable(pubKey: mint, isSigner: false),
      AccountMeta.writeable(pubKey: tokenAccount, isSigner: false),
    ],
    data: ByteArray(const [26, 4]),
  );

  /// Current epoch number (`getEpochInfo`).
  Future<int> getCurrentEpoch() async =>
      (await _rpcClient.getEpochInfo()).epoch;

  /// Current epoch progress (`getEpochInfo`): epoch number plus how far through
  /// the epoch we are (slots), for the staking unstake countdown / progress
  /// card. Returned as a record so the solana DTO stays encapsulated here.
  Future<({int epoch, int slotIndex, int slotsInEpoch})>
  getEpochProgress() async {
    final info = await _rpcClient.getEpochInfo();
    return (
      epoch: info.epoch,
      slotIndex: info.slotIndex,
      slotsInEpoch: info.slotsInEpoch,
    );
  }

  /// Generic `getProgramAccounts` passthrough.
  ///
  /// [minContextSlot] makes the read refuse to be stale: a node whose view is
  /// older than the given slot answers with an error instead of a snapshot
  /// that predates it. Pass the landed slot of a transaction whose effect the
  /// caller must see, and treat the resulting failure as "not caught up yet"
  /// rather than as "no accounts".
  Future<List<ProgramAccount>> getProgramAccounts(
    String programId, {
    required Encoding encoding,
    List<ProgramDataFilter>? filters,
    int? minContextSlot,
  }) => _rpcClient.getProgramAccounts(
    programId,
    encoding: encoding,
    filters: filters,
    minContextSlot: minContextSlot,
  );

  // ==========================================================================
  // Compute budget / priority fees (webapp parity)
  //
  // Mirrors the server's shared Solana helpers `createLegacyTransaction` /
  // `createVersionedTransactionWithTables`: simulate the instructions to size
  // the compute budget (×1.1), ask Helius for a recommended unit price, and
  // prepend [setComputeUnitPrice, setComputeUnitLimit]. Constants from
  // the server's shared instruction builders.
  // ==========================================================================

  static const _maxComputeBudget = 1400000;
  static const _defaultComputeBudget = 200000;
  static const _minComputeUnits = 10000;
  static const _computeBudgetMultiplier = 1.1;

  /// All-zero pubkey in base58 — a valid placeholder blockhash for simulation
  /// and fee probes (the RPC replaces/ignores it).
  static const _placeholderBlockhash = '11111111111111111111111111111111';

  /// Webapp's `units → computeBudget` rule: floor at [_minComputeUnits] (or
  /// fall back to [_defaultComputeBudget] when simulation failed), pad ×1.1,
  /// cap at [_maxComputeBudget].
  static int resolveComputeBudget(int? simulatedUnits) {
    final units = simulatedUnits == null
        ? _defaultComputeBudget
        : math.max(_minComputeUnits, simulatedUnits);
    return math.min(
      (units * _computeBudgetMultiplier).ceil(),
      _maxComputeBudget,
    );
  }

  /// The user's global priority-fee ceiling (Settings → Priority Fee), or
  /// Auto's default when the app's DI container isn't up — the `.mainnet`
  /// instance and unit tests both construct this service outside it. Shared
  /// with the send flow's Max reserve, which holds back exactly what this
  /// ceiling lets a transaction bid.
  static int get _priorityFeeCeilingLamports =>
      activePriorityFeeCeilingLamports;

  /// Webapp's `getComputeIxs`: a unit-price ix (Helius recommendation clamped
  /// to the `[15k, ceiling]`-lamport fee window for this budget, floored at
  /// 15k microlamports) plus a unit-limit ix when the budget differs from the
  /// 200k default.
  ///
  /// [maxPriorityFeeLamports] is the ceiling in lamports for the whole
  /// transaction; it defaults to the user's global Settings → Priority Fee
  /// selection, which is what makes raising that setting actually raise the
  /// fee every client-built Solana transaction is willing to pay.
  static List<Instruction> computeBudgetIxs({
    required int computeBudget,
    int? recommendedMicroLamports,
    int? maxPriorityFeeLamports,
    bool alwaysSetUnitLimit = false,
  }) {
    final microLamports = resolveUnitPriceMicroLamports(
      computeBudget: computeBudget,
      recommendedMicroLamports: recommendedMicroLamports,
      maxPriorityFeeLamports: maxPriorityFeeLamports,
    );
    return [
      ComputeBudgetInstruction.setComputeUnitPrice(
        microLamports: microLamports,
      ),
      if (alwaysSetUnitLimit || computeBudget != _defaultComputeBudget)
        ComputeBudgetInstruction.setComputeUnitLimit(units: computeBudget),
    ];
  }

  /// The `setComputeUnitPrice` figure [computeBudgetIxs] bids — split out so a
  /// caller that has to know the fee *before* the transaction exists (the
  /// send flow's Max, which prices the amount as `balance − fee`) reads the
  /// same number the instruction will carry.
  static int resolveUnitPriceMicroLamports({
    required int computeBudget,
    int? recommendedMicroLamports,
    int? maxPriorityFeeLamports,
  }) {
    final ceiling = maxPriorityFeeLamports ?? _priorityFeeCeilingLamports;
    final minMicro = (kMinPriorityFeeLamports / computeBudget * 1e6).ceil();
    // `num.clamp` THROWS ArgumentError on inverted bounds, and this call sits
    // outside every try/catch on the tx-build path — a ceiling below the
    // 15 000-lamport floor would break every client-built Solana transaction.
    // `PriorityFeeService` already floors what it resolves; this keeps a
    // caller passing `maxPriorityFeeLamports` directly from reintroducing it.
    final maxMicro = math.max((ceiling / computeBudget * 1e6).ceil(), minMicro);
    final clamped = (recommendedMicroLamports ?? minMicro).clamp(
      minMicro,
      maxMicro,
    );
    return math.max(clamped, kMinPriorityFeeLamports);
  }

  /// Simulate [instructions] → units → Helius fee → the compute-budget prefix
  /// to prepend. Both probes fail open (null → webapp defaults) so tx
  /// building never breaks on estimation hiccups.
  Future<List<Instruction>> buildComputeBudgetPrefix({
    required List<Instruction> instructions,
    List<AddressLookupTableAccount> addressLookupTableAccounts = const [],
  }) async => (await planComputeBudget(
    instructions: instructions,
    addressLookupTableAccounts: addressLookupTableAccounts,
  )).instructions;

  /// [buildComputeBudgetPrefix]'s prefix *plus the numbers behind it*, so a
  /// caller can know the prioritization fee the transaction will pay before it
  /// is built — and pin it, so the figure it priced against is the figure that
  /// gets signed.
  ///
  /// [alwaysSetUnitLimit] is what makes [ComputeBudgetPlan.priorityFeeLamports]
  /// trustworthy: without an explicit limit ix the runtime prices the tx at its
  /// own default (200 000 *per instruction*), which is not
  /// [ComputeBudgetPlan.computeUnits].
  Future<ComputeBudgetPlan> planComputeBudget({
    required List<Instruction> instructions,
    List<AddressLookupTableAccount> addressLookupTableAccounts = const [],
    bool alwaysSetUnitLimit = false,
  }) async {
    final simulatedUnits = await estimateComputeUnits(
      instructions: instructions,
      addressLookupTableAccounts: addressLookupTableAccounts,
    );
    final computeBudget = resolveComputeBudget(simulatedUnits);

    int? recommended;
    try {
      // Fee probe mirrors the webapp: [limit ix, ...core ixs] serialized and
      // sent to Helius getPriorityFeeEstimate.
      final probeTx = await _encodePlaceholderV0Tx(
        instructions: [
          ComputeBudgetInstruction.setComputeUnitLimit(units: computeBudget),
          ...instructions,
        ],
        addressLookupTableAccounts: addressLookupTableAccounts,
      );
      recommended = await getRecommendedPriorityFeeMicroLamports(probeTx);
    } catch (e) {
      debugPrint('[RPC] priority-fee probe failed: $e');
    }

    return ComputeBudgetPlan(
      instructions: computeBudgetIxs(
        computeBudget: computeBudget,
        recommendedMicroLamports: recommended,
        alwaysSetUnitLimit: alwaysSetUnitLimit,
      ),
      computeUnits: computeBudget,
      microLamportsPerUnit: resolveUnitPriceMicroLamports(
        computeBudget: computeBudget,
        recommendedMicroLamports: recommended,
      ),
    );
  }

  /// Price a native-SOL transfer to [destination] down to the lamport: the
  /// compute-budget prefix it will carry, and the total fee it will be charged.
  ///
  /// [provisionalLamports] only sizes the compute simulation. A system
  /// transfer's compute cost does not depend on the amount, so the plan this
  /// returns is valid for whatever amount the caller settles on — which is what
  /// breaks the circularity in "send everything except the fee": the fee has to
  /// be known before the amount, and the amount before the transaction.
  Future<SolTransferFeePlan> planSolTransferFee({
    required String destination,
    required int provisionalLamports,
  }) async {
    final sourceAddress = await _walletManager.getAddress();
    final budget = await planComputeBudget(
      instructions: [
        SystemInstruction.transfer(
          fundingAccount: Ed25519HDPublicKey.fromBase58(sourceAddress),
          recipientAccount: Ed25519HDPublicKey.fromBase58(destination),
          lamports: provisionalLamports,
        ),
      ],
      // The Max amount is derived from this plan's fee, so the fee must be the
      // one the runtime charges, not one it re-derives from a default limit.
      alwaysSetUnitLimit: true,
    );
    return SolTransferFeePlan(
      budget: budget,
      // One signature: the fee payer is the only signer on a transfer.
      feeLamports: kBaseSolanaTxFeeLamports + budget.priorityFeeLamports,
    );
  }

  /// Simulated compute units for [instructions] (with a max-limit ix
  /// prepended so the simulation can't be unit-starved), or null when
  /// simulation fails. Mirrors the webapp's `getSimulationComputeUnits`.
  Future<int?> estimateComputeUnits({
    required List<Instruction> instructions,
    List<AddressLookupTableAccount> addressLookupTableAccounts = const [],
  }) async {
    try {
      final encoded = await _encodePlaceholderV0Tx(
        instructions: [
          ComputeBudgetInstruction.setComputeUnitLimit(
            units: _maxComputeBudget,
          ),
          ...instructions,
        ],
        addressLookupTableAccounts: addressLookupTableAccounts,
      );
      final result = await simulateEncodedTransaction(encoded);
      return result.success ? result.unitsConsumed : null;
    } catch (e) {
      debugPrint('[RPC] compute-units simulation failed: $e');
      return null;
    }
  }

  /// Helius `getPriorityFeeEstimate` (priority level High) for a serialized
  /// transaction. Returns null on devnet (the API is mainnet-only — webapp
  /// parity) and on any error.
  Future<int?> getRecommendedPriorityFeeMicroLamports(
    String serializedTxBase64,
  ) async {
    if (_rpcUrl.contains('devnet')) return null;
    try {
      final response = await Dio().post<Map<String, dynamic>>(
        _rpcUrl,
        options: Options(headers: _rpcHeaders),
        data: {
          'jsonrpc': '2.0',
          'id': 'priority-fee',
          'method': 'getPriorityFeeEstimate',
          'params': [
            {
              'transaction': base58encode(base64Decode(serializedTxBase64)),
              'options': {'priorityLevel': 'High'},
            },
          ],
        },
      );
      final result = response.data?['result'];
      final estimate = result is Map<String, dynamic>
          ? result['priorityFeeEstimate']
          : null;
      return estimate is num ? estimate.ceil() : null;
    } catch (e) {
      debugPrint('[RPC] priority fee estimate failed: $e');
      return null;
    }
  }

  /// Fetch + deserialize address-lookup-table accounts, skipping addresses
  /// that don't resolve. Mirrors the webapp's
  /// `getAddressLookupTableAccounts`.
  Future<List<AddressLookupTableAccount>> getAddressLookupTableAccounts(
    List<String> addresses,
  ) async {
    if (addresses.isEmpty) return const [];
    final result = await _rpcClient.getMultipleAccounts(
      addresses,
      encoding: Encoding.base64,
    );
    final accounts = <AddressLookupTableAccount>[];
    for (var i = 0; i < addresses.length && i < result.value.length; i++) {
      final data = result.value[i]?.data;
      if (data is! BinaryAccountData) continue;
      accounts.add(
        AddressLookupTableAccount(
          key: Ed25519HDPublicKey.fromBase58(addresses[i]),
          state: AddressLookupTableAccount.deserialize(ByteArray(data.data)),
        ),
      );
    }
    return accounts;
  }

  /// Compile [message] into a base64-encoded *unsigned* **v0** transaction
  /// (with placeholder signatures) — the versioned-tx counterpart of
  /// [buildUnsignedTxBase64], for txs that reference address lookup tables.
  Future<String> buildUnsignedV0TxBase64(
    Message message, {
    List<AddressLookupTableAccount> addressLookupTableAccounts = const [],
  }) async {
    final blockhash = await getLatestBlockhash();
    return _encodePlaceholderV0Tx(
      instructions: message.instructions,
      addressLookupTableAccounts: addressLookupTableAccounts,
      recentBlockhash: blockhash,
    );
  }

  /// Compile [instructions] to a v0 message and encode with placeholder
  /// signatures. Uses [_placeholderBlockhash] unless a real one is given —
  /// fine for simulation/fee probes, which replace or ignore it.
  Future<String> _encodePlaceholderV0Tx({
    required List<Instruction> instructions,
    List<AddressLookupTableAccount> addressLookupTableAccounts = const [],
    String recentBlockhash = _placeholderBlockhash,
  }) async {
    final payerAddress = await _walletManager.getAddress();
    final feePayer = Ed25519HDPublicKey.fromBase58(payerAddress);
    final compiledMessage = Message(instructions: instructions).compileV0(
      recentBlockhash: recentBlockhash,
      feePayer: feePayer,
      addressLookupTableAccounts: addressLookupTableAccounts,
    );
    final placeholders = List.generate(
      compiledMessage.requiredSignatureCount,
      (_) => Signature(List<int>.filled(64, 0), publicKey: feePayer),
    );
    return SignedTx(
      signatures: placeholders,
      compiledMessage: compiledMessage,
    ).encode();
  }

  /// Request an airdrop (devnet/testnet only).
  ///
  /// [lamports] - Amount in lamports (max 1 SOL per request on devnet)
  ///
  /// Returns the transaction signature.
  Future<String> requestAirdrop({int lamports = lamportsPerSol}) async {
    if (Config.isProduction) {
      throw UnsupportedError('Airdrop not available on mainnet');
    }

    final address = await _walletManager.getAddress();
    return _rpcClient.requestAirdrop(address, lamports);
  }

  /// Get transaction details by signature.
  Future<TransactionDetails?> getTransaction(String signature) async {
    return _rpcClient.getTransaction(signature);
  }

  /// Raw `getTransaction` for [signature] at **confirmed** commitment, JSON
  /// parsed and version-aware. Returns the RPC `result`, or null when the
  /// transaction isn't queryable yet (or the call failed).
  ///
  /// Deliberately not [getTransaction]: the `solana` package's DTO drops the
  /// `owner` field of `pre/postTokenBalances` — exactly what post-confirmation
  /// balance reconciliation keys on — and defaults to `finalized`, which trails
  /// the confirmation the transaction flows act on by ~13 seconds.
  Future<Map<String, dynamic>?> getTransactionJson(String signature) async {
    try {
      final response = await Dio().post<Map<String, dynamic>>(
        _rpcUrl,
        options: Options(headers: _rpcHeaders),
        data: {
          'jsonrpc': '2.0',
          'id': 'get-transaction',
          'method': 'getTransaction',
          'params': [
            signature,
            {
              'encoding': 'jsonParsed',
              'commitment': 'confirmed',
              'maxSupportedTransactionVersion': 0,
            },
          ],
        },
      );
      return response.data?['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[RPC] getTransaction($signature) failed: $e');
      return null;
    }
  }

  /// ZK-compressed balance of [mint] held by [owner], in raw token units.
  ///
  /// Compressed tokens live in Light Protocol state, not in an SPL token
  /// account, so none of the normal balance reads see them — the Photon
  /// `getCompressedTokenBalancesByOwner` extension on the RPC proxy is the only
  /// way to count them. Staking season rewards (SMORES) are airdropped
  /// compressed, so this is what gates the "Your Rewards" claim.
  ///
  /// Best-effort: 0 on any transport or RPC error, matching the webapp's
  /// `fetchCompressedTokenBalances` (which swallows and returns `{}`). The
  /// caller treats 0 as "nothing to claim", so a blip hides the card for one
  /// refresh rather than surfacing a claim that would fail.
  Future<int> getCompressedTokenBalance({
    required String owner,
    required String mint,
  }) async {
    try {
      final response = await Dio().post<Map<String, dynamic>>(
        _rpcUrl,
        options: Options(headers: _rpcHeaders),
        data: {
          'jsonrpc': '2.0',
          'id': 'compressed-token-balances',
          'method': 'getCompressedTokenBalancesByOwner',
          'params': {'owner': owner},
        },
      );
      final balances =
          ((response.data?['result'] as Map<String, dynamic>?)?['value']
                  as Map<String, dynamic>?)?['token_balances']
              as List?;
      if (balances == null) return 0;
      for (final entry in balances) {
        if (entry is! Map) continue;
        if (entry['mint'] != mint) continue;
        final balance = entry['balance'];
        return balance is num ? balance.toInt() : int.tryParse('$balance') ?? 0;
      }
      return 0;
    } catch (e) {
      debugPrint('[RPC] getCompressedTokenBalancesByOwner failed: $e');
      return 0;
    }
  }

  /// Get recent transaction signatures for the wallet.
  Future<List<TransactionSignatureInformation>> getRecentTransactions({
    int limit = 20,
  }) async {
    final address = await _walletManager.getAddress();
    return _rpcClient.getSignaturesForAddress(address, limit: limit);
  }

  /// `getSignatureStatuses` view of a broadcast tx, or null when the cluster
  /// has never seen the signature (still in the mempool, or dropped).
  ///
  /// On a landed *successful* tx, records the slot it landed in into
  /// [TxLandedSlots] — `getSignatureStatuses` carries it for free, and it is
  /// the ordering floor slot-aware reconciliation uses to reject on-chain reads
  /// whose view predates our own action. A landed-but-failed tx mutated
  /// nothing, so it deliberately does not raise that floor.
  ///
  /// Deliberately raw JSON rather than `_rpcClient.getSignatureStatuses`: the
  /// `solana` package's generated deserializer types `err` as
  /// `Map<String, dynamic>?`, but Solana's `TransactionError` has unit variants
  /// that serialize as a bare string (`"AccountInUse"`,
  /// `"InsufficientFundsForFee"`, …). Those throw a `TypeError` inside the DTO,
  /// which [awaitConfirmationOrThrow] can only read as "not seen yet" — a
  /// landed-but-failed tx would then be reported as *unconfirmed* for the full
  /// blockhash lifetime instead of failing immediately. Parsing `err` untyped
  /// keeps every shape decodable and hands it to [_parseSimulationError], which
  /// already accepts both. RPC/transport faults still throw, as before.
  Future<SolanaTxStatus?> transactionStatus(String signature) async {
    final response = await Dio().post<Map<String, dynamic>>(
      _rpcUrl,
      options: Options(
        headers: _rpcHeaders,
        // Matches RpcClient's default timeout — a poll that hangs forever
        // would outlive awaitConfirmationOrThrow's maxWait cap.
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
      ),
      data: {
        'jsonrpc': '2.0',
        'id': 'get-signature-statuses',
        'method': 'getSignatureStatuses',
        'params': [
          [signature],
          {'searchTransactionHistory': false},
        ],
      },
    );
    final body = response.data;
    final rpcError = body?['error'];
    if (rpcError != null) {
      throw Exception('getSignatureStatuses failed: $rpcError');
    }
    final value = (body?['result'] as Map<String, dynamic>?)?['value'];
    final status = (value is List && value.isNotEmpty ? value.first : null);
    if (status is! Map<String, dynamic>) return null;

    final commitment = status['confirmationStatus'];
    final landed = commitment == 'confirmed' || commitment == 'finalized';
    final err = status['err'];
    final slot = status['slot'];
    if (landed && err == null && slot is num) {
      _txLandedSlots?.record(signature, slot.toInt());
    }
    return SolanaTxStatus(landed: landed, err: err);
  }

  /// True when [signature] landed *and executed successfully* at `confirmed`
  /// commitment or better. A landed tx whose runtime returned an error is not
  /// confirmed for our purposes — it changed nothing on-chain.
  Future<bool> isTransactionConfirmed(String signature) async {
    final status = await transactionStatus(signature);
    return status != null && status.landed && status.err == null;
  }

  /// True while [blockhash] can still be accepted by the cluster. Any RPC
  /// failure answers `true` — the bound in [awaitConfirmationOrThrow] must
  /// never *shorten* on a network blip, and its hard `maxWait` cap backstops a
  /// node that answers wrongly forever.
  Future<bool> isBlockhashStillValid(String blockhash) async {
    try {
      final result = await _rpcClient.isBlockhashValid(
        blockhash,
        commitment: Commitment.confirmed,
      );
      return result.value;
    } catch (_) {
      return true;
    }
  }

  /// Re-broadcast an already-sent [signedTx]. Preflight is skipped and every
  /// error swallowed: the expected failures here are "already processed" (the
  /// tx we are chasing landed) and transient 429s, neither of which is a
  /// transaction failure.
  Future<void> rebroadcastTransaction(SignedTx signedTx) async {
    try {
      await _rpcClient.sendTransaction(
        signedTx.encode(),
        skipPreflight: true,
        preflightCommitment: Commitment.confirmed,
      );
    } catch (_) {}
  }

  /// Wait for [signature] to reach a **terminal** state, re-broadcasting
  /// [rebroadcast] every [pollInterval] while it hasn't. Returns normally only
  /// when the tx executed successfully; otherwise throws.
  ///
  /// This is the honest confirmation contract, and replaces a poller that
  /// returned `false` after a flat 30 s into a caller that discarded it — the
  /// user was told "Transaction sent" while the tx was still in the mempool
  /// (a blockhash is valid ~60–90 s), saw an unchanged balance, and sent again.
  /// Both landed. Mirrors the webapp's `sendAndConfirmSignedTransaction` +
  /// `confirmTransactionWithError`
  /// (`transactions`), which re-sends until
  /// blockhash expiry and throws on failure.
  ///
  /// Three terminal states, all distinguishable by the caller:
  ///  * **confirmed** — returns normally.
  ///  * **failed on-chain** — throws [SolanaTransactionFailedException]; the
  ///    tx will never succeed, so retrying is safe.
  ///  * **expired unconfirmed** — throws
  ///    [SolanaTransactionUnconfirmedException]; indeterminate, so the copy
  ///    must NOT invite a blind retry (that is how you get a double-send).
  ///
  /// The wait is bounded by *blockhash validity*, not a fixed timeout: once the
  /// blockhash can no longer be accepted the tx can no longer land. Probing
  /// starts at [expiryProbeAfter] (a freshly-signed blockhash cannot have
  /// expired) so the common fast confirmation costs no extra RPC calls, and
  /// [maxWait] is a hard cap for a node that never reports expiry. Rebroadcast
  /// matters because sends carry no priority fee: the first broadcast can be
  /// dropped by a leader under load and never retried.
  ///
  /// Both the rebroadcast and the expiry probe are gated on the tx being
  /// *unseen*, and the probe additionally runs only every
  /// [_expiryProbeEveryNPolls]-th unseen poll (~10 s at the default 2 s
  /// interval). The RPC proxy is rate-limited and a poll that already got a
  /// live status back has nothing to re-send and nothing to expire — paying
  /// three RPCs per poll for that is wasted quota, not resilience.
  Future<void> awaitConfirmationOrThrow(
    String signature, {
    required SignedTx rebroadcast,
    Duration pollInterval = const Duration(seconds: 2),
    Duration expiryProbeAfter = const Duration(seconds: 15),
    Duration maxWait = const Duration(seconds: 90),
  }) async {
    final blockhash = rebroadcast.compiledMessage.recentBlockhash;
    final stopwatch = Stopwatch()..start();
    // Polls to skip before the next expiry probe. Zero on the first eligible
    // poll so a caller that starts probing immediately still probes at once.
    var pollsUntilProbe = 0;

    while (stopwatch.elapsed < maxWait) {
      await Future<void>.delayed(pollInterval);

      // A transient RPC failure (429, network blip) mid-poll must not surface
      // as a transaction failure — the tx is already broadcast and usually
      // lands fine. Treat it as "not seen yet" and keep polling.
      SolanaTxStatus? status;
      try {
        status = await transactionStatus(signature);
      } catch (_) {
        status = null;
      }
      if (status != null) {
        final err = status.err;
        if (err != null) {
          // Same formatter the simulation path uses, so an on-chain failure
          // reads like the pre-flight one ("Instruction 2 failed: …").
          throw SolanaTransactionFailedException(
            signature,
            _parseSimulationError(err),
          );
        }
        if (status.landed) return;
        // Seen but only `processed`: it is already in a block, so there is
        // nothing to re-send and its blockhash cannot expire out from under
        // it. If it does get forked away the next poll reads null again and
        // both resume.
        continue;
      }

      if (stopwatch.elapsed >= expiryProbeAfter) {
        if (pollsUntilProbe > 0) {
          pollsUntilProbe--;
        } else {
          if (!await isBlockhashStillValid(blockhash)) break;
          pollsUntilProbe = _expiryProbeEveryNPolls - 1;
        }
      }
      await rebroadcastTransaction(rebroadcast);
    }

    throw SolanaTransactionUnconfirmedException(signature);
  }

  /// How often [awaitConfirmationOrThrow] probes blockhash validity, counted in
  /// unseen polls: every 5th at the default 2 s poll interval is ~10 s, coarse
  /// enough to be cheap and far finer than the ~60–90 s a blockhash lives.
  static const int _expiryProbeEveryNPolls = 5;

  /// Get the minimum balance required for rent exemption.
  Future<int> getMinimumBalanceForRentExemption(int dataSize) async {
    return _rpcClient.getMinimumBalanceForRentExemption(dataSize);
  }

  /// Check if the RPC endpoint is healthy.
  Future<bool> isHealthy() async {
    try {
      final health = await _rpcClient.getHealth();
      return health == 'ok';
    } catch (_) {
      return false;
    }
  }

  /// Simulate a transaction before signing/sending.
  ///
  /// This allows checking if a transaction will succeed without actually
  /// executing it. Useful for showing warnings in confirmation dialogs.
  ///
  /// [message] - The transaction message to simulate
  ///
  /// Returns a [SimulationResult] with success status, logs, and compute units.
  ///
  /// Note: This requires signing the transaction first to simulate.
  /// For pre-signing simulation, use [simulateMessageWithSigner].
  Future<SimulationResult> simulateSignedTransaction(SignedTx signedTx) async {
    return simulateEncodedTransaction(signedTx.encode());
  }

  /// Simulate a message without signing it.
  ///
  /// Compiles [message] with the active wallet as fee payer and submits
  /// the encoded transaction with zero-byte placeholder signatures. The
  /// RPC simulator doesn't verify signatures (and we pass
  /// `replaceRecentBlockhash: true`), so simulation can run before the
  /// user approves anything — critical for Ledger wallets, which would
  /// otherwise need to be connected and unlocked just to preview fees.
  ///
  /// Returns a [SimulationResult] with success status, logs, and compute units.
  Future<SimulationResult> simulateMessage(
    Message message, {
    List<String> inspectAccounts = const [],
  }) async {
    try {
      final blockhash = await getLatestBlockhash();
      final payerAddress = await _walletManager.getAddress();
      final feePayer = Ed25519HDPublicKey.fromBase58(payerAddress);
      final compiledMessage = message.compile(
        recentBlockhash: blockhash,
        feePayer: feePayer,
      );
      // 64-byte zero signatures, one per required signer. Signature bytes
      // are not verified during simulation, so placeholders suffice.
      final placeholders = List.generate(
        compiledMessage.requiredSignatureCount,
        (_) => Signature(List<int>.filled(64, 0), publicKey: feePayer),
      );
      final tx = SignedTx(
        signatures: placeholders,
        compiledMessage: compiledMessage,
      );
      return simulateEncodedTransaction(
        tx.encode(),
        inspectAccounts: inspectAccounts,
      );
    } catch (e) {
      return SimulationResult(
        success: false,
        error: 'Failed to prepare simulation: $e',
      );
    }
  }

  /// Simulate an already-encoded transaction (e.g., from Jupiter API).
  ///
  /// [encodedTransaction] - Base64 encoded transaction
  /// [inspectAccounts] - When non-empty, asks the RPC to return post-execution
  /// state for these accounts. The lamport balances land in
  /// [SimulationResult.inspectedAccountLamports]; callers compare against a
  /// pre-balance to compute net SOL deltas (e.g. rent refund on a burn).
  ///
  /// Returns a [SimulationResult] with success status, logs, and compute units.
  Future<SimulationResult> simulateEncodedTransaction(
    String encodedTransaction, {
    List<String> inspectAccounts = const [],
  }) async {
    // Dev aid: an Explorer tx-inspector link for the exact bytes we're about
    // to simulate, so the decoded instructions/accounts can be opened in the
    // browser. Computed up front (while the encoded tx is in hand) but only
    // logged on the failure paths below. Null outside debug builds — see
    // [_inspectorUrl].
    final inspectUrl = kDebugMode
        ? _inspectorUrl(
            SignedTx.fromBytes(
              base64Decode(encodedTransaction),
            ).compiledMessage.toByteArray().toList(),
          )
        : null;
    Future<TransactionStatusResult> simulate(List<String> addresses) =>
        _rpcClient.simulateTransaction(
          encodedTransaction,
          commitment: Commitment.confirmed,
          replaceRecentBlockhash: true,
          accounts: addresses.isEmpty
              ? null
              : SimulateTransactionAccounts(
                  encoding: Encoding.base64,
                  addresses: addresses,
                ),
        );

    try {
      TransactionStatusResult result;
      try {
        result = await simulate(inspectAccounts);
      } on TypeError {
        // When the simulated tx fails, the RPC returns `accounts: [null]`
        // (no post-execution state), which the SDK's TransactionStatus
        // decoder can't handle — it casts every entry non-null and throws.
        // Retry without inspection so the real program error surfaces
        // instead of the decode TypeError.
        if (inspectAccounts.isEmpty) rethrow;
        result = await simulate(const []);
      }

      final status = result.value;
      // Pair returned accounts back to the requested addresses by index —
      // the RPC preserves request order.
      final lamportsByAddress = <String, int>{};
      final tokenAmountsByAddress = <String, int>{};
      final returnedAccounts = status.accounts;
      if (returnedAccounts != null) {
        for (
          var i = 0;
          i < inspectAccounts.length && i < returnedAccounts.length;
          i++
        ) {
          final account = returnedAccounts[i];
          lamportsByAddress[inspectAccounts[i]] = account.lamports;
          final tokenAmount = _parseTokenAccountAmount(account);
          if (tokenAmount != null) {
            tokenAmountsByAddress[inspectAccounts[i]] = tokenAmount;
          }
        }
      }

      if (status.err != null) {
        // Extract error message
        final errorStr = _parseSimulationError(status.err);
        if (inspectUrl != null) {
          _debugPrintInspectUrl('[RPC] simulate failed — inspect:', inspectUrl);
        }
        return SimulationResult(
          success: false,
          error: errorStr,
          logs: status.logs,
          unitsConsumed: status.unitsConsumed,
          inspectedAccountLamports: lamportsByAddress,
          inspectedAccountTokenAmounts: tokenAmountsByAddress,
        );
      }

      return SimulationResult(
        success: true,
        logs: status.logs,
        unitsConsumed: status.unitsConsumed,
        inspectedAccountLamports: lamportsByAddress,
        inspectedAccountTokenAmounts: tokenAmountsByAddress,
      );
    } catch (e) {
      if (inspectUrl != null) {
        _debugPrintInspectUrl('[RPC] simulate failed — inspect:', inspectUrl);
      }
      return SimulationResult(
        success: false,
        error: 'Simulation request failed: $e',
      );
    }
  }

  /// Snapshot [address]'s pre-balance, run [simulate], and return the signed
  /// net lamport delta (`post − pre`) alongside the raw result.
  ///
  /// [simulate] receives the `inspectAccounts` list to forward to whichever
  /// simulate entry point fits the caller (a [Message] via [simulateMessage]
  /// or an encoded tx via [simulateEncodedTransaction]).
  ///
  /// Best-effort by design: a failed pre-balance fetch degrades to a null
  /// delta rather than aborting — the simulation still runs (without
  /// inspection) so callers can surface the result. A null/empty [address]
  /// skips the pre-balance roundtrip entirely. This is the single
  /// implementation of the pre→simulate→delta pattern that mint, market, and
  /// send blocs used to each re-derive.
  ///
  /// Set [requirePreBalance] when the caller treats a pre-balance fetch
  /// failure as a hard simulation failure (the send flow's prior behavior):
  /// the error then propagates to the caller instead of degrading to a null
  /// delta. Defaults to the tolerant behavior mint and market rely on.
  Future<SimulationDelta> simulateWithDelta({
    required String? address,
    required Future<SimulationResult> Function(List<String> inspectAccounts)
    simulate,
    bool requirePreBalance = false,
  }) async {
    int? pre;
    if (address != null && address.isNotEmpty) {
      try {
        pre = await getBalanceForAddress(address);
      } catch (_) {
        // Pre-balance unavailable (RPC blip) — still simulate, just without
        // a delta. Matches the burn-flow tolerance the market bloc relied on.
        if (requirePreBalance) rethrow;
        pre = null;
      }
    }

    final inspect = pre != null ? [address!] : const <String>[];
    final result = await simulate(inspect);

    final post = pre != null ? result.inspectedAccountLamports[address!] : null;
    final delta = (result.success && pre != null && post != null)
        ? post - pre
        : null;
    return SimulationDelta(result: result, lamportsDelta: delta);
  }

  /// Parse simulation error into human-readable string.
  String _parseSimulationError(dynamic err) {
    if (err == null) return 'Unknown error';

    if (err is String) return err;

    if (err is Map) {
      // Handle InstructionError format: {"InstructionError": [index, error]}
      if (err.containsKey('InstructionError')) {
        final instructionError = err['InstructionError'];
        if (instructionError is List && instructionError.length >= 2) {
          final index = instructionError[0];
          final error = instructionError[1];
          final errorMsg = _parseInstructionError(error);
          return 'Instruction $index failed: $errorMsg';
        }
      }
      return err.toString();
    }

    return err.toString();
  }

  /// Parse instruction-level error.
  String _parseInstructionError(dynamic error) {
    if (error is String) return error;

    if (error is Map) {
      // Common error types
      if (error.containsKey('Custom')) {
        return 'Custom error ${error['Custom']}';
      }
      if (error.containsKey('InsufficientFunds')) {
        return 'Insufficient funds';
      }
      if (error.containsKey('InvalidAccountData')) {
        return 'Invalid account data';
      }
      if (error.containsKey('AccountNotFound')) {
        return 'Account not found';
      }
      return error.entries.first.toString();
    }

    return error.toString();
  }
}

/// What the cluster knows about a broadcast transaction.
class SolanaTxStatus {
  const SolanaTxStatus({required this.landed, this.err});

  /// The tx reached `confirmed` (or `finalized`) commitment. It is in a block;
  /// whether it *succeeded* depends on [err].
  final bool landed;

  /// Runtime error the transaction returned, or null when it executed cleanly.
  /// A non-null [err] is terminal — the tx will never succeed.
  ///
  /// Untyped because Solana's `TransactionError` is either a JSON object
  /// (`{"InstructionError": [2, {"Custom": 6003}]}`) or a bare string for its
  /// unit variants (`"AccountInUse"`). Both reach `_parseSimulationError`.
  final Object? err;
}

/// Thrown when a transaction landed on-chain but its runtime returned an error.
///
/// Terminal and unambiguous: nothing was transferred, so a retry is safe.
class SolanaTransactionFailedException implements Exception {
  const SolanaTransactionFailedException(this.signature, this.reason);

  /// The on-chain signature — the tx is on the explorer even though it failed.
  final String signature;

  /// Human-readable runtime error (e.g. `Instruction 2 failed: …`).
  final String reason;

  @override
  String toString() => 'Transaction failed on-chain: $reason';
}

/// Thrown when a broadcast transaction never reached a confirmed status before
/// its blockhash expired.
///
/// **Indeterminate, not failed.** We stopped being able to observe it; a tx we
/// never saw land may still have landed (our own view of expiry can lag the
/// cluster). [toString] is the user-facing copy and deliberately does not
/// invite a retry: re-sending an in-flight transfer is how a user ends up
/// sending twice.
class SolanaTransactionUnconfirmedException implements Exception {
  const SolanaTransactionUnconfirmedException(this.signature);

  /// The on-chain signature. Always surface it (explorer / Activity) — it is
  /// the only way the user can find out what actually happened.
  final String signature;

  @override
  String toString() =>
      'This transaction may still land. Check Activity or the explorer before '
      'sending again.';
}
