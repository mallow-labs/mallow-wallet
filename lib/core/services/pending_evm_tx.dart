import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Models and the pure replace-by-fee arithmetic behind the pending-EVM-tx
/// feature (speed up / cancel). Kept free of IO so the fee floors, the
/// escalation ladder, and the replacement shape are unit-testable without a
/// node, a database, or a signer — [PendingEvmTxTracker] is the IO shell around
/// these.
///
/// The identity of a tracked transaction is **(wallet, nonce)**: a speed-up or
/// cancel never allocates a new nonce, it re-signs the same slot at a higher
/// fee, so both live on the same row as extra [PendingTxCandidate]s.

/// What the tracked transaction *is*, for display filtering.
///
/// `external` marks a nonce-gap entry — a transaction broadcast from another
/// device that this app only knows the (wallet, nonce) of. Names are the wire
/// values persisted in `pending_evm_transactions.kind`.
enum PendingEvmTxKind {
  send,
  nftTransfer,
  swap,
  other,
  external;

  static PendingEvmTxKind fromWire(String? value) => PendingEvmTxKind.values
      .firstWhere((k) => k.name == value, orElse: () => PendingEvmTxKind.other);
}

/// Lifecycle of the slot. `cancelling` means a `role: cancel` replacement has
/// been broadcast against it; the slot is still unresolved (any candidate can
/// still mine), the UI just stops offering Cancel again.
enum PendingEvmTxStatus {
  pending,
  cancelling;

  static PendingEvmTxStatus fromWire(String? value) =>
      value == 'cancelling' ? PendingEvmTxStatus.cancelling : pending;
}

/// Which broadcast produced a candidate. Persisted by name.
enum PendingTxCandidateRole {
  original,
  speedup,
  cancel;

  static PendingTxCandidateRole fromWire(String? value) =>
      PendingTxCandidateRole.values.firstWhere(
        (r) => r.name == value,
        orElse: () => PendingTxCandidateRole.original,
      );
}

/// A concrete EIP-1559 fee pair, the unit both the floor and the escalation
/// ladder operate on.
typedef EvmFeeCaps = ({BigInt maxFeePerGas, BigInt maxPriorityFeePerGas});

/// One broadcast hash for a nonce slot. After a speed-up or cancel, *every*
/// candidate is live in the mempool and any of them can mine — resolution is
/// classified by which hash got a receipt, never by assuming the newest won.
@immutable
class PendingTxCandidate {
  const PendingTxCandidate({
    required this.hash,
    required this.role,
    required this.maxFeePerGas,
    required this.maxPriorityFeePerGas,
    required this.broadcastAt,
  });

  factory PendingTxCandidate.fromJson(Map<String, dynamic> json) =>
      PendingTxCandidate(
        hash: json['hash'] as String? ?? '',
        role: json['role'] as String? ?? PendingTxCandidateRole.original.name,
        maxFeePerGas: _bigIntOf(json['maxFeePerGas']),
        maxPriorityFeePerGas: _bigIntOf(json['maxPriorityFeePerGas']),
        broadcastAt: (json['broadcastAt'] as num?)?.toInt() ?? 0,
      );

  final String hash;

  /// [PendingTxCandidateRole] name — `original`, `speedup`, or `cancel`.
  final String role;
  final BigInt maxFeePerGas;
  final BigInt maxPriorityFeePerGas;

  /// Unix seconds at broadcast.
  final int broadcastAt;

  bool get isCancel => role == PendingTxCandidateRole.cancel.name;

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'role': role,
    'maxFeePerGas': maxFeePerGas.toString(),
    'maxPriorityFeePerGas': maxPriorityFeePerGas.toString(),
    'broadcastAt': broadcastAt,
  };

  /// Decode a persisted candidate list, degrading to empty on a malformed blob.
  ///
  /// Throwing here would poison the watcher: the decode runs on every pass
  /// *before* the row's delete, so a corrupted row would abort every pass and
  /// could never be removed — nor could any other row resolve. With no
  /// candidates the slot still resolves (as `replaced`) and the row goes away.
  static List<PendingTxCandidate> decodeList(String json) {
    if (json.isEmpty) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(PendingTxCandidate.fromJson)
          .toList();
    } on Object {
      // Bad JSON *or* a wrong-typed field (a cast in `fromJson`) — both are
      // corruption, and neither is worth stalling the watcher over.
      return const [];
    }
  }

  static String encodeList(List<PendingTxCandidate> candidates) =>
      jsonEncode(candidates.map((c) => c.toJson()).toList());
}

