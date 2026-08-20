import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/crypto/wallet_manager.dart';
import '../../../core/models/account.dart';
import '../../../core/services/active_networks.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../core/session/session_manager.dart';
import '../models/token_balance.dart';
import 'token_repository.dart';

import '../../../shared/utils/chain.dart';

/// A session wallet paired with its balance of a specific token — the unit the
/// send flow's source-wallet picker renders and filters
/// (send-wallet-select spec).
class SendSourceCandidate {
  const SendSourceCandidate({
    required this.wallet,
    required this.rawBalance,
    required this.uiBalance,
  });

  final WalletInfo wallet;
  final int rawBalance;
  final double uiBalance;

  /// Whether this wallet can actually fund the send: native SOL must clear what
  /// the transaction itself can cost ([worstCaseSolTxFeeLamports]); every other
  /// case (SPL tokens, and non-Solana native coins like XTZ whose fees are
  /// tiny) only needs a nonzero balance. Keying the floor to Solana keeps a
  /// Tezos wallet from being disqualified by a lamport-denominated number.
  ///
  /// The floor is the fee alone, not a cushion above it: a wallet holding
  /// 0.002 SOL can pay for its own transfer — via Max, which empties it — so
  /// refusing to offer it as a source is refusing to let the user close it out.
  /// (A *partial* send from such a wallet is a different matter: it would have
  /// to leave the account rent-exempt, which the amount field enforces.)
  bool qualifies({required bool isNative}) =>
      isNative && wallet.chainEnum == Chain.solana
      ? rawBalance > worstCaseSolTxFeeLamports
      : rawBalance > 0;

  /// [token] — an aggregated portfolio row, summed across the session — narrowed
  /// to this wallet's own holding.
  ///
  /// A sheet quoting the session-wide sum would promise a spend of holdings the
  /// signing wallet doesn't have, and the auth gate's USD step-up threshold is
  /// derived from the same figure, so the two must never drift apart.
  TokenBalance narrow(TokenBalance token) {
    final price = token.pricePerToken;
    return token.copyWith(
      rawBalance: rawBalance,
      uiBalance: uiBalance,
      totalUsdValue: price == null ? null : uiBalance * price,
    );
  }
}

/// The candidate that should fund a spend of the mint [candidates] were read
/// for, or null when none of them can fund it at all — in which case the caller
/// stays on the active wallet rather than switching the user somewhere just as
/// empty.
///
/// [activeAddress] wins whenever it qualifies, so a flow never moves the user's
/// wallet needlessly. Otherwise the largest qualifying holder is chosen: these
/// flows pick the source *before* the amount is entered, so a dust-holding
/// wallet would strand the user right back at an insufficient balance.
SendSourceCandidate? pickFundingSource(
  List<SendSourceCandidate> candidates, {
  required String? activeAddress,
  required bool isNative,
}) {
  final funded = [
    for (final c in candidates)
      if (c.qualifies(isNative: isNative)) c,
  ];
  if (funded.isEmpty) return null;
  return funded.firstWhereOrNull((c) => c.wallet.address == activeAddress) ??
      funded.reduce((a, b) => b.rawBalance > a.rawBalance ? b : a);
}

/// [active] as a single-wallet scope, narrowed to [sessionAddresses] — the
/// session's own wallets on that chain.
///
/// A Profile session reads only the wallets linked in its user record, and the
/// globally-selected wallet is not guaranteed to be one of them. When it isn't,
/// the session's own wallet on the chain is read instead of the outside one. An
/// empty [sessionAddresses] means the session isn't loaded yet (the callers that
/// treat it as "no wallet on this chain" check that before calling), so the
/// active wallet passes through unchanged.
List<String> scopeToSession(String active, List<String> sessionAddresses) {
  if (sessionAddresses.isEmpty) return [active];
  final key = apiOwnerAddress(active);
  return sessionAddresses.any((a) => apiOwnerAddress(a) == key)
      ? [active]
      : [sessionAddresses.first];
}

