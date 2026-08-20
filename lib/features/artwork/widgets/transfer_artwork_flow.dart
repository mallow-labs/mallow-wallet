import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/crypto/ens_resolver.dart';
import '../../../core/crypto/sns_resolver.dart';
import '../../../core/data/mallow_tokens.dart' as mallow_tokens;
import '../../../core/security/security_utils.dart' show SecurityUtils;
import '../../../core/session/session_manager.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/signing_copy.dart';
import '../../../core/services/token_price_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/artwork_display.dart';
import '../../../shared/utils/chain.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/utils/token_image_utils.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/flow_unavailable_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/artwork_sheet_image.dart';
import '../../../shared/widgets/mallow_pill_field.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/transaction_pipeline_sheet.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../../portfolio/services/portfolio_bloc.dart';
import '../../send/models/recent_recipient.dart';
import '../../send/models/recipient_suggestion.dart';
import '../../send/widgets/edit_gas_fee_sheet.dart';
import '../../send/widgets/recipient_search_dropdown.dart';
import '../../send/widgets/send_qr_scanner_view.dart';
import '../../send/widgets/send_sheet_widgets.dart';
import '../../wallets/services/profile_lookup_service.dart';
import '../services/transfer_artwork_bloc.dart';
import 'portfolio_removal_refresh.dart';

/// End-to-end transfer flow for an [artwork], callable from any screen that
/// holds a [PortfolioArtwork]. Provides its own transient [TransferArtworkBloc]
/// so callers don't need a [BlocProvider] in scope.
///
/// [isMasterEdition] overrides the printable-master-edition signal that drives
/// the "you're sending the master edition" warning. Callers that build a
/// [PortfolioArtwork] without complete edition data (e.g. the artwork detail
/// screen, which has no `parentEdition`) pass the authoritative value here;
/// list-screen callers omit it and the flow falls back to
/// [PortfolioArtwork.isPrintable].
///
/// Returns `true` once the on-chain transfer confirms (the caller refreshes
/// its data sources on a `true` return — the artwork has left the wallet).
///
/// [evmHolder] is the on-chain owner of an EVM asset, threaded to the bloc so
/// the transfer is prepared + signed by that specific ETH wallet even when it
/// isn't the active one (there is no per-chain active-wallet selection). Null
/// for Solana, where the signer resolves from the active wallet.
Future<bool> runTransferArtworkFlow(
  BuildContext context, {
  required PortfolioArtwork artwork,
  bool? isMasterEdition,
  String? evmHolder,
}) async {
  final isEvm = isEthereumArtwork(
    mintAccount: artwork.mintAccount,
    chain: artwork.chain,
  );
  // Kill-switch entry gate. It lives here rather
  // than at the ~6 call sites so every caller — context menu, collection,
  // curation, activity detail, portfolio group, the FAB chooser — inherits it,
  // and reads the same `(chain, nft-transfer)` cell the signing backstop will
  // (both go through [nftTransferFlowKey], a 3-way switch — a two-way
  // `isEvm ? … : solana` ternary would gate Tezos as Solana,).
  if (await guardFlowDisabled(
    context,
    nftTransferFlowKey(mintAccount: artwork.mintAccount, chain: artwork.chain),
  )) {
    return false;
  }
  if (!context.mounted) return false;
  final analyticsChain = isEvm
      ? AnalyticsChain.ethereum.wire
      : AnalyticsChain.solana.wire;
  final bloc = sl<TransferArtworkBloc>()
    ..add(
      TransferArtworkEvent.started(
        artwork.mintAccount,
        chain: artwork.chain,
        tokenStandard: artwork.tokenStandard,
        evmHolder: evmHolder,
        artworkName: artwork.title,
        imageUrl: artwork.imageUrl,
      ),
    );
  var succeeded = false;
  // Track the resolved recipient so a confirmed send can be recorded into the
  // shared recent-recipients list (the same list the token send flow uses).
  String? lastRecipient;
  final sub = bloc.stream.listen((s) {
    if (s is TransferReady) lastRecipient = s.recipient;
    // A remote kill is excluded: it is an operator action, not a failed
    // transfer, and is reported by `flow_disabled_hit` instead — counting it
    // here (as `unknown`, no less) would corrupt the transfer-failure rate.
    // `_TransferArtworkSheet` owns presenting it.
    if (s is TransferError && !(s.failure?.isFlowDisabled ?? false)) {
      // Post-execute failure (the bloc only emits TransferError from the
      // broadcast path). The failure kind isn't mapped to a `FailureReason`
      // here → unknown. The asset_kind isn't surfaced to the UI, so it's
      // omitted per taxonomy.
      unawaited(
        sl<AnalyticsService>().trackTransaction(
          AnalyticsEvent.nftTransferFailed,
          txType: TxType.transferArtwork,
          // TransferError is only emitted from the broadcast path's failure
          // branch, so no signature exists to attach.
          isOnchainTx: false,
          properties: {
            AnalyticsProp.chain: analyticsChain,
            AnalyticsProp.reason: FailureReason.unknown.wire,
          },
          entryPoint: EntryPoint.artworkDetail,
        ),
      );
    }
    if (s is TransferSuccess) {
      succeeded = true;
      // Fires once — TransferSuccess is terminal (no re-emit). NFT identity is
      // the collection; the item mint is never attached (cardinality).
      unawaited(
        sl<AnalyticsService>().trackTransaction(
          AnalyticsEvent.nftTransferCompleted,
          txType: TxType.transferArtwork,
          signature: s.signature,
          properties: {
            AnalyticsProp.chain: analyticsChain,
            AnalyticsProp.collectionName: artwork.collectionName,
          },
          entryPoint: EntryPoint.artworkDetail,
        ),
      );
      final recipient = lastRecipient;
      if (recipient != null && recipient.isNotEmpty) {
        final prefs = sl<PreferencesService>();
        unawaited(prefs.saveRecentSendAddress(recipient));
        // Counted alongside token sends: the send sheet's "previous sends"
        // label is about the address, and an NFT transfer is still a send to it.
        unawaited(prefs.incrementSendCount(recipient));
      }
      // A transfer to one of the viewer's own session wallets keeps the asset
      // in the (session-aggregated) portfolio, so it must NOT be optimistically
      // removed — only sends to an external wallet leave the owned set. The
      // reindex refetch below runs either way and reconciles.
      final toSessionWallet =
          recipient != null &&
          sl<SessionManager>().sessionWallets.any(
            (w) => w.address == recipient,
          );
      // The artwork has left the wallet. Refetch My Art once the indexer
      // reflects the new owner (not just on the `checkTx` ack, which lands
      // before ownership is flushed — see [refreshMyArtAfterRemoval]).
      unawaited(
        refreshMyArtAfterRemoval(
          mint: artwork.mintAccount,
          signature: s.signature,
          optimisticRemove: !toSessionWallet,
          checkSolanaIndexer: !isEvm,
          // Force the backend to persist the new owner immediately (matches
          // the webapp). Solana-only — the route reads a Solana on-chain owner.
          updateOwner: !isEvm,
        ),
      );
    }
  });
  try {
    await showMallowSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BlocProvider<TransferArtworkBloc>.value(
        value: bloc,
        child: _TransferArtworkSheet(
          artwork: artwork,
          isMasterEdition: isMasterEdition,
          evmHolder: evmHolder,
        ),
      ),
    );
    return succeeded;
  } finally {
    await sub.cancel();
    await bloc.close();
  }
}

