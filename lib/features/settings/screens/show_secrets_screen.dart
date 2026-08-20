import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/account.dart';
import '../../../core/router/app_router.dart';
import '../../../core/security/reauth_gate.dart';
import '../../../core/security/secure_storage.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/account_avatar.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/secret_row.dart';
import '../widgets/settings_page_scaffold.dart';

/// "Your secrets" — the settings surface for revealing recovery phrases and
/// imported private keys.
///
/// The biometric/PIN gate runs once when entering Security & Privacy, so this
/// screen lists two sections directly:
/// • **Recovery phrases** — one row per distinct seed phrase. Tapping reveals
///   the shared word grid (warning → words).
/// • **Private keys** — one row per imported private-key account. Tapping
///   reveals the raw key (warning → key + copy).
///
/// Empty sections are omitted entirely.
///
/// [preAuthenticated] is set only by the in-app "Show secrets" tap, which
/// already cleared the biometric/PIN gate when entering Security & Privacy.
/// Any other route into this screen (deep link, programmatic push, a future
/// refactor) leaves it `false`, so the screen self-gates on entry before
/// loading or revealing anything — this data (every seed phrase + imported
/// private key) must never be shown without authentication. Note `extra` is an
/// in-process object go_router can't populate from a URL, so a deep link can't
/// forge the pre-authenticated flag.
class ShowSecretsScreen extends StatefulWidget {
  const ShowSecretsScreen({super.key, this.preAuthenticated = false});

  final bool preAuthenticated;

  @override
  State<ShowSecretsScreen> createState() => _ShowSecretsScreenState();
}

class _ShowSecretsScreenState extends State<ShowSecretsScreen> {
  bool _loading = true;

  // Recovery phrases — one entry per distinct seed phrase.
  List<_PhraseEntry> _phrases = const [];
  // Imported private-key accounts.
  List<Account> _keyAccounts = const [];

  @override
  void initState() {
    super.initState();
    if (widget.preAuthenticated) {
      _loadAccounts();
    } else {
      // Reached without the Security & Privacy entry gate — challenge before
      // loading. `_loading` stays true (blank scaffold) until the gate clears.
      WidgetsBinding.instance.addPostFrameCallback((_) => _gateThenLoad());
    }
  }

  Future<void> _gateThenLoad() async {
    final passed = await requireReauth(context);
    if (!mounted) return;
    if (!passed) {
      context.pop();
      return;
    }
    await _loadAccounts();
  }

  // ── Data ───────────────────────────────────────────────────────────────────

  Future<void> _loadAccounts() async {
    final all = await sl<WalletRepository>().getAccountViews();
    if (!mounted) return;

    // Recovery phrases — collapse every seed-based account into one row per
    // distinct seed phrase; chips list every wallet address across all the
    // accounts derived from that phrase. Seed-based accounts with a null
    // seedPhraseId fall back to the single legacy mnemonic and collapse into a
    // single trailing row.
    final order = <String>[];
    final addrsById = <String, List<String>>{};
    final seen = <String>{};
    final legacyAddrs = <String>[];
    for (final account in all.where((a) => a.hasSeedPhrase)) {
      final id = account.seedPhraseId;
      final addrs = account.wallets.map((w) => w.address);
      if (id == null) {
        legacyAddrs.addAll(addrs);
        continue;
      }
      if (seen.add(id)) order.add(id);
      (addrsById[id] ??= <String>[]).addAll(addrs);
    }

    final phrases = <_PhraseEntry>[];
    for (final id in order) {
      phrases.add(
        _PhraseEntry(
          label: 'Recovery phrase ${_pad(phrases.length)}',
          seedPhraseId: id,
          addresses: _dedupe(addrsById[id]!),
        ),
      );
    }
    if (legacyAddrs.isNotEmpty) {
      phrases.add(
        _PhraseEntry(
          label: 'Recovery phrase ${_pad(phrases.length)}',
          seedPhraseId: null,
          addresses: _dedupe(legacyAddrs),
        ),
      );
    }

    setState(() {
      _phrases = phrases;
      _keyAccounts = all
          .where((a) => a.kind == AccountKind.privateKey)
          .toList();
      _loading = false;
    });
  }

