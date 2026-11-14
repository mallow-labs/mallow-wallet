import 'package:flutter/widgets.dart' show StringCharacters;

// How a sign-in key's label is drawn.
//
// A label is written by whoever holds a key of the vault, on any device and
// through any client, and this app shows it inside its own rows and
// sentences. So before it is drawn it is made one line of plain text: it
// cannot break a row, push the words after it off the screen, or reorder
// them.

/// Whether [rune] is a character a label never shows: a C0 or C1 control
/// (line breaks and tabs among them), one of the Unicode controls that
/// change the direction the text around them is drawn in, or half of a
/// surrogate pair on its own, which is no character at all.
bool isSignInKeyLabelControl(int rune) =>
    rune <= 0x1F ||
    (rune >= 0x7F && rune <= 0x9F) ||
    rune == 0x061C ||
    rune == 0x200E ||
    rune == 0x200F ||
    (rune >= 0x202A && rune <= 0x202E) ||
    (rune >= 0x2066 && rune <= 0x2069) ||
    (rune >= 0xD800 && rune <= 0xDFFF);

/// The characters that end a line or stand for a gap. Each becomes a space,
/// so words pasted on two lines do not run together.
bool _isLineBreakOrTab(int rune) =>
    (rune >= 0x09 && rune <= 0x0D) ||
    rune == 0x85 ||
    rune == 0x2028 ||
    rune == 0x2029;

/// [label] with every line break and tab turned into a space, and every other
/// character [isSignInKeyLabelControl] names dropped.
String stripSignInKeyLabelControls(String label) {
  final out = StringBuffer();
  for (final rune in label.runes) {
    if (_isLineBreakOrTab(rune)) {
      out.write(' ');
    } else if (!isSignInKeyLabelControl(rune)) {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// [label] as one line of display text: controls stripped, each run of white
/// space made a single space, the ends trimmed.
String signInKeyLabelOnOneLine(String label) =>
    stripSignInKeyLabelControls(label).replaceAll(RegExp(r'\s+'), ' ').trim();

/// [text] cut to [max] characters, as a reader counts them, with an ellipsis
/// in place of what was cut. For a label inside a sentence or a title, where
/// no widget can shorten it on its own.
String ellipsizeSignInKeyLabel(String text, int max) {
  final characters = text.characters;
  if (characters.length <= max) return text;
  return '${characters.take(max).toString().trimRight()}…';
}
