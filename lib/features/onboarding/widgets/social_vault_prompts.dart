import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/router/auth_state_notifier.dart';
import '../../../core/security/reauth_gate.dart';
import '../../../core/services/social_auth_service.dart';
import '../../../di.dart';
import '../../../shared/utils/social_wallet_copy.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/choice_sheet.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../social_vault/services/social_sign_in_routing.dart';
import '../../social_vault/widgets/social_vault_notice_sheet.dart';
import '../../social_vault/widgets/social_vault_notices.dart';

/// The social-vault questions and notices, shown on the root navigator — so
/// they appear whichever screen the sign-in started from, and after that
/// screen is gone.
///
/// A question asked while a sign-in is still running is shown at once: the
/// sign-in waits for its answer. A notice that follows a sign-in is not. The
/// app is then on its way to another screen, and whatever is pushed before it
/// gets there is removed with the screen it left; so a notice waits for
/// [SocialSignInRouting.settled], and is not shown at all while the app-lock
/// setup of onboarding is still ahead (see [reviewVault]).
class AppSocialVaultPrompts
    implements SocialVaultPrompts, SocialVaultKeyReplacedPrompt {
  const AppSocialVaultPrompts();

  BuildContext? get _context => AppRoutes.rootNavigatorKey.currentContext;

  /// Whether the user has a wallet but has not yet finished setting up the
  /// app lock. False where the app's sign-in state is not available at all.
  static bool get _settingUpAppLock =>
      sl.isRegistered<AuthStateNotifier>() &&
      !sl<AuthStateNotifier>().hasCompletedOnboarding;

  /// Where a notice can be shown, once the app has arrived where a sign-in
  /// (if one is being routed for) takes it. Null when there is no screen to
  /// show it on — which is not waited for.
  Future<BuildContext?> _noticeContext() async {
    if (_context == null) return null;
    await SocialSignInRouting.instance.settled();
    final context = _context;
    return context != null && context.mounted ? context : null;
  }

  /// The pending "check again once onboarding is done": its listener, and
  /// what it listens to.
  static ({VoidCallback listener, Listenable auth, Listenable router})?
  _afterOnboarding;

  /// Run the vault check an unlock runs, once, when onboarding is finished
  /// and Home is on screen: the first moment a notice held back during
  /// onboarding can be shown without standing between the user and the
  /// app-lock setup. Without this it would wait for the next unlock or
  /// return to the app, which a pending deletion of the backup should not.
  static void _checkVaultsAfterOnboarding(BuildContext context) {
    final auth = sl<AuthStateNotifier>();
    // Without a router there is no Home to wait for: the next unlock asks.
    final delegate = GoRouter.maybeOf(context)?.routerDelegate;
    if (delegate == null) return;
    final waiting = _afterOnboarding;
    if (waiting != null) {
      if (identical(waiting.router, delegate)) return;
      // The router was rebuilt: the old one will never reach Home.
      waiting.auth.removeListener(waiting.listener);
      waiting.router.removeListener(waiting.listener);
    }
    late final VoidCallback listener;
    listener = () {
      if (!auth.hasCompletedOnboarding) return;
      if (delegate.currentConfiguration.uri.path != AppRoutes.home) return;
      auth.removeListener(listener);
      delegate.removeListener(listener);
      _afterOnboarding = null;
      // Home has only been asked for: let it reach the screen first.
      unawaited(
        SocialSignInRouting.navigationApplied().then(
          (_) => sl<SocialAuthService>().checkVaults(),
        ),
      );
    };
    _afterOnboarding = (listener: listener, auth: auth, router: delegate);
    auth.addListener(listener);
    delegate.addListener(listener);
  }

  static String _name(String provider) =>
      provider == 'apple' ? 'Apple' : 'Google';

  @override
  Future<bool> offerPasskey(String provider) async {
    final context = _context;
    if (context == null || !context.mounted) return false;
    final yes = await showConfirmSheet(
      context,
      title: 'Add a passkey?',
      message:
          'A passkey lets you open this wallet on the web and on your other '
          'devices, including ones that do not share this phone’s backup. '
          'Your ${_name(provider)} account alone can never open it.',
      confirmLabel: 'Add passkey',
      cancelLabel: 'Not now',
    );
    return yes ?? false;
  }

  @override
  Future<bool> reauthenticate() async {
    final context = _context;
    // Nowhere to ask is not a pass.
    if (context == null || !context.mounted) return false;
    return requireReauth(context);
  }

  @override
  Future<SocialVaultCreateChoice> confirmCreate({
    required String provider,
    String? emailHint,
    bool hasWalletHere = false,
    String? walletAccountEmail,
  }) async {
    final context = _context;
    // Nowhere to ask is not a yes.
    if (context == null || !context.mounted) {
      return SocialVaultCreateChoice.cancel;
    }
    final name = _name(provider);
    final choice = await showChoiceSheet<SocialVaultCreateChoice>(
      context,
      title: hasWalletHere ? 'This account has no wallet' : 'Create a wallet?',
      message: hasWalletHere
          ? noWalletForThisAccountMessage(
              name,
              emailHint,
              walletAccountEmail: walletAccountEmail,
            )
          : noWalletFoundMessage(name, emailHint),
      options: hasWalletHere
          ? const [
              ChoiceSheetOption(
                label: 'Use another account',
                value: SocialVaultCreateChoice.useAnotherAccount,
                variant: MallowButtonVariant.primary,
              ),
              ChoiceSheetOption(
                label: 'Create a new wallet',
                value: SocialVaultCreateChoice.create,
              ),
              ChoiceSheetOption(
                label: 'Cancel',
                value: SocialVaultCreateChoice.cancel,
                variant: MallowButtonVariant.text,
              ),
            ]
          : const [
              ChoiceSheetOption(
                label: 'Create wallet',
                value: SocialVaultCreateChoice.create,
                variant: MallowButtonVariant.primary,
              ),
              ChoiceSheetOption(
                label: 'Use another account',
                value: SocialVaultCreateChoice.useAnotherAccount,
              ),
              ChoiceSheetOption(
                label: 'Cancel',
                value: SocialVaultCreateChoice.cancel,
                variant: MallowButtonVariant.text,
              ),
            ],
    );
    // A dismissed sheet is a no.
    return choice ?? SocialVaultCreateChoice.cancel;
  }

  @override
  Future<bool> wrongAccount({
    required String provider,
    String? expectedEmail,
    String? signedInEmail,
  }) async {
    final context = _context;
    if (context == null || !context.mounted) return false;
    final again = await showConfirmSheet(
      context,
      title: 'Wrong account',
      message: wrongAccountMessage(
        _name(provider),
        expectedEmail: expectedEmail,
        signedInEmail: signedInEmail,
      ),
      confirmLabel: 'Use another account',
    );
    return again ?? false;
  }

  @override
  Future<void> backupIncomplete({required String provider}) async {
    final context = _context;
    if (context == null || !context.mounted) return;
    // What repairs it is the sign-in itself, run again: it stores this
    // device's copy of the backup and adds its keys once more. The Sign-in
    // keys screen has no retry for a wallet in this state.
    final name = _name(provider);
    AppSnackBar.show(
      context,
      'Your $name wallet is ready, but its backup did not finish. Sign in '
      'with the same $name account again to finish it.',
      type: AppSnackBarType.error,
    );
  }

  /// Shown only once the app has arrived where the sign-in (if one is
  /// running) takes it, and never during onboarding.
  ///
  /// During onboarding the user is on the app-lock setup, which they must
  /// finish. A notice there would stand in its way, its "Review sign-in
  /// keys" would lead to a screen the app does not open before the lock
  /// exists, and nothing may offer a way round that setup. So nothing is
  /// shown and nothing is recorded as seen: the same check runs again when
  /// onboarding is done and Home is on screen, and at every unlock after.
  @override
  Future<void> reviewVault(String vaultId) async {
    final context = await _noticeContext();
    if (context == null || !context.mounted) return;
    if (_settingUpAppLock) {
      _checkVaultsAfterOnboarding(context);
      return;
    }
    await showSocialVaultNotices(context, vaultId);
  }

  /// Say, once, that this device's sign-in key for a [provider] wallet was
  /// replaced on another device: the wallet still works here, and signing in
  /// again is what lets this device manage its backup again.
  ///
  /// True once the user has closed it; false when it could not be shown or
  /// the app removed it before it was answered, so it can be said again.
  @override
  Future<bool> signInKeyReplaced({required String provider}) async {
    final context = await _noticeContext();
    // Not during the app-lock setup: it is said at a later check.
    if (context == null || !context.mounted || _settingUpAppLock) return false;
    final name = _name(provider);
    final answer = await showSocialVaultNoticeSheet(
      context,
      title: 'Sign in again to manage your backup',
      lines: [signInKeyReplacedMessage(name)],
      confirmLabel: 'OK',
    );
    return answer != null;
  }

  @override
  Future<bool> backupNoLongerStored({required String provider}) async {
    final context = await _noticeContext();
    // Not during the app-lock setup, where Show secrets cannot be opened:
    // it is said at a later check.
    if (context == null || !context.mounted || _settingUpAppLock) return false;
    final view = await showSocialVaultNoticeSheet(
      context,
      title: 'About your ${_name(provider)} wallet',
      lines: const [backupNoLongerStoredMessage],
      confirmLabel: 'View recovery phrase',
      cancelLabel: 'OK',
    );
    // Seen, whichever way the user left the sheet. A sheet the app removed
    // was not left by the user: it is said again.
    if (view == null) return false;
    if (view && context.mounted) {
      // Not awaited: the push completes only when the screen is left again.
      // No pre-authenticated flag, so Show secrets asks for the PIN or
      // biometrics before it lists anything.
      unawaited(GoRouter.of(context).push(AppRoutes.recoveryPhrase));
    }
    return true;
  }

  @override
  Future<bool?> offerKeyReplacement() async {
    final context = await _noticeContext();
    // Not during the app-lock setup, where Sign-in keys cannot be opened:
    // it is offered at a later check.
    if (context == null || !context.mounted || _settingUpAppLock) return null;
    final replace = await showSocialVaultNoticeSheet(
      context,
      title: backupWasUnprotectedTitle,
      lines: const [backupWasUnprotectedMessage],
      confirmLabel: replaceSignInKeysLabel,
      cancelLabel: 'Dismiss',
    );
    // A dismissal drops the advice for good, so it has to be the user's. A
    // sheet the app removed was not shown, as far as its reader goes.
    if (replace == null) return null;
    if (!replace) return false;
    // Not awaited: the push completes only when the screen is left again. No
    // pre-authenticated flag, so the screen asks for the PIN or biometrics.
    if (context.mounted) {
      unawaited(GoRouter.of(context).push(AppRoutes.signInKeys));
    }
    return true;
  }
}
