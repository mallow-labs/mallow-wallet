import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/router/nav_bar_state.dart';
import 'package:mallow_wallet/shared/widgets/bottom_nav_bar.dart';

void main() {
  tearDown(() => NavBarState.selectedTab.value = MallowNavTab.home);

  test('selectedTab reports a tap on the tab it already holds', () {
    // A route can switch TabNavigator to another tab without a tap, leaving
    // selectedTab on the last tapped tab. Tapping that tab must still switch.
    NavBarState.selectedTab.value = MallowNavTab.home;
    final heard = <MallowNavTab>[];
    void listener() => heard.add(NavBarState.selectedTab.value);
    NavBarState.selectedTab.addListener(listener);
    addTearDown(() => NavBarState.selectedTab.removeListener(listener));

    NavBarState.selectedTab.value = MallowNavTab.home;
    NavBarState.selectedTab.value = MallowNavTab.browser;

    expect(heard, [MallowNavTab.home, MallowNavTab.browser]);
  });
}
