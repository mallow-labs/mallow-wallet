import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/models/account.dart';
import '../../../core/utils/address_format.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import 'browser_tap.dart';
import 'browser_wallet_avatar.dart';

/// What the wallet pill reports for the current page.
enum BrowserWalletPillState {
  /// No Solana or Ethereum wallet is selected in this session.
  none,

  /// A wallet is selected; the committed website (if any) is not connected
  /// to it.
  disconnected,

  /// The committed website is connected to the selected wallet.
  connected,
}

/// The browser's bottom chrome: the control pill and the wallet pill, floating
/// over the page. The bar itself paints nothing, so the page shows between
/// and around the pills; the WebView treats the bar's height as an obscured
/// inset (see `BrowserObscuredInsets`), or on Android runs under the bar only
/// while that is safe for the page (see `BrowserBottomOverlay`). The address
/// bar is at the top (`BrowserAddressBar`).
///
/// Every string that names a website here must come from the natively
/// committed origin ([host]); a page's title never reaches this widget.
class BrowserBottomBar extends StatelessWidget {
  const BrowserBottomBar({
    required this.host,
    required this.canBack,
    required this.canForward,
    required this.tabCount,
    required this.wallet,
    required this.walletState,
    required this.onMinimise,
    required this.onBack,
    required this.onForward,
    required this.onTabs,
    required this.onMenu,
    required this.onWallet,
    super.key,
  });

  static const double controlHeight = 48;
  static const double _top = 8;
  static const double _side = 12;

  /// Space between the bottom of the chrome and the screen edge: the
  /// home-indicator inset, or a small margin on devices without one.
  static double bottomInset(BuildContext context) =>
      math.max(MediaQuery.viewPaddingOf(context).bottom, _top);

  /// The height the bar takes from the bottom of the screen; the website is
  /// laid out above it.
  static double height(BuildContext context) =>
      _top + controlHeight + bottomInset(context);

