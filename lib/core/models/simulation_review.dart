/// Execution and interpretation are independent: a successful simulation can
/// still contain effects this wallet cannot explain.
enum SimulationExecution { succeeded, failed, unavailable }

enum SimulationCoverage { complete, partial, unavailable }

enum ReviewEvidence { simulatedState, requestedInstruction, event, inferred }

enum AccountChangeKind {
  create,
  close,
  approve,
  revoke,
  freeze,
  thaw,
  authority,
  contractCall,
}

enum NftChangeKind { transfer, mint, burn, approve, revoke, authority }

/// What an NFT's delegate may do with it. A Core NFT's transfer, burn and
/// freeze delegates are separate grants, each with its own holder.
enum NftDelegatePower { transfer, burn, freeze }

/// The key in [SimulationReview.delegatedBy] for calls that may have set a
/// delegate or an authority and could not be tied to an account. Their
/// programs count toward every account's set. No address is empty, so the key
/// cannot collide with one.
const String kUntracedDelegations = '';

class ReviewAsset {
  const ReviewAsset({
    required this.id,
    required this.symbol,
    this.decimals,
    this.verified = false,
  });
  final String id;
  final String symbol;

  /// Null means raw units only; never guess a token's precision.
  final int? decimals;

  /// A token the wallet itself vouches for, so [symbol] is shown as its name.
  /// Registry mints are verified without this; it is for assets the registry
  /// does not key, such as a known ERC-20 contract.
  final bool verified;
}

class FundChange {
  const FundChange({
    required this.asset,
    required this.address,
    required this.rawAmount,
    required this.evidence,
    this.from,
    this.to,
    this.isNet = false,
  });
  final ReviewAsset asset;
  final String address;
  final BigInt rawAmount;
  final ReviewEvidence evidence;
  final String? from;
  final String? to;
  final bool isNet;
}

class AccountChange {
  const AccountChange({
    required this.kind,
    required this.address,
    required this.program,
    required this.description,
    required this.evidence,
    this.beneficiary,
    this.rawAllowance,
    this.assetId,
    this.balance,
    this.power,
  });
  final AccountChangeKind kind;
  final String address;
  final String program;
  final String description;
  final ReviewEvidence evidence;
  final String? beneficiary;
  final BigInt? rawAllowance;
  final String? assetId;

  /// What the token account at [address] held before the transaction, in
  /// base units, when it was read. Lets the review tell an approval that
  /// covers the whole balance from a partial one.
  final BigInt? balance;

  /// What the delegate of an NFT may do with it, when the grant says: a Core
  /// NFT's delegates. Null for every other change, where an approval is the
  /// right to transfer.
  final NftDelegatePower? power;
}

class NftChange {
  const NftChange({
    required this.kind,
    required this.assetId,
    required this.description,
    required this.evidence,
    this.from,
    this.to,
    this.quantity,
    this.isMultiCopy = false,
  });
  final NftChangeKind kind;
  final String assetId;
  final String description;
  final ReviewEvidence evidence;
  final String? from;
  final String? to;

  /// Copy count for a multi-copy NFT; null means the count is unknown.
  final BigInt? quantity;

  /// Distinguishes an unknown copy count from a single-item NFT.
  final bool isMultiCopy;
}

class ReviewNftMetadata {
  const ReviewNftMetadata({this.name, this.imageUrl});
  final String? name;
  final String? imageUrl;
}

/// An unverified token's own symbol and image, from its on-chain metadata.
///
/// Both are chosen by whoever created the token, so the review shows them
/// only beside its "Unverified token" line, and [fromCreator] refuses a
/// symbol that a known token already uses: a look-alike must never read as
/// the real thing.
class ReviewTokenMetadata {
  const ReviewTokenMetadata({required this.symbol, this.imageUrl});

  final String symbol;
  final String? imageUrl;

  /// Short, plain ASCII only: no spaces, no look-alike letters from other
  /// scripts, no direction overrides.
  static final _symbolPattern = RegExp(r'^[A-Za-z0-9$_.\-]{1,12}$');

  /// Metadata from a token's creator, or null when it cannot be shown safely:
  /// no usable symbol, or one in [reservedSymbols] (lower-cased symbols of
  /// the tokens the app knows). The image is kept only over https.
  static ReviewTokenMetadata? fromCreator({
    required Object? symbol,
    required Object? image,
    required Set<String> reservedSymbols,
  }) {
    if (symbol is! String) return null;
    final trimmed = symbol.trim();
    if (!_symbolPattern.hasMatch(trimmed)) return null;
    if (reservedSymbols.contains(trimmed.toLowerCase())) return null;
    final url = image is String ? Uri.tryParse(image.trim()) : null;
    return ReviewTokenMetadata(
      symbol: trimmed,
      imageUrl: url != null && url.scheme == 'https' && url.host.isNotEmpty
          ? url.toString()
          : null,
    );
  }
}

class ReviewProgramCall {
  const ReviewProgramCall({required this.program, this.instruction});
  final String program;
  final String? instruction;
}

