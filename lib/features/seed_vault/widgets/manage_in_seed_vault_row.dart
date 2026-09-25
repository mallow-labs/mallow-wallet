import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../../../core/observability/app_logger.dart';
import '../../../core/services/seed_vault_service.dart';
import '../../../di.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/menu_row.dart';

const _tag = 'SeedVaultSettings';

/// Opens Seed Vault's own settings screen for the seed holding one of
/// [addresses].
///
/// The auth token that call needs is resolved at tap time from the content
/// provider — which raises no UI — and thrown away again. Nothing here is
/// persisted: a token changes on every deauthorize/re-authorize, so a stored
/// one is a stale token waiting to fail.
///
/// A resolution miss means no authorized seed holds this wallet any more
/// (deauthorized, or the seed was deleted). There is no CTA for that here:
/// opening Seed Vault settings *needs* a token, which is exactly what is
/// missing, so the row says what happened instead of offering a dead button.
class ManageInSeedVaultRow extends StatelessWidget {
  const ManageInSeedVaultRow({required this.addresses, super.key});

  final List<String> addresses;

  Future<void> _open(BuildContext context) async {
    try {
      final rows = await sl<SeedVaultService>().listAccounts();
      final match = rows
          .where((r) => addresses.contains(r.address))
          .firstOrNull;
      if (match == null) {
        if (context.mounted) {
          AppSnackBar.show(
            context,
            'This wallet is no longer authorized in Seed Vault.',
            type: AppSnackBarType.error,
          );
        }
        return;
      }
      await sl<SeedVaultService>().showSeedSettings(match.authToken);
    } catch (e) {
      AppLogger.error(_tag, 'could not open Seed Vault settings', e);
      if (!context.mounted) return;
      AppSnackBar.show(
        context,
        'Could not open Seed Vault.',
        type: AppSnackBarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) => MenuRow(
    icon: 'assets/icons/shield_half.svg',
    label: 'Manage in Seed Vault',
    onTap: () => _open(context),
  );
}