/// Display-only payload for a pending cell. **Never** used to build a
/// transaction — the replacement is rebuilt from the row's `to`/`value`/`data`,
/// so a wrong title can't move funds anywhere.
///
/// The swap fields are unused today; they are part of the schema now so a
/// future EVM swap needs no migration.
@immutable
class PendingTxMetadata {
  const PendingTxMetadata({
    required this.title,
    this.subtitle,
    this.tokenSymbol,
    this.amountRaw,
    this.decimals,
    this.artworkMint,
    this.imageUrl,
    this.swapInSymbol,
    this.swapInAmountRaw,
    this.swapOutSymbol,
    this.swapOutAmountRaw,
  });

  factory PendingTxMetadata.fromJson(Map<String, dynamic> json) =>
      PendingTxMetadata(
        title: json['title'] as String? ?? 'Transaction',
        subtitle: json['subtitle'] as String?,
        tokenSymbol: json['tokenSymbol'] as String?,
        amountRaw: json['amountRaw'] as String?,
        decimals: (json['decimals'] as num?)?.toInt(),
        artworkMint: json['artworkMint'] as String?,
        imageUrl: json['imageUrl'] as String?,
        swapInSymbol: json['swapInSymbol'] as String?,
        swapInAmountRaw: json['swapInAmountRaw'] as String?,
        swapOutSymbol: json['swapOutSymbol'] as String?,
        swapOutAmountRaw: json['swapOutAmountRaw'] as String?,
      );

  /// Decode a persisted payload, falling back to a generic title on malformed
  /// JSON — a display string must never be able to hide an actionable entry,
  /// and (like [PendingTxCandidate.decodeList]) a throw here would stall the
  /// watcher pass that has to delete the row.
  factory PendingTxMetadata.decode(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        return PendingTxMetadata.fromJson(decoded);
      }
    } on Object {
      // fall through
    }
    return const PendingTxMetadata(title: 'Transaction');
  }

  /// Cell title, e.g. "Send" / "Transfer" / "Swap".
  final String title;

  /// Cell subtitle, e.g. "to 0x4fB…29dF" or an artwork name.
  final String? subtitle;

  final String? tokenSymbol;

  /// Signed smallest-unit amount as a decimal string — negative for an outflow
  /// (matches the activity rows' convention).
  final String? amountRaw;
  final int? decimals;

  /// `contract-tokenId` for an NFT transfer, for image lookup.
  final String? artworkMint;
  final String? imageUrl;

  final String? swapInSymbol;
  final String? swapInAmountRaw;
  final String? swapOutSymbol;
  final String? swapOutAmountRaw;

  Map<String, dynamic> toJson() => {
    'title': title,
    'subtitle': subtitle,
    'tokenSymbol': tokenSymbol,
    'amountRaw': amountRaw,
    'decimals': decimals,
    'artworkMint': artworkMint,
    'imageUrl': imageUrl,
    'swapInSymbol': swapInSymbol,
    'swapInAmountRaw': swapInAmountRaw,
    'swapOutSymbol': swapOutSymbol,
    'swapOutAmountRaw': swapOutAmountRaw,
  };

  String encode() => jsonEncode(toJson());
}

/// One unresolved (wallet, nonce) slot as the UI sees it.
@immutable
class PendingEvmTx {
  const PendingEvmTx({
    required this.walletAddress,
    required this.nonce,
    required this.chainId,
    required this.kind,
    required this.status,
    required this.toAddress,
    required this.valueWei,
    required this.data,
    required this.gasLimit,
    required this.metadata,
    required this.candidates,
    required this.createdAt,
    this.canCancelNow = true,
  });

  /// Lowercased broadcasting wallet.
  final String walletAddress;
  final int nonce;
  final int chainId;
  final PendingEvmTxKind kind;
  final PendingEvmTxStatus status;

  /// Original `to` — empty for a derived (never-broadcast-against) external
  /// entry, whose payload is unknown.
  final String toAddress;
  final BigInt valueWei;

  /// Original calldata as `0x` hex, empty for a native send.
  final String data;
  final int gasLimit;
  final PendingTxMetadata metadata;
  final List<PendingTxCandidate> candidates;
  final int createdAt;

  /// False for external entries above the lowest unresolved gap nonce —
  /// replacements mine in nonce order, so cancelling nonce N+1 before N is
  /// pointless. Always true for locally tracked entries.
  final bool canCancelNow;

  /// True when this slot is a nonce gap: the app never broadcast its original,
  /// so there is no payload to speed up, only a nonce to cancel.
  bool get isExternal => kind == PendingEvmTxKind.external;

  bool get isCancelling => status == PendingEvmTxStatus.cancelling;

  /// The highest-fee candidate — the one a replacement must out-bid.
  PendingTxCandidate? get highestFeeCandidate =>
      highestFeeCandidateOf(candidates);