  static String _pad(int zeroBasedIndex) =>
      (zeroBasedIndex + 1).toString().padLeft(2, '0');

  static List<String> _dedupe(List<String> addresses) {
    final seen = <String>{};
    final out = <String>[];
    for (final a in addresses) {
      if (seen.add(a)) out.add(a);
    }
    return out;
  }

  // ── Reveal ─────────────────────────────────────────────────────────────────

  Future<void> _revealPhrase(_PhraseEntry entry) async {
    final storage = sl<SecureWalletStorage>();
    var mnemonic = entry.seedPhraseId == null
        ? await storage.loadMnemonic()
        : await storage.loadMnemonicForSeedPhrase(entry.seedPhraseId!);
    if (!mounted) return;

    // Keyed phrases may still live under the legacy single-mnemonic key.
    if ((mnemonic == null || mnemonic.isEmpty) && entry.seedPhraseId != null) {
      mnemonic = await storage.loadMnemonic();
      if (!mounted) return;
    }

    if (mnemonic == null || mnemonic.isEmpty) {
      AppSnackBar.show(context, 'Recovery phrase not found for this account.');
      return;
    }

    // Reuse the existing warning → words flow. The warning screen replaces
    // itself with the word grid, so backing out of the grid returns here.
    unawaited(
      context.push(AppRoutes.recoveryPhraseWarning, extra: mnemonic.split(' ')),
    );
  }

  Future<void> _revealKey(Account account) async {
    final wallet = account.wallets.isEmpty ? null : account.wallets.first;
    if (wallet == null) {
      AppSnackBar.show(context, 'Private key not found for this account.');
      return;
    }
    final key = await sl<SecureWalletStorage>().loadPrivateKey(wallet.id);
    if (!mounted) return;
    if (key == null || key.isEmpty) {
      AppSnackBar.show(context, 'Private key not found for this account.');
      return;
    }
    unawaited(context.push(AppRoutes.privateKeyWarning, extra: key));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SettingsPageScaffold(
        title: 'Your secrets',
        child: SizedBox.shrink(),
      );
    }
    return _buildList();
  }

  Widget _buildList() {
    final children = <Widget>[];

    if (_phrases.isNotEmpty) {
      children.add(_sectionHeader(context, 'Recovery phrases'));
      for (final phrase in _phrases) {
        children.add(
          SecretRow(
            leading: const SecretGlyphAvatar(),
            title: phrase.label,
            addresses: phrase.addresses,
            onTap: () => _revealPhrase(phrase),
          ),
        );
      }
    }

    if (_keyAccounts.isNotEmpty) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 24));
      children.add(_sectionHeader(context, 'Private keys'));
      for (final account in _keyAccounts) {
        children.add(
          SecretRow(
            leading: AccountAvatar(seed: account.avatarSeed, size: 24),
            title: account.name,
            addresses: account.wallets.map((w) => w.address).toList(),
            onTap: () => _revealKey(account),
          ),
        );
      }
    }

    return SettingsPageScaffold(
      title: 'Your secrets',
      child: children.isEmpty
          ? _emptyState(context)
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              children: children,
            ),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: MallowTheme.uiLabel.copyWith(
        color: context.mallowColors.textSecondary,
      ),
    ),
  );

  Widget _emptyState(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Text(
        'No exportable secrets on this device.',
        textAlign: TextAlign.center,
        style: MallowTheme.uiMeta.copyWith(
          color: context.mallowColors.textSecondary,
        ),
      ),
    ),
  );
}

/// One distinct recovery phrase, with the addresses of every wallet derived
/// from it. A null [seedPhraseId] is the legacy single-mnemonic fallback.
class _PhraseEntry {
  const _PhraseEntry({
    required this.label,
    required this.seedPhraseId,
    required this.addresses,
  });

  final String label;
  final String? seedPhraseId;
  final List<String> addresses;
}