enum _Step { recipient, confirm }

class _TransferArtworkSheet extends StatefulWidget {
  const _TransferArtworkSheet({
    required this.artwork,
    this.isMasterEdition,
    this.evmHolder,
  });

  final PortfolioArtwork artwork;
  final bool? isMasterEdition;

  /// The EVM asset's on-chain holder — the wallet the transfer is prepared and
  /// signed by (see [runTransferArtworkFlow]). Null for Solana, and for EVM
  /// callers that didn't resolve one, in which case the active chain wallet is
  /// used. Read by the self-send guard only; the bloc gets its own copy.
  final String? evmHolder;

  @override
  State<_TransferArtworkSheet> createState() => _TransferArtworkSheetState();
}

class _TransferArtworkSheetState extends State<_TransferArtworkSheet> {
  final _addressController = TextEditingController();
  final _addressFocusNode = FocusNode();

  _Step _step = _Step.recipient;

  /// True once the user confirms — the flow morphs from the input steps to the
  /// in-flight pipeline step within the same route (no separate sheet).
  bool _inPipeline = false;

  // Recent recipients (shared with the token send flow), capped at 5.
  List<RecentRecipient> _recents = [];

  /// The active (sending) wallet address. Recipients matching it are filtered
  /// out of recents and blocked at the Next step so the user can't transfer to
  /// themselves.
  String? _selfAddress;

  // SNS (.sol) resolution state for the recipient field.
  Timer? _resolveDebounce;
  bool _isResolving = false;
  String? _resolvedAddress;
  String? _snsError;

  /// Drives the username-search dropdown under the recipient field.
  ///
  /// Unlike the token send sheet this needs no "a profile was picked" flag: the
  /// bloc owns recipient validation here and is handed the resolved address
  /// directly, so nothing ever re-parses the handle sitting in the field.
  late final RecipientSearchController _recipientSearch =
      RecipientSearchController(isExcluded: _isSelfAddress);

  // Resolved recipient identity for the confirm step, ranked mallow profile →
  // local account → truncated address. Kept in the same order as
  // [RecentRecipient.displayName] and the send confirm pill, so one recipient
  // cannot read as two different people between the surfaces.
  String? _accountName;
  String? _accountAvatarSeed;
  String? _profileUsername;
  String? _profileImageUrl;

  /// Whether to show the master-edition heads-up. Prefers the explicit
  /// override from the caller; falls back to the artwork's own
  /// [PortfolioArtwork.isPrintable] when none was supplied.
  bool get _isMasterEdition =>
      widget.isMasterEdition ?? widget.artwork.isPrintable;

  /// EVM (ERC-721/1155) artwork — switches recipient validation/resolution to
  /// Ethereum + ENS and the confirm UI to the Ethereum network + ETH fees.
  bool get _isEvm => isEthereumArtwork(
    mintAccount: widget.artwork.mintAccount,
    chain: widget.artwork.chain,
  );

  /// The chain this artwork actually moves on, via the same 3-way resolution
  /// the kill-switch key uses — so the sender address the self-send guard reads
  /// can never be resolved on a different chain than the transfer signs on.
  Chain get _artworkChain => nftTransferFlowKey(
    mintAccount: widget.artwork.mintAccount,
    chain: widget.artwork.chain,
  ).chain;

