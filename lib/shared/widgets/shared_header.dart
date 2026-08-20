import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/auth_service.dart';
import '../../core/router/menu_drawer_controller.dart';
import '../../core/services/avatar_service.dart';
import '../../core/session/session_manager.dart';
import '../../core/router/nav_bar_state.dart';
import '../../core/utils/address_format.dart';
import '../../core/utils/reduce_motion.dart';
import '../../di.dart';
import '../../features/activity/screens/activity_screen.dart';
import '../../features/portfolio/services/token_balance_bloc.dart';
import '../../features/search/screens/search_sheet.dart';
import '../../features/wallets/services/wallet_drawer_bloc.dart';
import '../theme/mallow_theme.dart';
import '../utils/price_format.dart';
import 'account_avatar.dart';
import 'bottom_nav_bar.dart';
import 'loading_indicator.dart';
import 'mallow_network_image.dart';
import 'mallow_svg_icon.dart';
import 'tappable.dart';

/// Persistent header shown above all main tabs.
///
/// Displays the active session's avatar (Account identicon or Profile picture)
/// to the left of its identity — the Profile username or Account name, in Geist
/// — with a dropdown toggle, plus search + activity icons.
class SharedHeader extends StatefulWidget {
  const SharedHeader({super.key});

  @override
  State<SharedHeader> createState() => _SharedHeaderState();
}

class _SharedHeaderState extends State<SharedHeader> {
  // Cached last-known fallback label so transient bloc states
  // (loading/initial/error) don't flash a placeholder over rendered text.
  String? _lastPrimaryLabel;