/// The addresses whose [chain] balances a portfolio surface should read, never
/// leaving the session. The single rule `TokenBalanceBloc` (which renders the
/// rows) and `TokenDetailBloc` (which rewrites one of them after a confirmed
/// transaction) both resolve through — a divergent copy would let the detail
/// sheet rewrite an aggregated row with one wallet's share of it, or keep
/// updating a chain the user has switched off.
///
/// 🛑 [WalletManager.getAddress] resolves a non-Solana chain from the *active
/// account*, whose Ethereum/Tezos wallets are auto-derived at account creation.
/// In a Profile session those siblings are not linked to the profile, and
/// reading them surfaced an XTZ/ETH row — and its USD in the header total — for
/// a wallet the profile does not own.
///
/// [sessionAddresses] is therefore the ceiling: an aggregating surface reads all
/// of them, a per-signer one reads the active wallet only when the session owns
/// it. An empty result means the chain contributes nothing — no rows, no USD in
/// the total — which is also how a chain switched off in Active Networks
/// disappears.
Future<List<String>> resolveChainScope(
  Chain chain, {
  required List<String> sessionAddresses,
  required ActiveNetworks activeNetworks,
  required WalletManager walletManager,
  required bool aggregateAcrossSession,
}) async {
  if (sessionAddresses.isEmpty) return const [];
  if (!await activeNetworks.isEnabled(chain)) return const [];
  if (aggregateAcrossSession) return sessionAddresses;
  try {
    final active = await walletManager.getAddress(chain: chain);
    return scopeToSession(active, sessionAddresses);
  } catch (_) {
    // NoWalletException: the active account has no wallet on this chain.
    return [sessionAddresses.first];
  }
}

/// Aggregates token holdings across **all wallets in the active session**.
/// Portfolio stays a **client-side fan-out + merge** — the
/// multi-address login cookie scopes social/feed/notifications, NOT portfolio.
///
/// Fans out [TokenRepository.getTokenBalances] (which keeps its own per-wallet
/// cache + in-flight coalescing) over the session's Solana wallets in parallel,
/// then merges by mint. Ethereum and Tezos balances are fetched separately by
/// the tokens-tab bloc (via `EthereumTokenService`/`TezosTokenService` over
/// [sessionEthereumAddresses]/[sessionTezosAddresses]); this aggregator's own
/// fan-out stays Solana-only.
///
/// View-only wallets are included for reads where the address alone suffices —
/// a Solana address is enough to query Helius, so a Profile's unheld linked
/// Solana wallets still count toward the aggregate.
@lazySingleton
class SessionPortfolioAggregator {
  SessionPortfolioAggregator(this._session, this._tokens);

  final SessionManager _session;
  final TokenRepository _tokens;

  /// The distinct Solana addresses in the active session, in session order.
  List<String> sessionSolanaAddresses() {
    final seen = <String>{};
    return [
      for (final w in _session.sessionWallets)
        if (w.chainEnum == Chain.solana && seen.add(w.address)) w.address,
    ];
  }

  /// The distinct Ethereum addresses in the active session, in session order.
  /// Symmetric with [sessionSolanaAddresses]; the tokens-tab bloc fans
  /// [EthereumTokenService] over these when a Profile spans multiple wallets.
  List<String> sessionEthereumAddresses() {
    final seen = <String>{};
    return [
      for (final w in _session.sessionWallets)
        if (w.chainEnum == Chain.ethereum && seen.add(w.address)) w.address,
    ];
  }

  /// The distinct Tezos addresses in the active session, in session order.
  /// Symmetric with [sessionEthereumAddresses]; the tokens-tab bloc fans
  /// `TezosTokenService` over these when a Profile spans multiple wallets.
  List<String> sessionTezosAddresses() {
    final seen = <String>{};
    return [
      for (final w in _session.sessionWallets)
        if (w.chainEnum == Chain.tezos && seen.add(w.address)) w.address,
    ];
  }

  /// Solana addresses the **header/tokens-tab portfolio** should aggregate when
  /// a Profile is active; otherwise null, signalling the single active-signer
  /// path.
  ///
  /// Scoped to Profile sessions on purpose: the reported header-vs-drawer
  /// mismatch is the Profile row's per-profile aggregate diverging from the
  /// single-signer header. Account sessions keep the single active wallet.
  ///
  /// A profile linking a *single* Solana wallet returns that one address rather
  /// than null. Falling through to the active-signer path there read whatever
  /// wallet was globally selected — which a Profile session does not guarantee
  /// to be one of its linked wallets ([SessionManager.scopedToSession]).
  List<String>? profilePortfolioAddresses() {
    if (!_session.isProfileMode) return null;
    final addresses = sessionSolanaAddresses();
    return addresses.isNotEmpty ? addresses : null;
  }

