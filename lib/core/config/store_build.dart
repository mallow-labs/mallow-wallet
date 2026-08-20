/// Build-time visibility flags for store submissions.
///
/// These hide UI for features that exist in the tree but must not be *visible*
/// in a public store build, because showing them is a store-policy rejection
/// risk. A raffle reads as a lottery to both stores, which is a rejection risk
/// the flag exists to remove from a submitted build.
///
/// **The code stays.** Every flag here gates a widget's *visibility*, never the
/// underlying bloc, repository or service — so flipping a flag back on is a
/// one-line change, not a re-implementation.
///
/// Two rules that make the App Review notes true (Apple 2.3.1 prohibits
/// revealing features review never saw):
///
/// 1. **Compile-time, not remote.** A store build cannot be made to reveal one
///    of these surfaces by a remote-config change. Where a `RemoteConfigService`
///    gate also exists for the same flow, the two compose with `&&` — the remote
///    gate can only disable further, never re-enable.
/// 2. **Default to hidden in release.** Every flag is `kDebugMode`-derived, so a
///    release archive hides the surface unless someone deliberately overrides it
///    with `--dart-define`.
library;

import 'package:flutter/foundation.dart';

/// Overridable at build time: `--dart-define=SHOW_UNRELEASED=true`.
///
/// Debug builds default to showing everything so development and QA are not
/// blocked by store-policy hiding.
const bool _showUnreleased = bool.fromEnvironment(
  'SHOW_UNRELEASED',
  defaultValue: kDebugMode,
);

/// In-app raffle **entry** (ticket purchase).
///
/// Consideration + chance + prize is a lottery under Apple 5.3 and Play's
/// Real-Money Gambling/Contests policy, and shipping it requires developer
/// sponsorship, in-app rules text, an approved Play application and a country
/// allowlist. None of that is in place.
///
/// Claim paths (`claimNft`, `claimProceeds`) are deliberately NOT gated by this
/// flag — users holding tickets in a live raffle must still be able to claim.
const bool kShowRaffleEntry = _showUnreleased;