  @override
  Widget build(BuildContext context) {
    // Identity is owned by SessionManager (a ChangeNotifier), but the header
    // below only repaints on WalletDrawerBloc emissions — which fire on an
    // active-*wallet* change. A Profile → Account switch flips the session and
    // calls notifyListeners(), yet doesn't always change the active wallet
    // (e.g. an account with no Solana signer never calls switchWalletById), so
    // the header would otherwise keep painting the stale Profile name. Listen
    // to the session directly so every switch rebuilds the identity label.
    return ListenableBuilder(
      listenable: sl<SessionManager>(),
      builder: (context, _) {
        return BlocBuilder<WalletDrawerBloc, WalletDrawerState>(
          builder: (context, walletState) {
            String? activeUsername;
            String? activeWalletName;
            final activeAddress =
                walletState.maybeWhen(
                  loaded: (profileGroups, anonGroup, activeWalletId, _, _, _) {
                    if (activeWalletId == null) return null;
                    for (final group in [...profileGroups, anonGroup]) {
                      for (final wallet in group.wallets) {
                        if (wallet.id == activeWalletId) {
                          final un = group.username;
                          if (un != null && un.isNotEmpty) activeUsername = un;
                          activeWalletName = wallet.name;
                          return wallet.address;
                        }
                      }
                    }
                    return null;
                  },
                  offline: (wallets, activeWalletId, _) {
                    if (activeWalletId == null) return null;
                    for (final wallet in wallets) {
                      if (wallet.id == activeWalletId) {
                        activeWalletName = wallet.name;
                        return wallet.address;
                      }
                    }
                    return null;
                  },
                  orElse: () => null,
                ) ??
                sl<AuthService>().currentAddress;

            final freshTruncatedAddress =
                (activeAddress != null && activeAddress.isNotEmpty)
                ? truncateAddress(activeAddress)
                : null;
            // Fallback identity for cold start (before the session resolves a
            // display name): username → local wallet name → truncated address.
            final freshFallbackLabel =
                (activeUsername != null && activeUsername!.isNotEmpty)
                ? activeUsername!
                : (activeWalletName != null && activeWalletName!.isNotEmpty)
                ? activeWalletName!
                : freshTruncatedAddress;
            if (freshFallbackLabel != null && freshFallbackLabel.isNotEmpty) {
              _lastPrimaryLabel = freshFallbackLabel;
            }

            // The session is the source of truth for identity: the Profile
            // username or the Account name, always rendered in Geist.
            final session = sl<SessionManager>();
            final sessionName = session.displayName;
            final identityLabel =
                (sessionName != null && sessionName.isNotEmpty)
                ? sessionName
                : (freshFallbackLabel ?? _lastPrimaryLabel);
            final hasAnyLabel =
                identityLabel != null && identityLabel.isNotEmpty;

            // Avatar mirrors the drawer header's selection logic: an Account
            // session shows its dicebear identicon; a Profile shows its uploaded
            // picture (falling back to a generated identicon seeded by the
            // profile identity, or the active address).
            final isProfile = session.isProfileMode;
            final activeAccount = session.activeAccount;
            final activeProfile = session.activeProfile;
            final String? avatarImageUrl;
            final String avatarSeed;
            if (!isProfile && activeAccount != null) {
              avatarImageUrl = null;
              avatarSeed = activeAccount.avatarSeed;
            } else if (isProfile && activeProfile != null) {
              avatarImageUrl = activeProfile.imageUrl;
              avatarSeed = avatarSeedOf(
                username: activeProfile.username,
                id: activeProfile.userId,
              );
            } else {
              avatarImageUrl = null;
              avatarSeed = avatarSeedOf(address: activeAddress);
            }

            return Padding(
              padding: const EdgeInsets.only(
                left: MallowTheme.spacing20 - 5,
                right: MallowTheme.spacing20,
                top: MallowTheme.spacingSm - 5,
              ),
              child: SizedBox(
                height: 48 + 10,
                child: Row(
                  children: [
                    // Left: session avatar + identity w/ dropdown, in one row.
                    // Expanded (not min-width + Spacer) so a long name flexes
                    // and ellipsizes instead of pushing the right cluster off.
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: 'Open account menu',
                        child: Tappable(
                          semanticButton: false,
                          onTap: () =>
                              MenuDrawerController.of(context).toggle(),
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: Row(
                              children: [
                                if (avatarImageUrl != null &&
                                    avatarImageUrl.isNotEmpty)
                                  MallowNetworkImage(
                                    imageUrl: avatarImageUrl,
                                    logicalSize: 24,
                                    width: 24,
                                    height: 24,
                                    borderRadius: BorderRadius.circular(12),
                                    errorBuilder: (_) => AccountAvatar(
                                      seed: avatarSeed,
                                      size: 24,
                                    ),
                                  )
                                else
                                  AccountAvatar(seed: avatarSeed, size: 24),
                                const SizedBox(width: 8),
                                if (hasAnyLabel)
                                  Flexible(
                                    child: Text(
                                      identityLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: MallowTheme.uiTitle.copyWith(
                                        color: context.mallowColors.textPrimary,
                                      ),
                                    ),
                                  )
                                else
                                  ShimmerBox(
                                    width: 96,
                                    height: MallowTheme.uiTitle.fontSize ?? 16,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                const SizedBox(width: 4),
                                const MallowSvgIcon(
                                  'assets/icons/arrow_down.svg',
                                  width: 6,
                                  height: 6,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Search + Clock icons + Wallet value
                    Row(
                      children: [
                        _HeaderIconButton(
                          assetPath: 'assets/icons/search.svg',
                          semanticLabel: 'Search',
                          size: 24,
                          onTap: () => showSearchSheet(context),
                        ),
                        _HeaderIconButton(
                          assetPath: 'assets/icons/clock.svg',
                          semanticLabel: 'Activity',
                          size: 24,
                          onTap: () => showActivitySheet(context),
                        ),
                        const _TabAwareWalletValue(),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Wraps [_WalletValue] so it slides + fades out to the right (and collapses
/// its footprint, leaving the clock icon flush-right) on the tokens tab — which
/// shows its own large portfolio value — and slides + fades back in on the home
/// and nfts tabs. Driven by [NavBarState.activeTab].
class _TabAwareWalletValue extends StatelessWidget {
  const _TabAwareWalletValue();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MallowNavTab>(
      valueListenable: NavBarState.activeTab,
      builder: (context, tab, child) {
        final hidden = tab == MallowNavTab.tokens;
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: hidden ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
          child: child,
          builder: (context, t, child) {
            // t: 0 = fully shown, 1 = fully hidden (slid right, faded, collapsed)
            return ClipRect(
              child: Align(
                alignment: Alignment.centerRight,
                widthFactor: 1.0 - t,
                child: Opacity(
                  opacity: 1.0 - t,
                  child: Transform.translate(
                    offset: Offset(28 * t, 0),
                    child: child,
                  ),
                ),
              ),
            );
          },
        );
      },
      child: const _WalletValue(),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.assetPath,
    required this.semanticLabel,
    required this.size,
    this.onTap,
  });

  final String assetPath;

  /// Screen-reader label for the otherwise unlabeled SVG icon.
  final String semanticLabel;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Tappable(
        onTap: onTap,
        semanticButton: false,
        // 10dp padding around a 24dp icon → a 44dp target (the a11y minimum).
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: MallowSvgIcon(assetPath, width: size, height: size),
        ),
      ),
    );
  }
}

/// Header-right wallet USD value with two animations:
/// 1. While loading/refreshing, opacity pulses 0.3↔1.0 over the last-known
///    value (or $0.00 on first load).
/// 2. Cached emissions (`isRefreshing: true` — initial app load, wallet
///    switch) snap instantly to the new wallet's last-known value so we
///    never animate from a stale or unrelated number. Fresh emissions
///    (`isRefreshing: false`) roll each part of the value (dollars, then
///    cents) up and out while the new part rises from below — the same
///    clipped translate the Sign/Confirm sheet uses for its status label
///    (see [_RollingValuePart]) — rather than counting digits.
class _WalletValue extends StatefulWidget {
  const _WalletValue();

  @override
  State<_WalletValue> createState() => _WalletValueState();
}

class _WalletValueState extends State<_WalletValue>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  /// Committed USD value currently shown. On a fresh change each part rolls to
  /// the new digits; snaps replace it instantly (see [_snapEpoch]).
  double _value = 0.0;

  /// Bumped on every snap (wallet switch, cached emission, first load). The
  /// value parts are keyed by it, so a snap rebuilds them at rest instead of
  /// rolling from the previous wallet's number.
  int _snapEpoch = 0;

  /// Address of the wallet whose value we're currently showing. When a loaded
  /// state arrives for a different address it's a wallet switch — snap rather
  /// than count-animate from the previous wallet's number.
  String? _lastAddress;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      value: 1.0,
    );
    _pulseAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  bool _didInitialSync = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInitialSync) return;
    _didInitialSync = true;
    final state = context.read<TokenBalanceBloc>().state;
    final isLoading = state.maybeMap(
      loaded: (s) => s.isRefreshing,
      loading: (_) => true,
      initial: (_) => true,
      orElse: () => false,
    );
    _syncPulse(isLoading);
    state.mapOrNull(
      // First sync is always a snap — either initial app load (cached
      // value for the active wallet) or a hot reload mid-session.
      loaded: (s) {
        _lastAddress = s.address;
        _snapValueTo(s.totalUsdValue);
      },
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _syncPulse(bool isLoading) {
    if (isLoading) {
      if (context.reduceMotion) {
        // Reduce Motion: no pulsing loop — hold a static dim to still signal
        // that a refresh is in flight.
        if (_pulseController.isAnimating) _pulseController.stop();
        _pulseController.value = 0.5;
      } else if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      if (_pulseController.isAnimating) {
        _pulseController.stop();
        _pulseController.animateTo(
          1.0,
          duration: const Duration(milliseconds: 200),
        );
      } else {
        // Restore full opacity when leaving the reduce-motion static dim.
        _pulseController.value = 1.0;
      }
    }
  }

  /// Replace the value with no roll — the parts are re-keyed so they rebuild at
  /// rest showing [target].
  void _snapValueTo(double target) {
    setState(() {
      _value = target;
      _snapEpoch++;
    });
  }

  /// Commit a new value in place; each part whose digits changed rolls to them
  /// (the parts watch their own text — see [_RollingValuePart]).
  void _animateValueTo(double target) {
    setState(() => _value = target);
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<TokenBalanceBloc, TokenBalanceState>(
      listenWhen: (prev, curr) => true,
      listener: (context, state) {
        final isLoading = state.maybeMap(
          loaded: (s) => s.isRefreshing,
          loading: (_) => true,
          initial: (_) => true,
          orElse: () => false,
        );
        _syncPulse(isLoading);
        state.mapOrNull(
          // A `loading` state only happens on a fresh load with no cache (a
          // refresh keeps the loaded state). Show $0.00 while it resolves
          // rather than pulsing the previous wallet's number.
          loading: (_) {
            _snapValueTo(0);
          },
          loaded: (s) {
            // A loaded state for a different address means the active wallet
            // changed — snap so we never count-animate from the previous
            // wallet's number (which would also happen when the new wallet
            // has no cache and the first value to arrive is the fresh one).
            final addressChanged =
                s.address != null &&
                _lastAddress != null &&
                s.address != _lastAddress;
            if (s.address != null) _lastAddress = s.address;
            if (s.totalUsdValue == _value) return;
            // Cached emissions (`isRefreshing: true`) arrive on app start and
            // on wallet switch — snap to the new wallet's last-known value.
            // Same-wallet fresh values (`isRefreshing: false`) tween normally.
            if (addressChanged || s.isRefreshing) {
              _snapValueTo(s.totalUsdValue);
            } else {
              _animateValueTo(s.totalUsdValue);
            }
          },
        );
      },
      builder: (context, state) {
        final mainStyle = MallowTheme.uiIdentity.copyWith(
          color: context.mallowColors.textPrimary,
        );
        final centsStyle = MallowTheme.uiCaption.copyWith(
          color: context.mallowColors.textSecondary,
        );
        final formatted = _formatCurrency(_value);

        // The dollars and cents are different font sizes but must share one
        // alphabetic baseline. Measure both so the smaller cents can be dropped
        // to the dollars' baseline inside its own full-height clip box (the
        // roll clips vertically, so each part needs the full line height).
        final mainMetrics = _measureLine(formatted.main, mainStyle);
        final centsBaseline = _measureLine(
          formatted.cents,
          centsStyle,
        ).baseline;
        final boxHeight = mainMetrics.height;
        final centsTopOffset = math.max(
          0.0,
          mainMetrics.baseline - centsBaseline,
        );

        return AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return Opacity(opacity: _pulseAnimation.value, child: child);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => NavBarState.selectedTab.value = MallowNavTab.tokens,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              // Tabular figures keep the width constant while the digit count
              // holds, so an equal-length change never shifts anything to the
              // left. When the digit count *does* change (crossing a comma,
              // e.g. $999 → $1,020) the width genuinely changes; AnimatedSize
              // eases that change (right-anchored, so the value's right edge
              // stays put) instead of snapping it in one frame.
              child: AnimatedSize(
                duration: const Duration(milliseconds: 340),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _RollingValuePart(
                      key: ValueKey('main-$_snapEpoch'),
                      text: formatted.main,
                      style: mainStyle,
                      boxHeight: boxHeight,
                      topOffset: 0,
                    ),
                    _RollingValuePart(
                      key: ValueKey('cents-$_snapEpoch'),
                      text: formatted.cents,
                      style: centsStyle,
                      boxHeight: boxHeight,
                      topOffset: centsTopOffset,
                      // Trails the dollars so the pair reads as one cascading
                      // roll rather than moving in lockstep.
                      startDelay: const Duration(milliseconds: 100),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One part (dollars or cents) of the header wallet value. When [text] changes
/// the old string translates up and out while the new one rises from below,
/// clipped to [boxHeight] so neither spills its slot — the same roll the
/// Sign/Confirm sheet uses for its status label (`_RollingText` in
/// striped_activity_panel.dart). [topOffset] drops the line inside its box so a
/// smaller part (the cents) can sit on a larger part's baseline; [startDelay]
/// holds the roll back so the cents can trail the dollars into a cascade.
class _RollingValuePart extends StatefulWidget {
  const _RollingValuePart({
    required this.text,
    required this.style,
    required this.boxHeight,
    required this.topOffset,
    super.key,
    this.startDelay = Duration.zero,
    this.slideDuration = const Duration(milliseconds: 340),
  });

  final String text;
  final TextStyle style;
  final double boxHeight;
  final double topOffset;
  final Duration startDelay;
  final Duration slideDuration;

  @override
  State<_RollingValuePart> createState() => _RollingValuePartState();
}

class _RollingValuePartState extends State<_RollingValuePart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// The string rolling up and out; null at rest. The incoming string is always
  /// [widget.text] (read live in build), so a change mid-roll just retargets the
  /// rising line rather than restarting.
  String? _outgoing;

  static const Curve _curve = Curves.easeOutCubic;

  /// Below this raw progress a fresh change retargets the still-rising line
  /// instead of starting over, keeping rapid back-to-back updates one roll.
  static const double _retargetBelow = 0.85;

  /// Fraction of the controller's run that is dead time before the slide, so
  /// [startDelay] can be baked into a single controller.
  double get _delayFraction {
    final total = widget.startDelay + widget.slideDuration;
    if (total == Duration.zero) return 0;
    return widget.startDelay.inMicroseconds / total.inMicroseconds;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.startDelay + widget.slideDuration,
      // Start settled — the first build shows the initial text at rest.
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant _RollingValuePart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;

    if (context.reduceMotion) {
      // No vestibular motion — snap straight to the new string.
      _outgoing = null;
      _controller.value = 1;
      return;
    }

    if (!_controller.isCompleted && _controller.value < _retargetBelow) {
      // A roll is in flight and hasn't nearly landed — keep it going; because
      // the rising line renders [widget.text] live it now shows the newest
      // digits and finishes the same continuous roll.
      return;
    }

    _outgoing = oldWidget.text;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _line(String text) => Text(
    text,
    style: widget.style,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.visible,
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.boxHeight,
      child: ClipRect(
        child: Padding(
          padding: EdgeInsets.only(top: widget.topOffset),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final delay = _delayFraction;
              // Remap past the dead time, then ease.
              final raw = delay >= 1
                  ? 0.0
                  : ((_controller.value - delay) / (1 - delay)).clamp(0.0, 1.0);
              final t = _curve.transform(raw);

              final incoming = FractionalTranslation(
                translation: Offset(0, 1 - t),
                child: Opacity(opacity: t, child: _line(widget.text)),
              );

              final outgoing = _outgoing;
              if (outgoing == null || t >= 1) {
                return incoming;
              }

              return Stack(
                children: [
                  FractionalTranslation(
                    translation: Offset(0, -t),
                    child: Opacity(opacity: 1 - t, child: _line(outgoing)),
                  ),
                  incoming,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Alphabetic baseline (distance from the top) and full line height of a single
/// line of [text] in [style], used to align the differently-sized dollars and
/// cents parts of the wallet value.
class _LineMetrics {
  const _LineMetrics({required this.baseline, required this.height});
  final double baseline;
  final double height;
}

_LineMetrics _measureLine(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return _LineMetrics(
    baseline: painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
    height: painter.height,
  );
}

class _FormattedCurrency {
  const _FormattedCurrency({required this.main, required this.cents});
  final String main;
  final String cents;
}

/// Splits the shared [formatUsd] rendering so the cents can be typeset
/// smaller than the dollars. Formatting once and splitting keeps the two
/// halves consistent — deriving them separately let the cents reach 100 and
/// the header read "$9.100".
_FormattedCurrency _formatCurrency(double value) {
  final formatted = formatUsd(value);
  final dot = formatted.lastIndexOf('.');
  return _FormattedCurrency(
    main: formatted.substring(0, dot),
    cents: formatted.substring(dot),
  );
}