  /// Summed USD value of all tokens held across the session's Solana wallets.
  /// Feeds the switcher header's aggregate balance (Task 06). Per-wallet
  /// failures degrade to 0 for that wallet rather than failing the whole sum.
  Future<double> aggregateBalanceUsd() async {
    final perWallet = await _balancesPerWallet();
    return perWallet.fold<double>(
      0,
      (sum, tokens) => sum + _tokens.calculateTotalValue(tokens),
    );
  }

  /// All session tokens merged across wallets: one row per mint, balances
  /// summed, sorted native-SOL-first then by USD value (mirrors the per-wallet
  /// ordering in [TokenRepository]).
  Future<List<TokenBalance>> aggregateTokenBalances() async {
    final perWallet = await _balancesPerWallet();
    return mergeTokenBalances(perWallet);
  }

  /// Merged Solana balances across the session's **signable** wallets — the
  /// mints a Solana signing flow can actually spend, which is what the swap's
  /// sell picker lists.
  ///
  /// Narrower than [aggregateTokenBalances] on purpose: a view-only wallet's
  /// holdings belong in the portfolio (an address alone is enough to read them)
  /// but never in a picker that has to produce a signature. [sendSourcesForMint]
  /// drops those wallets, so such a pick resolves no funding source and
  /// dead-ends on a zero balance.
  ///
  /// Reads the per-wallet **cache** by default so a picker can open without a
  /// spinner (the portfolio it was opened from has already written it); pass
  /// [refresh] to fan out to Helius and pick up a wallet whose cache was never
  /// written — there, a failing wallet contributes nothing rather than sinking
  /// the whole list.
  Future<List<TokenBalance>> signableSolanaBalances({
    bool refresh = false,
  }) async {
    return mergeTokenBalances(await _signableSolanaPerWallet(refresh: refresh));
  }

  /// Fan out over the session's signable Solana wallets in parallel, each
  /// wallet's balances from the cache or (with [refresh]) the network, where a
  /// failing wallet degrades to an empty list rather than sinking the scan.
  Future<List<List<TokenBalance>>> _signableSolanaPerWallet({
    bool refresh = false,
  }) {
    return Future.wait(
      _signableWalletsOn(Chain.solana).map(
        (w) => refresh
            ? _safeBalances(w.address)
            : _tokens.getCachedBalances(w.address),
      ),
    );
  }

  /// The session's **signable** wallets on [chain] paired with their balance of
  /// [mint], in session order (deduped by address) — the candidate set for the
  /// send flow's source-wallet picker (send-wallet-select spec).
  ///
  /// Reads only the per-wallet balance **cache** by default so the send flow
  /// can decide whether to prompt without a blocking spinner; pass
  /// [refresh] to fan out to Helius and refine. Wallets that can't locally sign
  /// a transfer on [chain] are excluded (view-only everywhere, plus Ledger and
  /// social on Ethereum) — they can never be a source.
  Future<List<SendSourceCandidate>> sendSourcesForMint({
    required Chain chain,
    required String mint,
    bool refresh = false,
  }) async {
    final session = _session.sessionWallets;
    if (kDebugMode) {
      debugPrint(
        '[SendSources] request chain=${chain.toDbString()} mint=$mint '
        'refresh=$refresh sessionWallets=${session.length}',
      );
      for (final w in session) {
        debugPrint(
          '[SendSources]   wallet ${w.address} chain=${w.chain} '
          'type=${w.walletType.toDbString()} canSign=${w.canSign}',
        );
      }
    }
    final wallets = _signableWalletsOn(chain);
    if (kDebugMode) {
      debugPrint(
        '[SendSources] chain-matched signable wallets=${wallets.length}',
      );
    }
    final candidates = <SendSourceCandidate>[];
    for (final w in wallets) {
      final balances = refresh
          ? await _safeBalances(w.address)
          : await _tokens.getCachedBalances(w.address);
      final token = balances.firstWhereOrNull(
        (t) => t.chain == chain && t.mint == mint,
      );
      if (kDebugMode) {
        debugPrint(
          '[SendSources]   candidate ${w.address} '
          'balancesFetched=${balances.length} '
          'mintMatch=${token != null} rawBalance=${token?.rawBalance ?? 0} '
          '(mints=${balances.where((t) => t.chain == chain).map((t) => t.mint).toList()})',
        );
      }
      candidates.add(
        SendSourceCandidate(
          wallet: w,
          rawBalance: token?.rawBalance ?? 0,
          uiBalance: token?.uiBalance ?? 0,
        ),
      );
    }
    return candidates;
  }

