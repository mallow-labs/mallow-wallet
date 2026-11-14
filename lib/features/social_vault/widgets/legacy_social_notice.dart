import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/account.dart';
import '../../../core/observability/app_logger.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/preferences_service.dart';
import '../../../core/services/wallet_repository.dart';
import '../../../di.dart';
import '../../../shared/widgets/confirm_sheet.dart';
import '../../../shared/utils/social_wallet_copy.dart';

/// The accounts that still owe their one-time notice about the older sign-in:
/// every account of [accounts] that answers [Account.isLegacySocial] and is
/// not in [shown]. A social vault wallet never owes one.
List<Account> legacySocialNoticesDue(
  Iterable<Account> accounts,
  Set<String> shown,
) => [
  for (final account in accounts)
    if (account.isLegacySocial && !shown.contains(account.id)) account,
];

/// What the notice says for a [providerName] ("Google" or "Apple") wallet:
/// what the mark on it means, how it is recovered now, and what to do today.
String legacySocialNoticeMessage(String providerName) =>
    '${legacySocialSentence(providerName)}\n\n'
    '$legacySocialRecoverySentence This app no longer supports that sign-in.\n\n'
    'Save the wallet’s keys now, so you have your own copy.';

/// Show each wallet from the older Google or Apple sign-in its one-time
/// notice: what the mark on its icon means, that a lost phone is recovered
/// through the older sign-in on the mallow website, and a shortcut to Show
/// secrets so its keys can be saved now.
///
/// Called after an unlock, so it never sits on top of the lock screen. Once
/// per wallet, ever: the account is recorded as shown before its sheet opens,
/// so a sheet the app is killed under does not come back. There is no banner
/// behind it — the mark and the sentence on the wallet's own screens stay.
///
/// Stops after a wallet whose owner chose Show secrets (the screen that opens
/// is where they are going); any other wallet is told at the next launch.
Future<void> maybeShowLegacySocialNotice() async {
  final prefs = sl<PreferencesService>();
  final List<Account> due;
  try {
    due = legacySocialNoticesDue(
      await sl<WalletRepository>().getAccountViews(),
      prefs.legacySocialNoticeShown,
    );
  } catch (e) {
    AppLogger.warn('LegacySocialNotice', 'lookup failed: ${e.runtimeType}');
    return;
  }
  for (final account in due) {
    final context = AppRoutes.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    await prefs.markLegacySocialNoticeShown(account.id);
    if (!context.mounted) return;
    if (await showLegacySocialNotice(context, account)) return;
  }
}

/// The notice sheet for [account]. Returns true when the user went to Show
/// secrets, which opens behind its own PIN or biometric gate: the route is
/// pushed without the pre-authenticated flag, so the screen challenges before
/// it lists or reveals anything.
Future<bool> showLegacySocialNotice(
  BuildContext context,
  Account account,
) async {
  final providerName = account.socialProviderName;
  final save = await showConfirmSheet(
    context,
    title: 'About your $providerName wallet',
    message: legacySocialNoticeMessage(providerName),
    confirmLabel: 'Show secrets',
    cancelLabel: 'Not now',
  );
  if (save != true || !context.mounted) return false;
  // Not awaited: the push completes only when Show secrets is left again.
  unawaited(GoRouter.of(context).push(AppRoutes.recoveryPhrase));
  return true;
}
