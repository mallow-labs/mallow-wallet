import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/account.dart';
import '../../../core/network/auth_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/avatar_service.dart';
import '../../../core/session/session_manager.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/utils/price_format.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_refresh_indicator.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/menu_row.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../../../shared/widgets/wallet_type_badge.dart';
import '../../notifications/data/notifications_repository.dart';
import '../../profile/data/user_profile_repository.dart';
import '../../profile/widgets/profile_required_sheet.dart';
import '../../receive/sheets/account_receive_sheet.dart';
import '../../wallets/services/wallet_drawer_bloc.dart';
import 'account_menu_constants.dart';

part 'account_menu_drawer/drawer_header.dart';
part 'account_menu_drawer/menu_content.dart';
part 'account_menu_drawer/switcher_content.dart';
part 'account_menu_drawer/wallets_tab_content.dart';
part 'account_menu_drawer/profile_group_list_content.dart';
part 'account_menu_drawer/profile_avatar.dart';
part 'account_menu_drawer/bottom_section.dart';
part 'account_menu_drawer/menu_rows.dart';

/// Left sliding menu panel for the home screen.
///
/// Has two content modes:
/// 1. **Menu mode** (default): navigation rows (Add wallet, Notifications, etc.)
/// 2. **Account list mode**: profile groups with expandable wallet rows
///
/// Tap header to toggle between modes with a fade/slide animation.
class AccountMenuDrawer extends StatefulWidget {
  const AccountMenuDrawer({
    super.key,
    this.onClose,
    this.totalUsdValue = 0,
    this.initialShowAccounts = false,
  });

  final VoidCallback? onClose;
  final double totalUsdValue;

  /// When true, the drawer starts in account list mode instead of menu mode.
  final bool initialShowAccounts;

  @override
  State<AccountMenuDrawer> createState() => AccountMenuDrawerState();
}

class AccountMenuDrawerState extends State<AccountMenuDrawer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _modeController;

  /// Drives the accounts panel slide. 0 = parked above (behind the header),
  /// 1 = fully down in place. `easeOutCubic` both directions so the present
  /// (down) and dismiss (up) motions each ease out.
  late final Animation<double> _slideAnimation;

  /// Translation for the accounts panel: from one panel-height above (hidden
  /// behind the header) to resting in place. Applied via [SlideTransition] so
  /// it's a render-layer transform — no per-frame subtree rebuild.
  late final Animation<Offset> _slideOffset;

  /// Peak blur applied to the menu underneath as the accounts panel covers it.
  static const double _kMenuBlurSigma = 6;

  /// true = showing account list, false = showing menu
  bool _showingAccounts = false;

  @override
  void initState() {
    super.initState();
    _modeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _slideAnimation = CurvedAnimation(
      parent: _modeController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic,
    );
    _slideOffset = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(_slideAnimation);

    if (widget.initialShowAccounts) {
      _showingAccounts = true;
      _modeController.value = 1.0;
    }

    refreshNotificationBadge();
  }

  /// Re-read the unread-notification count that drives the bell dot.
  ///
  /// Called on first build and again by [TabNavigator] every time the drawer
  /// is opened — the drawer's State outlives every session event, so without
  /// a per-open refresh the badge would be frozen at whatever it was when the
  /// app started.
  void refreshNotificationBadge() {
    sl<NotificationsRepository>().refreshUnreadCount();
  }

  @override
  void dispose() {
    _modeController.dispose();
    super.dispose();
  }

  void _toggleMode() {
    setState(() => _showingAccounts = !_showingAccounts);
    if (_showingAccounts) {
      _modeController.forward();
    } else {
      _modeController.reverse();
    }
  }

  void collapseAccounts() {
    if (_showingAccounts) {
      setState(() => _showingAccounts = false);
      _modeController.reverse();
    }
  }

  /// Switch to the accounts list. Used when an already-alive drawer is opened
  /// after adding an account — [initialShowAccounts] only takes effect in
  /// [initState], so the reuse path needs this imperative flip.
  void showAccounts() {
    if (!_showingAccounts) {
      setState(() => _showingAccounts = true);
      _modeController.forward();
    }
  }

  void _handleClose() {
    collapseAccounts();
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final authService = sl<AuthService>();
    final currentAddress = authService.currentAddress;

    return Material(
      color: context.mallowColors.bgPrimary,
      child: Column(
        children: [
          // Header section
          _DrawerHeader(
            currentAddress: currentAddress,
            totalUsdValue: widget.totalUsdValue,
            showingAccounts: _showingAccounts,
            onToggleMode: _toggleMode,
          ),
          // Animated content swap: the accounts panel slides down from behind
          // the header (clipped to this area) over the menu, which blurs as it
          // is covered. Both content subtrees are built once and passed as
          // cached `child`ren — only the transform / blur wrappers rebuild per
          // frame, so the slide stays at full framerate.
          Expanded(
            child: ClipRect(
              child: Stack(
                children: [
                  // Menu content underneath, stationary, blurred while covered.
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: _showingAccounts,
                      child: AnimatedBuilder(
                        animation: _slideAnimation,
                        builder: (context, child) {
                          final sigma = _slideAnimation.value * _kMenuBlurSigma;
                          if (sigma <= 0.01) return child!;
                          return ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: sigma,
                              sigmaY: sigma,
                            ),
                            child: child,
                          );
                        },
                        child: _MenuContent(
                          currentAddress: currentAddress,
                          onClose: _handleClose,
                        ),
                      ),
                    ),
                  ),
                  // Accounts panel translates down from above (parked one
                  // panel-height up, behind the header) into place.
                  Positioned.fill(
                    child: SlideTransition(
                      position: _slideOffset,
                      child: IgnorePointer(
                        ignoring: !_showingAccounts,
                        child: ColoredBox(
                          color: context.mallowColors.bgPrimary,
                          child: _SwitcherContent(
                            onClose: _handleClose,
                            onSwitched: collapseAccounts,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
