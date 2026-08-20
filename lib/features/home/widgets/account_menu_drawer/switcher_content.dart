part of '../account_menu_drawer.dart';

/// The expanded "Switch" view: a `Wallets | Profiles` tab selector over the
/// account list (Wallets) and the existing profile-group list (Profiles).
class _SwitcherContent extends StatefulWidget {
  const _SwitcherContent({this.onClose, this.onSwitched});

  final VoidCallback? onClose;

  /// Collapses the account list back to the menu after switching accounts or
  /// profiles, leaving the surrounding drawer open.
  final VoidCallback? onSwitched;

  @override
  State<_SwitcherContent> createState() => _SwitcherContentState();
}

class _SwitcherContentState extends State<_SwitcherContent> {
  /// Default to the Profiles tab when the active session is a profile, else
  /// the Wallets tab. (0 = Wallets, 1 = Profiles.)
  late int _tab = sl<SessionManager>().isProfileMode ? 1 : 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: MallowUnderlineTabBar(
            tabs: const ['Wallets', 'Profiles'],
            activeIndex: _tab,
            onTabSelected: (i) => setState(() => _tab = i),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            sizing: StackFit.expand,
            children: [
              _WalletsTabContent(
                onClose: widget.onClose,
                onSwitched: widget.onSwitched,
              ),
              _ProfileGroupListContent(
                onClose: widget.onClose,
                onSwitched: widget.onSwitched,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