  /// Most recently broadcast hash — what "View on Etherscan" links to.
  String? get newestHash {
    PendingTxCandidate? newest;
    for (final c in candidates) {
      if (newest == null || c.broadcastAt >= newest.broadcastAt) newest = c;
    }
    return newest?.hash;
  }

  PendingEvmTx copyWith({bool? canCancelNow}) => PendingEvmTx(
    walletAddress: walletAddress,
    nonce: nonce,
    chainId: chainId,
    kind: kind,
    status: status,
    toAddress: toAddress,
    valueWei: valueWei,
    data: data,
    gasLimit: gasLimit,
    metadata: metadata,
    candidates: candidates,
    createdAt: createdAt,
    canCancelNow: canCancelNow ?? this.canCancelNow,
  );
}

/// How a slot stopped being pending.
enum PendingTxResolutionKind {
  /// A non-cancel candidate mined successfully.
  confirmed,

  /// A non-cancel candidate mined with `status == 0x0`.
  reverted,

  /// Our own `role: cancel` candidate mined.
  cancelled,

  /// The nonce was consumed by a transaction we have no candidate for.
  replaced,
}

/// What a speed-up or cancel actually did, so the caller can tell the user the
/// truth.
enum PendingTxReplacementResult {
  /// A replacement is on the wire (or the identical one already was).
  broadcast,

  /// The node answered `nonce too low`: the slot resolved while the user was
  /// deciding, so nothing was signed onto the chain and no second fee was paid.
  /// Reporting this as a submitted replacement would tell the user they are
  /// paying for a transaction that does not exist.
  alreadyResolved,
}

/// A resolved slot, emitted on `PendingEvmTxTracker.resolutions` for the
/// app-wide toast.
@immutable
class PendingTxResolution {
  const PendingTxResolution({required this.tx, required this.kind});

  final PendingEvmTx tx;
  final PendingTxResolutionKind kind;
}

/// The transaction shape a replacement broadcast must sign. A speed-up replays
/// the stored payload verbatim; a cancel is a 0-ETH self-send.
@immutable
class EvmReplacementPlan {
  const EvmReplacementPlan({
    required this.nonce,
    required this.to,
    required this.value,
    required this.data,
    required this.gasLimit,
    required this.role,
  });

  final int nonce;
  final String to;
  final BigInt value;

  /// `0x` hex; empty means "no calldata" (a plain value transfer).
  final String data;
  final int gasLimit;
  final PendingTxCandidateRole role;
}

/// Everything the sign-and-broadcast funnel knows about a transaction it just
/// put on the wire, handed to the tracker to persist.
///
/// [role] decides whether this creates a row or appends a candidate to the one
/// already occupying (wallet, nonce): a speed-up or cancel is *not* a new
/// pending transaction, it is another live hash for the same slot.
@immutable
class PendingEvmBroadcast {
  const PendingEvmBroadcast({
    required this.walletAddress,
    required this.nonce,
    required this.chainId,
    required this.kind,
    required this.role,
    required this.toAddress,
    required this.valueWei,
    required this.data,
    required this.gasLimit,
    required this.maxFeePerGas,
    required this.maxPriorityFeePerGas,
    required this.hash,
    this.metadata,
  });

  /// Broadcasting wallet in whatever casing the caller had; lowercased on
  /// persist.
  final String walletAddress;
  final int nonce;
  final int chainId;
  final PendingEvmTxKind kind;
  final PendingTxCandidateRole role;
  final String toAddress;
  final BigInt valueWei;

  /// `0x` hex calldata, empty for a native send.
  final String data;
  final int gasLimit;
  final BigInt maxFeePerGas;
  final BigInt maxPriorityFeePerGas;
  final String hash;

  /// Display payload; a caller that passes none still gets tracked, with a
  /// generic title, so no EVM broadcast escapes the Pending list.
  final PendingTxMetadata? metadata;
}

/// Gas a 0-ETH self-send costs — the cancel's fixed limit.
const int kCancelGasLimit = 21000;

/// Attempts the blind-cancel escalation ladder makes before giving up. Each
/// attempt is a fresh signature (a Ledger user sees up to this many prompts).
const int kBlindCancelMaxAttempts = 5;

/// `ceil(value × num / den)` — the replacement arithmetic rounds *up* so a
/// truncated division can never leave the replacement a wei under the node's
/// bump requirement.
BigInt ceilScale(BigInt value, int num, int den) =>
    (value * BigInt.from(num) + BigInt.from(den - 1)) ~/ BigInt.from(den);

