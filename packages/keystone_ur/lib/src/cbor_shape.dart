/// A strict, iterative pre-check of CBOR structure, run before any bytes reach
/// the recursive `cbor` package decoder.
///
/// Scanned QR codes are attacker-controlled. The `cbor` package decodes
/// nesting recursively, so a few kilobytes of `[[[[…]]]]` take seconds and end
/// in a stack overflow. Every type this package reads nests at most five
/// levels, so anything deeper is rejected here in linear time, together with
/// the other things no Keystone encoder produces: indefinite lengths, reserved
/// header values, duplicate integer map keys, lengths that overrun the input,
/// and trailing bytes.
///
/// Returns null when [bytes] is exactly one well-formed, definite-length item
/// no deeper than [maxDepth]; otherwise a short reason.
String? cborShapeError(List<int> bytes, {int maxDepth = 8}) {
  // Items still expected at each open array/map level.
  final remaining = <int>[];
  // A set per map preserves integer keys before cborDecode collapses them.
  // The major type distinguishes unsigned and negative integers, including
  // 64-bit arguments represented by signed Dart ints. Arrays have no set.
  final integerKeys = <Set<(int, int)>?>[];
  var i = 0;
  var topLevelItems = 0;
  var tagRun = 0;
  while (i < bytes.length) {
    if (remaining.isEmpty && topLevelItems == 1) return 'trailing bytes';
    final b = bytes[i++];
    final major = b >> 5;
    final ai = b & 0x1F;
    int arg;
    if (ai < 24) {
      arg = ai;
    } else if (ai <= 27) {
      final n = 1 << (ai - 24);
      if (i + n > bytes.length) return 'truncated';
      arg = 0;
      for (var k = 0; k < n; k++) {
        arg = (arg << 8) | bytes[i++];
      }
      // A 64-bit argument above 2^63 reads negative here; no length or tag
      // this package accepts is anywhere near that.
      if (arg < 0 && major != 0 && major != 1 && major != 7) return 'length out of range';
    } else if (ai == 31) {
      return 'indefinite length';
    } else {
      return 'reserved header';
    }

    if (remaining.isNotEmpty &&
        remaining.last.isEven &&
        tagRun == 0 &&
        (major == 0 || major == 1)) {
      final keys = integerKeys.last;
      if (keys != null && !keys.add((major, arg))) return 'duplicate map key';
    }

    var completesItem = true;
    switch (major) {
      case 0 || 1:
        break;
      case 2 || 3:
        if (arg > bytes.length - i) return 'truncated';
        i += arg;
      case 4 || 5:
        final itemsPerEntry = major == 5 ? 2 : 1;
        // Bound the argument before multiplication can overflow. Every item
        // consumes at least one byte, including an empty container.
        if (arg > (bytes.length - i) ~/ itemsPerEntry) return 'truncated';
        final items = arg * itemsPerEntry;
        if (items > 0) {
          if (remaining.length >= maxDepth) return 'nested too deeply';
          remaining.add(items);
          integerKeys.add(major == 5 ? <(int, int)>{} : null);
          completesItem = false;
        }
      case 6:
        if (++tagRun > 4) return 'too many tags';
        continue;
      default: // 7: simple values and floats
        if (ai == 24 && arg < 32) return 'invalid simple value';
    }
    tagRun = 0;
    if (!completesItem) continue;

    // One item finished; close every level it completes.
    while (true) {
      if (remaining.isEmpty) {
        topLevelItems += 1;
        break;
      }
      remaining[remaining.length - 1] -= 1;
      if (remaining.last > 0) break;
      remaining.removeLast();
      integerKeys.removeLast();
    }
  }
  if (remaining.isNotEmpty || tagRun > 0) return 'truncated';
  if (topLevelItems != 1) return topLevelItems == 0 ? 'empty' : 'trailing bytes';
  return null;
}