  /// Solana mints at least one **signable** session wallet actually holds — the
  /// set of rows the tokens tab may offer a swipe action on.
  ///
  /// A token whose only balances sit on watch-only session wallets still shows
  /// in the aggregated portfolio (a watch-only address is enough to read from
  /// Helius), but neither swipe action can complete for it: the send picker
  /// offers no source and the burn has no wallet to sign the close. Surfacing
  /// the whole mint set in one pass keeps the gate off the per-row build path —
  /// [sendSourcesForMint] would be one scan per rendered row.
  ///
  /// Reads only the per-wallet balance **cache** (never the network): the tab's
  /// own load writes every session wallet's cache before it paints, so this is
  /// warm for exactly the rows on screen. Solana-only, because the cache rows
  /// carry no chain of their own — the swipe gate is Solana-only too.
  Future<Set<String>> signableSolanaMints() async {
    final perWallet = await _signableSolanaPerWallet();
    return {
      for (final balances in perWallet)
        for (final token in balances)
          if (token.rawBalance > 0) token.mint,
    };
  }

  /// The session's wallets on [chain] that can locally sign a transfer, in
  /// session order and deduped by address.
  ///
  /// `canSignSendTransfer` (not plain `canSign`) so an ETH social wallet — which
  /// can't sign a transfer — is never offered as a send source and can't
  /// dead-end a flow after the biometric gate.
  List<WalletInfo> _signableWalletsOn(Chain chain) {
    final seen = <String>{};
    return [
      for (final w in _session.sessionWallets)
        if (w.chainEnum == chain &&
            w.canSignSendTransfer &&
            seen.add(w.address))
          w,
    ];
  }

  /// Network balance fetch that degrades a failing wallet to an empty list so
  /// one bad wallet can't sink the whole candidate scan.
  Future<List<TokenBalance>> _safeBalances(String address) async {
    try {
      return await _tokens.getTokenBalances(address);
    } catch (_) {
      return const [];
    }
  }

  /// Fan out per session Solana wallet in parallel. Each wallet's balances come
  /// from its own cache; a wallet that throws contributes an empty list so one
  /// bad wallet can't sink the aggregate.
  Future<List<List<TokenBalance>>> _balancesPerWallet() async {
    final addresses = sessionSolanaAddresses();
    return Future.wait(
      addresses.map((a) async {
        try {
          return await _tokens.getTokenBalances(a);
        } catch (_) {
          return <TokenBalance>[];
        }
      }),
    );
  }

  /// Merge per-wallet balance lists into one list keyed by **(chain, mint)**:
  /// raw + UI balances are summed; price/metadata are taken from the first
  /// wallet that reported them; `totalUsdValue` is recomputed from the summed
  /// UI balance. Keying on chain as well as mint keeps a Solana mint and an
  /// Ethereum contract (or two chains' native sentinels) from ever collapsing
  /// into one row.
  ///
  /// Static + pure so the merge math is unit-testable without a session.
  static List<TokenBalance> mergeTokenBalances(
    List<List<TokenBalance>> perWallet,
  ) {
    final byKey = <String, TokenBalance>{};
    for (final wallet in perWallet) {
      for (final t in wallet) {
        final key = '${t.chain.name}:${t.mint}';
        final existing = byKey[key];
        if (existing == null) {
          byKey[key] = t;
          continue;
        }
        final rawBalance = existing.rawBalance + t.rawBalance;
        final uiBalance = existing.uiBalance + t.uiBalance;
        final price = existing.pricePerToken ?? t.pricePerToken;
        byKey[key] = existing.copyWith(
          rawBalance: rawBalance,
          uiBalance: uiBalance,
          pricePerToken: price,
          totalUsdValue: price == null ? null : uiBalance * price,
          // Preserve a verified/native classification if either source had it.
          isVerified: existing.isVerified || t.isVerified,
          logoUrl: existing.logoUrl ?? t.logoUrl,
        );
      }
    }

    return byKey.values.toList()..sort((a, b) {
      if (a.isNative != b.isNative) return a.isNative ? -1 : 1;
      return (b.totalUsdValue ?? 0).compareTo(a.totalUsdValue ?? 0);
    });
  }
}
