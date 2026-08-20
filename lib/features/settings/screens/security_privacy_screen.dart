import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/analytics/analytics_service.dart';
import '../../../core/router/app_router.dart';
import '../../../core/security/app_lock_bloc.dart';
import '../../../core/security/biometric_auth.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/security/transaction_auth_gate.dart';
import '../../../core/services/preferences_service.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_toggle.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../services/account_deletion.dart';
import '../widgets/settings_page_scaffold.dart';
import 'package:go_router/go_router.dart';

/// Security & Privacy settings hub screen.
class SecurityPrivacyScreen extends StatefulWidget {
  const SecurityPrivacyScreen({super.key});

  @override
  State<SecurityPrivacyScreen> createState() => _SecurityPrivacyScreenState();
}

class _SecurityPrivacyScreenState extends State<SecurityPrivacyScreen>
    with WidgetsBindingObserver {
  bool _biometricsEnabled = false;
  bool _biometricsAvailable = false;
  bool _useFingerprintIcon = false;
  bool _txAuthEnabled = false;
  double _txAuthThresholdUsd = kTransactionAuthThresholdUsd;
  // Opted-in view of the analytics pref (pref stores opt-OUT; UI shows enabled).
  bool _analyticsEnabled = true;
  bool _loaded = false;

  /// Username of the mallow profile owned by the logged-in address, or null
  /// when there is none. Gates the "Delete profile" row: with no profile there
  /// is nothing for `POST /v2/user/delete` to remove.
  String? _deletableUsername;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh biometric flag when returning from system biometric prompt
      // or from the Change PIN flow.
      _refreshBiometricsFlag();
    }
  }

  Future<void> _load() async {
    final storage = sl<SecureWalletStorage>();
    final biometricsEnabled = await storage.loadBiometricEnabled();
    final txAuthEnabled = await storage.loadTransactionAuthEnabled();
    final threshold = await storage.loadTransactionAuthThresholdUsd();
    final auth = sl<BiometricAuthService>();
    final available = await auth.isAvailable();
    final hasFaceId = await auth.hasFaceId();
    final hasFingerprint = await auth.hasFingerprint();
    final analyticsOptOut = sl<PreferencesService>().analyticsOptOut;
    if (!mounted) return;
    setState(() {
      _biometricsEnabled = biometricsEnabled;
      _biometricsAvailable = available;
      _txAuthEnabled = txAuthEnabled;
      _txAuthThresholdUsd = threshold ?? kTransactionAuthThresholdUsd;
      _useFingerprintIcon = hasFingerprint && !hasFaceId;
      _analyticsEnabled = !analyticsOptOut;
      _deletableUsername = deletableUsername();
      _loaded = true;
    });
  }

  /// One switch governs both telemetry pipelines: the product-analytics queue
  /// and the Sentry hub. The ordering invariants (final opt-out event, queue
  /// discard, Sentry hub sync) live in [AnalyticsService.setConsent].
  Future<void> _onAnalyticsToggled(bool next) async {
    await sl<AnalyticsService>().setConsent(enabled: next);
    if (mounted) setState(() => _analyticsEnabled = next);
  }

  Future<void> _refreshBiometricsFlag() async {
    final enabled = await sl<SecureWalletStorage>().loadBiometricEnabled();
    if (mounted && enabled != _biometricsEnabled) {
      setState(() => _biometricsEnabled = enabled);
    }
  }

  Future<void> _editTxAuthThreshold() async {
    final result = await showMallowSheet<({bool enabled, double usd})>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _ThresholdSheet(
        initialEnabled: _txAuthEnabled,
        initialUsd: _txAuthThresholdUsd,
      ),
    );
    if (result == null || !mounted) return;
    final storage = sl<SecureWalletStorage>();
    await storage.storeTransactionAuthEnabled(result.enabled);
    await storage.storeTransactionAuthThresholdUsd(result.usd);
    if (!mounted) return;
    setState(() {
      _txAuthEnabled = result.enabled;
      _txAuthThresholdUsd = result.usd;
    });
  }

  Future<void> _onBiometricToggled(bool next) async {
    if (next) {
      await _enableBiometrics();
    } else {
      await _disableBiometrics();
    }
  }

  Future<void> _enableBiometrics() async {
    final auth = sl<BiometricAuthService>();
    final available = await auth.isAvailable();
    if (!mounted) return;
    if (!available) {
      _showSnack(
        'Biometrics aren\'t set up on this device. Enable Face ID or '
        'fingerprint in your system settings first.',
      );
      return;
    }
    final result = await auth.authenticate(
      reason: 'Authenticate to enable biometrics',
    );
    if (!mounted) return;
    if (result == BiometricAuthResult.success) {
      context.read<AppLockBloc>().add(const AppLockEvent.enableBiometric());
      setState(() => _biometricsEnabled = true);
    } else {
      final message =
          result.errorMessage ?? 'Could not verify biometrics. Try again.';
      _showSnack(message);
    }
  }

  Future<void> _disableBiometrics() async {
    final hasPin = await sl<SecureWalletStorage>().hasPin();
    if (!mounted) return;
    if (!hasPin) {
      final shouldSetPin = await _showSetPinFirstDialog();
      if (shouldSetPin == true && mounted) {
        await context.push(AppRoutes.changePin);
        if (mounted) {
          await _refreshBiometricsFlag();
        }
      }
      return;
    }
    context.read<AppLockBloc>().add(const AppLockEvent.disableBiometric());
    setState(() => _biometricsEnabled = false);
  }

  Future<bool?> _showSetPinFirstDialog() {
    return showConfirmSheet(
      context,
      title: 'Set a PIN first',
      message:
          'You need a PIN before you can turn off biometrics — '
          'otherwise the app would have no lock.',
      confirmLabel: 'Set PIN',
    );
  }

  void _showSnack(String message) {
    AppSnackBar.show(context, message);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Security & Privacy',
      child: _loaded
          ? _Body(
              biometricsEnabled: _biometricsEnabled,
              biometricsAvailable: _biometricsAvailable,
              onBiometricsChanged: _onBiometricToggled,
              useFingerprintIcon: _useFingerprintIcon,
              txAuthThresholdLabel: _txAuthEnabled
                  ? '\$${_formatThreshold(_txAuthThresholdUsd)}'
                  : 'Off',
              onEditTxAuthThreshold: _editTxAuthThreshold,
              analyticsEnabled: _analyticsEnabled,
              onAnalyticsChanged: _onAnalyticsToggled,
              onResetApp: () => context.push(AppRoutes.resetApp),
              onBlockedAccounts: () => context.push(AppRoutes.blockedAccounts),
              onDeleteAccount: _deletableUsername == null
                  ? null
                  : () async {
                      await context.push(AppRoutes.deleteAccount);
                      // The delete pops straight back past this screen, but a
                      // cancel returns here — re-read so the row disappears if
                      // the profile went away some other way.
                      if (mounted) await _load();
                    },
            )
          : const SizedBox.shrink(),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.biometricsEnabled,
    required this.biometricsAvailable,
    required this.onBiometricsChanged,
    required this.useFingerprintIcon,
    required this.txAuthThresholdLabel,
    required this.onEditTxAuthThreshold,
    required this.analyticsEnabled,
    required this.onAnalyticsChanged,
    required this.onResetApp,
    required this.onBlockedAccounts,
    required this.onDeleteAccount,
  });

  final bool biometricsEnabled;
  final bool biometricsAvailable;
  final ValueChanged<bool> onBiometricsChanged;
  final bool useFingerprintIcon;
  final String txAuthThresholdLabel;
  final VoidCallback onEditTxAuthThreshold;
  final bool analyticsEnabled;
  final ValueChanged<bool> onAnalyticsChanged;
  final VoidCallback onResetApp;
  final VoidCallback onBlockedAccounts;

  /// Null when the logged-in address owns no profile — the row is then hidden
  /// entirely rather than rendered dead.
  final VoidCallback? onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      children: [
        _MenuItem(
          iconAsset: 'assets/icons/star_lines.svg',
          label: 'Change PIN',
          onTap: () => context.push(AppRoutes.changePin),
        ),
        // Only surface the biometric toggle when the device actually has
        // biometric hardware enrolled — otherwise it can't be turned on.
        if (biometricsAvailable) ...[
          const SizedBox(height: 8),
          _ToggleRow(
            icon: useFingerprintIcon
                ? MallowSvgIcon(
                    'assets/icons/fingerprint.svg',
                    width: 24,
                    height: 24,
                    color: context.mallowColors.textPrimary,
                  )
                : const MallowSvgIcon(
                    'assets/icons/face_id.svg',
                    width: 24,
                    height: 24,
                  ),
            label: 'Biometric authentication',
            value: biometricsEnabled,
            onChanged: onBiometricsChanged,
          ),
        ],
        const SizedBox(height: 8),
        _ValueMenuItem(
          iconAsset: 'assets/icons/shield.svg',
          label: 'Require auth over',
          value: txAuthThresholdLabel,
          onTap: onEditTxAuthThreshold,
        ),
        const SizedBox(height: 8),
        _MenuItem(
          iconAsset: 'assets/icons/notes.svg',
          label: 'Show secrets',
          // Entry to Security & Privacy already cleared the reauth gate, so
          // flag this push as pre-authenticated to avoid a second prompt.
          onTap: () => context.push(AppRoutes.recoveryPhrase, extra: true),
        ),
        const SizedBox(height: 8),
        _ToggleRow(
          icon: const MallowSvgIcon(
            'assets/icons/analytics.svg',
            width: 24,
            height: 24,
          ),
          label: 'Share usage analytics',
          value: analyticsEnabled,
          onChanged: onAnalyticsChanged,
        ),
        const SizedBox(height: 8),
        // Management, not destruction — the block list is undoable, so it sits
        // with the privacy entries above the danger rows.
        _MenuItem(
          iconAsset: 'assets/icons/users.svg',
          label: 'Blocked accounts',
          onTap: onBlockedAccounts,
        ),
        const SizedBox(height: 8),
        _DangerMenuItem(
          iconAsset: 'assets/icons/reset.svg',
          label: 'Reset app',
          onTap: onResetApp,
        ),
        // Only shown when there is a profile to delete. Reset app (wallets) and
        // Delete profile are deliberately adjacent and deliberately distinct.
        if (onDeleteAccount != null) ...[
          const SizedBox(height: 8),
          _DangerMenuItem(
            iconAsset: 'assets/icons/user_minus.svg',
            label: 'Delete profile',
            onTap: onDeleteAccount!,
          ),
        ],
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.iconAsset,
    required this.label,
    required this.onTap,
  });

  final String iconAsset;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: MallowSvgIcon(iconAsset, width: 24, height: 24),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: MallowTheme.uiBody)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tap row showing a label plus the current value on the trailing edge
