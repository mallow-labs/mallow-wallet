/// Shared copy for every phase of a transaction pipeline — preparing,
/// wallet-approval / signing, and on-chain confirmation.
///
/// Every flow that drives a `TransactionPipelineSheet` reads its progress
/// label and sublabel from the constants and helpers here rather than
/// inlining string literals, so the wording changes in exactly one place. A
/// flow may override the *label* with action-specific copy where a design
/// calls for it (e.g. "Listing artwork…"), but the paired sublabel stays
/// shared — the wait it describes is the same wait everywhere.
///
/// A LOCAL key wallet (HD or imported private key) signs in-app with no
/// external prompt, so the copy says the app is handling approval instead of
/// telling the user to approve in a wallet. External/Ledger signers keep the
/// approve-in-wallet nudge.
///
/// The marketplace and mint flows carry the local-vs-external signal in the
/// signing *stage* string the bloc emits: every local-signing stage starts
/// with [kLocalSigningLabel] (the multi-tx flows append a " (1/N)"
/// progress suffix). Render sites map that stage to the right label and
/// sublabel via the helpers below, keeping the copy identical across every
/// flow.
library;

import '../../shared/utils/chain.dart';

/// Title shown while the transaction is being built, before any signing.
const String kPreparingLabel = 'Preparing transaction…';

/// Subtitle paired with the preparing phase. Building a tx is a backend call,
/// not an on-chain wait, so it promises no duration.
const String kPreparingSublabel = 'This may take a moment';

/// Title shown once the tx is broadcast and the app is waiting for it to land.
const String kConfirmingLabel = 'Confirming transaction…';

/// Confirming-phase subtitle on **Solana**, where a transaction normally lands
/// within a slot or two.
///
/// This describes the common case, not the worst one. The wait itself is
/// bounded by *blockhash validity* — `signSendConfirm` →
/// `SolanaRpcService.awaitConfirmationOrThrow` re-broadcasts until the
/// blockhash expires (~60–90 s, 90 s hard cap), so a congested tail can outrun
/// this copy. Cover that tail with `TransactionPipelineSheet.sublabelCycle`
/// rather than by inflating the promise here.
const String kConfirmingSublabelSolana = 'This will take a few seconds';

/// Confirming-phase subtitle on **EVM and Tezos**, whose block times are far
/// longer than Solana's — "a few seconds" would be wrong there.
const String kConfirmingSublabelOtherChains = 'This may take up to a minute';

/// Reassurance lines swapped in under [kConfirmingSublabelSolana], one every
/// `TransactionPipelineSheet.sublabelCycleInterval` (10 s), when a Solana
/// confirmation outruns the "few seconds" the opening line promises.
///
/// Order matters: each line concedes a little more, and the sheet holds on the
/// last one rather than looping — returning to "a few seconds" after 30 s of
/// waiting reads as the wait starting over.
const List<String> kConfirmingSublabelCycleSolana = [
  'Just a bit longer',
  'Network is busier than usual',
];

/// Confirming-phase subtitle for [chain]. Flows that can only ever sign on one
/// chain should read the matching constant directly instead.
String confirmingSublabelForChain(Chain chain) => switch (chain) {
  Chain.solana => kConfirmingSublabelSolana,
  Chain.ethereum || Chain.tezos => kConfirmingSublabelOtherChains,
};

/// The `sublabelCycle` to pair with [sublabel] — the Solana reassurance lines
/// for the Solana confirming subtitle, nothing for anything else.
///
/// Keying off the subtitle rather than the phase lets every host pass this
/// unconditionally: the cycle can only start on the one step that renders
/// [kConfirmingSublabelSolana], which is exactly the wait it describes. Flows
/// with an action-specific *label* over that subtitle ("Buying artwork…",
/// "Listing artwork…") are covered for free, and a non-Solana confirmation
/// falls through to empty because its subtitle is a different constant.
List<String> sublabelCycleFor(String? sublabel) =>
    sublabel == kConfirmingSublabelSolana
    ? kConfirmingSublabelCycleSolana
    : const [];

/// Title shown while a local key wallet signs a single tx, and the
/// prefix of every local-signing stage string (multi-tx variants append a
/// progress suffix after it).
const String kLocalSigningLabel = 'Approving transaction…';

/// Subtitle paired with local signing — no external action is required.
const String kLocalSigningSublabel = 'One moment please';

/// Main label shown while an external signer is waiting for approval.
const String kExternalSigningLabel = 'Awaiting approval…';

/// Subtitle shown while a Ledger user approves on the hardware wallet.
const String kLedgerSigningSublabel = 'Approve the transaction on your Ledger';

/// Fallback subtitle for social and any future external wallet signers.
const String kExternalSigningSublabel =
    'Approve the transaction in your wallet';

/// Prefix used by executor stages while a Ledger device waits for approval.
const String kLedgerSigningStage = 'Approve on your Ledger device';

/// Whether [stage] denotes local-key signing.
bool isLocalSigningStage(String? stage) =>
    stage != null && stage.startsWith(kLocalSigningLabel);

/// Whether [stage] denotes a Ledger-device approval stage.
bool isLedgerSigningStage(String? stage) =>
    stage != null && stage.startsWith(kLedgerSigningStage);

/// Signing-phase label for [stage]. Local stages retain their multi-tx
/// progress suffix; external stages use the shared approval label and retain
/// any batch progress suffix.
String signingLabelForStage(String? stage) {
  if (isLocalSigningStage(stage)) return stage!;
  if (stage == null) return kExternalSigningLabel;
  final progress = RegExp(r' \(\d+(?:/\d+| of \d+)\)$').firstMatch(stage);
  return '$kExternalSigningLabel${progress?.group(0) ?? ''}';
}

/// Signing-phase subtitle for [stage]: local reassurance, Ledger-specific
/// instruction, or the external-wallet fallback.
String signingSublabelForStage(String? stage) {
  if (isLocalSigningStage(stage)) return kLocalSigningSublabel;
  if (isLedgerSigningStage(stage)) return kLedgerSigningSublabel;
  return kExternalSigningSublabel;
}
