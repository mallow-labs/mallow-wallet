import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/environment.dart';
import 'social_vault_crypto.dart';

/// What a completed Apple web sign-in yields: the ID token, and the raw nonce
/// whose SHA-256 that token carries.
///
/// Hand-written with a redacted [toString]: the token is a credential.
class AppleWebCredential {
  const AppleWebCredential({required this.idToken, required this.rawNonce});

  final String idToken;
  final String rawNonce;

  @override
  String toString() => 'AppleWebCredential(<redacted>)';
}

/// The Apple web sign-in could not be started, or Apple's answer was not one
/// this request can accept. The message never carries anything from the
/// answer.
class AppleWebSignInException implements Exception {
  const AppleWebSignInException(this.message);

  final String message;

  @override
  String toString() => 'AppleWebSignInException: $message';
}

/// Sign in with Apple where there is no native sheet (Android): Apple's web
/// flow in a browser tab, answered through a verified App Link.
///
/// The round trip:
///
/// 1. [signIn] opens Apple's authorize page in a Custom Tab, with a random
///    `state` and the SHA-256 of a random nonce.
/// 2. Apple form-posts the result to the backend's relay (`redirect_uri`),
///    which answers with a redirect to the site's `/auth/apple` page, the
///    fields in the URL **fragment** — so that a browser which opens that
///    page instead of the app sends them to no server.
/// 3. Android hands that `https` link to this app — and only to an app whose
///    signing certificate the site's `assetlinks.json` lists for its package.
///    `DeepLinkService` passes it to [handleReturn] before anything else
///    looks at it.
///
/// What an answer must be to be accepted, since anything able to start an
/// activity can still put a link in front of the app:
///
/// - a sign-in this app instance started must be waiting. With none, the link
///   is dropped: a cold start, a duplicate, a late answer.
/// - its `state` must be that request's (compared in constant time). Any
///   other link is dropped *without ending the request*, so a forged link
///   cannot cancel a sign-in in progress.
/// - the ID token's `nonce` claim must be the hash this request sent. The
///   token's payload is decoded for this one comparison and nothing else —
///   the backend does all verification — and it is what stops a substituted
///   token even from someone who learned the `state`.
///
/// Nothing from the link is logged, routed or stored, here or in the caller.
///
/// The request ends without an answer after [timeout], or [returnGrace] after
/// the app is back in front with the tab gone, so a sign-in menu never waits
/// on a tab the user closed.
@lazySingleton
class AppleWebSignIn {
  AppleWebSignIn({
    @visibleForTesting Future<bool> Function(Uri uri)? launch,
    @visibleForTesting this.timeout = const Duration(minutes: 5),
    @visibleForTesting this.returnGrace = const Duration(seconds: 5),
  }) : _launch = launch ?? _launchInTab;

  @factoryMethod
  static AppleWebSignIn forInjection() => AppleWebSignIn();

  /// The path of the site's return page, which the app claims as an App Link.
  static const returnPath = '/auth/apple';

  /// How long a request waits for Apple's answer.
  final Duration timeout;

  /// How long a request still waits once the app is back in the foreground.
  /// The answer's link is delivered just before the app resumes, so this only
  /// has to cover the hand-over, not the user.
  final Duration returnGrace;

  final Future<bool> Function(Uri uri) _launch;

  _PendingRequest? _pending;

  /// Whether a sign-in is waiting for Apple's answer.
  @visibleForTesting
  bool get isPending => _pending != null;

  /// A Custom Tab where a browser offers one, else the browser itself — and
  /// never the launcher's embedded web view, which it falls back to when
  /// asked for a tab that no browser provides. A web view inside the app is
  /// the wrong place to type an Apple ID password, and a link opened in one
  /// is not handed to any app, so the answer could never come back.
  static Future<bool> _launchInTab(Uri uri) async {
    final tab = await supportsLaunchMode(LaunchMode.inAppBrowserView);
    return launchUrl(
      uri,
      mode: tab ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication,
    );
  }

  /// Apple's authorize page for one request.
  ///
  /// `response_mode=form_post` is what Apple requires once a scope is asked
  /// for, and the only scope asked for is the email — the same as the native
  /// sheet on iOS. [nonceHash] is the SHA-256 of the raw nonce: Apple copies
  /// it into the ID token as is.
  @visibleForTesting
  static Uri authorizeUri({
    required String clientId,
    required String redirectUri,
    required String state,
    required String nonceHash,
  }) => Uri(
    scheme: 'https',
    host: 'appleid.apple.com',
    path: '/auth/authorize',
    queryParameters: <String, String>{
      'response_type': 'code id_token',
      'response_mode': 'form_post',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': 'email',
      'state': state,
      'nonce': nonceHash,
    },
  );

  /// What Apple is sent for a raw nonce: its SHA-256, lowercase hex.
  static String nonceHash(String rawNonce) =>
      crypto.sha256.convert(utf8.encode(rawNonce)).toString();

