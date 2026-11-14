import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:injectable/injectable.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../config/environment.dart';
import '../observability/app_logger.dart';
import 'apple_web_sign_in.dart';
import 'social_vault_crypto.dart';

/// Google and Apple sign-in, reduced to the one thing the social vault needs
/// from them: a fresh OIDC **ID token**.
///
/// The ID token identifies the person to the backend, which verifies it
/// against the provider's keys and uses its issuer and subject to find the
/// vault. Nothing here uses an access token, a refresh token, a scope beyond
/// the email, or a server auth code (Apple's web flow on Android has to
/// request a `code` beside the ID token, and it is ignored), and nothing here
/// stores a token: each one is sent to the vault's `open` route once (the
/// backend accepts each ID token once) and dropped.
///
/// Google's SDK keeps its own sign-in session, which is what lets
/// [idToken] with `silent: true` re-issue a token without a sheet during key
/// recovery. That session is the provider's, inside its SDK; this app never
/// reads a token out of it except the ID token.
abstract interface class SocialIdentityProvider {
  /// A fresh ID token for [provider] (`google` or `apple`), or null when the
  /// user cancels. With [silent], tries a sign-in that shows no UI first and
  /// falls back to the interactive one when that fails — never silent-only.
  ///
  /// With [chooseAccount] the user is asked which account to use, even when
  /// the provider remembers one: for the moment the remembered account turned
  /// out to be the wrong one. It overrides [silent]. Google forgets its
  /// remembered account first; Apple has one account per device and shows its
  /// sheet as always.
  Future<String?> idToken(
    String provider, {
    bool silent = false,
    bool chooseAccount = false,
  });

  /// Whether [provider] is configured in this build.
  bool isConfigured(String provider);
}

class SocialIdentityException implements Exception {
  const SocialIdentityException(this.message);

  final String message;

  @override
  String toString() => 'SocialIdentityException: $message';
}

@LazySingleton(as: SocialIdentityProvider)
class PlatformSocialIdentityProvider implements SocialIdentityProvider {
  PlatformSocialIdentityProvider(this._appleWeb);

  static const _tag = 'SocialIdentity';

  /// Apple's web flow, for the platform with no native Apple sheet (Android).
  final AppleWebSignIn _appleWeb;

  Future<void>? _googleInit;

  /// The raw nonce whose SHA-256 the last Apple ID token carries. Held in
  /// memory only; never logged or stored.
  String? lastAppleRawNonce;

  /// Whether Apple's native sheet answered with the state this request sent.
  /// A missing state is refused too: Apple echoes it.
  @visibleForTesting
  static bool appleStateMatches({
    required String sent,
    required String? returned,
  }) => returned != null && returned == sent;

  @override
  bool isConfigured(String provider) => switch (provider) {
    'google' =>
      Config.googleServerClientId.isNotEmpty &&
          (!Platform.isIOS || Config.googleIosClientId.isNotEmpty),
    // iOS signs in natively with the app's own identity; Android runs Apple's
    // web flow, which needs the Services ID, the backend's relay and the
    // site's return page (an App Link the app claims).
    'apple' => Platform.isIOS || Config.appleServicesId.isNotEmpty,
    _ => false,
  };

  @override
  Future<String?> idToken(
    String provider, {
    bool silent = false,
    bool chooseAccount = false,
  }) {
    if (!isConfigured(provider)) {
      throw SocialIdentityException(
        '$provider sign-in is not configured in this build',
      );
    }
    return switch (provider) {
      'google' => _google(
        silent: silent && !chooseAccount,
        chooseAccount: chooseAccount,
      ),
      'apple' => _apple(),
      _ => throw SocialIdentityException('unknown provider "$provider"'),
    };
  }

  /// `initialize` must run exactly once per process before any other call.
  Future<void> _ensureGoogle() => _googleInit ??= GoogleSignIn.instance
      .initialize(
        clientId: Platform.isIOS ? Config.googleIosClientId : null,
        serverClientId: Config.googleServerClientId,
      )
      .catchError((Object e) {
        _googleInit = null;
        throw e;
      });

  Future<String?> _google({
    required bool silent,
    bool chooseAccount = false,
  }) async {
    await _ensureGoogle();
    final signIn = GoogleSignIn.instance;
    if (chooseAccount) {
      // Without this the SDK can hand back the account it remembers without
      // asking — the one that was just found to be the wrong one.
      try {
        await signIn.signOut();
      } catch (e) {
        AppLogger.info(_tag, 'Google sign-out failed: ${e.runtimeType}');
      }
    }
    if (silent) {
      try {
        final account = await signIn.attemptLightweightAuthentication();
        final token = account?.authentication.idToken;
        if (token != null && token.isNotEmpty) return token;
      } on GoogleSignInException catch (e) {
        AppLogger.info(_tag, 'silent Google sign-in unavailable: ${e.code}');
      }
    }
    try {
      final account = await signIn.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        throw const SocialIdentityException('Google returned no ID token');
      }
      return token;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw SocialIdentityException('Google sign-in failed: ${e.code.name}');
    }
  }

  /// Apple has no silent sign-in; every call shows the sheet (iOS) or the
  /// web flow (Android).
  Future<String?> _apple() => Platform.isIOS ? _appleNative() : _appleOnWeb();

  /// Android has no native Apple sign-in. [AppleWebSignIn] opens Apple's page
  /// in a browser tab and takes the answer from a verified App Link; it
  /// checks the answer's `state` and the token's nonce itself.
  Future<String?> _appleOnWeb() async {
    try {
      final credential = await _appleWeb.signIn();
      if (credential == null) return null;
      lastAppleRawNonce = credential.rawNonce;
      return credential.idToken;
    } on AppleWebSignInException catch (e) {
      throw SocialIdentityException('Apple sign-in failed: ${e.message}');
    }
  }

  /// The native sheet, through the sign-in plugin.
  Future<String?> _appleNative() async {
    // `state` ties the answer to this request, and an answer carrying another
    // one is refused. The nonce goes to Apple hashed, and Apple puts that
    // hash in the ID token; the raw value stays in memory.
    final state = SocialVaultCrypto.base64UrlNoPad(
      SocialVaultCrypto.randomBytes(16),
    );
    final rawNonce = SocialVaultCrypto.base64UrlNoPad(
      SocialVaultCrypto.randomBytes(32),
    );
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [AppleIDAuthorizationScopes.email],
        state: state,
        nonce: AppleWebSignIn.nonceHash(rawNonce),
      );
      if (!appleStateMatches(sent: state, returned: credential.state)) {
        throw const SocialIdentityException(
          'Apple sign-in answered a different request',
        );
      }
      lastAppleRawNonce = rawNonce;
      final token = credential.identityToken;
      if (token == null || token.isEmpty) {
        throw const SocialIdentityException('Apple returned no ID token');
      }
      return token;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      throw SocialIdentityException('Apple sign-in failed: ${e.code.name}');
    }
  }
}