  @override
  void initState() {
    super.initState();
    // Recipients are shared with the fungible-token send flow, so scope them
    // to the artwork's chain before applying the five-row display cap. A
    // recent Ethereum address must never appear when sending a Solana NFT
    // (or vice versa), and filtering first keeps an older same-chain address
    // from being displaced by unrelated-chain recents.
    _recents = [
      for (final address in sl<PreferencesService>().recentSendAddresses)
        if (Chain.fromAddress(address) == _artworkChain)
          RecentRecipient(address: address),
    ].take(5).toList();
    unawaited(_resolveRecentAccounts());
    unawaited(_resolveRecentProfiles());
    unawaited(_loadSelfAddress());
  }

  /// Loads the address this transfer will be signed *from*, then drops it from
  /// recents so the user can't pick their own wallet as a recipient.
  ///
  /// Resolved per-chain, and for EVM preferring the asset's on-chain holder:
  ///
  ///  * `getAddress()` defaults to `Chain.solana`, so the chain-blind call this
  ///    replaced compared a base58 Solana address against a `0x…` recipient on
  ///    every Ethereum transfer — the guard could never fire and the user's own
  ///    address was never filtered out of recents. An artwork transfer is
  ///    irreversible, so the guard has to be the artwork's chain.
  ///  * On EVM the signer is [_TransferArtworkSheet.evmHolder] (the wallet that
  ///    actually holds the asset), which need not be the active ETH wallet —
  ///    there is no per-chain active selection. Comparing against the *active*
  ///    ETH wallet would both miss a real self-send and refuse the legitimate
  ///    "move it to my other wallet" transfer.
  ///
  /// [apiOwnerAddress] normalises the comparison: EVM addresses are stored
  /// checksummed in some places and lowercased in others, and a case-sensitive
  /// `==` between the two forms of the *same* address silently disarms this.
  Future<void> _loadSelfAddress() async {
    try {
      // The session's own signer on the chain, not the active account's — a
      // Profile signs with a linked wallet, and filtering recents against an
      // unlinked account sibling would guard the wrong address.
      final self =
          (_isEvm ? widget.evmHolder : null) ??
          await sl<SessionManager>().activeAddress(_artworkChain);
      if (!mounted || self == null) return;
      final selfKey = apiOwnerAddress(self);
      setState(() {
        _selfAddress = self;
        _recents = [
          for (final r in _recents)
            if (apiOwnerAddress(r.address) != selfKey) r,
        ];
      });
    } catch (_) {
      // Best-effort — leave recents as-is if the sender can't be resolved.
    }
  }

  /// True when [address] is the wallet this transfer would be sent *from*.
  /// Normalised, never a raw `==` — see [_loadSelfAddress].
  bool _isSelfAddress(String address) {
    final self = _selfAddress;
    if (self == null || address.isEmpty) return false;
    return apiOwnerAddress(address) == apiOwnerAddress(self);
  }

  @override
  void dispose() {
    _resolveDebounce?.cancel();
    _recipientSearch.dispose();
    _addressController.dispose();
    _addressFocusNode.dispose();
    super.dispose();
  }

  // ── Recent recipients ──────────────────────────────────────────────────

