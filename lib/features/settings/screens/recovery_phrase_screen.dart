import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/account.dart';
import '../../../core/router/app_router.dart';
import '../../../core/security/biometric_auth.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/custom_number_pad.dart';
import '../../../shared/widgets/secret_row.dart';
import '../widgets/settings_page_scaffold.dart';

/// Whether this screen is being used to view a recovery phrase (settings flow)
/// or to pick one for wallet import.
enum PhraseListMode { view, import }

enum _Step { accountList, pinGate }

/// Shared recovery-phrase selection screen.
///
/// **View mode** (settings): account list → PIN gate → warning → word grid.
/// **Import mode**: account list → import-from-phrase screen.
///
/// If only one seed-phrase account exists the list is skipped and the flow
/// auto-advances.  Pressing back from a downstream screen returns here (or
/// pops to the previous screen when there is only one account).
class RecoveryPhraseScreen extends StatefulWidget {
  const RecoveryPhraseScreen({super.key, this.mode = PhraseListMode.view});

  final PhraseListMode mode;

  @override
  State<RecoveryPhraseScreen> createState() => _RecoveryPhraseScreenState();
}

class _RecoveryPhraseScreenState extends State<RecoveryPhraseScreen>
    with SingleTickerProviderStateMixin {
  _Step _step = _Step.accountList;

  // Account list state — one entry per distinct seed phrase.
  List<Account> _accounts = [];
  // Wallet addresses across every account sharing each seed phrase, keyed by id.
  Map<String, List<String>> _addressesBySeedId = {};
  bool _accountsLoaded = false;
  Account? _selectedAccount;

  // PIN gate state (view mode only)
  String _pin = '';
  bool _pinError = false;
  bool _biometricsEnabled = false;
  static const _pinLength = 6;

  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  String get _title => widget.mode == PhraseListMode.view
      ? 'Your recovery phrase'
      : 'Select recovery phrase';

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation =
        TweenSequence([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: -8.0), weight: 1),
          TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
          TweenSequenceItem(tween: Tween(begin: 8.0, end: -8.0), weight: 2),
          TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
          TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
        ]).animate(
          CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut),
        );
    _loadAccounts();
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    final all = await sl<WalletRepository>().getAccountViews();
    final withPhrase = all.where((a) => a.hasSeedPhrase).toList();
    if (!mounted) return;

    if (withPhrase.isEmpty) {
      if (context.canPop()) context.pop();
      return;
    }

    // Collapse to one row per distinct seed phrase — several derivation-index
    // accounts can share a single recovery phrase, and the picker must not list
    // the same phrase more than once. Each row's address pills list every wallet
    // address across all accounts derived from that phrase. (Accounts with a null
    // seedPhraseId, if any, each get their own row.)
    final addressesBySeedId = <String, List<String>>{};
    final seen = <String>{};
    final distinct = <Account>[];
    for (final account in withPhrase) {
      final id = account.seedPhraseId;
      if (id == null) {
        distinct.add(account);
        continue;
      }
      (addressesBySeedId[id] ??= <String>[]).addAll(
        account.wallets.map((w) => w.address),
      );
      if (seen.add(id)) distinct.add(account);
    }

    _accounts = distinct;
    _addressesBySeedId = addressesBySeedId;

    if (distinct.length == 1) {
      _selectedAccount = distinct.first;
      await _handleAccountSelected(distinct.first);
      return;
    }

    setState(() => _accountsLoaded = true);
  }

  static List<String> _dedupe(List<String> addresses) {
    final seen = <String>{};
    final out = <String>[];
    for (final a in addresses) {
      if (seen.add(a)) out.add(a);
    }
    return out;
  }

  // ── Account selection ────────────────────────────────────────────────────

  Future<void> _handleAccountSelected(Account account) async {
    _selectedAccount = account;
    if (widget.mode == PhraseListMode.import) {
      await _navigateToImport(account);
    } else {
      await _advanceToPinGate();
    }
  }

  Future<void> _navigateToImport(Account account) async {
    await context.push(
      AppRoutes.importFromPhraseGlobalPath(account.seedPhraseId!),
    );
    if (!mounted) return;

    if (_accounts.length <= 1) {
      if (context.canPop()) context.pop();
    }
  }

  // ── View mode: PIN gate ──────────────────────────────────────────────────

  Future<void> _advanceToPinGate() async {
    final storage = sl<SecureWalletStorage>();
    final biometricsEnabled = await storage.loadBiometricEnabled();
    final hasPin = await storage.hasPin();
    if (!mounted) return;

    // Neither biometrics nor a PIN configured — nothing to gate on.
    if (!biometricsEnabled && !hasPin) {
      await _loadMnemonicAndNavigate();
      return;
    }

    if (biometricsEnabled) {
      final result = await sl<BiometricAuthService>()
          .authenticateForSeedPhrase();
      if (!mounted) return;
      if (result == BiometricAuthResult.success) {
        await _loadMnemonicAndNavigate();
        return;
      }
    }

    // Biometric didn't clear the gate. Require the PIN; without one we can't
    // verify, so leave rather than revealing. (Previously this auto-revealed
    // on a cancelled biometric with no PIN.)
    if (!hasPin) {
      if (mounted && context.canPop()) context.pop();
      return;
    }

    setState(() {
      _step = _Step.pinGate;
      _accountsLoaded = true;
      _biometricsEnabled = biometricsEnabled;
    });
  }

  Future<void> _retryBiometric() async {
    final result = await sl<BiometricAuthService>().authenticateForSeedPhrase();
    if (!mounted) return;
    if (result == BiometricAuthResult.success) {
      await _loadMnemonicAndNavigate();
    }
  }

  void _onPinNumber(String digit) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _pin += digit;
      _pinError = false;
    });
    if (_pin.length == _pinLength) _validatePin();
  }

  void _onPinBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _pinError = false;
    });
  }

  Future<void> _validatePin() async {
    final storage = sl<SecureWalletStorage>();
    if (!await storage.hasPin() || await storage.verifyPin(_pin)) {
      await _loadMnemonicAndNavigate();
    } else {
      setState(() {
        _pinError = true;
        _pin = '';
      });
      unawaited(_shakeController.forward(from: 0));
    }
  }

  Future<void> _loadMnemonicAndNavigate() async {
    final seedPhraseId = _selectedAccount!.seedPhraseId;
    final mnemonic = seedPhraseId == null
        ? null
        : await sl<SecureWalletStorage>().loadMnemonicForSeedPhrase(
            seedPhraseId,
          );
    if (!mounted) return;

    List<String> words;
    if (mnemonic == null || mnemonic.isEmpty) {
      final legacy = await sl<SecureWalletStorage>().loadMnemonic();
      if (!mounted) return;
      if (legacy == null || legacy.isEmpty) {
        AppSnackBar.show(
          context,
          'Recovery phrase not found for this account.',
        );
        return;
      }
      words = legacy.split(' ');
    } else {
      words = mnemonic.split(' ');
    }

    // Replace this screen with the warning → words flow so that pressing
    // back from the words screen returns to Security & Privacy directly.
    context.pushReplacement(AppRoutes.recoveryPhraseWarning, extra: words);
  }

  // ── Back logic ───────────────────────────────────────────────────────────

  void _onBack() {
    switch (_step) {
      case _Step.accountList:
        if (context.canPop()) context.pop();
      case _Step.pinGate:
        final hasList = _accounts.length > 1;
        setState(() {
          _pin = '';
          _pinError = false;
          _step = _Step.accountList;
        });
        if (!hasList && context.canPop()) context.pop();
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      _Step.accountList => _buildAccountList(),
      _Step.pinGate => _buildPinGate(),
    };
  }

  Widget _buildAccountList() {
    if (!_accountsLoaded) {
      return SettingsPageScaffold(
        title: _title,
        child: const SizedBox.shrink(),
      );
    }
    return SettingsPageScaffold(
      title: _title,
      onBack: _onBack,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        itemCount: _accounts.length,
        itemBuilder: (context, i) {
          final account = _accounts[i];
          final index = (i + 1).toString().padLeft(2, '0');
          final addresses = account.seedPhraseId == null
              ? account.wallets.map((w) => w.address).toList()
              : _addressesBySeedId[account.seedPhraseId] ?? const [];
          return SecretRow(
            leading: const SecretGlyphAvatar(),
            title: 'Recovery phrase $index',
            addresses: _dedupe(addresses),
            onTap: () => _handleAccountSelected(account),
          );
        },
      ),
    );
  }

  Widget _buildPinGate() {
    return SettingsPageScaffold(
      title: _title,
      onBack: _onBack,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 40),
            Text(
              'Please enter your pin to view',
              style: MallowTheme.editorialSection,
            ),
            const SizedBox(height: 12),
            Divider(color: context.mallowColors.dividerLight),
            const SizedBox(height: 20),
            AnimatedBuilder(
              animation: _shakeAnimation,
              builder: (context, child) => Transform.translate(
                offset: Offset(_shakeAnimation.value, 0),
                child: child,
              ),
              child: _PinDots(
                length: _pinLength,
                filled: _pin.length,
                isError: _pinError,
              ),
            ),
            const SizedBox(height: 20),
            CustomNumberPad(
              onNumberTap: _onPinNumber,
              onBackspace: _onPinBackspace,
            ),
            if (_biometricsEnabled) ...[
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: _retryBiometric,
                  child: Text(
                    'Use biometrics',
                    style: MallowTheme.uiIdentity.copyWith(
                      color: context.mallowColors.accent,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ─── PIN dots ─────────────────────────────────────────────────────────────────

class _PinDots extends StatelessWidget {
  const _PinDots({
    required this.length,
    required this.filled,
    required this.isError,
  });

  final int length;
  final int filled;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final on = i < filled;
        return Container(
          width: MallowTheme.pinDotSize,
          height: MallowTheme.pinDotSize,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isError && on
                ? context.mallowColors.error
                : on
                ? context.mallowColors.accent
                : context.mallowColors.dividerLight,
          ),
        );
      }),
    );
  }
}
