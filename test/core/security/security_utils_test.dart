import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/security/security_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecurityUtils.isValidSolanaAddress', () {
    test('rejects empty/short input (paste-an-address guard)', () {
      expect(SecurityUtils.isValidSolanaAddress(''), isFalse);
      expect(SecurityUtils.isValidSolanaAddress('abc'), isFalse);
      expect(SecurityUtils.isValidSolanaAddress('a' * 31), isFalse);
    });

    test('rejects strings longer than 44 chars', () {
      expect(SecurityUtils.isValidSolanaAddress('1' * 45), isFalse);
    });

    test('accepts the wrapped-SOL mint (canonical 43-char base58)', () {
      expect(
        SecurityUtils.isValidSolanaAddress(
          'So11111111111111111111111111111111111111112',
        ),
        isTrue,
      );
    });

    test('rejects base58-illegal characters', () {
      const len32WithBadChar = '0123456789ABCDEFGHJKLMNPQRSTUVWX'; // 32 chars
      // The leading '0' is invalid in base58. Length is fine.
      expect(SecurityUtils.isValidSolanaAddress(len32WithBadChar), isFalse);
    });

    // The reason this is a decode and not a character-class check: a mistyped
    // character keeps the string inside the 32-44 base58 window while changing
    // how many bytes it decodes to. A "valid-looking" address that isn't 32
    // bytes used to clear the send form and the royalty-creator form, and fail
    // late — after biometric auth, or permanently in on-chain metadata.
    test('rejects base58 that decodes to the wrong byte length', () {
      // 32 valid base58 chars, but only ~23 bytes once decoded.
      expect(SecurityUtils.isValidSolanaAddress('A' * 32), isFalse);
      // 44 valid base58 chars whose leading 'z's overflow 32 bytes.
      expect(SecurityUtils.isValidSolanaAddress('z' * 44), isFalse);
    });

    test('accepts a real 32-byte pubkey, rejects a truncated one', () {
      const real = '9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM';
      expect(SecurityUtils.isValidSolanaAddress(real), isTrue);
      // Four characters short: still base58, still inside the 32-44 window
      // the old character-class heuristic accepted, but 29 bytes.
      expect(
        SecurityUtils.isValidSolanaAddress(real.substring(0, 40)),
        isFalse,
      );
    });
  });

  group('SecurityUtils.isValidMnemonicFormat', () {
    test('accepts canonical 12-word phrase', () {
      const m =
          'abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon about';
      expect(SecurityUtils.isValidMnemonicFormat(m), isTrue);
    });

    test('accepts canonical 24-word phrase', () {
      final words = List.filled(24, 'abandon').join(' ');
      expect(SecurityUtils.isValidMnemonicFormat(words), isTrue);
    });

    test('rejects 11, 13, 18, 23 — counts BIP39 does not allow', () {
      for (final n in [11, 13, 18, 23]) {
        final words = List.filled(n, 'abandon').join(' ');
        expect(
          SecurityUtils.isValidMnemonicFormat(words),
          isFalse,
          reason: 'word count $n should be rejected',
        );
      }
    });

    test('normalises leading/trailing whitespace and inner runs of spaces', () {
      // Padding around the 12 words is fine, and multiple spaces between
      // words collapse via the \s+ split.
      const m =
          '  abandon  abandon  abandon  abandon  abandon  abandon  '
          'abandon  abandon  abandon  abandon  abandon  about  ';
      expect(SecurityUtils.isValidMnemonicFormat(m), isTrue);
    });

    test('rejects empty string', () {
      expect(SecurityUtils.isValidMnemonicFormat(''), isFalse);
      expect(SecurityUtils.isValidMnemonicFormat('   '), isFalse);
    });
  });

  group('SecurityUtils.copyToClipboardWithClear', () {
    // Why: an in-process Dart Timer does not fire when the app is
    // backgrounded or suspended, so a seed copied within 60s of background
    // would never get cleared. The contract under test is that the work
    // is delegated to the native channel with an OS-enforced expiration —
    // not scheduled in-process.
    const securityChannel = MethodChannel('mallow_wallet/security');
    const platformClipboard = MethodChannel('flutter/platform');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    final calls = <MethodCall>[];
    final clipboardCalls = <MethodCall>[];

    setUp(() {
      calls.clear();
      clipboardCalls.clear();
      messenger.setMockMethodCallHandler(securityChannel, (call) async {
        calls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(platformClipboard, (call) async {
        clipboardCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(securityChannel, null);
      messenger.setMockMethodCallHandler(platformClipboard, null);
    });

    test('delegates to native copyToClipboardWithExpiration', () async {
      await SecurityUtils.copyToClipboardWithClear(
        'seed words here',
        clearAfter: const Duration(seconds: 30),
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'copyToClipboardWithExpiration');
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['text'], 'seed words here');
      expect(args['expirationSeconds'], 30.0);
    });

    test('does not write via flutter/platform Clipboard.setData when native '
        'channel handles it (no in-process Timer path taken)', () async {
      await SecurityUtils.copyToClipboardWithClear('seed');
      expect(
        clipboardCalls.where((c) => c.method == 'Clipboard.setData'),
        isEmpty,
        reason: 'Native expiration must be the only write path on success',
      );
    });
  });

  group('SecurityUtils.clearClipboard', () {
    const securityChannel = MethodChannel('mallow_wallet/security');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    test('delegates clearing to native channel', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(securityChannel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(securityChannel, null),
      );

      await SecurityUtils.clearClipboard();

      expect(calls.single.method, 'clearClipboard');
    });
  });

  group('SecurityUtils.clipboardHasSolanaAddress', () {
    // SystemChannels.platform uses JSONMethodCodec — must match here so the
    // test framework can decode the incoming call bytes correctly.
    const clipboardChannel = MethodChannel(
      'flutter/platform',
      JSONMethodCodec(),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void setClipboard(String? text) {
      messenger.setMockMethodCallHandler(clipboardChannel, (call) async {
        if (call.method == 'Clipboard.getData') {
          // Returning null simulates an empty/unavailable clipboard;
          // Clipboard.getData maps null result → null ClipboardData.
          return text != null ? {'text': text} : null;
        }
        return null;
      });
    }

    tearDown(() => messenger.setMockMethodCallHandler(clipboardChannel, null));

    test('returns true for a valid Solana address on the clipboard', () async {
      setClipboard('So11111111111111111111111111111111111111112');
      expect(await SecurityUtils.clipboardHasSolanaAddress(), isTrue);
    });

    test('returns false for an Ethereum address on the clipboard', () async {
      setClipboard('0x742d35Cc6634C0532925a3b844Bc454e4438f44e');
      expect(await SecurityUtils.clipboardHasSolanaAddress(), isFalse);
    });

    test('returns false for an empty string on the clipboard', () async {
      setClipboard('');
      expect(await SecurityUtils.clipboardHasSolanaAddress(), isFalse);
    });

    test('returns false when clipboard has no data', () async {
      setClipboard(null);
      expect(await SecurityUtils.clipboardHasSolanaAddress(), isFalse);
    });

    test('returns false for a partial address (too short)', () async {
      setClipboard('HN7cABqLq46Es1jh92dQQis');
      expect(await SecurityUtils.clipboardHasSolanaAddress(), isFalse);
    });
  });
}
