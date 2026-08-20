/// The one definition of the key an aggregated **address scope** is stored,
/// paginated, and compared under.
///
/// Balances, the activity feed, and per-token transfer history are each fetched
/// over a *set* of session wallets, but every Drift cache table is keyed by a
/// single `walletAddress` string. This collapses the set into that string: the
/// lone address for a single-wallet scope, else the sorted addresses joined
/// with `|`.
///
/// It is shared rather than reimplemented per feature because the keys have to
/// agree. `TokenBalanceBloc` uses it as the loaded state's identity so the
/// header can tell a session switch apart from a same-session refresh, while
/// `TokenTransferRepository` and `ActivityRepository` write their Drift rows
/// under it. Four hand-synced copies of this expression used to exist; if any
/// one of them drifted, a wallet-set change would read a cache under a key
/// nothing was written to — a silent cold start, or a stale mixed feed.
///
/// The format is load-bearing and must not change: it is a durable on-disk key,
/// so a new shape orphans every cached row (reaped only by the 24h prune) and
/// re-fetches from cold. Properties callers rely on:
///
/// - **Order-independent.** The same wallets in any order give one key, so a
///   re-ordered session reads its own cache instead of cold-starting.
/// - **Bare address for a single wallet.** A one-wallet scope keys on the plain
///   address, which is also what the single-wallet write paths store.
/// - **No de-duplication.** Callers pass an already-unique scope; duplicates
///   would produce a distinct key rather than being folded away.
String addressScopeKey(List<String> addresses) =>
    (List<String>.of(addresses)..sort()).join('|');
