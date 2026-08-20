import 'package:flutter/widgets.dart';

/// Provides drawer control (open/close/toggle) to any descendant widget.
///
/// Placed above the tab content in [TabNavigator] so that any screen
/// (Home, Your Art, Curations) can open or close the account menu drawer.
class MenuDrawerController extends InheritedWidget {
  const MenuDrawerController({
    required this.toggle,
    required this.open,
    required this.close,
    required super.child,
    super.key,
  });

  final VoidCallback toggle;
  final VoidCallback open;
  final VoidCallback close;

  static MenuDrawerController? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MenuDrawerController>();
  }

  static MenuDrawerController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'No MenuDrawerController found in context');
    return controller!;
  }

  @override
  bool updateShouldNotify(MenuDrawerController oldWidget) =>
      toggle != oldWidget.toggle ||
      open != oldWidget.open ||
      close != oldWidget.close;
}