/// The candidate bidding the most for the slot — the one a replacement must
/// out-bid. A tie on `maxFeePerGas` breaks on the tip; null for an empty list
/// (a derived external entry, whose stuck transaction's fees are unknown).
PendingTxCandidate? highestFeeCandidateOf(List<PendingTxCandidate> candidates) {
  PendingTxCandidate? best;
  for (final c in candidates) {
    if (best == null ||
        c.maxFeePerGas > best.maxFeePerGas ||
        (c.maxFeePerGas == best.maxFeePerGas &&
            c.maxPriorityFeePerGas > best.maxPriorityFeePerGas)) {
      best = c;
    }
  }
  return best;
}

/// The minimum caps a replacement for [candidates] may sign: per-field
/// `ceil(1.1 × highest-fee candidate)`, matching go-ethereum's 10% bump rule.
/// Null when there is nothing to out-bid (a derived external entry).
///
/// The reference is the **highest-fee** candidate, not the newest, so a second
/// speed-up floors against the first rather than against the original.
EvmFeeCaps? replacementFloorFor(List<PendingTxCandidate> candidates) {
  final best = highestFeeCandidateOf(candidates);
  if (best == null) return null;
  return (
    maxFeePerGas: ceilScale(best.maxFeePerGas, 11, 10),
    maxPriorityFeePerGas: ceilScale(best.maxPriorityFeePerGas, 11, 10),
  );
}

/// Raise [caps] to [floor] **per field** — a tier can be above the floor on the
/// max fee but below it on the tip, and the node rejects the replacement unless
/// *both* clear the bump.
EvmFeeCaps applyReplacementFloor(EvmFeeCaps caps, EvmFeeCaps? floor) {
  if (floor == null) return caps;
  return (
    maxFeePerGas: caps.maxFeePerGas > floor.maxFeePerGas
        ? caps.maxFeePerGas
        : floor.maxFeePerGas,
    maxPriorityFeePerGas: caps.maxPriorityFeePerGas > floor.maxPriorityFeePerGas
        ? caps.maxPriorityFeePerGas
        : floor.maxPriorityFeePerGas,
  );
}

/// One rung of the blind-cancel ladder: both caps ×1.25, rounded up so a small
/// value still grows.
EvmFeeCaps escalateCaps(EvmFeeCaps caps) => (
  maxFeePerGas: ceilScale(caps.maxFeePerGas, 5, 4),
  maxPriorityFeePerGas: ceilScale(caps.maxPriorityFeePerGas, 5, 4),
);

/// The transaction a replacement for [entry] must sign.
///
/// [asCancel] produces the cancel shape — self-send, zero value, no calldata,
/// [kCancelGasLimit] — which is also what "speed up" means for an entry that is
/// already cancelling (it bumps the cancel, it does not resurrect the original).
/// Otherwise the stored payload is replayed byte-for-byte, including the
/// original gas limit: raising it would invalidate the estimate the original
/// passed its safety gate with.
EvmReplacementPlan buildReplacementPlan(
  PendingEvmTx entry, {
  required bool asCancel,
}) {
  if (asCancel) {
    return EvmReplacementPlan(
      nonce: entry.nonce,
      to: entry.walletAddress,
      value: BigInt.zero,
      data: '',
      gasLimit: kCancelGasLimit,
      role: PendingTxCandidateRole.cancel,
    );
  }
  return EvmReplacementPlan(
    nonce: entry.nonce,
    to: entry.toAddress,
    value: entry.valueWei,
    data: entry.data,
    gasLimit: entry.gasLimit,
    role: PendingTxCandidateRole.speedup,
  );
}

/// Broadcast [caps], escalating ×1.25 and retrying whenever the node answers
/// "replacement transaction underpriced".
///
/// This is the blind-cancel path: for a nonce gap we do not know the stuck
/// transaction's fees, so the floor can't be computed and the only way to find
/// the required bid is to walk up until the node accepts. Bounded at
/// [maxAttempts]; the last failure is rethrown.
Future<String> broadcastWithEscalation({
  required EvmFeeCaps caps,
  required Future<String> Function(EvmFeeCaps caps) broadcast,
  required bool Function(Object error) isUnderpriced,
  int maxAttempts = kBlindCancelMaxAttempts,
}) async {
  var attemptCaps = caps;
  for (var attempt = 1; ; attempt++) {
    try {
      return await broadcast(attemptCaps);
    } on Object catch (e) {
      if (attempt >= maxAttempts || !isUnderpriced(e)) rethrow;
      attemptCaps = escalateCaps(attemptCaps);
    }
  }
}

BigInt _bigIntOf(Object? value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  return BigInt.tryParse('$value') ?? BigInt.zero;
}
