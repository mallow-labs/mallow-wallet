import 'dart:convert';

import 'package:flutter/services.dart';

/// UTF-8 **byte** length of [value] — what the webapp's `Buffer.from(s).length`
/// measures, and what an on-chain metadata string actually costs.
///
/// Dart's `String.length` counts UTF-16 code units, so "🎨" reads as 2 there
/// and 4 here. The webapp's create form caps title/description on the byte
/// count (`Details`), so
/// character-based caps let mobile submit a name the webapp would refuse —
/// 32 emoji is 128 bytes.
int utf8ByteLength(String value) => utf8.encode(value).length;

/// Rejects any edit that would push the field past [maxBytes] UTF-8 bytes.
///
/// Mirrors the webapp's guard exactly: it drops the whole change rather than
/// truncating (`if (Buffer.from(e.target.value).length > 32) return;`), so a
/// pasted over-long string leaves the field untouched instead of landing a
/// half-clipped — possibly mid-code-point — value.
class Utf8ByteLimitingTextInputFormatter extends TextInputFormatter {
  const Utf8ByteLimitingTextInputFormatter(this.maxBytes);

  final int maxBytes;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (utf8ByteLength(newValue.text) <= maxBytes) return newValue;
    return oldValue;
  }
}
