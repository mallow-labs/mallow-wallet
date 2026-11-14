import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mallow_wallet/core/crypto/exceptions.dart';
import 'package:mallow_wallet/core/services/social_auth_service.dart';
import 'package:mallow_wallet/core/social_vault/social_identity.dart';
import 'package:mallow_wallet/core/social_vault/social_vault_service.dart';
import 'package:mallow_wallet/core/services/wallet_repository.dart'
    show DuplicateWalletException;
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/utils/social_wallet_copy.dart';
import 'package:mallow_wallet/shared/widgets/app_snack_bar.dart';
import 'package:mallow_wallet/shared/widgets/mallow_button.dart';
import 'package:mallow_wallet/shared/widgets/sheet_drag_handle.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shared bottom-sheet scaffold for the create / import wallet menus: the
/// Google / Apple social-sign-in buttons plus their in-flight state machine
/// (spinner, mutual disable, dismissal-blocking [PopScope]), with the
/// per-screen [title] and [otherOptions] slotted around them.
///
/// Those buttons always make (or open) a social vault wallet, never one from
/// the older sign-in. The sheet deliberately says nothing about that older
/// sign-in: it does not apply to a new wallet, and restoring an older one
/// goes through support.
///
/// The state machine lives here once so the two entry points (create + import)
/// can't drift, and the in-flight flag is cleared in a `finally`-style fallout
/// path so a sign-in closure that *throws* can never leave the sheet
/// permanently busy + undismissable.
class SocialSignInMenu extends StatefulWidget {
  const SocialSignInMenu({
    required this.title,
    required this.onGoogleSignIn,
    required this.onAppleSignIn,
    required this.otherOptions,
    super.key,
  });

  /// Leading title widget (rendered left-aligned above the buttons).
  final Widget title;

  /// Runs the Google social sign-in and resolves with its result, or null when
  /// the user cancels. Any other failure must *throw*: the sheet renders it as
  /// an error snack bar, and a closure that converted it to null would put the
  /// user back on an idle sheet with no idea why nothing happened. The sheet
  /// stays open with a spinner until this completes, then closes — so the user
  /// isn't left on a blank screen while the SDK launches the browser.
  final Future<SocialAuthResult?> Function() onGoogleSignIn;
  final Future<SocialAuthResult?> Function() onAppleSignIn;

  /// The non-social options (recovery phrase, private key, …) rendered below
  /// the divider, including any inter-button spacing. [busy] is true while a
  /// social sign-in is in flight so each option can disable itself.
  final List<Widget> Function(bool busy) otherOptions;

  @override
  State<SocialSignInMenu> createState() => _SocialSignInMenuState();
}

class _SocialSignInMenuState extends State<SocialSignInMenu> {
  /// Which social provider is currently signing in ('google' | 'apple'), or
  /// null when idle. Drives the per-button spinner and disables the others.
  String? _loadingProvider;

  /// Recognizers for the two legal links in the implicit-consent line. Built
  /// once and disposed with the state — creating them inline in [build] leaks
  /// one per rebuild.
  late final _termsRecognizer = TapGestureRecognizer()
    ..onTap = () => _launch('https://wallet.mallow.art/terms');
  late final _privacyRecognizer = TapGestureRecognizer()
    ..onTap = () => _launch('https://wallet.mallow.art/privacy');

  @override
  void dispose() {
    _termsRecognizer.dispose();
    _privacyRecognizer.dispose();
    super.dispose();
  }

