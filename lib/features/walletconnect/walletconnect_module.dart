import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/environment.dart';
import '../../core/config/remote_config_service.dart';
import '../../core/crypto/wallet_manager.dart';
import '../../core/models/account.dart' show WalletInfo;
import '../../core/network/tezos_rpc_service.dart';
import '../../core/observability/app_logger.dart';
import '../../core/router/app_router.dart';
import '../../core/security/app_lock_bloc.dart';
import '../../core/services/wallet_repository.dart';
import '../../core/session/session_manager.dart';
import '../../di.dart';
import '../../shared/utils/chain.dart';
import '../../shared/widgets/app_snack_bar.dart';
import '../browser/services/browser_signing_service.dart';
import '../browser/services/ethereum_dapp_adapter.dart';
import '../browser/services/tezos_dapp_adapter.dart';
import '../browser/widgets/browser_wallet_picker.dart';
import 'services/walletconnect_client.dart';
import 'services/walletconnect_service.dart';
import 'services/walletconnect_uri.dart';
import 'widgets/walletconnect_proposal_sheet.dart';

/// Plugs WalletConnect into the app: the service, its lock and wallet
/// listeners, and the relay reconnect for a device that has paired before.
///
/// Called once from the app bootstrap, after `configureDependencies()` and
/// before the app starts, so a cold-start `wc:` link finds the service. Does
/// nothing when the build has no `WALLETCONNECT_PROJECT_ID`, and never
/// throws: a throw here would replace the app with the startup error screen.
void registerWalletConnectModule() {
  if (WalletConnectService.instance != null) return;
  final projectId = Config.walletConnectProjectId;
  if (projectId.isEmpty) return;
  try {
    final appLock = sl<AppLockBloc>();
    final sessionManager = sl<SessionManager>();
    final remote = sl<RemoteConfigService>();
    final ethereum = EthereumDappAdapter(walletManager: sl<WalletManager>());
    final tezos = TezosDappAdapter(
      walletManager: sl<WalletManager>(),
      rpc: sl<TezosRpcService>(),
    );
    bool unlocked() =>
        appLock.state is AppLockStateUnlocked ||
        appLock.state is AppLockStateNoPinSet;
    final service = WalletConnectService(
      projectId: projectId,
      createClient: () => ReownWalletConnectClient(
        projectId: projectId,
        metadata: WalletConnectService.metadata,
      ),
      presenter: _RootPresenter(sessionManager),
      deviceWallets: () => sl<WalletRepository>().getAllWallets(),
      sessionWallets: () => sessionManager.sessionWallets,
      attended: () =>
          unlocked() &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          AppRoutes.rootNavigatorKey.currentContext != null,
      unattendedReason: () {
        if (!unlocked()) return 'app locked';
        final state = WidgetsBinding.instance.lifecycleState;
        if (state != AppLifecycleState.resumed) {
          return 'app ${state?.name ?? 'state unknown'}';
        }
        return 'no screen';
      },
      // A request already in review survives the brief background of an
      // external signer, but never the lock.
      canContinue: unlocked,
      enabled: () => remote.config.value.browserEnabled,
      sign: (context, request) => BrowserSigningService(
        ethereumAdapter: ethereum,
        tezosAdapter: tezos,
        openExternal: (url) =>
            launchUrl(url, mode: LaunchMode.externalApplication),
      ).execute(context, request),
      tezosPublicKey: (wallet, active, cancelled) => tezos.publicKey(
        wallet.id,
        wallet.address,
        active,
        cancelled: cancelled,
      ),
      allowDevnet: !Config.isProduction,
    );
    WalletConnectService.instance = service;
    appLock.stream.listen((state) {
      if (state is AppLockStateLocked) service.cancelActive();
      service.attendedChanged();
    });
    sessionManager.addListener(() => unawaited(service.walletsChanged()));
    unawaited(service.start());
  } catch (e, st) {
    AppLogger.error('WalletConnectModule', 'Registration failed', e, st);
  }
}

/// Takes a `wc:` link (or this app's wrapper of one) from a QR code, a
/// paste, a deep link or a page in the in-app browser. Returns whether
/// [uri] was a WalletConnect link at all, so the caller drops it either way:
/// such a link holds a pairing key and must go nowhere else.
bool handleWalletConnectLink(Uri uri) =>
    handleWalletConnectText(uri.toString());

/// Whether [text] is a WalletConnect link, valid or not, which must go to
/// [handleWalletConnectText] or nowhere.
bool isWalletConnectText(String text) {
  final trimmed = text.trim();
  return trimmed.startsWith('wc:') ||
      WalletConnectUri.isWrapper(Uri.tryParse(trimmed) ?? Uri());
}

/// As [handleWalletConnectLink], for text that may not parse as a [Uri].
bool handleWalletConnectText(String text) {
  if (!isWalletConnectText(text)) return false;
  final trimmed = text.trim();
  final parsed = WalletConnectUri.tryParse(trimmed);
  final service = WalletConnectService.instance;
  if (service == null) {
    // The `wc` scheme is registered in every build, so say why nothing
    // happens rather than open the app to nothing.
    final context = AppRoutes.rootNavigatorKey.currentContext;
    if (context != null && context.mounted) {
      AppSnackBar.show(
        context,
        'WalletConnect is not available in this version of mallow',
        type: AppSnackBarType.error,
      );
    }
    return true;
  }
  if (parsed == null) {
    service.presenter.showMessage(
      'This WalletConnect link is invalid or has expired',
      error: true,
    );
    return true;
  }
  unawaited(service.pair(parsed));
  return true;
}

class _RootPresenter implements WalletConnectPresenter {
  _RootPresenter(this._session);
  final SessionManager _session;

  @override
  BuildContext? get context => AppRoutes.rootNavigatorKey.currentContext;

  @override
  Future<Map<String, WalletInfo>?> approveProposal(
    WalletConnectProposal proposal,
  ) async {
    final context = this.context;
    // Thrown, not null: null is the user's "Not now", and this is no answer.
    if (context == null || !context.mounted) throw StateError('no screen');
    return showWalletConnectProposalSheet(
      context,
      proposal,
      pickWallet: (context, chain, current) =>
          _pickWallet(context, chain, current, proposal.origin.host),
    );
  }

  /// The browser's own picker, in its connect mode: every wallet on the
  /// device for [chain], grouped by Account or Profile. The pick only binds
  /// this session; unlike the browser, the app's active wallet stays put.
  Future<WalletInfo?> _pickWallet(
    BuildContext context,
    Chain chain,
    WalletInfo current,
    String host,
  ) async {
    final result = await showBrowserWalletPicker(
      context: context,
      selected: chain == Chain.solana ? current : null,
      selectedEthereum: chain == Chain.ethereum ? current : null,
      selectedTezos: chain == Chain.tezos ? current : null,
      profileMode: _session.isProfileMode,
      activeAccountId: _session.activeAccount?.id,
      activeProfileId: _session.activeProfile?.userId,
      host: host,
      connectMode: true,
      onlyChain: chain,
    );
    return result is BrowserWalletPicked ? result.wallet : null;
  }

  @override
  void showMessage(String message, {bool error = false}) {
    final context = this.context;
    if (context == null || !context.mounted) return;
    AppSnackBar.show(
      context,
      message,
      type: error ? AppSnackBarType.error : AppSnackBarType.info,
    );
  }
}