  /// Enrich recents whose address belongs to one of the user's local accounts
  /// with that account's name + avatar, so an address you own reads as
  /// "Account NN" (with its identicon) rather than a bare hash. The twin of the
  /// send sheet's pass of the same name — without it this list could only ever
  /// show a mallow username or the address, which is what it did.
  Future<void> _resolveRecentAccounts() async {
    final addresses = [for (final r in _recents) r.address];
    if (addresses.isEmpty) return;
    try {
      final accounts = await sl<WalletRepository>().accountsForAddresses(
        addresses,
      );
      if (!mounted || accounts.isEmpty) return;
      setState(() {
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

  Future<void> _resolveRecentProfiles() async {
    final addresses = [for (final r in _recents) r.address];
    if (addresses.isEmpty) return;
    try {
      final profiles = await sl<ProfileLookupService>().profilesForAddresses(
        addresses,
      );
      if (!mounted || profiles.isEmpty) return;
      setState(() {
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

  // ── Recipient input ────────────────────────────────────────────────────

  void _onAddressChanged(String value) {
    _resolveDebounce?.cancel();
    final trimmed = value.trim();

    setState(() {
      _snsError = null;
      _resolvedAddress = null;
      _isResolving = false;
    });

    if (trimmed.isEmpty) {
      _recipientSearch.close();
      _setBlocRecipient('');
      return;
    }

    // A username search and address validation are mutually exclusive readings
    // of the same text — `alice` is not an address, and letting the bloc see it
    // would print an invalid-address error under an open dropdown of matching
    // users. Handing the bloc an empty recipient instead keeps the CTA disabled
    // without an error, since `_validateAddress('')` returns null.
    _recipientSearch.onInput(trimmed, _searchChain);
    if (_recipientSearch.isOpen) {
      _setBlocRecipient('');
      return;
    }

    // Human-readable names resolve (debounced) to an address before the bloc
    // sees them: `.eth` via ENS for EVM artworks, `.sol` via SNS for Solana.
    final isDomain = _isEvm
        ? EnsResolver.isEthDomain(trimmed)
        : SnsResolver.isSolDomain(trimmed);
    final resolveDomain = _isEvm ? EnsResolver.resolve : SnsResolver.resolve;
    if (isDomain) {
      setState(() => _isResolving = true);
      _setBlocRecipient('');
      _resolveDebounce = Timer(const Duration(milliseconds: 500), () async {
        if (_addressController.text.trim() != trimmed) return;
        final resolved = await resolveDomain(trimmed);
        if (!mounted || _addressController.text.trim() != trimmed) return;
        setState(() {
          _isResolving = false;
          if (resolved != null) {
            _resolvedAddress = resolved;
            _snsError = null;
          } else {
            _snsError = 'Could not resolve domain';
          }
        });
        if (resolved != null) _setBlocRecipient(resolved);
      });
      return;
    }

    // Plain address — let the bloc validate it.
    _setBlocRecipient(trimmed);
  }

  void _setBlocRecipient(String address) {
    context.read<TransferArtworkBloc>().add(
      TransferArtworkEvent.recipientChanged(address),
    );
  }

  /// Chain the username search filters addresses to. This flow transfers Solana
  /// and EVM artworks only, so it mirrors [_isEvm] rather than reading a
  /// three-way chain the way the token send sheet does.
  Chain get _searchChain => _isEvm ? Chain.ethereum : Chain.solana;

  /// Fills the field with the picked profile's handle and commits its address
  /// for this chain. Deliberately does not advance — one profile can produce
  /// several rows, so the user needs to see which wallet they landed on.
  void _onSuggestionPicked(RecipientSuggestion suggestion) {
    // Assigning `.text` does not fire `onChanged`, so the gate is not re-run.
    _addressController.text = suggestion.fieldText;
    setState(() {
      _resolvedAddress = suggestion.address;
      _snsError = null;
      _isResolving = false;
    });
    _setBlocRecipient(suggestion.address);
  }

  /// Mirrors a chosen address into the field and the bloc, trimmed once.
  void _setAddress(String address) {
    final trimmed = address.trim();
    _addressController.text = trimmed;
    _onAddressChanged(trimmed);
  }

  Future<void> _pasteAddress() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || !mounted) return;
    _setAddress(text);
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
    _setAddress(scanned);
  }

  void _onScanDetect(BuildContext routeContext, BarcodeCapture capture) {
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null) return;
    final trimmed = code.trim();
    final isAddress = _isEvm
        ? isEthereumAddress(trimmed)
        : SecurityUtils.isValidSolanaAddress(trimmed);
    final isDomain = _isEvm
        ? EnsResolver.isEthDomain(trimmed)
        : SnsResolver.isSolDomain(trimmed);
    if (!isAddress && !isDomain) return;
    final route = ModalRoute.of(routeContext);
    if (route == null || !route.isCurrent) return;
    Navigator.of(routeContext).pop(trimmed);
  }

  // Tapping a recent recipient fills the field and advances immediately.
  void _onRecentTap(RecentRecipient recent) {
    _setAddress(recent.address);
    _onNext();
  }

  void _onNext() {
    _recipientSearch.close();
    final recipient = _resolvedAddress ?? _addressController.text.trim();
    if (_isSelfAddress(recipient)) {
      setState(() => _snsError = "You can't send to your own wallet");
      _addressFocusNode.requestFocus();
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    context.read<TransferArtworkBloc>().add(
      const TransferArtworkEvent.proceed(),
    );
  }

  // ── Recipient resolution ───────────────────────────────────────────────

  Future<void> _resolveRecipient(String address) async {
    // The local account's own label is a fallback when the address has no
    // mallow profile — the mallow username takes precedence (below).
    final key = apiOwnerAddress(address);
    try {
      // 🛑 The ACCOUNT's name ("Account 2"), never the wallet row's `name`.
      // A wallet label is an internal, per-chain-key detail: social login
      // stores its wallets as "Apple Wallet"/"Google Wallet"
      // (`SocialAuthService`), so reading `WalletInfo.name` here surfaced the
      // user's login provider as the name of the recipient. `accountsForAddresses`
      // is also case-insensitive, which is what a checksummed EVM recipient needs.
      final accounts = await sl<WalletRepository>().accountsForAddresses([
        address,
      ]);
      final account = accounts[address];
      _accountName = account?.name;
      _accountAvatarSeed = account?.avatarSeed;
    } catch (_) {
      // Fall through — name resolution is best-effort.
    }
    try {
      final profiles = await sl<ProfileLookupService>().profilesForAddresses([
        address,
      ]);
      final profile = profiles[key];
      if (profile != null) {
        _profileUsername = profile.username;
        _profileImageUrl = profile.imageUrl;
      }
    } catch (_) {
      // Confirm step falls back to the truncated address.
    }
    if (mounted) setState(() {});
  }

  // ── Confirm / execute ──────────────────────────────────────────────────

  void _onTransfer() {
    // Morph to the in-flight pipeline step in place and kick off the transfer.
    // Signing/broadcasting/success/error all render in the pipeline step; it
    // closes the flow on success and morphs back to the recipient step on
    // error (see [_exitPipelineToInput]).
    setState(() => _inPipeline = true);
    context.read<TransferArtworkBloc>().add(
      const TransferArtworkEvent.execute(),
    );
  }

  /// Pipeline error → restore the typed recipient and morph back to the
  /// recipient step so the user can retry.
  void _exitPipelineToInput() {
    context.read<TransferArtworkBloc>().add(const TransferArtworkEvent.reset());
    setState(() {
      _inPipeline = false;
      _step = _Step.recipient;
    });
  }

  void _onConfirmBack() {
    context.read<TransferArtworkBloc>().add(const TransferArtworkEvent.reset());
    setState(() => _step = _Step.recipient);
  }

  // ── Bloc listener ──────────────────────────────────────────────────────

  void _onBlocState(BuildContext context, TransferArtworkState state) {
    if (state is TransferReady && _step != _Step.confirm) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _step = _Step.confirm);
      unawaited(_resolveRecipient(state.recipient));
    } else if (state case TransferError(
      failure: final failure?,
    ) when failure.isFlowDisabled) {
      // Kill switch, handled before both branches below because it
      // reaches this listener on the pre-execute path *and* the post-execute
      // one — where the pipeline step's hardcoded "Transfer failed" is all the
      // user would otherwise see, and the operator's copy is the only thing
      // that can say whether the artwork moved. Never a snackbar, never a
      // Retry on a switched-off flow, and no failure analytics.
      //
      // The sheet stays open with the typed recipient intact: the reset below
      // restores it into the input step (`TransferReset` reads
      // `previousRecipient` off this very state).
      //
      // Deferred a frame + re-checked: the reset dispatched below rebuilds this
      // subtree (and, on the pipeline path, morphs it back), so pushing the
      // explanation synchronously would race the morph.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        handleFlowDisabled(
          this.context,
          failure,
          flow: nftTransferFlowKey(
            mintAccount: widget.artwork.mintAccount,
            chain: widget.artwork.chain,
          ),
        );
      });
      if (_inPipeline) {
        _exitPipelineToInput();
      } else {
        context.read<TransferArtworkBloc>().add(
          const TransferArtworkEvent.reset(),
        );
        setState(() => _step = _Step.recipient);
      }
    } else if (state is TransferError && !_inPipeline) {
      // Pre-execute (validation) failure — surface it and stay on the input
      // steps. Post-execute failures render inside the pipeline step instead.
      AppSnackBar.show(context, state.message);
      context.read<TransferArtworkBloc>().add(
        const TransferArtworkEvent.reset(),
      );
      setState(() => _step = _Step.recipient);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final media = MediaQuery.of(context);
    final keyboardInset = media.viewInsets.bottom;
    // When the keyboard is up, pad to clear it; otherwise reserve the device
    // safe area (home indicator) plus a gap so the buttons aren't flush with
    // the screen edge. `viewPadding` reports the inset even inside a modal
    // sheet where `padding` can collapse to zero.
    final bottomPad = keyboardInset > 0
        ? keyboardInset + MallowTheme.spacingMd
        : media.viewPadding.bottom + MallowTheme.spacingMd;

    return BlocConsumer<TransferArtworkBloc, TransferArtworkState>(
      listener: _onBlocState,
      builder: (context, state) {
        // Outer morph: the input phase (recipient/confirm steps) cross-fades +
        // resizes into the in-flight pipeline phase in place once the user
        // confirms — instead of presenting the pipeline as a separate sheet.
        final Widget child = _inPipeline
            ? _TransferPipelineView(
                key: const ValueKey('pipeline'),
                chain: _artworkChain,
                onClosed: () => Navigator.of(context).pop(),
                onBack: _exitPipelineToInput,
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
                        child: AnimatedSwitcher(
                          duration: MallowTheme.sheetDuration,
                          child: KeyedSubtree(
                            key: ValueKey(_step),
                            child: _step == _Step.recipient
                                ? _buildRecipientStep(context, state)
                                : _buildConfirmStep(context, state),
                          ),
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

  Widget _buildRecipientStep(BuildContext context, TransferArtworkState state) {
    final colors = context.mallowColors;
    final input = state is TransferInput ? state : const TransferInput();
    final canProceed = state.canProceed && !_isResolving;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SendStepHeader(title: 'Send Artwork'),
          const SizedBox(height: MallowTheme.spacingLg),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ArtworkHeader(artwork: widget.artwork),
                  const SizedBox(height: MallowTheme.spacingLg),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Recipient Address',
                          style: MallowTheme.uiMeta.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      TapTargetExpander(
                        child: GestureDetector(
                          onTap: _pasteAddress,
                          behavior: HitTestBehavior.opaque,
                          child: Text(
                            'Paste',
                            style: MallowTheme.uiMeta.copyWith(
                              color: colors.accent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: MallowTheme.spacing12),
                  RecipientSearchDropdown(
                    controller: _recipientSearch,
                    focusNode: _addressFocusNode,
                    onSelected: _onSuggestionPicked,
                    child: MallowPillField(
                      controller: _addressController,
                      focusNode: _addressFocusNode,
                      hintText: _isEvm
                          ? 'Ethereum address, ENS or username'
                          : 'Solana address or username',
                      errorText: _snsError ?? input.recipientError,
                      onChanged: _onAddressChanged,
                      autocorrect: false,
                      enableSuggestions: false,
                      suffix: TapTargetExpander(
                        child: GestureDetector(
                          onTap: _openScanner,
                          behavior: HitTestBehavior.opaque,
                          child: MallowSvgIcon(
                            'assets/icons/qr.svg',
                            width: 20,
                            height: 20,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_isResolving) ...[
                    const SizedBox(height: MallowTheme.spacingSm),
                    _ResolvingRow(),
                  ] else if (_resolvedAddress != null) ...[
                    const SizedBox(height: MallowTheme.spacingSm),
                    Text(
                      _resolvedAddress!,
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                  if (input.isEvm &&
                      input.maxQuantity != null &&
                      input.maxQuantity! > 1) ...[
                    const SizedBox(height: MallowTheme.spacingLg),
                    _QuantityStepper(
                      quantity: input.quantity,
                      max: input.maxQuantity!,
                      onChanged: (q) => context.read<TransferArtworkBloc>().add(
                        TransferArtworkEvent.quantityChanged(q),
                      ),
                    ),
                  ],
                  if (input.unsupportedReason != null) ...[
                    const SizedBox(height: MallowTheme.spacing12),
                    _WarningBanner(message: input.unsupportedReason!),
                  ] else if (input.advisoryNotice != null) ...[
                    const SizedBox(height: MallowTheme.spacing12),
                    SendWarningNotice(message: input.advisoryNotice!),
                  ],
                  if (_recents.isNotEmpty) ...[
                    const SizedBox(height: MallowTheme.spacingLg),
                    Text(
                      'Recent',
                      style: MallowTheme.uiMeta.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: MallowTheme.spacing12),
                    for (var i = 0; i < _recents.length; i++) ...[
                      if (i > 0) const SizedBox(height: MallowTheme.spacingSm),
                      _RecentRow(recent: _recents[i], onTap: _onRecentTap),
                    ],
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: MallowTheme.spacingMd + 10),
          SendStepButtons(
            primaryLabel: 'Next',
            enabled: canProceed,
            isLoading: input.isCheckingStandard,
            onCancel: () => Navigator.of(context).pop(),
            onPrimary: canProceed ? _onNext : null,
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmStep(BuildContext context, TransferArtworkState state) {
    final colors = context.mallowColors;
    final ready = state is TransferReady ? state : null;

    final isSending = state is TransferSigning || state is TransferBroadcasting;

    final isEvm = _isEvm;
    final feeLamports = ready?.simulatedNetSolLamports;
    final feeWei = ready?.simulatedFeeWei;
    final feeText = isEvm
        ? (feeWei == null
              ? '—'
              : stripTrailingZeros(
                  (feeWei.toDouble() / 1e18).toStringAsFixed(6),
                ))
        : (feeLamports == null
              ? '—'
              : stripTrailingZeros((feeLamports / 1e9).toStringAsFixed(6)));
    // ETH/ERC-20 prices aren't reliably cached, so EVM shows the fee in ETH
    // without a USD estimate (mirrors the send flow).
    final feeUsd = isEvm || feeLamports == null
        ? null
        : sl<TokenPriceService>().usdValueOfRaw(
            feeLamports,
            mallow_tokens.solMint,
          );

    final recipient = ready?.recipient ?? '';
    // Prefer the mallow username, then an imported account's own label, then
    // the truncated address.
    final recipientName =
        _profileUsername ?? _accountName ?? truncateAddress(recipient);

    // Surface a failed simulation so a broken transfer (e.g. an unsupported
    // token standard) can't be sent.
    final simResult = ready?.simulationResult;
    final showSimError =
        ready != null &&
        !ready.isSimulating &&
        simResult != null &&
        !simResult.success;
    // Send is live only once a simulation has succeeded for this recipient and
    // no (re)simulation is in flight — so it can never broadcast while a sim is
    // still running (which would sign a prepared for the previous recipient) or
    // before one has confirmed the transfer is safe. The shimmer/fee UX is
    // driven separately by [ready.isSimulating] on the fee pill above.
    final canSend =
        ready != null &&
        !ready.isSimulating &&
        simResult != null &&
        simResult.success;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ArtworkHeader(artwork: widget.artwork),
        if (_isMasterEdition) ...[
          const SizedBox(height: MallowTheme.spacingLg),
          const _WarningBanner(
            message:
                "You're sending the Master Edition! To send a print, use "
                'Airdrop',
          ),
        ],
        const SizedBox(height: MallowTheme.spacingLg),
        _sectionLabel(context, 'Recipient'),
        const SizedBox(height: MallowTheme.spacing12),
        _pill(
          context,
          child: Row(
            children: [
              RecipientAvatar(
                size: 24,
                imageUrl: _profileImageUrl,
                // The picture follows the name from the same identity — see
                // the send confirm pill, which resolves it identically.
                seed: _profileUsername != null
                    ? avatarSeedOf(
                        username: _profileUsername,
                        address: recipient,
                      )
                    : (_accountAvatarSeed ?? recipient),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: Text(
                  recipientName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiLabel.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: MallowTheme.spacing12),
        Text(
          recipient,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        _sectionLabel(context, 'Network'),
        const SizedBox(height: MallowTheme.spacing12),
        _pill(
          context,
          child: Text(
            isEvm ? 'Ethereum' : 'Solana',
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        _sectionLabel(context, 'Network fee'),
        const SizedBox(height: MallowTheme.spacing12),
        _pill(
          context,
          child: Row(
            children: [
              if (!isEvm) ...[
                tokenImageWidget(
                  mint: mallow_tokens.solMint,
                  size: 16,
                  symbol: 'SOL',
                  enlargeChainGlyph: true,
                ),
                const SizedBox(width: MallowTheme.spacingSm),
              ],
              Expanded(
                child: ready?.isSimulating ?? false
                    ? _feeSpinner(context)
                    : Text(
                        isEvm ? '$feeText ETH' : feeText,
                        style: MallowTheme.uiBody.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
              ),
              if (!isEvm)
                Text(
                  feeUsd == null ? '--' : '~\$${feeUsd.toStringAsFixed(4)}',
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textSecondary,
                  ),
                )
              else if (_canEditEthGasFee(ready))
                _EditFeeAffordance(
                  label: ready!.ethGasSelection!.modeLabel,
                  onTap: () => _onEditEthGasFee(ready),
                ),
            ],
          ),
        ),
        if (showSimError) ...[
          const SizedBox(height: MallowTheme.spacing12),
          _WarningBanner(
            message:
                "This artwork can't be transferred right now. "
                        "${simResult.error ?? ''}"
                    .trim(),
          ),
        ] else if (ready?.recipientIsContract ?? false) ...[
          const SizedBox(height: MallowTheme.spacing12),
          const _WarningBanner(
            message:
                'The recipient is a contract. Make sure it can receive NFTs — '
                'a transfer to a contract that does not may revert.',
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SendStepHeader(title: 'Confirm Send', onBack: _onConfirmBack),
          const SizedBox(height: MallowTheme.spacingLg),
          Flexible(child: SingleChildScrollView(child: body)),
          const SizedBox(height: MallowTheme.spacingMd),
          SendStepButtons(
            primaryLabel: 'Send',
            isLoading: isSending,
            enabled: canSend,
            onCancel: () => Navigator.of(context).pop(),
            onPrimary: canSend ? _onTransfer : null,
          ),
        ],
      ),
    );
  }

  Widget _feeSpinner(BuildContext context) => const Align(
    alignment: Alignment.centerLeft,
    child: ShimmerBox(width: 110, height: 15),
  );

  Widget _sectionLabel(BuildContext context, String label) => Text(
    label,
    style: MallowTheme.uiMeta.copyWith(color: context.mallowColors.textPrimary),
  );

  Widget _pill(BuildContext context, {required Widget child}) => Container(
    height: 40,
    padding: const EdgeInsets.only(left: 16, right: MallowTheme.spacingSm),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      color: context.mallowColors.surfaceMuted,
      borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
    ),
    child: child,
  );

  /// The EVM fee is editable once the live fee market + a resolved selection are
  /// in hand (and simulation is done). A missing market degrades to a read-only
  /// default fee — mirrors the send flow's `onEditFee` gating.
  bool _canEditEthGasFee(TransferReady? ready) =>
      ready != null &&
      !ready.isSimulating &&
      ready.ethGasMarket != null &&
      ready.ethGasSelection != null &&
      ready.ethEstimatedGasUsed != null &&
      ready.ethDefaultGasLimit != null;

  /// Open the shared Edit Gas Fee sheet (Low/Market/Advanced) and apply the
  /// user's pick. The sheet persists the choice; the bloc re-points the fee
  /// display and the broadcast without re-running the safety gate.
  Future<void> _onEditEthGasFee(TransferReady ready) async {
    final market = ready.ethGasMarket;
    final selection = ready.ethGasSelection;
    final gasUsed = ready.ethEstimatedGasUsed;
    final defaultGasLimit = ready.ethDefaultGasLimit;
    if (market == null ||
        selection == null ||
        gasUsed == null ||
        defaultGasLimit == null) {
      return;
    }
    final bloc = context.read<TransferArtworkBloc>();
    final result = await showEditGasFeeSheet(
      context,
      market: market,
      selection: selection,
      estimatedGasUsed: gasUsed,
      defaultGasLimit: defaultGasLimit,
    );
    if (result != null) {
      bloc.add(TransferArtworkEvent.setEthGasSelection(result));
    }
  }
}

/// A compact trailing "tier · Edit" control on the network-fee pill that opens
/// the Edit Gas Fee sheet. EVM only — the Solana fee is not user-tunable.
class _EditFeeAffordance extends StatelessWidget {
  const _EditFeeAffordance({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(width: MallowTheme.spacingXs),
          Text(
            'Edit',
            style: MallowTheme.uiCaption.copyWith(color: colors.accent),
          ),
          Icon(Icons.chevron_right, size: 16, color: colors.accent),
        ],
      ),
    );
  }
}

/// Artwork preview: the image centered above a "Title / @artist" line with a
/// leading send glyph. Shared by both steps.
class _ArtworkHeader extends StatelessWidget {
  const _ArtworkHeader({required this.artwork});

  final PortfolioArtwork artwork;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final username = artwork.artistUsername;
    final artistLabel = username != null && username.isNotEmpty
        ? '@$username'
        : artwork.artistName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ArtworkSheetImage(
          imageUrl: artwork.imageUrl,
          nsfw: artwork.nsfw,
          borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: colors.divider),
              ),
              child: Center(
                child: MallowSvgIcon(
                  'assets/icons/send.svg',
                  width: 18,
                  height: 18,
                  color: colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: formatArtworkName(
                        name: artwork.title,
                        editionNumber: artwork.editionNumber,
                      ),
                      style: MallowTheme.editorialSubhead.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    if (artistLabel.isNotEmpty) ...[
                      TextSpan(
                        text: ' / ',
                        style: MallowTheme.uiBody.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      TextSpan(
                        text: artistLabel,
                        style: MallowTheme.uiCaption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                    if (artwork.isVerified)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: VerifiedBadge(
                            size: 16,
                            isAdmin: artwork.isAdmin,
                          ),
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A recent recipient row: avatar + (username or truncated address) + the
/// truncated address pinned right.
class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.recent, required this.onTap});

  final RecentRecipient recent;
  final ValueChanged<RecentRecipient> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final truncated = truncateAddress(recent.address);
    // Same order as [RecentRecipient.displayName] and the send sheet's row, so
    // the picture and the name always come from one identity.
    final username = recent.username;
    final seed = username != null
        ? avatarSeedOf(username: username, address: recent.address)
        : (recent.accountAvatarSeed ?? recent.address);
    return TapTargetExpander(
      child: GestureDetector(
        onTap: () => onTap(recent),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 24,
          child: Row(
            children: [
              RecipientAvatar(size: 24, imageUrl: recent.imageUrl, seed: seed),
              const SizedBox(width: MallowTheme.spacingSm),
              Expanded(
                child: Text(
                  recent.displayName ?? truncated,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: MallowTheme.spacingSm),
              Text(
                truncated,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline "Resolving…" row shown while a `.sol` domain resolves.
class _ResolvingRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: [
        MallowLoader(size: 12, color: colors.textSecondary),
        const SizedBox(width: MallowTheme.spacingSm),
        Text(
          'Resolving...',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// Quantity picker for ERC-1155 transfers, bounded to the owned balance.
class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({
    required this.quantity,
    required this.max,
    required this.onChanged,
  });

  final int quantity;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    Widget stepButton(IconData icon, bool enabled, VoidCallback onTap) {
      return TapTargetExpander(
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          behavior: HitTestBehavior.opaque,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? colors.textPrimary : colors.textSecondary,
          ),
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            'Quantity',
            style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
          ),
        ),
        stepButton(Icons.remove, quantity > 1, () => onChanged(quantity - 1)),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacingMd,
          ),
          child: Text(
            '$quantity',
            style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
          ),
        ),
        stepButton(Icons.add, quantity < max, () => onChanged(quantity + 1)),
        const SizedBox(width: MallowTheme.spacingSm),
        Text(
          'of $max',
          style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// Inline warning banner (unsupported standard, master-edition heads-up, or a
/// failed simulation).
class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      padding: const EdgeInsets.all(MallowTheme.spacing12),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MallowSvgIcon(
            'assets/icons/alert_triangle.svg',
            width: 18,
            height: 18,
            color: colors.textSecondary,
          ),
          const SizedBox(width: MallowTheme.spacingSm),
          Expanded(
            child: Text(
              message,
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pipeline step of the transfer flow (in-flight signing/broadcasting →
/// success/error). Hosted in-place by [_TransferArtworkSheet]: on success it
/// calls [onClosed] (close the whole flow) after a brief pause; on error its
/// Back/Retry call [onBack] (morph back to the recipient step).
class _TransferPipelineView extends StatefulWidget {
  const _TransferPipelineView({
    required this.chain,
    required this.onClosed,
    required this.onBack,
    super.key,
  });

  /// The chain this transfer signs on, from the host's `_artworkChain` — picks
  /// the confirming subtitle, whose wait differs sharply between Solana and EVM.
  final Chain chain;
  final VoidCallback onClosed;
  final VoidCallback onBack;

  @override
  State<_TransferPipelineView> createState() => _TransferPipelineViewState();
}

class _TransferPipelineViewState extends State<_TransferPipelineView> {
  bool _closed = false;

  /// Closes the whole flow, guarded so a double-tap can't pop twice (the
  /// success path sets the same flag before auto-closing).
  void _close() {
    if (_closed) return;
    _closed = true;
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<TransferArtworkBloc, TransferArtworkState>(
      listenWhen: (prev, next) => prev.runtimeType != next.runtimeType,
      listener: (context, state) async {
        if (state is TransferSuccess) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
          if (!context.mounted || _closed) return;
          _closed = true;
          widget.onClosed();
        }
      },
      builder: (context, state) {
        final phase = switch (state) {
          TransferSuccess() => TransactionPipelinePhase.success,
          // A kill is already morphing this step away (the host's listener):
          // don't flash "Transfer failed" over the operator's actual reason.
          TransferError(:final failure)
              when !(failure?.isFlowDisabled ?? false) =>
            TransactionPipelinePhase.error,
          _ => TransactionPipelinePhase.progress,
        };
        final (label, sublabel) = _labelsFor(state);
        // Broadcast, never observed as confirmed before the blockhash expired:
        // indeterminate, not failed. This is the sharpest edge of the lot — an
        // NFT transfer that lands twice cannot be undone — so neither the
        // headline nor the affordances may suggest nothing happened. Mirrors
        // `SendPipelineView`.
        final unconfirmed =
            state is TransferError && (state.failure?.isUnconfirmed ?? false);
        // Once an EVM broadcast is registered, the pending tracker owns the
        // nonce and this flow can safely leave the inclusion wait to Activity.
        // The bloc only sets [pendingRegistered] after the raw transaction was
        // accepted and persisted, so a failed broadcast still reaches this
        // sheet instead of being hidden by an early dismissal.
        final canExitEarly =
            state is TransferBroadcasting && state.pendingRegistered;
        return TransactionPipelineSheet(
          phase: phase,
          label: label,
          sublabel: sublabel,
          errorTitle: unconfirmed ? 'Not confirmed yet' : 'Transfer failed',
          // The failure message — `sublabel` isn't rendered in the error body,
          // so without this the reason was dropped entirely.
          errorSublabel: state is TransferError ? state.message : null,
          onRetry: unconfirmed ? null : widget.onBack,
          // Unconfirmed: [onBack] morphs back to the recipient step with the
          // address still filled in — one tap from re-sending an NFT that may
          // already be gone, and a double-landed transfer is irreversible. Bow
          // out of the flow entirely instead; the user reopens Transfer once
          // Activity says which way it went.
          onClose: unconfirmed ? _close : widget.onBack,
          progressActionLabel: canExitEarly ? 'Done' : null,
          onProgressAction: canExitEarly ? _close : null,
        );
      },
    );
  }

  (String, String?) _labelsFor(TransferArtworkState state) {
    return switch (state) {
      TransferSuccess() => ('Artwork transferred', null),
      TransferSigning() => (kExternalSigningLabel, kExternalSigningSublabel),
      // Multi-chain: Solana lands in a slot or two, EVM doesn't.
      TransferBroadcasting() => (
        kConfirmingLabel,
        confirmingSublabelForChain(widget.chain),
      ),
      TransferError(:final message) => ('Transfer failed', message),
      _ => ('Working…', null),
    };
  }
}
