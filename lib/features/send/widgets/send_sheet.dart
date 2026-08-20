import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mallow_api/mallow_api.dart' show UserPreview;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/config/remote_config_service.dart';
import '../../../core/crypto/ens_resolver.dart';
import '../../../core/crypto/sns_resolver.dart';
import '../../../core/data/mallow_tokens.dart' as mallow_tokens;
import '../../../core/models/account.dart';
import '../../../core/security/security_utils.dart' show SecurityUtils;
import '../../../core/crypto/wallet_manager.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/services/fee_config.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/priority_fee_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../core/session/session_manager.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/utils/token_amount.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/balance_check.dart';
import '../../../shared/utils/chain.dart'
    show Chain, apiOwnerAddress, evmRecipientError, isEthereumAddress;
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/tezos_address.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/generic_confirmation_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/view_only_prompt.dart';
import '../../portfolio/data/ethereum_token_service.dart';
import '../../portfolio/data/session_portfolio_aggregator.dart';
import '../../portfolio/data/tezos_token_service.dart';
import '../../portfolio/data/token_repository.dart';
import '../../portfolio/models/token_balance.dart';
import '../../portfolio/services/token_balance_bloc.dart';
import '../../wallets/services/profile_lookup_service.dart';
import '../models/recent_recipient.dart';
import '../models/recipient_advisory.dart';
import '../models/recipient_suggestion.dart';
import '../services/recipient_advisory_service.dart';
import '../services/send_bloc.dart';
import 'recipient_search_dropdown.dart';
import 'send_amount_step.dart';
import 'edit_gas_fee_sheet.dart';
import 'send_confirm_step.dart';
import 'send_pipeline_view.dart';
import 'send_qr_scanner_view.dart';
import 'send_recipient_step.dart';
import 'send_token_select_step.dart';
import 'send_wallet_select_sheet.dart';

/// Opens the multi-step send sheet: token select →
/// recipient → amount → confirm.
///
/// Pass [initialToken] to skip token selection (e.g. from a token detail
/// screen) and [tokenBalanceBloc] to share the caller's balances; otherwise
/// the sheet spins up its own.
///
/// Deliberately **not** a kill-switch gate: neither the chain nor the
/// native-vs-token split is known yet — both come from token selection inside
/// the sheet. The gates are the picker rows
/// ([sendDisabledMessage]) and the confirm step's re-check; all this does is
/// refresh the config on the way in so both read a fresh value.
///
/// It **is** the signer gate for every entry point that passes an
/// [initialToken], since the chain is known here. Placed in the sheet rather
/// than at each caller so a call site added later inherits it — the same
/// convention the kill-switch gates follow. Chain-less entry points are gated
/// at token selection ([_SendSheetState._onTokenSelected]) instead.
Future<void> showSendSheet(
  BuildContext context, {
  TokenBalance? initialToken,
  TokenBalanceBloc? tokenBalanceBloc,
}) async {
  unawaited(sl<RemoteConfigService>().refreshIfStale());
  if (initialToken != null &&
      await guardCannotSend(context, chain: initialToken.chain)) {
    return;
  }
  if (!context.mounted) return;
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => MultiBlocProvider(
      providers: [
        if (tokenBalanceBloc != null)
          BlocProvider.value(value: tokenBalanceBloc)
        else
          BlocProvider(
            create: (_) =>
                sl<TokenBalanceBloc>()..add(const TokenBalanceEvent.load()),
          ),
        BlocProvider(create: (_) => sl<SendBloc>()),
      ],
      child: SendSheet(initialToken: initialToken),
    ),
  );
}

enum _SendStep { token, recipient, amount, confirm }

class SendSheet extends StatefulWidget {
  const SendSheet({this.initialToken, super.key});

  final TokenBalance? initialToken;

