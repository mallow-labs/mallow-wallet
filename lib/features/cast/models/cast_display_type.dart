/// How the receiver should fit artwork onto the display.
enum CastDisplayType {
  /// Letterbox the artwork into the screen, preserving aspect ratio.
  fitToScreen,

  /// Crop the artwork to cover the full screen.
  fillScreen,

  /// Repeat the artwork side-by-side across the screen.
  tile,
}
