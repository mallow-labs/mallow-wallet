part of '../artwork_detail_screen.dart';

/// Reports its child's rendered size whenever it changes. Used so the
/// scroll content can reserve exactly the sticky action sheet's height as
/// bottom padding, regardless of which sheet variant is showing.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required Widget super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRenderObject(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    _MeasureSizeRenderObject renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  _MeasureSizeRenderObject(this.onChange);

  ValueChanged<Size> onChange;
  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();
    final newSize = child?.size;
    if (newSize == null || newSize == _oldSize) return;
    _oldSize = newSize;
    // Defer to a post-frame callback so listeners can safely call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(newSize));
  }
}

/// Mirrors the `@JsonValue` strings on [SupplyType] so the chooser
/// route can round-trip the enum through a query param.
String _supplyTypeJsonValue(SupplyType type) => switch (type) {
  SupplyType.oneOfOne => '1/1',
  SupplyType.limitedEdition => 'limited-edition',
  SupplyType.openEdition => 'open-edition',
  SupplyType.editionPrint => 'edition-print',
  SupplyType.collection => 'collection',
};

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
