import 'package:flutter/services.dart';
import 'package:solana/base58.dart' show base58decode;

import '../utils/address_format.dart';

/// Security utilities for the wallet app.
///
/// Provides:
/// - Clipboard management (expiring writes, clear, read helpers)
/// - Address / mnemonic format validation
///
/// Screenshot blocking and root/jailbreak detection are deliberately **not**
/// provided: iOS has no `FLAG_SECURE` equivalent, so the two platforms could
/// never reach parity, and shipping asymmetric half-protection was judged
/// worse than being explicit about the gap.
class SecurityUtils {
  const SecurityUtils._();

  // Platform channel for native security features
  static const _channel = MethodChannel('mallow_wallet/security');

  /// Copy text to clipboard with an OS-enforced expiration.
  ///
  /// Use this for copying seed phrases or addresses. The clipboard entry
  /// is cleared by the OS after [clearAfter], regardless of whether the
  /// app is foregrounded, backgrounded, or terminated.
  ///
  /// iOS: `UIPasteboard.setItems(_:options:)` with `expirationDate`
  /// (also `localOnly: true` so the value does not propagate via
  /// Universal Clipboard to other Apple devices).
  ///
  /// Android: there is no per-clip OS expiration API. The clip is marked
  /// sensitive (API 33+ `ClipDescription.EXTRA_IS_SENSITIVE` plus the
  /// legacy OEM-honored key) so the system suppresses on-screen previews
  /// and contributes to its own auto-clear behavior. A Dart-side Timer
  /// is intentionally not used as a fallback because it does not fire
  /// when the process is suspended.
  static Future<void> copyToClipboardWithClear(
    String text, {
    Duration clearAfter = const Duration(minutes: 1),
  }) async {
    try {
      await _channel.invokeMethod('copyToClipboardWithExpiration', {
        'text': text,
        'expirationSeconds': clearAfter.inMilliseconds / 1000.0,
      });
      return;
    } on MissingPluginException {
      // Native channel not wired (e.g. unit tests). Fall through to a
      // plain clipboard write so existing call sites still copy.
    } on PlatformException {
      // Native call failed; surface a best-effort copy.
    }

    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Clear the clipboard immediately.
  static Future<void> clearClipboard() async {
    try {
      await _channel.invokeMethod('clearClipboard');
      return;
    } on MissingPluginException {
      // Fall through.
    } on PlatformException {
      // Fall through.
    }
    await Clipboard.setData(const ClipboardData(text: ''));
  }

  /// Check if clipboard contains a valid Solana address.
  static Future<bool> clipboardHasSolanaAddress() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null) return false;

    return isValidSolanaAddress(text);
  }

  /// Get text from clipboard.
  static Future<String?> getClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  /// Whether [text] is a real Solana public key: base58 that **decodes** to
  /// exactly 32 bytes.
  ///
  /// [isLikelySolanaAddress] is only a 32–44-char base58 *character-class*
  /// heuristic — its job is routing (address vs mallow username), not
  /// validation. Plenty of strings pass it and decode to 31 or 33 bytes, so a
  /// single mistyped character used to clear the form gate and fail late:
  /// after biometric auth on a send, or permanently on-chain for a royalty
  /// creator. Mirrors the webapp's `isPublicKey` (umi) / `new PublicKey()`
  /// guards, which are likewise a decode.
  ///
  /// Deliberately **not** an on-curve check — the webapp doesn't do one either,
  /// and PDAs are legitimate recipients for some flows.
  static bool isValidSolanaAddress(String text) {
    if (!isLikelySolanaAddress(text)) return false;
    try {
      return base58decode(text).length == 32;
    } on Object catch (_) {
      return false;
    }
  }

  /// Validate if a string looks like a valid BIP39 mnemonic.
  ///
  /// This is a basic check for word count (12 or 24).
  /// Full validation should be done with the bip39 package.
  static bool isValidMnemonicFormat(String text) {
    final words = text.trim().split(RegExp(r'\s+'));
    return words.length == 12 || words.length == 24;
  }
}
