/// Formats a byte count into human-readable units.
///
/// Examples: `1023` → `1023 B`, `1024` → `1.00 KB`, `33800000` → `32.23 MB`.
/// Uses 1024-based units (KB/MB/GB/TB), matching common desktop conventions.
String formatBytes(int bytes, {int fractionDigits = 2}) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return '${value.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
}