  /// Run the web flow. Null when the user cancels, closes the tab, or no
  /// answer arrives in time; [AppleWebSignInException] when the tab cannot
  /// be opened or the answer is refused.
  ///
  /// A request still waiting when this is called is ended first: one tab, one
  /// request.
  Future<AppleWebCredential?> signIn() async {
    _finish(_pending, null);
    final state = SocialVaultCrypto.base64UrlNoPad(
      SocialVaultCrypto.randomBytes(16),
    );
    final rawNonce = SocialVaultCrypto.base64UrlNoPad(
      SocialVaultCrypto.randomBytes(32),
    );
    final request = _PendingRequest(
      state: state,
      rawNonce: rawNonce,
      nonceHash: nonceHash(rawNonce),
    );
    request.timer = Timer(timeout, () => _finish(request, null));
    _pending = request;

    // Apple's servers call the relay, not the app: it is a redirect target,
    // not one of the API operations this app calls, so its URL is built from
    // the base here and not through the API client.
    final v2Base = Config.apiV2BaseUrl;
    final uri = authorizeUri(
      clientId: Config.appleServicesId,
      redirectUri: '$v2Base/social-vault/apple/callback',
      state: state,
      nonceHash: request.nonceHash,
    );
    var launched = false;
    try {
      launched = await _launch(uri);
    } catch (_) {
      launched = false;
    }
    if (!launched) {
      _finish(request, null);
      throw const AppleWebSignInException('could not open Apple sign-in');
    }
    return request.completer.future;
  }

  /// Take the answer to a sign-in out of the App Link [uri], whose fragment
  /// carries the fields Apple posted. The caller has established that [uri]
  /// is the return link; from here it is consumed whatever it holds, and
  /// nothing from it is logged.
  void handleReturn(Uri uri) {
    final request = _pending;
    if (request == null) return;
    final Map<String, String> fields;
    try {
      fields = Uri.splitQueryString(uri.fragment);
    } catch (_) {
      return;
    }
    final state = fields['state'];
    if (state == null || !_constantTimeEquals(state, request.state)) return;

    // This request's answer. Whatever it says, the request is over: a state
    // is good for one answer.
    if (fields.containsKey('error')) {
      // The user backed out at Apple's page, or Apple refused the request.
      _finish(request, null);
      return;
    }
    final idToken = fields['id_token'];
    if (idToken == null || idToken.isEmpty) {
      _fail(request, 'Apple returned no ID token');
      return;
    }
    if (!idTokenCarriesNonce(idToken, request.nonceHash)) {
      _fail(request, 'Apple sign-in answered a different request');
      return;
    }
    _finish(
      request,
      AppleWebCredential(idToken: idToken, rawNonce: request.rawNonce),
    );
  }

  /// The app left the foreground: the tab is up.
  void appPaused() => _pending?.leftApp = true;

  /// The app is in the foreground again, which — with a request waiting —
  /// means the tab is gone: Android closed it to deliver the answer, or the
  /// user closed it. An answer arrives with the resume; without one by
  /// [returnGrace], the user closed the tab.
  void appResumed() {
    final request = _pending;
    if (request == null || !request.leftApp) return;
    request.graceTimer ??= Timer(returnGrace, () => _finish(request, null));
  }

  /// Whether the JWT [idToken] carries [nonceHash] as its `nonce` claim.
  /// Reads the payload only, and only that claim; a token that cannot be read
  /// does not carry it.
  @visibleForTesting
  static bool idTokenCarriesNonce(String idToken, String nonceHash) {
    try {
      final parts = idToken.split('.');
      if (parts.length != 3) return false;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map) return false;
      final nonce = payload['nonce'];
      return nonce is String && _constantTimeEquals(nonce, nonceHash);
    } catch (_) {
      return false;
    }
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  void _finish(_PendingRequest? request, AppleWebCredential? credential) {
    if (request == null || !_release(request)) return;
    request.completer.complete(credential);
  }

  void _fail(_PendingRequest request, String message) {
    if (!_release(request)) return;
    request.completer.completeError(AppleWebSignInException(message));
  }

  /// Stop [request]'s timers and, when it is the one waiting, stop waiting.
  /// False when it was already answered.
  bool _release(_PendingRequest request) {
    request.timer?.cancel();
    request.graceTimer?.cancel();
    if (identical(_pending, request)) _pending = null;
    return !request.completer.isCompleted;
  }
}

class _PendingRequest {
  _PendingRequest({
    required this.state,
    required this.rawNonce,
    required this.nonceHash,
  });

  final String state;
  final String rawNonce;
  final String nonceHash;
  final Completer<AppleWebCredential?> completer =
      Completer<AppleWebCredential?>();
  Timer? timer;
  Timer? graceTimer;

  /// Whether the app left the foreground since the tab was opened.
  bool leftApp = false;
}
