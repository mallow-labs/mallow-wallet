import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/shared/utils/utf8_byte_limit.dart';

// The mint form's title/description caps exist to keep mobile and the webapp
// accepting the same input. The webapp counts `Buffer.from(value).length` —
// UTF-8 bytes — so a character-based cap on mobile let a creator submit a
// 32-emoji (128-byte) title the webapp refuses at 8 characters, and the
// "characters remaining" counters disagreed across the two clients for any
// non-ASCII text.
void main() {
  group('utf8ByteLength', () {
    test('counts bytes, not UTF-16 code units', () {
      expect(utf8ByteLength('abc'), 3);
      // 'é' is 2 bytes; Dart's String.length reports 1.
      expect(utf8ByteLength('é'), 2);
      // An emoji outside the BMP is 4 bytes; String.length reports 2.
      expect('🎨'.length, 2);
      expect(utf8ByteLength('🎨'), 4);
      expect(utf8ByteLength('🎨' * 32), 128);
    });
  });

  group('Utf8ByteLimitingTextInputFormatter', () {
    const formatter = Utf8ByteLimitingTextInputFormatter(32);

    TextEditingValue v(String text) => TextEditingValue(text: text);

    test('accepts input at or under the byte budget', () {
      expect(formatter.formatEditUpdate(v(''), v('a' * 32)).text, 'a' * 32);
      // 8 emoji = 32 bytes: the exact point the webapp stops accepting more.
      expect(formatter.formatEditUpdate(v(''), v('🎨' * 8)).text, '🎨' * 8);
    });

    test(
      'rejects input over the byte budget even when short in characters',
      () {
        // 9 emoji = 36 bytes but only 18 UTF-16 code units — a character-based
        // cap of 32 would have waved this through.
        final result = formatter.formatEditUpdate(v('🎨' * 8), v('🎨' * 9));
        expect(result.text, '🎨' * 8);
      },
    );

    test('drops the whole edit rather than truncating mid-code-point', () {
      // Webapp parity: `if (Buffer.from(value).length > 32) return;` leaves the
      // field untouched. Truncating by bytes could split a multi-byte glyph.
      final result = formatter.formatEditUpdate(v('hello'), v('🎨' * 20));
      expect(result.text, 'hello');
    });
  });
}