  /// Opens [url] in the in-app browser (Custom Tabs on Android, Safari view
  /// controller on iOS).
  ///
  /// Deliberately does *not* gate on `canLaunchUrl`. That call answers "is a
  /// handler visible to this app", which Android 11+ package visibility can
  /// answer `false` for even when a browser is installed — so gating on it
  /// turned these two legal links into a silent no-op. Launch first, and fall
  /// back to an external browser if the in-app view is unavailable.
  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return;
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[SocialSignInMenu] could not open $url: $e');
    }
  }

  Future<void> _handleSocial(
    String provider,
    Future<SocialAuthResult?> Function() signIn,
  ) async {
    if (_loadingProvider != null) return;
    setState(() => _loadingProvider = provider);
    String? error;
    try {
      final result = await signIn();
      if (!mounted) return;
      if (result != null) {
        _close(result);
        return;
      }
      // Null means the user cancelled — `SocialAuthService` swallows only that
      // and rethrows every real failure — so it stays silent.
    } on DuplicateWalletException {
      // Permanent, not transient: the derived address is already held by an
      // hd/imported/ledger row, so retrying this provider can never succeed.
      // Name the wallet it collided with instead of a "try again" that can't.
      error =
          'This wallet was already added with a recovery phrase, private key '
          'or hardware wallet. Use that account instead.';
    } on SocialVaultUnlockException catch (e) {
      error = socialVaultUnlockMessage(e);
    } on SocialAccountMismatchException catch (e) {
      // A second, silent sign-in in the same flow answered as another
      // account. The message names the account and says nothing changed.
      error = e.message;
    } on SocialIdentityException {
      error =
          'This sign-in option is not available in this version of the app.';
    } catch (e) {
      // Logged, never rendered: the thrown reason can carry SDK/config
      // internals that mean nothing to the user.
      debugPrint('[SocialSignInMenu] $provider sign-in threw: $e');
      error = 'Could not sign in. Check your connection and try again.';
    }
    // Cancelled or failed — clear the spinner so the user can retry and
    // PopScope re-enables dismissal.
    if (!mounted) return;
    setState(() => _loadingProvider = null);
    if (error != null) {
      AppSnackBar.show(context, error, type: AppSnackBarType.error);
    }
  }

  /// Close this sheet with [result]: this sheet, and nothing else.
  ///
  /// A sign-in publishes its result before it returns here, and the app
  /// answers that by replacing the screen the sheet was opened from. The
  /// sheet goes with that screen, but it stays mounted until the transition
  /// to the new one has ended. `Navigator.pop` closes whatever is on top,
  /// and by then that is the new screen: the only page the app has, so
  /// popping it left the app showing nothing at all.
  void _close(SocialAuthResult result) {
    final route = ModalRoute.of(context);
    // Already on its way out. The navigator finishes that on its own.
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop(result);
    } else {
      // Something sits on top of the sheet: take the sheet out from under it.
      navigator.removeRoute(route);
    }
  }

  Widget _googleButton(bool busy) => MallowButton(
    label: 'Continue with Google',
    variant: MallowButtonVariant.secondary,
    svgAsset: 'assets/icons/google.svg',
    // The Google mark is multi-colour and must stay untinted per their
    // branding guidelines.
    svgUseOriginalColors: true,
    foregroundColor: context.mallowColors.textPrimary,
    isLoading: _loadingProvider == 'google',
    enabled: !busy || _loadingProvider == 'google',
    onPressed: () => _handleSocial('google', widget.onGoogleSignIn),
    isFullWidth: true,
  );

  Widget _appleButton(bool busy) => MallowButton(
    label: 'Continue with Apple',
    variant: MallowButtonVariant.secondary,
    svgAsset: 'assets/icons/apple.svg',
    // The asset's fill is hardcoded near-black, which disappears against the
    // dark-mode surface — tint it with the label colour instead.
    foregroundColor: context.mallowColors.textPrimary,
    isLoading: _loadingProvider == 'apple',
    enabled: !busy || _loadingProvider == 'apple',
    onPressed: () => _handleSocial('apple', widget.onAppleSignIn),
    isFullWidth: true,
  );

  @override
  Widget build(BuildContext context) {
    final busy = _loadingProvider != null;
    return PopScope(
      // Block back/drag dismissal while a sign-in is in flight so the sheet
      // stays put through the browser round-trip.
      canPop: !busy,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
        child: Container(
          decoration: BoxDecoration(
            color: context.mallowColors.bgSurface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(MallowTheme.popupRadius),
            ),
            boxShadow: [
              BoxShadow(
                color: context.mallowColors.shadow.withValues(alpha: 0.16),
                blurRadius: 24,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SheetDragHandle(bottomSpacing: 20),
                  Align(alignment: Alignment.centerLeft, child: widget.title),
                  const SizedBox(height: 24),
                  // Apple leads on iOS (platform-native expectation); Google
                  // leads everywhere else.
                  ...(defaultTargetPlatform == TargetPlatform.iOS
                      ? [
                          _appleButton(busy),
                          const SizedBox(height: 12),
                          _googleButton(busy),
                        ]
                      : [
                          _googleButton(busy),
                          const SizedBox(height: 12),
                          _appleButton(busy),
                        ]),
                  const SizedBox(height: 16),
                  // Divider with "or"
                  Row(
                    children: [
                      Expanded(
                        child: Divider(
                          color: context.mallowColors.dividerLight,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('or', style: MallowTheme.editorialSubhead),
                      ),
                      Expanded(
                        child: Divider(
                          color: context.mallowColors.dividerLight,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...widget.otherOptions(busy),
                  const SizedBox(height: 20),
                  // Terms
                  RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: MallowTheme.uiMeta.copyWith(
                        color: context.mallowColors.textSecondary,
                      ),
                      children: [
                        const TextSpan(
                          text: "By continuing, you agree to mallow's ",
                        ),
                        TextSpan(
                          text: 'Terms of Service',
                          style: TextStyle(color: context.mallowColors.accent),
                          recognizer: _termsRecognizer,
                        ),
                        const TextSpan(text: ' & '),
                        TextSpan(
                          text: 'Privacy Policy',
                          style: TextStyle(color: context.mallowColors.accent),
                          recognizer: _privacyRecognizer,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Why a social wallet cannot be opened or created on this device, in words
/// that say what to do about it.
String socialVaultUnlockMessage(SocialVaultUnlockException e) {
  if (e.platformStoreFull) {
    return 'This phone’s Google backup already holds as many mallow keys as '
        'it can. Remove sign-in keys you no longer use, or use a device that '
        'can add a passkey.';
  }
  if (e.platformTooOld) return androidTooOldForSocialWalletMessage;
  if (e.creating) {
    return 'Set a screen lock on this device first. Your wallet’s key is kept '
        'with end-to-end encryption, which needs one.';
  }
  if (e.hasPasskeySlots && !e.passkeysSupportedHere) {
    return 'This wallet opens with a passkey, which needs iOS 18 or later or '
        'Android 9 or later. Update this device, or sign in on the device you '
        'created the wallet on.';
  }
  if (e.hasPasskeySlots) {
    return 'No passkey for this wallet was found here. Use a device where you '
        'saved one, or open the wallet on the device you created it on.';
  }
  return 'This wallet can only be opened on the device you created it on, or '
      'one that shares its backup. Open it there and add a passkey under '
      'Settings, Sign-in keys.';
}