/// One transaction of a batch reviewed as a whole: its own program calls and
/// Explorer link, and whether its simulation ran. The batch's effects are
/// combined on the [SimulationReview] that holds it.
class ReviewTransaction {
  ReviewTransaction({
    required this.execution,
    this.explorerUrl,
    List<ReviewProgramCall> programCalls = const [],
  }) : programCalls = List.unmodifiable(programCalls);
  final SimulationExecution execution;
  final Uri? explorerUrl;
  final List<ReviewProgramCall> programCalls;
}

/// A [SimulationReview.warnings] entry: the before and after balances were
/// read at different slots. The review sheet folds it into its estimate
/// caption rather than showing it as a caution.
const String kSimulationSnapshotSlotsWarning =
    'Balance snapshots use different slots; displayed changes are estimates.';

class SimulationReview {
  SimulationReview({
    required this.payloadDigest,
    required this.origin,
    required this.walletId,
    required this.address,
    required this.chain,
    required this.simulatedAt,
    required this.execution,
    required this.coverage,
    this.effectsUndecodable = false,
    this.slot,
    this.feeLamports,
    this.networkFee,
    this.maxNetworkFee,
    this.feePayer,
    this.error,
    this.outgoingUsd,
    this.explorerUrl,
    Map<String, ReviewNftMetadata> nftMetadata = const {},
    Map<String, ReviewTokenMetadata> tokenMetadata = const {},
    Map<String, ReviewAsset> assets = const {},
    List<ReviewProgramCall> programCalls = const [],
    List<ReviewTransaction> transactions = const [],
    List<String> warnings = const [],
    List<FundChange> funds = const [],
    List<AccountChange> accounts = const [],
    List<NftChange> nfts = const [],
    Map<String, Set<String>> delegatedBy = const {},
  }) : nftMetadata = Map.unmodifiable(nftMetadata),
       tokenMetadata = Map.unmodifiable(tokenMetadata),
       assets = Map.unmodifiable(assets),
       programCalls = List.unmodifiable(programCalls),
       transactions = List.unmodifiable(transactions),
       warnings = List.unmodifiable(warnings),
       funds = List.unmodifiable(funds),
       accounts = List.unmodifiable(accounts),
       nfts = List.unmodifiable(nfts),
       delegatedBy = Map.unmodifiable({
         for (final MapEntry(:key, :value) in delegatedBy.entries)
           key: Set<String>.unmodifiable(value),
       });
  final Uri? explorerUrl;

  /// On Solana, for each account whose delegate or authority a call sets (a
  /// token account, a compressed or Core NFT by its asset id, a stake
  /// account, a program, a name), the programs of the top-level instructions
  /// whose calls did so: the program itself when the transaction calls it
  /// directly, otherwise the program whose calls reached it. Read from the
  /// simulation's inner instructions, so it is empty until a simulation has
  /// run. An account missing here was not traced, and who chose its delegate
  /// or authority is unknown. [kUntracedDelegations] keys the programs whose
  /// calls could not be tied to any account.
  final Map<String, Set<String>> delegatedBy;
  final Map<String, ReviewNftMetadata> nftMetadata;

  /// Unverified tokens' own symbol and image, keyed by mint. Registry mints
  /// never appear here: their bundled symbol and logo always win.
  final Map<String, ReviewTokenMetadata> tokenMetadata;

  /// Display assets for ids that appear only in [accounts] — a token whose
  /// allowance changes without any of it moving — keyed by asset id.
  final Map<String, ReviewAsset> assets;
  final List<ReviewProgramCall> programCalls;

  /// The transactions of a batch, in order, when this review combines more
  /// than one. Empty for a single transaction, whose calls and Explorer link
  /// are [programCalls] and [explorerUrl].
  final List<ReviewTransaction> transactions;
  final String payloadDigest;
  final String origin;
  final String walletId;
  final String address;
  final String chain;
  final DateTime simulatedAt;
  final int? slot;
  final SimulationExecution execution;
  final SimulationCoverage coverage;

  /// The simulation response could not be interpreted. Execution stays
  /// unavailable unless independently known; approval still needs caution.
  final bool effectsUndecodable;
  final int? feeLamports;

  /// The expected fee in the chain's native base unit (wei on Ethereum), for
  /// chains whose fee does not fit [feeLamports]. Null when unknown.
  final BigInt? networkFee;

  /// The most the fee can reach (gas limit × max fee per gas), when the chain
  /// has a ceiling above its expected fee.
  final BigInt? maxNetworkFee;
  final String? feePayer;
  final String? error;
  final double? outgoingUsd;
  final List<String> warnings;
  final List<FundChange> funds;
  final List<AccountChange> accounts;
  final List<NftChange> nfts;
}

/// Exact fixed-point formatting, including values beyond JavaScript precision.
String formatReviewAmount(BigInt value, int? decimals) {
  if (decimals == null) return '$value base units';
  final sign = value.isNegative ? '−' : '';
  final digits = value.abs().toString().padLeft(decimals + 1, '0');
  if (decimals == 0) return '$sign$digits';
  final split = digits.length - decimals;
  final fraction = digits.substring(split).replaceFirst(RegExp(r'0+$'), '');
  return '$sign${digits.substring(0, split)}${fraction.isEmpty ? '' : '.$fraction'}';
}