  @override
  State<SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<SendSheet> {
  final _addressController = TextEditingController();
  final _amountController = TextEditingController();
  final _addressFocusNode = FocusNode();
  final _amountFocusNode = FocusNode();

  _SendStep _step = _SendStep.token;
  TokenBalance? _selectedToken;

  Timer? _resolveDebounce;
  String? _addressError;
  String? _resolvedAddress;
  bool _isResolving = false;

  /// Drives the username-search dropdown under the address field.
  late final RecipientSearchController _recipientSearch =
      RecipientSearchController(isExcluded: _isSelfAddress);

  /// A profile was picked from that dropdown, so the field holds a handle
  /// rather than an address.
  ///
  /// No address validator accepts `@alice`, so this is what tells
  /// [_onRecipientNext] to trust [_resolvedAddress] instead of re-parsing the
  /// field text. A boolean rather than the username itself: the backend also
  /// matches on display name, so a picked profile may legitimately have no
  /// username and a null would then read as "nothing picked". Cleared on the
  /// next keystroke.
  bool _pickedProfile = false;

  /// A signer switch is in flight. Blocks input and shows a spinner over the
  /// step: since T0.2 the switch awaits a `/v0/login`, and the auto-adopt path
  /// fires it without any user action.
  bool _switchingSource = false;

  List<RecentRecipient> _recents = const [];

  /// The sending wallet's address. Recipients matching it are filtered out of
  /// recents and blocked at the Next step so the user can't send to themselves.
  String? _selfAddress;

  /// The chain [_selfAddress] was resolved for. The sheet is seeded before a
  /// token (and therefore a chain) is known, so this is what lets
  /// [_ensureSelfAddress] re-resolve when the send turns out to be on another
  /// chain instead of keeping the initial Solana answer.
  Chain? _selfAddressChain;

  /// Normalized address → resolved mallow profile. A null value marks an
  /// address that has been looked up (or is in flight) with no profile, so it
  /// isn't re-fetched.
  ///
  /// Every key and every read goes through [apiOwnerAddress], the form
  /// [ProfileLookupService.profilesForAddresses] answers in — see
  /// [_loadSelfAddress] for why a raw `==` between the two EVM forms of one
  /// address is always wrong.
  final Map<String, UserPreview?> _profiles = {};

  /// Normalized address → the local account that holds it, when the recipient
  /// is another account on this device. Same key rule and same "key present
  /// means looked up" contract as [_profiles].
  ///
  /// Separate from [_profiles] because it answers a different question: a
  /// mallow profile is who the *world* knows an address as, while this is what
  /// *this device* calls it. Most accounts have no profile at all, so the
  /// confirm step showed a bare hash for a wallet the user owns — on every
  /// chain, since nothing here is EVM-specific.
  final Map<String, ({String name, String avatarSeed})?> _accounts = {};

  /// Address → recipient advisory, same "key present means looked up" contract
  /// as [_profiles]. Resolved when the confirm step appears rather than during
  /// review, so classification latency never delays reaching the step and can
  /// never fail a send: the advisory is UI, and the CTA does not read it.
  final Map<String, RecipientAdvisory?> _advisories = {};

  /// Latest ready snapshot — kept so the confirm step can still render while
  /// the bloc has moved on to signing/broadcasting in the pipeline step.
  SendReady? _ready;

  /// True once the user confirms — the flow morphs from the input steps to the
  /// in-flight pipeline step within the same route (no separate sheet).
  bool _inPipeline = false;

  // ── Source-wallet selection (send-wallet-select spec) ──────────────────────

  /// Qualifying source wallets for the selected token: signable, same-chain,
  /// holding an above-dust balance of it. 2+ enables the picker + the Switch
  /// line; exactly 1 shows the line without Switch; 0 falls back to the active
  /// signer with no line.
  List<SendSourceCandidate> _sources = const [];

  /// The chosen (or default-active) source wallet when the picker is in play.
  WalletInfo? _sourceWallet;

  /// The funding wallet's own token list, used for the confirm-time balance
  /// checks so they reflect the chosen wallet rather than the session aggregate
  /// the portfolio entry point shares in.
  List<TokenBalance> _sourceTokens = const [];

  /// The address [_sourceTokens] was loaded for — the wallet that will actually
  /// fund the send. Usually [_sourceWallet], but on Solana's no-qualifying-
  /// source fallback no wallet is adopted and the executor still
  /// signs with the active signer, so the guards have to follow *that* address
  /// rather than lose their subject.
  String? _fundingAddress;

  /// Whether [_sourceTokens] is an *answer* about [_fundingAddress] rather than
  /// an unread cache. An empty list means "this wallet holds nothing" only once
  /// this is true; until then the confirm-time guards allow through, mirroring
  /// [checkBalance]'s "don't false-disable on entry" rule.
  bool _fundingBalancesKnown = false;

  /// Guards the one-time up-front picker prompt so a late cache refresh can't
  /// re-open it after the user already chose.
  bool _sourcePromptShown = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialToken;
    if (initial != null) {
      _selectedToken = initial;
      _step = _SendStep.recipient;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!initial.isNative) {
          context.read<SendBloc>().add(SendEvent.setToken(initial));
        }
        unawaited(_initSourcesFromInitialToken(initial));
      });
    }
    _recents = [
      for (final address in sl<PreferencesService>().recentSendAddresses)
        RecentRecipient(address: address),
    ];
    unawaited(_resolveRecentAccounts());
    unawaited(_resolveRecentProfiles());
    // Seeded from the chain known now — `initialToken`'s, else Solana. A
    // token picked later re-resolves via [_ensureSelfAddress].
    unawaited(_loadSelfAddress(initial?.chain ?? Chain.solana));
  }

  /// The session's default wallet on [chain] **that could actually fund a
  /// send**, or null.
  ///
  /// `SessionManager.sessionWalletForChain` gates on the broader
  /// [WalletInfo.canSign], while every source-resolution path here gates on
  /// [WalletInfo.canSignSendTransfer] (the aggregator filters candidates with
  /// it, and the no-fundable-balance fallback in [_resolveSources] re-checks
  /// it). Seeding the self-send guard from the looser predicate pointed it at a
  /// wallet — a Tezos Ledger, say — that `_resolveSources` will never adopt, so
  /// the guard compared recipients against an address that can't fund the send.
  /// One predicate, both gates.
  WalletInfo? _sessionSendWallet(Chain chain) {
    final wallet = sl<SessionManager>().sessionWalletForChain(chain);
    return wallet != null && wallet.canSignSendTransfer ? wallet : null;
  }

  /// Whether the wallet a Solana send would silently fall back to — the global
  /// selection, which its executor signs with — is itself on [chain].
  ///
  /// [_loadSelfAddress] seeds `_selfAddress` from `WalletManager.getAddress()`
  /// for Solana, and that reads the selected wallet row **whatever chain it is
  /// on**: a session whose only imported key is a Tezos wallet answers with a
  /// `tz1…` address. Read from the address rather than the session, because
  /// this is precisely the case where the selection is not a wallet the send's
  /// own chain resolution would ever return.
  bool _activeSignerIsOnChain(Chain chain) {
    final self = _selfAddress;
    if (self == null || self.isEmpty) return false;
    return Chain.fromAddress(self) == chain;
  }

  /// Seeds [_selfAddress] with the wallet this send would default to on
  /// [chain], then drops it from recents so the user can't pick their own
  /// wallet as a recipient.
  ///
  /// Chain-aware, because the two chains resolve their default signer
  /// differently: Solana's is the globally selected wallet
  /// ([WalletInfo.bindsGlobalSigner]), while Tezos/Ethereum sign by explicit id
  /// and so default to the session's own wallet on that chain.
  /// `WalletManager.getAddress()` answers only the former — using it for a
  /// Tezos send seeded a *Solana* address, against which the self-send guard
  /// could never match.
  ///
  /// The comparison goes through [apiOwnerAddress], never a raw `==`: an EVM
  /// address exists in two forms — EIP-55 checksummed (how `derivation.dart`
  /// derives and how a wallet stores it) and lowercased (how the backend
  /// stores/returns it, and what a user pastes from an explorer). A
  /// case-sensitive compare between the two forms of the *same* address
  /// returns false, which silently leaves the user's own wallet in the recents
  /// list. Solana/Tezos are base58 and case-sensitive, so they pass through
  /// [apiOwnerAddress] untouched.
  Future<void> _loadSelfAddress(Chain chain) async {
    try {
      final self = chain == Chain.solana
          ? await sl<WalletManager>().getAddress()
          : _sessionSendWallet(chain)?.address;
      if (!mounted || self == null || self.isEmpty) return;
      // A source chosen while this was in flight is the authoritative answer —
      // overwriting it with the chain's *default* wallet would make the
      // self-send guard test a wallet that isn't funding the send (and, with
      // two wallets on one chain, wrongly block the other one).
      if (_sourceWallet != null) return;
      final selfKey = apiOwnerAddress(self);
      setState(() {
        _selfAddress = self;
        _selfAddressChain = chain;
        _recents = [
          for (final r in _recents)
            if (apiOwnerAddress(r.address) != selfKey) r,
        ];
      });
    } catch (_) {
      // Best-effort — leave recents as-is if the sender can't be resolved.
    }
  }

  /// True when [address] is the wallet this send would be signed *from*.
  /// Normalised, never a raw `==` — see [_loadSelfAddress].
  bool _isSelfAddress(String address) {
    final self = _selfAddress;
    if (self == null || address.isEmpty) return false;
    return apiOwnerAddress(address) == apiOwnerAddress(self);
  }

  /// Ensures [_selfAddress] holds a wallet on [chain].
  ///
  /// Keyed on the chain, not on null: `initState` seeds the sheet before any
  /// token is chosen, when [_chain] still reports Solana. A null check would
  /// then short-circuit here and leave the Solana address in place for the
  /// whole of a Tezos/Ethereum send — the entry point this exists to serve.
  Future<void> _ensureSelfAddress(Chain chain) async {
    if (_selfAddress != null && _selfAddressChain == chain) return;
    await _loadSelfAddress(chain);
  }

  // ── Source-wallet selection ────────────────────────────────────────────

  /// Entry from the token page: the token is already known, so resolve the
  /// candidate wallets and — when 2+ qualify — present the picker before the
  /// recipient step. Cancelling here closes the whole flow.
  Future<void> _initSourcesFromInitialToken(TokenBalance token) async {
    await _ensureSelfAddress(token.chain);
    await _resolveSources(token);
    unawaited(_refreshSources(token));
    if (!mounted || _sources.length < 2) return;
    final chosen = await _promptWalletSelect(token);
    if (!mounted) return;
    if (chosen == null) {
      Navigator.of(context).pop(); // first-step cancel → close the send flow
      return;
    }
    await _setSource(chosen, alreadyCommitted: true);
  }

  /// Resolve the candidate source wallets for [token] from the per-wallet
  /// balance cache (fast, no spinner — spec); pass [refresh] to fan out to
  /// the network and refine. Drops dust/view-only/wrong-chain wallets, then
  /// adopts the default source — keeping `_sourceWallet` equal to the active
  /// signer, switching it when the only sendable wallet isn't the active one.
  Future<void> _resolveSources(
    TokenBalance token, {
    bool refresh = false,
  }) async {
    final candidates = await sl<SessionPortfolioAggregator>()
        .sendSourcesForMint(
          chain: token.chain,
          mint: token.mint,
          refresh: refresh,
        );
    if (!mounted || _selectedToken?.mint != token.mint) return;
    final qualifying = [
      for (final c in candidates)
        if (c.qualifies(isNative: token.isNative)) c,
    ];
    setState(() => _sources = qualifying);

    final next = _resolveActiveSource(qualifying);
    if (kDebugMode) {
      debugPrint(
        '[SendSheet] _resolveSources chain=${token.chain.toDbString()} '
        'mint=${token.mint} isNative=${token.isNative} refresh=$refresh '
        'candidates=${candidates.length} qualifying=${qualifying.length} '
        'next=${next?.address} selfAddress=$_selfAddress',
      );
    }
    if (next == null) {
      // No wallet holds a *fundable* balance of this token. For a non-Solana
      // chain that is NOT "no wallet": the sign/inject path needs the chain
      // wallet's id (there is no executor-signer fallback like Solana's), so
      // resolve the session's active wallet FOR THIS CHAIN and sign with it
      // even when its balance can't fund the send — a zero/short balance is an
      // insufficient-funds error at the amount/confirm step, not a "no wallet"
      // error here. Prefer a candidate (carries the fetched balance); else the
      // session/account sibling (e.g. a Profile whose linked set is Solana-only
      // but whose account holds the Tezos wallet). Solana keeps the spec
      // behavior below (silent fall back to the active signer, no line) — but
      // only while that signer is actually a Solana wallet. When the global
      // selection sits on another chain, would hand Solana's executor a
      // Tezos/Ethereum wallet to sign a Solana transaction with, so Solana
      // joins the adopt-a-chain-wallet path here instead.
      if (token.chain != Chain.solana || !_activeSignerIsOnChain(token.chain)) {
        // Only adopt a wallet that can actually sign a transfer on this chain —
        // both arms go through the `canSignSendTransfer` gate, so an ETH
        // Ledger/social sibling can't land here; adopting one would proceed to
        // the biometric gate and then dead-end at broadcast. Fall through to the
        // no-walletId path instead, which blocks truthfully at Next.
        final chainWallet =
            candidates.firstOrNull?.wallet ?? _sessionSendWallet(token.chain);
        if (chainWallet != null) {
          if (kDebugMode) {
            debugPrint(
              '[SendSheet] no fundable balance; adopting session '
              '${token.chain.toDbString()} wallet ${chainWallet.address} '
              '(id=${chainWallet.id})',
            );
          }
          await _setSource(
            chainWallet,
            interactive: false, // auto-adopt — the user only picked a token
          );
          return;
        }
      }
      // Solana, or a chain the session truly has no signable wallet on: fall
      // back to the active signer with no line so recipient
      // validation still uses the token's chain; a non-Solana send then blocks
      // at Next ("No {Chain} wallet available"), the truthful outcome.
      //
      // Only Solana passes an address, and only when the active signer is a
      // Solana wallet: this is the one branch [_setSource] never runs on, so
      // [_selfAddress] can still hold whatever chain the global selection is on
      // — the Solana seed on a Tezos send, a tz1 address on a Solana one.
      // Handing that to the bloc sets a wrong-chain source the self-send guard
      // would then compare recipients against. Empty is the honest answer.
      if (!mounted) return;
      final activeIsSolanaSigner =
          token.chain == Chain.solana && _activeSignerIsOnChain(Chain.solana);
      context.read<SendBloc>().add(
        SendEvent.setSource(
          chain: token.chain,
          address: activeIsSolanaSigner ? (_selfAddress ?? '') : '',
        ),
      );
      setState(() => _sourceWallet = null);
      // Keep the confirm-time guard pointed at the wallet that will sign.
      // Clearing the token list here instead skipped that guard entirely — and
      // this branch is reached precisely when no wallet holds a *fundable*
      // balance ([SendSourceCandidate.qualifies]), i.e. for the very user it
      // exists to stop, who then cleared biometrics only to fail on-chain.
      // Solana's fallback signer is the active one; the other chains have no
      // signer at all here (the flow blocks at Next), so they pass null and the
      // guards stay in their "balance unknown, allow through" state.
      final fallback = activeIsSolanaSigner ? _selfAddress : null;
      await _loadSourceTokens(fallback, token.chain);
      unawaited(_loadSourceTokens(fallback, token.chain, refresh: true));
      return;
    }
    await _setSource(next);
  }

  /// Refine the candidate set from the network, then — only if the up-front
  /// prompt never showed (cold cache) and the user is still on the first
  /// interactive step — surface the picker now that data has arrived.
  Future<void> _refreshSources(TokenBalance token) async {
    await _resolveSources(token, refresh: true);
    if (!mounted) return;
    if (!_sourcePromptShown &&
        _sources.length >= 2 &&
        _step == _SendStep.recipient &&
        _selectedToken?.mint == token.mint) {
      final chosen = await _promptWalletSelect(token);
      if (!mounted || chosen == null) return;
      await _setSource(chosen, alreadyCommitted: true);
    }
  }

  /// The source to mark active in the picker / show in the line: a prior
  /// explicit choice if it still qualifies, else the chain's default signing
  /// wallet ([_loadSelfAddress]), else the first candidate.
  WalletInfo? _resolveActiveSource(List<SendSourceCandidate> sources) {
    final current = _sourceWallet;
    if (current != null) {
      final keep = sources.firstWhereOrNull((c) => c.wallet.id == current.id);
      if (keep != null) return keep.wallet;
    }
    final active = _selfAddress;
    return sources
            .firstWhereOrNull((c) => c.wallet.address == active)
            ?.wallet ??
        sources.firstOrNull?.wallet;
  }

  /// Load the full token list (native coin + the sent token) of the wallet that
  /// will fund the send — [address] on [chain] — for the confirm-time balance
  /// guards. Reads the cache by default; [refresh] fans out to the network.
  ///
  /// Routed per chain. [TokenRepository] is Helius/Solana-only: refreshing an
  /// Ethereum or Tezos address through it answers with an empty list, which
  /// both disarms the ETH/XTZ guards and overwrites the rows the tokens tab
  /// cached for that address. Its *cache* read is likewise not enough on its
  /// own — a session that never opened the tokens tab for this chain (Ethereum
  /// switched off in Active Networks, or a cold start straight into Send) has
  /// no rows at all, and the guard would silently do nothing.
  Future<void> _loadSourceTokens(
    String? address,
    Chain chain, {
    bool refresh = false,
  }) async {
    if (_fundingAddress != address && mounted) {
      // A different wallet is funding the send now: its balances are unknown
      // until a load answers for *it*, and the previous wallet's rows must
      // never be checked against it.
      setState(() {
        _fundingAddress = address;
        _sourceTokens = const [];
        _fundingBalancesKnown = false;
      });
    }
    if (address == null || address.isEmpty) return;
    List<TokenBalance> tokens;
    try {
      tokens = switch (chain) {
        Chain.ethereum =>
          refresh
              ? await sl<EthereumTokenService>().getTokenBalances(address)
              : await sl<EthereumTokenService>().getCachedBalances(address),
        Chain.tezos =>
          refresh
              ? await sl<TezosTokenService>().getTokenBalances(address)
              : await sl<TezosTokenService>().getCachedBalances(address),
        Chain.solana =>
          refresh
              ? await sl<TokenRepository>().getTokenBalances(address)
              : await sl<TokenRepository>().getCachedBalances(address),
      };
    } catch (_) {
      // Keep whatever we had. A failed read is an *unknown* balance, never a
      // zero one — the guards must not block a funded wallet because the
      // balance service was down.
      return;
    }
    if (!mounted || _fundingAddress != address) return;
    // An empty *cache* read means "not loaded yet", so it must not overwrite (or
    // downgrade) what a network pass already established for this wallet — the
    // two passes race, and the cache one is not refilled by the network one.
    if (tokens.isEmpty && !refresh && _fundingBalancesKnown) return;
    setState(() {
      _sourceTokens = tokens;
      _fundingBalancesKnown = refresh || tokens.isNotEmpty;
    });
  }

  Future<WalletInfo?> _promptWalletSelect(TokenBalance token) {
    _sourcePromptShown = true;
    return showSendWalletSelectSheet(
      context,
      chain: token.chain,
      tokenSymbol: token.symbol,
      candidates: _sources,
      activeWalletId: _sourceWallet?.id,
    );
  }

  /// "Switch" tapped on a step's source line — re-open the picker, returning to
  /// the same step unchanged on cancel.
  Future<void> _onSwitchSource() async {
    final token = _selectedToken;
    if (token == null) return;
    final chosen = await _promptWalletSelect(token);
    if (!mounted || chosen == null) return;
    await _setSource(chosen, alreadyCommitted: true);
  }

  /// Make [wallet] the in-flow source.
  ///
  /// 🛑 Only a **Solana** source commits a real signer switch
  /// ([SessionManager.selectSourceWallet]), and only when the picker hasn't
  /// already done it ([alreadyCommitted]). Solana's executor signs with the
  /// globally selected wallet, so the selection has to move for the signature
  /// to come from the chosen source ([WalletInfo.bindsGlobalSigner]).
  ///
  /// Tezos and Ethereum sign by explicit wallet id — the id this method hands
  /// to [SendBloc] via `SendEvent.setSource` is the whole mechanism — so they
  /// keep the source **flow-local**. Switching for them re-pointed the backend
  /// login identity (and every `owner == req.loginAddress` write with it) for
  /// no signing benefit, cost a `/v0/login` round trip mid-flow, and was never
  /// restored. It also never delivered what it appeared to: `getAddress(chain:)`
  /// resolves through the *account*, so with two wallets on one chain the
  /// switch still left it pointing at the first.
  ///
  /// Reflects the new wallet in the self-send guard, the amount-step balance,
  /// and the confirm-time check. Recipient + amount are preserved; a switch on
  /// the confirm step drops back to amount so the fee/simulation re-validate
  /// against the new wallet.
  Future<void> _setSource(
    WalletInfo wallet, {
    bool alreadyCommitted = false,
    bool interactive = true,
  }) async {
    if (wallet.bindsGlobalSigner &&
        !alreadyCommitted &&
        wallet.address != _selfAddress) {
      // The switch now awaits a `/v0/login` round trip, so it is seconds-long,
      // not a local DB write. Surface it: the auto-adopt path fires with no
      // user action at all and would otherwise read as a frozen sheet.
      if (mounted) setState(() => _switchingSource = true);
      try {
        await sl<SessionManager>().selectSourceWallet(wallet);
      } catch (_) {
        if (mounted) {
          setState(() => _switchingSource = false);
          // Only for a switch the user actually asked for. The auto-adopt path
          // is triggered by token selection, so a failure snackbar there blames
          // the user for a tap they never made; the flow keeps the previous
          // source and blocks truthfully at Next instead.
          if (interactive) {
            AppSnackBar.show(
              context,
              "Couldn't switch wallet. Please try again.",
            );
          }
        }
        return; // keep the previous source; fail loud, don't sign with it
      }
      if (mounted) setState(() => _switchingSource = false);
    }
    if (!mounted) return;
    // Tell the bloc which chain/wallet is funding the send so recipient
    // validation, fee math, and the sign/inject path branch correctly. The
    // walletId is the Tezos/Ethereum signing key — for those chains this event
    // is the *only* thing that points the send at the chosen wallet, since
    // nothing global moved. Solana ignores it (executor signer).
    context.read<SendBloc>().add(
      SendEvent.setSource(
        chain: wallet.chainEnum,
        address: wallet.address,
        walletId: wallet.id,
      ),
    );
    // Suggestions are filtered to the chain they were fetched for, so a source
    // switch can strand rows whose address the new chain would reject.
    _recipientSearch.close();
    final candidate = _sources.firstWhereOrNull(
      (c) => c.wallet.id == wallet.id,
    );
    final token = _selectedToken;
    setState(() {
      _sourceWallet = wallet;
      _selfAddress = wallet.address;
      _selfAddressChain = wallet.chainEnum;
      if (candidate != null && token != null) {
        _selectedToken = token.copyWith(
          rawBalance: candidate.rawBalance,
          uiBalance: candidate.uiBalance,
        );
      }
      // Same normalisation as [_loadSelfAddress] — a raw `==` here would let
      // the newly-chosen EVM source wallet stay in recents whenever the two
      // sides disagree on EIP-55 casing.
      _recents = [
        for (final r in _recents)
          if (apiOwnerAddress(r.address) != apiOwnerAddress(wallet.address)) r,
      ];
    });
    // Warm cache for the new wallet, then refine from the network.
    await _loadSourceTokens(wallet.address, wallet.chainEnum);
    unawaited(
      _loadSourceTokens(wallet.address, wallet.chainEnum, refresh: true),
    );
    if (!mounted) return;
    if (_step == _SendStep.confirm) {
      context.read<SendBloc>().add(const SendEvent.reset());
      setState(() => _step = _SendStep.amount);
    }
  }

  /// The chain the current send is on — resolved from the chosen source wallet,
  /// falling back to the selected token's chain (before a source is resolved),
  /// then Solana. Drives recipient validation, fee copy, and the confirm step.
  Chain get _chain =>
      _sourceWallet?.chainEnum ?? _selectedToken?.chain ?? Chain.solana;

  /// Recents scoped to the current send's chain — a saved tz1…/0x…/base58
  /// address is only offered when its inferred chain matches, so a Tezos send
  /// never lists Solana recipients (and vice-versa) that would fail validation.
  List<RecentRecipient> get _recentsForChain => [
    for (final r in _recents)
      if (Chain.fromAddress(r.address) == _chain) r,
  ];

  /// Address shown in a step's "Your wallet" line, or null to hide it (no
  /// qualifying source — fall back to the active signer silently, spec).
  String? get _sourceLineAddress => _sourceWallet?.address;

  /// Switch handler for the line — null when fewer than 2 wallets qualify, so
  /// the line renders without a Switch action.
  VoidCallback? get _sourceSwitchHandler =>
      _sources.length >= 2 ? _onSwitchSource : null;

  /// A balance state scoped to the wallet funding the send, so the confirm-time
  /// check reflects that wallet and not the session aggregate the portfolio
  /// entry point shares in.
  ///
  /// Null **only** when the answer is genuinely unknown (no funding wallet
  /// resolved, or its balances haven't been read yet) — callers allow through
  /// there, per [checkBalance]'s "don't false-disable on entry" rule. A wallet
  /// that is *known* to hold nothing returns a loaded state with no rows, which
  /// is what makes the check fire instead of silently passing.
  TokenBalanceState? _sourceBalanceState() {
    final address = _fundingAddress;
    if (address == null || !_fundingBalancesKnown) return null;
    return TokenBalanceState.loaded(
      tokens: _sourceTokens,
      totalUsdValue: 0,
      address: address,
    );
  }

  @override
  void dispose() {
    _resolveDebounce?.cancel();
    _recipientSearch.dispose();
    _addressController.dispose();
    _amountController.dispose();
    _addressFocusNode.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  // ── Recent recipients ──────────────────────────────────────────────────

  /// Enrich recents whose address belongs to one of the user's local accounts
  /// with that account's name + avatar, so an address you own reads as
  /// "Account NN" (with its identicon) rather than a bare hash. Runs alongside
  /// the profile lookup; the account name takes precedence over a profile.
  Future<void> _resolveRecentAccounts() async {
    final addresses = [for (final r in _recents) r.address];
    if (addresses.isEmpty) return;
    try {
      final accounts = await sl<WalletRepository>().accountsForAddresses(
        addresses,
      );
      if (!mounted || accounts.isEmpty) return;
      setState(() {
        // Also seeds [_accounts], so tapping a recent reaches the confirm step
        // with its account identity already resolved instead of re-reading the
        // same rows.
        for (final entry in accounts.entries) {
          _accounts[apiOwnerAddress(entry.key)] = entry.value;
        }
        _recents = [
          for (final r in _recents)
            r.copyWith(
              accountName: accounts[r.address]?.name,
              accountAvatarSeed: accounts[r.address]?.avatarSeed,
            ),
        ];
      });
    } catch (_) {
      // Recents fall back to profile/truncated address; nothing actionable.
    }
  }

  /// Resolves the local account behind [address], so the confirm step can name
  /// a recipient the user owns. Absent from the result means "not one of ours",
  /// which is the common case and renders the profile/truncation as before.
  Future<void> _resolveRecipientAccount(String address) async {
    try {
      final accounts = await sl<WalletRepository>().accountsForAddresses([
        address,
      ]);
      if (!mounted) return;
      setState(() {
        _accounts[apiOwnerAddress(address)] = accounts[address];
      });
    } catch (_) {
      // Confirm step falls back to the profile or the truncated address.
    }
  }

  Future<void> _resolveRecentProfiles() async {
    final addresses = [for (final r in _recents) r.address];
    if (addresses.isEmpty) return;
    for (final address in addresses) {
      _profiles[apiOwnerAddress(address)] = null;
    }
    try {
      final profiles = await sl<ProfileLookupService>().profilesForAddresses(
        addresses,
      );
      if (!mounted || profiles.isEmpty) return;
      setState(() {
        _profiles.addAll(profiles);
        _recents = [
          for (final r in _recents)
            r.copyWith(
              username: profiles[apiOwnerAddress(r.address)]?.username,
              imageUrl: profiles[apiOwnerAddress(r.address)]?.imageUrl,
            ),
        ];
      });
    } catch (_) {
      // Recents render with truncated addresses; nothing actionable.
    }
  }

  Future<void> _resolveRecipientProfile(String address) async {
    try {
      final profiles = await sl<ProfileLookupService>().profilesForAddresses([
        address,
      ]);
      if (!mounted || profiles.isEmpty) return;
      setState(() => _profiles.addAll(profiles));
    } catch (_) {
      // Confirm step falls back to the truncated address.
    }
  }

  /// Classifies [address] on [chain] and shows the result as a non-blocking
  /// notice. The service already fails soft, so a null result means either
  /// "ordinary wallet" or "couldn't tell" — both render nothing, because a
  /// transport failure must never read as "this recipient is dangerous".
  Future<void> _resolveRecipientAdvisory(String address, Chain chain) async {
    final advisory = await sl<RecipientAdvisoryService>().detect(
      chain: chain,
      address: address,
    );
    if (!mounted || advisory == null) return;
    setState(() => _advisories[address] = advisory);
  }

  // ── Recipient input ────────────────────────────────────────────────────

  void _onAddressChanged(String value) {
    _resolveDebounce?.cancel();
    final trimmed = value.trim();

    setState(() {
      _addressError = null;
      _resolvedAddress = null;
      _isResolving = false;
      _pickedProfile = false;
    });

    if (trimmed.isEmpty) {
      _recipientSearch.close();
      return;
    }

    // A username search and address validation are mutually exclusive readings
    // of the same text. Running both would print "Invalid Solana address" under
    // an open dropdown of matching users, because `alice` is not an address.
    // The dropdown's own empty state carries the no-match case instead.
    _recipientSearch.onInput(trimmed, _chain);
    if (_recipientSearch.isOpen) return;

    // Tezos recipients are Base58Check tz1/2/3/KT1 — no SNS domain resolution.
    if (_chain == Chain.tezos) {
      if (!isValidTezosAddress(trimmed)) {
        setState(() => _addressError = 'Invalid Tezos address');
        return;
      }
      context.read<SendBloc>().add(SendEvent.setRecipient(trimmed));
      return;
    }

    // Ethereum recipients are `0x` + 40 hex, or a `.eth` ENS domain resolved
    // via ENS (debounced) — mirroring the `.sol` SNS path below.
    if (_chain == Chain.ethereum) {
      if (EnsResolver.isEthDomain(trimmed)) {
        _resolveDomain(trimmed, EnsResolver.resolve);
        return;
      }
      // EIP-55 aware: a mixed-case address whose checksum doesn't match is a
      // mistyped address, and nothing downstream can catch it (the calldata
      // assertion compares against this same string). Rejected here, at the
      // form gate, so it can never reach the biometric prompt.
      final ethError = evmRecipientError(trimmed);
      if (ethError != null) {
        setState(() => _addressError = ethError);
        return;
      }
      context.read<SendBloc>().add(SendEvent.setRecipient(trimmed));
      return;
    }

    if (SnsResolver.isSolDomain(trimmed)) {
      _resolveDomain(trimmed, SnsResolver.resolve);
      return;
    }

    if (!SecurityUtils.isValidSolanaAddress(trimmed)) {
      setState(() => _addressError = 'Invalid Solana address');
      return;
    }

    context.read<SendBloc>().add(SendEvent.setRecipient(trimmed));
  }

  /// Debounced domain resolution shared by the SNS (`.sol`) and ENS (`.eth`)
  /// paths: shows the Resolving state, resolves via [resolve] 500 ms after the
  /// last keystroke, and on success stores the resolved address and hands it to
  /// [SendBloc]. The controller-text guards drop a resolution whose input has
  /// since changed.
  void _resolveDomain(String domain, Future<String?> Function(String) resolve) {
    setState(() => _isResolving = true);
    _resolveDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (_addressController.text.trim() != domain) return;
      final resolved = await resolve(domain);
      if (!mounted || _addressController.text.trim() != domain) return;

      setState(() {
        _isResolving = false;
        if (resolved != null) {
          _resolvedAddress = resolved;
          _addressError = null;
        } else {
          _addressError = 'Could not resolve domain';
        }
      });
      if (resolved != null) {
        context.read<SendBloc>().add(SendEvent.setRecipient(resolved));
      }
    });
  }

  Future<void> _pasteAddress() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || !mounted) return;
    _addressController.text = text;
    _onAddressChanged(text);
  }

  Future<void> _openScanner() async {
    final scanned = await Navigator.of(context, rootNavigator: true)
        .push<String>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (routeContext) => SendQrScannerView(
              onDetect: (capture) => _onScanDetect(routeContext, capture),
              onClose: () => Navigator.of(routeContext).pop(),
            ),
          ),
        );
    if (scanned == null || !mounted) return;
    _addressController.text = scanned;
    _onAddressChanged(scanned);
  }

  void _onScanDetect(BuildContext routeContext, BarcodeCapture capture) {
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null) return;
    final trimmed = code.trim();
    final bool isValid;
    if (_chain == Chain.tezos) {
      isValid = isValidTezosAddress(trimmed);
    } else if (_chain == Chain.ethereum) {
      // Shape-level on purpose: a scanned address that fails its EIP-55
      // checksum should pop the scanner and surface the error in the field
      // (via [_onAddressChanged]) rather than have the scanner ignore it
      // silently, which reads as "the camera didn't see the code".
      isValid = isEthereumAddress(trimmed) || EnsResolver.isEthDomain(trimmed);
    } else {
      isValid =
          SecurityUtils.isValidSolanaAddress(trimmed) ||
          SnsResolver.isSolDomain(trimmed);
    }
    if (!isValid) return;
    // Detection fires repeatedly — only the first hit may pop the scanner.
    final route = ModalRoute.of(routeContext);
    if (route == null || !route.isCurrent) return;
    Navigator.of(routeContext).pop(trimmed);
  }

  /// Tapping a username-search row fills the field with the handle and commits
  /// the profile's address for that chain.
  ///
  /// Unlike a recent-recipient tap this does **not** advance: the user searched
  /// by name, so leaving them on the step with the resolved address visible
  /// underneath is what lets them confirm they picked the right wallet — which
  /// matters most when one profile produced several rows.
  void _onSuggestionPicked(RecipientSuggestion suggestion) {
    // Assigning `.text` does not fire `onChanged`, so the search gate is not
    // re-run and the dropdown stays closed.
    _addressController.text = suggestion.fieldText;
    setState(() {
      _pickedProfile = true;
      _resolvedAddress = suggestion.address;
      _addressError = null;
      _isResolving = false;
    });
    context.read<SendBloc>().add(SendEvent.setRecipient(suggestion.address));
  }

  /// Drops the recipient that was chosen for the *previous* chain.
  ///
  /// [_pickedProfile] + [_resolvedAddress] are what [_onRecipientNext] trusts
  /// **instead of** re-parsing the field, and both are chain-specific: a
  /// profile picked while sending an SPL token carries a Solana address, and
  /// the field then holds `@handle`, which no address validator would reject
  /// or accept. Left in place across a token re-selection they still satisfied
  /// the Next gate, so an Ethereum/Tezos send advanced on a Solana recipient
  /// — nothing downstream re-validates it, and the flow only failed at
  /// prepare/simulate, after the confirm step.
  ///
  /// Called at the moment the token changes rather than at the end of
  /// [_onTokenSelected], so the invariant holds even when source resolution
  /// bails out early (a cancelled wallet picker leaves the user on the token
  /// step with the new token already selected).
  void _dropRecipientForChainChange() {
    _resolveDebounce?.cancel();
    // Suggestions are fetched per chain, so any open rows are wrong-chain too.
    _recipientSearch.close();
    setState(() {
      _pickedProfile = false;
      _resolvedAddress = null;
      _addressError = null;
      _isResolving = false;
    });
  }

  // Tapping a recent recipient fills the field and advances immediately.
  void _onRecentTap(RecentRecipient recent) {
    _addressController.text = recent.address;
    _onAddressChanged(recent.address);
    _onRecipientNext();
  }

  void _onRecipientNext() {
    _recipientSearch.close();
    final trimmed = _addressController.text.trim();
    if (trimmed.isEmpty || _isResolving) {
      _addressFocusNode.requestFocus();
      return;
    }
    // A picked profile already carries a chain-validated address; the field
    // holds its handle, which no address validator would accept.
    final hasValidRecipient = _pickedProfile
        ? _resolvedAddress != null
        : _chain == Chain.tezos
        ? isValidTezosAddress(trimmed)
        : _chain == Chain.ethereum
        ? (EnsResolver.isEthDomain(trimmed)
              ? _resolvedAddress != null
              // Same EIP-55 gate as [_onAddressChanged] — otherwise "Next"
              // advanced past the checksum error the field is showing.
              : evmRecipientError(trimmed) == null)
        : SnsResolver.isSolDomain(trimmed)
        ? _resolvedAddress != null
        : SecurityUtils.isValidSolanaAddress(trimmed);
    if (!hasValidRecipient) {
      _onAddressChanged(trimmed);
      _addressFocusNode.requestFocus();
      return;
    }
    final recipient = _resolvedAddress ?? trimmed;
    if (_isSelfAddress(recipient)) {
      setState(() => _addressError = "You can't send to your own wallet");
      _addressFocusNode.requestFocus();
      return;
    }
    setState(() => _step = _SendStep.amount);
  }

  // ── Amount input ───────────────────────────────────────────────────────

  void _onAmountChanged(String value) {
    context.read<SendBloc>().add(SendEvent.setAmount(value));
  }

  void _onHalf() {
    final token = _selectedToken;
    if (token == null) return;
    final text = stripTrailingZeros(
      (token.uiBalance / 2).toStringAsFixed(math.min(token.decimals, 9)),
    );
    _amountController.text = text;
    context.read<SendBloc>().add(SendEvent.setAmount(text));
  }

  void _onMax() {
    // The bloc computes Max from the live on-chain balance (keeping fee
    // headroom for SOL) and emits the amount; the listener below syncs the
    // text controller.
    context.read<SendBloc>().add(const SendEvent.setMaxAmount());
  }

  void _onAmountNext() {
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) {
      _amountFocusNode.requestFocus();
      return;
    }
    context.read<SendBloc>().add(const SendEvent.validateAndProceed());
  }

  // ── Confirm / execute ──────────────────────────────────────────────────

  Future<void> _onSend() async {
    final ready = _ready;
    if (ready == null) return;

    // Re-check the kill switch before the confirm control: the config
    // can land *after* the token was picked, and the `initialToken` entry skips
    // the picker's row gate entirely, so this is the only gate that path sees
    // before the signing backstop. `token == null` is the bloc's own
    // native-vs-token discriminator — same cell the execute path will pass.
    final cell = sendFlowKey(_chain, isNative: ready.token == null);
    if (await guardFlowDisabled(context, cell)) return;
    if (!mounted) return;

    if (_chain == Chain.tezos) {
      // Native XTZ collapses to a null token (like native SOL). XTZ pays its own
      // fee in mutez; the Solana gas-reserve model in [checkBalance] (SOL kept
      // back for fees) doesn't apply. Check the XTZ balance covers amount + fee.
      if (!_ensureSufficientTezos(ready)) return;
    } else if (_chain == Chain.ethereum) {
      // ETH/ERC-20 pay gas in ETH. Amounts are 18-decimal wei that overflow
      // int, so the guard compares in whole-token doubles, not raw units.
      if (!_ensureSufficientEth(ready)) return;
    } else {
      final paymentMint = ready.token?.mint ?? TokenBalance.solMint;
      final decimals = ready.token?.decimals ?? 9;
      final raw = TokenAmount.toInt(
        TokenAmount.parseTokenAmount(ready.amountString, decimals),
      );
      final sourceBalances = _sourceBalanceState();
      // No fallback to the shared bloc: from the tokens-tab entry point that is
      // the session *aggregate* instance, which sums every session wallet's
      // holding of the mint. Checking a single wallet's spend against the
      // summed balance passes a send the chain then rejects — after the user
      // has already cleared the biometric gate. Null here is only a balance
      // that is genuinely not loaded yet ([_sourceBalanceState]), which falls
      // through to the same "don't false-disable on entry" rule [checkBalance]
      // uses; a wallet known to hold nothing still gets checked, and stopped.
      if (sourceBalances != null) {
        // A native-SOL send is checked against what it really costs, not the
        // flat [kSolGasReserveLamports] cushion. Two cases:
        //
        //  * A Max was priced off a live balance read as `balance − exact fee`,
        //    so the fee is already inside the amount and it deliberately leaves
        //    the account at zero. Any reserve on top would refuse the one
        //    amount the Max button just offered.
        //  * Every other native send must clear the fee *and* leave the account
        //    rent-exempt — the runtime rejects a residue between one lamport
        //    and [kSolRentExemptMinimumLamports] outright.
        //
        // Token sends keep the cushion: theirs may also fund a destination
        // ATA's rent.
        final isNativeSol = ready.token == null;
        final isMaxSend =
            isNativeSol &&
            context.read<SendBloc>().isSolMaxAmount(
              ready.amountString,
              ready.recipient,
            );
        final balanceResult = checkBalance(
          paymentMint: paymentMint,
          requiredRawAmount: raw,
          balanceState: sourceBalances,
          includeGasReserve: !isNativeSol,
          additionalSolLamports: !isNativeSol || isMaxSend
              ? 0
              : worstCaseSolTxFeeLamports + kSolRentExemptMinimumLamports,
        );
        if (!ensureSufficientBalance(context, balanceResult)) return;
      }
    }

    // Morph to the in-flight pipeline step in place and kick off the send.
    // Signing/broadcasting/success/error all render in the pipeline step; its
    // Done action closes the flow and its Back morphs to the amount step.
    setState(() => _inPipeline = true);
    context.read<SendBloc>().add(const SendEvent.execute());
  }

  /// Confirm-time balance guard for Tezos. Native XTZ needs `amount + fee` in
  /// mutez from one balance; an FA1.2/FA2 send needs the token balance to cover
  /// the amount **and** XTZ to cover the fee, since the fee is never paid in the
  /// token. Returns `true` (allow) when the source balances aren't known yet,
  /// mirroring [checkBalance]'s "don't false-disable on entry" rule; shows a
  /// snackbar and returns `false` on a genuine shortfall.
  bool _ensureSufficientTezos(SendReady ready) {
    // Not loaded yet — don't block. A *loaded* wallet with no XTZ row holds no
    // XTZ, which is a shortfall like any other and must not read as "unknown".
    if (!_fundingBalancesKnown) return true;
    final xtzBalance =
        _sourceTokens
            .firstWhereOrNull((t) => t.mint == TokenBalance.tezosNativeSentinel)
            ?.rawBalance ??
        0;
    // Fee + storage burn, matching what the confirm step quotes — a fresh
    // destination's 0.06425 XTZ allocation dwarfs the baker fee, so checking
    // `feeMutez` alone waves through a send the node then rejects.
    final feeMutez = ready.tezosEstimate?.totalCostMutez.toInt() ?? 0;
    final token = ready.token;

    if (token != null && !token.isNative) {
      final tokenRaw = TokenAmount.parseTokenAmount(
        ready.amountString,
        token.decimals,
      );
      final held =
          _sourceTokens.firstWhereOrNull((t) => t.mint == token.mint) ?? token;
      // A clamped raw balance is a floor, not the amount held (18-decimal
      // FA1.2s such as kUSD pass int64 above ~9.22 tokens), so comparing
      // against it would refuse a perfectly fundable send. That is the
      // "don't false-disable" rule: an unknown balance allows through, and the
      // review step's `run_operation` — which already simulated this exact
      // transfer against the contract's real ledger — is the backstop.
      if (!held.isRawBalanceClamped &&
          tokenRaw > BigInt.from(held.rawBalance)) {
        AppSnackBar.show(context, 'Insufficient ${token.symbol} balance.');
        return false;
      }
      if (xtzBalance < feeMutez) {
        AppSnackBar.show(context, 'Insufficient XTZ for the network fee.');
        return false;
      }
      return true;
    }

    final needed =
        TokenAmount.toInt(TokenAmount.parseTokenAmount(ready.amountString, 6)) +
        feeMutez;
    if (xtzBalance >= needed) return true;
    AppSnackBar.show(
      context,
      BalanceCheckResult.insufficient(
        symbol: 'XTZ',
        deficitRawAmount: needed - xtzBalance,
        deficitDecimals: 6,
      ).insufficientMessage,
    );
    return false;
  }

  /// Confirm-time balance guard for Ethereum. ETH/ERC-20 raw amounts are
  /// 18-decimal wei that overflow int, so this compares in whole-token doubles
  /// (uiBalance) rather than raw units. Best-effort — returns `true` (allow)
  /// when the source balances aren't loaded yet, mirroring [checkBalance]'s
  /// "don't false-disable on entry" rule; the node's `insufficient funds` is
  /// the real backstop. Shows a snackbar and returns `false` on a clear
  /// shortfall of either the sent token or the ETH needed for gas.
  bool _ensureSufficientEth(SendReady ready) {
    // The chosen source wallet's tokens only — never the shared bloc. From the
    // tokens-tab entry point that bloc is the session *aggregate*, so a sibling
    // wallet's ETH would be summed into this wallet's gas check and wave through
    // a send the node then rejects for insufficient funds, after the biometric
    // gate. Only a balance that hasn't been read yet allows through, per
    // [checkBalance]'s "don't false-disable on entry" rule; a wallet read from
    // `/evm/balances` and found empty holds no ETH, so it cannot pay gas and is
    // stopped here rather than at the node.
    final tokens = _sourceTokens;
    if (!_fundingBalancesKnown) return true; // balances unknown — don't block
    // The fee for the *selected* tier — the same number the confirm step
    // quotes and the same basis a native Max reserved against. See [_ethFeeEth].
    final feeEth = _ethFeeEth(ready);
    final ethBalance =
        tokens
            .firstWhereOrNull((t) => t.mint == TokenBalance.evmNativeSentinel)
            ?.uiBalance ??
        0;

    if (ready.token == null) {
      // Native ETH: balance must cover the amount + gas fee.
      if (ethBalance >= ready.amount + feeEth) return true;
      AppSnackBar.show(context, 'Insufficient ETH for the amount plus fee.');
      return false;
    }

    // ERC-20: the token balance must cover the amount AND ETH must cover gas.
    final tokenBalance =
        tokens
            .firstWhereOrNull((t) => t.mint == ready.token!.mint)
            ?.uiBalance ??
        ready.token!.uiBalance;
    if (ready.amount > tokenBalance) {
      AppSnackBar.show(context, 'Insufficient ${ready.token!.symbol} balance.');
      return false;
    }
    if (feeEth > ethBalance) {
      AppSnackBar.show(context, 'Insufficient ETH for the network fee.');
      return false;
    }
    return true;
  }

  void _onConfirmBack() {
    context.read<SendBloc>().add(const SendEvent.reset());
    setState(() => _step = _SendStep.amount);
  }

  /// Pipeline error → the bloc restored the typed values; morph back to the
  /// amount step so the user can retry.
  void _exitPipelineToInput() {
    setState(() {
      _inPipeline = false;
      _step = _SendStep.amount;
    });
  }

  // ── Bloc listener ──────────────────────────────────────────────────────

  void _onBlocState(BuildContext context, SendState state) {
    state.mapOrNull(
      input: (input) {
        // Sync the text controller when the bloc sets the amount (Max).
        if (input.amount.isNotEmpty && _amountController.text != input.amount) {
          _amountController.text = input.amount;
        }
      },
      ready: (ready) {
        _ready = ready;
        if (_step != _SendStep.confirm) {
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() => _step = _SendStep.confirm);
          context.read<SendBloc>().add(const SendEvent.simulate());
          if (!_profiles.containsKey(apiOwnerAddress(ready.recipient))) {
            _profiles[apiOwnerAddress(ready.recipient)] = null;
            unawaited(_resolveRecipientProfile(ready.recipient));
          }
          if (!_accounts.containsKey(apiOwnerAddress(ready.recipient))) {
            _accounts[apiOwnerAddress(ready.recipient)] = null;
            unawaited(_resolveRecipientAccount(ready.recipient));
          }
          if (!_advisories.containsKey(ready.recipient)) {
            _advisories[ready.recipient] = null;
            unawaited(_resolveRecipientAdvisory(ready.recipient, _chain));
          }
        }
      },
      success: (_) {
        // Record the recipient once on success; closing is user-driven via the
        // pipeline step's Done action.
        final recipient = _ready?.recipient;
        if (recipient != null) {
          final prefs = sl<PreferencesService>();
          unawaited(prefs.saveRecentSendAddress(recipient));
          unawaited(prefs.incrementSendCount(recipient));
        }
      },
      error: (error) {
        // A kill got past the token-select / review gates and was stopped by the
        // signing backstop. Present the operator's message — the pipeline
        // step's generic "Transaction failed" body drops it entirely — and hand
        // the sheet back to the form, open and idle with the typed values
        // intact. Never a Retry on a switched-off flow.
        final kill = context.read<SendBloc>().killFailure;
        if (kill != null &&
            handleFlowDisabled(
              context,
              kill,
              flow: sendFlowKey(_chain, isNative: _ready?.token == null),
            )) {
          context.read<SendBloc>().add(const SendEvent.reset());
          if (_inPipeline) {
            _exitPipelineToInput();
          } else if (_step == _SendStep.confirm) {
            setState(() => _step = _SendStep.amount);
          }
          return;
        }
        // Pre-execute failures (validation) surface here; post-execute errors
        // render inside the pipeline step instead.
        if (!_inPipeline) {
          AppSnackBar.show(context, error.message);
          context.read<SendBloc>().add(const SendEvent.reset());
          if (_step == _SendStep.confirm) {
            setState(() => _step = _SendStep.amount);
          }
        }
      },
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final bottomPad = sheetBottomInset(context);

    return BlocConsumer<SendBloc, SendState>(
      listener: _onBlocState,
      builder: (context, state) {
        // Outer morph: the input phase (token/recipient/amount/confirm steps)
        // cross-fades + resizes into the in-flight pipeline phase in place once
        // the user confirms — instead of presenting the pipeline as a separate
        // sheet over the top.
        final Widget child = _inPipeline
            ? SendPipelineView(
                key: const ValueKey('pipeline'),
                token: _ready?.token,
                chain: _chain,
                onResetToInput: _exitPipelineToInput,
              )
            : KeyedSubtree(
                key: const ValueKey('input'),
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.bgSurface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(MallowTheme.popupRadius),
                    ),
                  ),
                  padding: EdgeInsets.only(bottom: bottomPad),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SheetDragHandle(color: colors.divider),
                      Flexible(
                        child: Stack(
                          children: [
                            // Floor: every step renders at least as tall as a
                            // representative confirm step, so the sheet doesn't
                            // resize between steps. Ethereum confirm carries an
                            // extra Speed section, so probe that taller height
                            // when sending on Ethereum.
                            _sizingProbe(
                              SendConfirmStep.sizing(
                                showSpeed: _chain == Chain.ethereum,
                              ),
                            ),
                            // The confirm step as it will actually render.
                            // Content that grows past the floor (the "may fail"
                            // simulation warning, a multi-line error) has to
                            // grow the sheet, not scroll inside it — both
                            // probes are unpositioned, so the stack takes the
                            // taller of the two. The route's [maxSheetHeight]
                            // cap is where growth stops and the visible step
                            // starts scrolling.
                            if (_step == _SendStep.confirm)
                              _sizingProbe(
                                _buildConfirmStep(
                                  context,
                                  state,
                                  intrinsicHeight: true,
                                ),
                              ),
                            Positioned.fill(
                              child: AnimatedSwitcher(
                                duration: MallowTheme.sheetDuration,
                                child: KeyedSubtree(
                                  key: ValueKey(_step),
                                  child: _buildStep(context, state),
                                ),
                              ),
                            ),
                            if (_switchingSource)
                              Positioned.fill(
                                child: ColoredBox(
                                  color: colors.bgSurface.withValues(
                                    alpha: 0.7,
                                  ),
                                  child: Center(
                                    child: MallowLoader(
                                      size: 24,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
        return SheetStepSwitcher(child: child);
      },
    );
  }

  /// An invisible copy of [child] that contributes its height to the sizing
  /// stack without painting or taking taps. The non-scrollable viewport lets
  /// that height collapse gracefully when the keyboard shrinks the available
  /// space, instead of overflowing.
  ///
  /// Not [Visibility.maintain] — that also maintains interactivity, which
  /// would make the probe's Send/Switch buttons tappable through the step
  /// that's actually on screen.
  Widget _sizingProbe(Widget child) => Visibility(
    visible: false,
    maintainSize: true,
    maintainAnimation: true,
    maintainState: true,
    child: SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: child,
    ),
  );

  Widget _buildStep(BuildContext context, SendState state) {
    switch (_step) {
      case _SendStep.token:
        return SendTokenSelectStep(onSelected: _onTokenSelected);
      case _SendStep.recipient:
        return SendRecipientStep(
          controller: _addressController,
          focusNode: _addressFocusNode,
          chain: _chain,
          errorText: _addressError,
          isResolving: _isResolving,
          resolvedAddress: _resolvedAddress,
          recents: _recentsForChain,
          onChanged: _onAddressChanged,
          onPaste: _pasteAddress,
          onScan: _openScanner,
          onRecentTap: _onRecentTap,
          searchController: _recipientSearch,
          onSuggestionPicked: _onSuggestionPicked,
          onBack: () {
            // The dropdown lives in the root overlay, so it would otherwise
            // hang over the token step after this step is gone.
            _recipientSearch.close();
            setState(() => _step = _SendStep.token);
          },
          onCancel: () => Navigator.of(context).pop(),
          onNext: _onRecipientNext,
          sourceAddress: _sourceLineAddress,
          onSwitch: _sourceSwitchHandler,
        );
      case _SendStep.amount:
        return SendAmountStep(
          token: _selectedToken!,
          controller: _amountController,
          focusNode: _amountFocusNode,
          errorText: state.mapOrNull(input: (s) => s.amountError),
          fiatText: _amountFiatText(),
          isValidating: state.maybeMap(
            input: (s) => s.isValidating,
            orElse: () => false,
          ),
          onChanged: _onAmountChanged,
          onHalf: _onHalf,
          onMax: _onMax,
          onBack: () => setState(() => _step = _SendStep.recipient),
          onCancel: () => Navigator.of(context).pop(),
          onNext: _onAmountNext,
          sourceAddress: _sourceLineAddress,
          onSwitch: _sourceSwitchHandler,
        );
      case _SendStep.confirm:
        return _buildConfirmStep(context, state);
    }
  }

  Future<void> _onTokenSelected(TokenBalance token) async {
    // The signer gate for the chain-less entry points (portfolio action row,
    // the shared action menu): they open the sheet before any chain is known,
    // so this is the first point at which the question can be asked. Without
    // it, picking a Solana token in a session whose only key is a Tezos one
    // walked all the way to a confirm step that Solana's executor would sign
    // with that Tezos wallet. Blocked → stay on the token step.
    if (await guardCannotSend(context, chain: token.chain)) return;
    if (!mounted) return;
    // Read before the token moves: `_chain` is the chain the recipient field
    // was filled in against ([_dropRecipientForChainChange]).
    final chainChanged = _chain != token.chain;
    _amountController.clear();
    setState(() => _selectedToken = token);
    if (chainChanged) _dropRecipientForChainChange();
    // SOL is represented as a null token in [SendBloc] so the native-vs-
    // wrapped distinction collapses to the existing SOL code path.
    context.read<SendBloc>().add(
      SendEvent.setToken(token.isNative ? null : token),
    );

    // Resolve which session wallets can send this token; when 2+ qualify,
    // pick the source before the recipient step. Cancelling the
    // picker leaves the user on the token step.
    await _ensureSelfAddress(token.chain);
    await _resolveSources(token);
    unawaited(_refreshSources(token));
    if (!mounted) return;
    if (_sources.length >= 2) {
      final chosen = await _promptWalletSelect(token);
      if (!mounted) return;
      if (chosen == null) return; // cancel → stay on the token step
      await _setSource(chosen, alreadyCommitted: true);
      if (!mounted) return;
    }
    // Re-read whatever text the user left in the field as an address on the
    // new chain, now that the source — and with it `_chain` — has settled. A
    // handle re-runs the username search against the new chain; a raw address
    // reports itself invalid instead of sitting there looking accepted.
    if (chainChanged) _onAddressChanged(_addressController.text);
    setState(() => _step = _SendStep.recipient);
  }

  /// Builds the confirm step. [intrinsicHeight] renders it shrink-wrapped for
  /// the sheet's live height probe; the visible copy fills the height that
  /// probe produced.
  Widget _buildConfirmStep(
    BuildContext context,
    SendState state, {
    bool intrinsicHeight = false,
  }) {
    final ready = state.mapOrNull(ready: (s) => s) ?? _ready;
    if (ready == null) return const SizedBox.shrink();

    final isTezos = _chain == Chain.tezos;
    final isEthereum = _chain == Chain.ethereum;
    final tezEstimate = ready.tezosEstimate;
    final ethEstimate = ready.ethereumEstimate;

    // The sent asset, not the fee asset: a null token is the chain's coin (SOL /
    // ETH / XTZ collapse to it in [SendBloc]), anything else keeps its own
    // symbol and name. Tezos used to force XTZ/Tezos here regardless, so an FA
    // send reviewed as "N XTZ · Tezos" while the operation moved the token.
    final String symbol =
        ready.token?.symbol ?? (isTezos ? 'XTZ' : (isEthereum ? 'ETH' : 'SOL'));

    // Amount fiat. ETH/XTZ and their tokens are priced from the sent token's
    // cached per-token USD: ETH/ERC-20 amounts are 18-decimal wei that overflow
    // int, and [usdValueOfRaw]'s mint-keyed map can't resolve the XTZ native
    // sentinel — so both go through [pricePerToken] rather than [usdValueOfRaw]
    // (which takes an int raw amount keyed by a Solana mint).
    final double? amountUsd;
    if (isEthereum || isTezos) {
      final price = (ready.token ?? _selectedToken)?.pricePerToken;
      amountUsd = price != null ? ready.amount * price : null;
    } else {
      amountUsd = sl<TokenPriceService>().usdValueOfRaw(
        TokenAmount.toInt(
          TokenAmount.parseTokenAmount(
            ready.amountString,
            ready.token?.decimals ?? 9,
          ),
        ),
        ready.token?.mint ?? mallow_tokens.solMint,
      );
    }

    // Solana fees are lamports priced in SOL; Tezos fees are mutez priced in
    // XTZ (gas/storage/reveal breakdown); Ethereum fees are wei priced in ETH
    // (gas + tip breakdown) — regardless of whether ETH or an ERC-20 is sent.
    final String feeText;
    final double? feeUsd;
    final String? feeDetailText;
    String? speedName;
    String? speedEta;
    if (isTezos && tezEstimate != null) {
      // Quote fee + storage burn, not the baker fee alone: allocating a fresh
      // destination burns 0.06425 XTZ, which dwarfs the ~0.0004 XTZ fee — and
      // the breakdown below names it so the headline number isn't a surprise.
      final totalXtz = tezEstimate.totalCostXtz;
      feeText = stripTrailingZeros(totalXtz.toStringAsFixed(6));
      final xtzPrice = _nativeCoinPrice(TokenBalance.tezosNativeSentinel);
      feeUsd = xtzPrice != null ? totalXtz * xtzPrice : null;
      final burnXtz = tezEstimate.burnXtz;
      feeDetailText = [
        'Gas ${tezEstimate.gasLimit}',
        'Storage ${tezEstimate.storageLimit}',
        if (burnXtz > 0)
          'incl. ${stripTrailingZeros(burnXtz.toStringAsFixed(6))} XTZ '
              'storage burn',
        if (tezEstimate.includesReveal) 'incl. reveal',
      ].join(' · ');
    } else if (isEthereum && ethEstimate != null) {
      final ethPrice = _nativeCoinPrice(TokenBalance.evmNativeSentinel);
      final market = ready.ethGasMarket;
      final selection = ready.ethGasSelection;
      // With a fee market + selection, show the fee for the user's chosen tier
      // (expected = estimated gas × capped effective price). Otherwise fall
      // back to the read-only default estimate (feeHistory unavailable).
      // [_ethFeeEth] makes that choice once, so the quote and the balance guard
      // can never price the same send differently.
      final feeEth = _ethFeeEth(ready);
      feeText = stripTrailingZeros(feeEth.toStringAsFixed(9));
      feeUsd = ethPrice != null ? feeEth * ethPrice : null;
      if (market != null && selection != null) {
        speedName = selection.modeLabel;
        speedEta = selection.speedEta;
        feeDetailText = null;
      } else {
        feeDetailText =
            'Gas ${ethEstimate.gasLimit} · '
            '${ethEstimate.priorityFeeGwei.toStringAsFixed(1)} gwei tip';
      }
    } else {
      final feeLamports = _feeLamports(ready);
      feeText = stripTrailingZeros((feeLamports / 1e9).toStringAsFixed(6));
      feeUsd = sl<TokenPriceService>().usdValueOfRaw(
        feeLamports,
        mallow_tokens.solMint,
      );
      feeDetailText = null;
    }

    final profile = _profiles[apiOwnerAddress(ready.recipient)];
    // Falls back to the local account this device holds, when the recipient is
    // one of the user's own wallets — so a send between accounts reviews as
    // "Account 2" with its identicon rather than a bare hash. Ranked *below*
    // the mallow profile, the same order [RecentRecipient.displayName] applies
    // one step earlier: the username is the recipient's public identity, while
    // `Account NN` is a local label that names nobody.
    final account = _accounts[apiOwnerAddress(ready.recipient)];
    final username = profile?.username;
    final isSending = state.maybeMap(
      signing: (_) => true,
      broadcasting: (_) => true,
      orElse: () => false,
    );

    // Only pass a banner state for an actual failure — the banner paints
    // nothing on the happy path, but a non-null state still adds its spacer
    // row, which would pad the sheet for a warning that never appears.
    final simResult = ready.simulationResult;
    final showSimWarning =
        !ready.isSimulating && simResult != null && !simResult.success;

    return SendConfirmStep(
      amountText: '${stripTrailingZeros(ready.amountString)} $symbol',
      amountFiatText: _fiat(amountUsd),
      tokenName:
          ready.token?.name ??
          (isTezos ? 'Tezos' : (isEthereum ? 'Ethereum' : 'Solana')),
      recipientName:
          username ?? account?.name ?? truncateAddress(ready.recipient),
      recipientImageUrl: profile?.imageUrl,
      // The picture and the name come from one identity, never a mix of two: a
      // profile with no pfp is seeded by its username (the repo-wide
      // [avatarSeedOf] rule), and only an address with no profile at all falls
      // through to the local account's own identicon.
      recipientAvatarSeed: username != null
          ? avatarSeedOf(username: username, address: ready.recipient)
          : account?.avatarSeed,
      recipientAddress: ready.recipient,
      feeText: feeText,
      feeFiatText: _fiat(feeUsd),
      networkName: isTezos ? 'Tezos' : (isEthereum ? 'Ethereum' : 'Solana'),
      feeSymbol: isTezos ? 'XTZ' : (isEthereum ? 'ETH' : 'SOL'),
      feeMint: isTezos
          ? TokenBalance.tezosNativeSentinel
          : (isEthereum
                ? TokenBalance.evmNativeSentinel
                : mallow_tokens.solMint),
      feeDetailText: feeDetailText,
      onEditFee:
          (isEthereum &&
              ready.ethGasMarket != null &&
              ready.ethGasSelection != null)
          ? () => _onEditEthGasFee(ready)
          : null,
      speedName: speedName,
      speedEta: speedEta,
      simulation: showSimWarning
          ? SimulationBannerState(isSimulating: false, result: simResult)
          : null,
      recipientAdvisory: _advisories[ready.recipient],
      previousSendCount: sl<PreferencesService>().sendCountFor(ready.recipient),
      isSending: isSending,
      onBack: _onConfirmBack,
      onCancel: () => Navigator.of(context).pop(),
      onSend: _onSend,
      sourceAddress: _sourceLineAddress,
      onSwitch: _sourceSwitchHandler,
      intrinsicHeight: intrinsicHeight,
    );
  }

  /// Opens the Edit Gas Fee sheet over the confirm step and applies the fee the
  /// user picks. Persistence of the choice happens inside the sheet; here we
  /// only re-point the in-flight send via [SendSetEthGasSelection].
  Future<void> _onEditEthGasFee(SendReady ready) async {
    final market = ready.ethGasMarket;
    final selection = ready.ethGasSelection;
    final estimate = ready.ethereumEstimate;
    if (market == null || selection == null || estimate == null) return;
    final bloc = context.read<SendBloc>();
    final result = await showEditGasFeeSheet(
      context,
      market: market,
      selection: selection,
      estimatedGasUsed: estimate.estimatedGasUsed,
      defaultGasLimit: estimate.gasLimit,
      ethPriceUsd: _nativeCoinPrice(TokenBalance.evmNativeSentinel),
    );
    if (result != null) {
      bloc.add(SendEvent.setEthGasSelection(result));
    }
  }

  /// Expected Ethereum network fee, in whole ETH — the single figure the
  /// confirm step quotes and the balance guard checks against.
  ///
  /// With a live fee market and a selection, that is the user's chosen tier
  /// priced against the live base fee (estimated gas × capped effective price).
  /// Only when the market is unavailable does it fall back to the prepared
  /// estimate's own `getFeeData`-derived fee, which is also what `execute` then
  /// signs (a null fee override refreshes `getFeeData` at broadcast).
  ///
  /// 🛑 The guard must price the fee exactly this way. `EthereumSendEstimate.
  /// feeEth` is always the node's `getFeeData` figure and never reflects the
  /// chosen tier, while a native Max reserves `gasLimit × selection.
  /// maxFeePerGas` for that tier ([SendBloc] `_maxNativeSendable`). On the Low
  /// tier the node fee alone can exceed the whole Max reserve, so checking
  /// `estimate.feeEth` refused the one amount the Max button had just offered.
  /// Priced off the selection the check is bounded by construction: estimated
  /// gas ≤ the gas limit and the effective price ≤ `maxFeePerGas`, so the
  /// expected fee can never exceed the reserve the Max left behind.
  double _ethFeeEth(SendReady ready) {
    final estimate = ready.ethereumEstimate;
    if (estimate == null) return 0;
    final market = ready.ethGasMarket;
    final selection = ready.ethGasSelection;
    if (market == null || selection == null) return estimate.feeEth;
    return (estimate.estimatedGasUsed *
                selection.effectiveGasPrice(market.baseFeeWei))
            .toDouble() /
        1e18;
  }

  /// Network fee in lamports. Prefers the simulated net-SOL delta (which
  /// folds in any destination-ATA rent); for native sends that delta also
  /// includes the transferred amount, so it is subtracted back out.
  int _feeLamports(SendReady ready) {
    final simulated = ready.simulatedNetSolLamports;
    if (simulated == null) return ready.estimatedFeeLamports;
    if (ready.token != null) return simulated;
    final amountLamports = TokenAmount.toInt(
      TokenAmount.solToLamports(ready.amountString),
    );
    final fee = simulated - amountLamports;
    return fee >= 0 ? fee : ready.estimatedFeeLamports;
  }

  /// Per-token USD price of the chain's native coin ([nativeSentinel] is
  /// [TokenBalance.evmNativeSentinel] or [TokenBalance.tezosNativeSentinel]),
  /// used to price the network fee. The fee is always paid in the native coin
  /// even when an ERC-20/FA token is being sent, so the price is pulled from
  /// whichever loaded balance row is the native coin: the source wallet's
  /// tokens (populated for token sends), or the selected/ready token (the
  /// native coin itself on a native send, before source tokens have loaded).
  /// Unlike Solana, [TokenPriceService] can't resolve these — its map is keyed
  /// by real Solana mints, not the native sentinels.
  double? _nativeCoinPrice(String nativeSentinel) {
    final candidates = <TokenBalance>[
      ..._sourceTokens,
      ?_selectedToken,
      ?_ready?.token,
    ];
    return candidates
        .firstWhereOrNull(
          (t) => t.mint == nativeSentinel && t.pricePerToken != null,
        )
        ?.pricePerToken;
  }

  String? _amountFiatText() {
    final token = _selectedToken;
    if (token == null) return null;
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) return null;
    final price = token.pricePerToken;
    var usd = price != null ? amount * price : null;
    if (usd == null) {
      // Fall back to the price service keyed by raw amount. Guard the int
      // conversion: an 18-decimal (ETH) raw amount overflows int, so skip the
      // fallback rather than throw in build — the row just shows no estimate.
      final raw = TokenAmount.parseTokenAmount(
        _amountController.text,
        token.decimals,
      );
      if (raw <= BigInt.from(0x7FFFFFFFFFFFFFFF)) {
        usd = sl<TokenPriceService>().usdValueOfRaw(raw.toInt(), token.mint);
      }
    }
    return usd == null ? null : '~\$${usd.toStringAsFixed(2)}';
  }

  static String _fiat(double? usd) {
    if (usd == null) return '--';
    final digits = usd > 0 && usd < 0.01 ? 4 : 2;
    return '~\$${usd.toStringAsFixed(digits)}';
  }
}