  /// The committed host, or null before the first navigation commits.
  final String? host;
  final bool canBack;
  final bool canForward;
  final int tabCount;
  final WalletInfo? wallet;
  final BrowserWalletPillState walletState;
  final VoidCallback onMinimise;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onTabs;
  final VoidCallback onMenu;
  final VoidCallback onWallet;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_side, _top, _side, bottomInset(context)),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The two pills are one group, centred. The control pill keeps
            // its 5 × 42 dp; the wallet pill hugs its content, shrinks its
            // text to fit what is left, and drops the text before the
            // controls lose their 44 dp targets.
            final avatarOnly =
                textScale > 1.3 ||
                constraints.maxWidth - 8 - _ControlPill.minWidth < 110;
            return SizedBox(
              height: controlHeight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ControlPill(bar: this),
                  const SizedBox(width: 8),
                  Flexible(
                    child: BrowserWalletPill(
                      wallet: wallet,
                      state: walletState,
                      avatarOnly: avatarOnly,
                      host: host,
                      onTap: onWallet,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The browser chrome's pill. In dark mode its shadow vanishes against
/// bgPrimary, so a hairline keeps the pill's edge.
BoxDecoration browserPillDecoration(BuildContext context, {Color? border}) {
  final colors = context.mallowColors;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final edge = border ?? (dark ? colors.dividerLight : null);
  return BoxDecoration(
    color: colors.bgPrimary,
    borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
    border: edge == null ? null : Border.all(color: edge),
    boxShadow: MallowTheme.navBarShadow(context),
  );
}

class _ControlPill extends StatelessWidget {
  const _ControlPill({required this.bar});

  static const double _item = 42;
  static const double minWidth = _item * 5 + 14;

  final BrowserBottomBar bar;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      width: minWidth,
      height: BrowserBottomBar.controlHeight,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: browserPillDecoration(context),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          BrowserBarIconButton(
            asset: 'assets/icons/chevron_down.svg',
            label: 'Minimise browser',
            onTap: bar.onMinimise,
          ),
          BrowserBarIconButton(
            asset: 'assets/icons/chevron_left.svg',
            label: 'Back',
            onTap: bar.canBack ? bar.onBack : null,
          ),
          BrowserBarIconButton(
            asset: 'assets/icons/chevron_right.svg',
            label: 'Forward',
            onTap: bar.canForward ? bar.onForward : null,
          ),
          BrowserTap(
            onTap: bar.onTabs,
            label: bar.tabCount == 1
                ? '1 open tab'
                : '${bar.tabCount} open tabs',
            child: SizedBox(
              width: _item,
              height: BrowserBottomBar.controlHeight,
              child: Center(
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.textPrimary, width: 1.9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    bar.tabCount > 99 ? '∞' : '${bar.tabCount}',
                    textScaler: TextScaler.noScaling,
                    style: MallowTheme.uiLabel.copyWith(
                      fontSize: bar.tabCount > 9 ? 9.5 : 11,
                      fontWeight: FontWeight.w600,
                      height: 1,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
          BrowserBarIconButton(
            asset: 'assets/icons/dots_horizontal.svg',
            label: 'Page menu',
            onTap: bar.onMenu,
          ),
        ],
      ),
    );
  }
}

/// A 44 dp chrome icon button; disabled (tertiary) when [onTap] is null.
class BrowserBarIconButton extends StatelessWidget {
  const BrowserBarIconButton({
    required this.asset,
    required this.label,
    required this.onTap,
    this.size = 22,
    this.width = _ControlPill._item,
    super.key,
  });

  final String asset;
  final String label;
  final VoidCallback? onTap;
  final double size;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final icon = SizedBox(
      width: width,
      height: BrowserBottomBar.controlHeight,
      child: Center(
        child: MallowSvgIcon(
          asset,
          width: size,
          height: size,
          color: onTap == null ? colors.textTertiary : colors.textPrimary,
        ),
      ),
    );
    if (onTap == null) {
      return Semantics(
        button: true,
        enabled: false,
        label: label,
        excludeSemantics: true,
        child: icon,
      );
    }
    return BrowserTap(onTap: onTap, label: label, child: icon);
  }
}

/// The wallet pill: who this website sees, and whether it is connected. It
/// names the wallet by its short address only, never the wallet's stored
/// label. [avatarOnly] drops the text on narrow screens and large text; the
/// ring still carries the state. Tapping it opens the wallet picker.
class BrowserWalletPill extends StatelessWidget {
  const BrowserWalletPill({
    required this.wallet,
    required this.state,
    required this.onTap,
    this.host,
    this.avatarOnly = false,
    super.key,
  });

  /// The avatar's diameter; the connected ring is drawn inside it, so the
  /// pill does not change size when the site connects.
  static const double avatarSize = 34;

  final WalletInfo? wallet;
  final BrowserWalletPillState state;
  final String? host;
  final bool avatarOnly;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final wallet = this.wallet;
    final connected = state == BrowserWalletPillState.connected;
    final address = wallet == null
        ? null
        : truncateAddress(wallet.address, lead: 4, trail: 4);
    final (String title, String caption) = switch (state) {
      BrowserWalletPillState.none => ('Wallet', 'Select'),
      BrowserWalletPillState.disconnected => (address!, 'Disconnected'),
      BrowserWalletPillState.connected => (address!, 'Connected'),
    };
    final site = host == null ? '' : ' to $host';
    final semantics = switch (state) {
      BrowserWalletPillState.none => 'Select a wallet',
      BrowserWalletPillState.disconnected =>
        'Wallet $address, not connected$site. Choose wallet',
      BrowserWalletPillState.connected =>
        'Wallet $address, connected$site. Choose wallet',
    };
    // The light positive token is too faint for 11 dp text on bgPrimary;
    // the label is pulled toward textPrimary, which darkens it in light mode
    // and lightens it in dark mode. The ring keeps the token itself.
    final captionColor = connected
        ? Color.lerp(colors.positive, colors.textPrimary, 0.3)!
        : colors.textSecondary;
    final avatar = BrowserWalletAvatar(
      wallet: wallet,
      size: avatarSize,
      ring: connected ? colors.positive : null,
    );
    return BrowserTap(
      onTap: onTap,
      label: semantics,
      child: Container(
        height: BrowserBottomBar.controlHeight,
        width: avatarOnly ? BrowserBottomBar.controlHeight : null,
        padding: avatarOnly
            ? EdgeInsets.zero
            : const EdgeInsets.only(left: 7, right: 12),
        // Only the fixed-size avatar-only pill centres its child: an aligned
        // Container grows to its full width, and the labelled pill must hug
        // its content.
        alignment: avatarOnly ? Alignment.center : null,
        decoration: browserPillDecoration(context),
        child: avatarOnly
            ? avatar
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  avatar,
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Scales down rather than wrapping or clipping, so
                        // the full short address always stays readable.
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            title,
                            maxLines: 1,
                            softWrap: false,
                            style: MallowTheme.uiLabel.copyWith(
                              fontWeight: FontWeight.w500,
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            caption,
                            maxLines: 1,
                            softWrap: false,
                            style: MallowTheme.uiCaption.copyWith(
                              fontWeight: connected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: captionColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The 2 dp accent loading hairline under the status bar.
class BrowserProgressHairline extends StatelessWidget {
  const BrowserProgressHairline({required this.progress, super.key});

  /// 0–100, as the WebView reports it.
  final int progress;

  @override
  Widget build(BuildContext context) {
    final visible = progress > 0 && progress < 100;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: MallowTheme.sheetDuration,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: (progress.clamp(5, 100)) / 100,
            child: Container(
              height: 2,
              decoration: BoxDecoration(
                color: context.mallowColors.accent,
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Decides when the address bar collapses to its compact form from the page's scroll
/// offsets. It reacts to a change of direction past [slop], never to position
/// alone, and at most once per [debounce]: each change resizes the WebView,
/// which must not reflow on every frame. Reaching the top always expands.
class BrowserBarCollapse {
  BrowserBarCollapse({
    this.slop = 24,
    this.minOffset = 64,
    this.debounce = const Duration(milliseconds: 350),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int slop;

  /// Offsets closer to the top than this never collapse the bar.
  final int minOffset;
  final Duration debounce;
  final DateTime Function() _clock;

  bool _compact = false;
  bool get compact => _compact;
  int? _anchor;
  DateTime? _changedAt;

  /// Feeds one scroll offset; true when [compact] changed.
  bool scrolled(int y) {
    final anchor = _anchor;
    if (anchor == null) {
      _anchor = y;
      return false;
    }
    if (y <= 0) {
      _anchor = 0;
      return _compact && set(false, force: true);
    }
    // The anchor follows the page while it keeps going the same way, so the
    // slop is measured from where the direction last turned.
    if (!_compact) {
      if (y < anchor) {
        _anchor = y;
      } else if (y - anchor > slop && y > minOffset && set(true)) {
        _anchor = y;
        return true;
      }
    } else {
      if (y > anchor) {
        _anchor = y;
      } else if (anchor - y > slop && set(false)) {
        _anchor = y;
        return true;
      }
    }
    return false;
  }

  /// Sets the state directly (a tap on the pill, a new page); [force] skips
  /// the debounce. True when [compact] changed.
  bool set(bool compact, {bool force = false}) {
    if (_compact == compact) return false;
    final now = _clock();
    final last = _changedAt;
    if (!force && last != null && now.difference(last) < debounce) {
      return false;
    }
    _changedAt = now;
    _compact = compact;
    return true;
  }

  /// A new document or tab: full bar, and the next offset starts afresh.
  void reset() {
    _compact = false;
    _anchor = null;
  }
}
