/// A simple signal to communicate between account creation screens
/// and the home screen's drawer.
///
/// Set [showAccountsOnNextOpen] to `true` before navigating to home
/// to have the drawer automatically open in accounts mode.
class DrawerSignal {
  DrawerSignal._();

  /// When true, the home screen will open the drawer in accounts mode
  /// on its next initialization. The flag is consumed (reset to false)
  /// by the home screen.
  static bool showAccountsOnNextOpen = false;

  /// When true, the tab navigator will reload the WalletDrawerBloc
  /// on its next build. Consumed (reset to false) after use.
  static bool reloadDrawerOnReturn = false;
}