/// (e.g. "Require auth over    $100"). Tapping opens an editor.
class _ValueMenuItem extends StatelessWidget {
  const _ValueMenuItem({
    required this.iconAsset,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String iconAsset;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: MallowSvgIcon(iconAsset, width: 24, height: 24),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: MallowTheme.uiBody)),
              Text(
                value,
                style: MallowTheme.uiBody.copyWith(
                  color: context.mallowColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final Widget icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              SizedBox(width: 24, height: 24, child: icon),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: MallowTheme.uiBody)),
              MallowToggle(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// Error-colored tap row for destructive actions.
class _DangerMenuItem extends StatelessWidget {
  const _DangerMenuItem({
    required this.iconAsset,
    required this.label,
    required this.onTap,
  });

  final String iconAsset;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTargetExpander(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: SvgPicture.asset(
                  iconAsset,
                  colorFilter: ColorFilter.mode(
                    context.mallowColors.error,
                    BlendMode.srcIn,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: MallowTheme.uiBody.copyWith(
                    color: context.mallowColors.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `100`, or `2.50` when the value isn't a whole dollar amount. Callers
/// prepend the `$`.
String _formatThreshold(double usd) {
  final whole = usd == usd.roundToDouble();
  return whole ? usd.toStringAsFixed(0) : usd.toStringAsFixed(2);
}

/// Editor for transaction step-up auth. Lets the user enable/disable the
/// gate and pick the USD threshold above which signing demands a PIN /
/// biometrics. Returns `(enabled, usd)` via [Navigator.pop], or null (no
/// change) on cancel.
class _ThresholdSheet extends StatefulWidget {
  const _ThresholdSheet({
    required this.initialEnabled,
    required this.initialUsd,
  });

  final bool initialEnabled;
  final double initialUsd;

  @override
  State<_ThresholdSheet> createState() => _ThresholdSheetState();
}

class _ThresholdSheetState extends State<_ThresholdSheet> {
  /// Slider step in dollars.
  static const _step = 5.0;

  /// Default upper bound. Stretched to fit a larger persisted value so the
  /// thumb never jams against the right edge.
  static const _baseMax = 1000.0;

  late bool _enabled = widget.initialEnabled;
  late double _value = _snap(widget.initialUsd);
  late final double _max = _value > _baseMax
      ? ((_value / 500).ceil() * 500).toDouble()
      : _baseMax;

  double _snap(double v) {
    if (v <= 0) return 0;
    return (v / _step).round() * _step;
  }

  void _onSave() => Navigator.of(context).pop((enabled: _enabled, usd: _value));

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final divisions = (_max / _step).round();
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingSm,
                MallowTheme.spacing20,
                MallowTheme.spacing20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Require auth over',
                    style: MallowTheme.editorialSection.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingSm),
                  Text(
                    'Ask for your PIN or biometrics before signing any '
                    'transaction worth more than this amount.',
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  // Enable checkbox — the gate stays off until this is on.
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: MallowTheme.spacingSm,
                    ),
                    child: MallowCheckbox(
                      value: _enabled,
                      onChanged: (v) => setState(() => _enabled = v),
                      label: 'Require authentication',
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  Center(
                    child: Text(
                      '\$${_formatThreshold(_value)}',
                      style: MallowTheme.editorialSection.copyWith(
                        fontSize: 36,
                        letterSpacing: 36 * MallowTheme.trackingTight,
                        color: _enabled
                            ? colors.textPrimary
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                  Slider(
                    value: _value.clamp(0, _max).toDouble(),
                    max: _max,
                    divisions: divisions,
                    activeColor: colors.accent,
                    label: '\$${_formatThreshold(_value)}',
                    onChanged: _enabled
                        ? (v) => setState(() => _value = _snap(v))
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '\$0',
                          style: MallowTheme.uiCaption.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                        Text(
                          '\$${_formatThreshold(_max)}',
                          style: MallowTheme.uiCaption.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingLg),
                  Row(
                    children: [
                      Expanded(
                        child: MallowButton(
                          label: 'Cancel',
                          variant: MallowButtonVariant.secondary,
                          isFullWidth: true,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                      const SizedBox(width: MallowTheme.spacingSm),
                      Expanded(
                        child: MallowButton(
                          label: 'Save',
                          isFullWidth: true,
                          onPressed: _onSave,
                        ),
                      ),
                    ],
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

// Error color is now sourced from context.mallowColors.error for dark mode support.
