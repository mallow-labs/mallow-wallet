import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../features/auction/sheets/physical_edit_sheet.dart';
import '../../features/auction/sheets/rewards_edit_sheet.dart';
import '../theme/mallow_theme.dart';
import 'mallow_checkbox.dart';
import 'mallow_svg_icon.dart';
import 'tap_target_expander.dart';

/// Listing-flow step: physical artwork + rewards opt-ins, plus a
/// shipping-details checkbox when a physical is included. Bloc-agnostic —
/// driven by props + callbacks so both the auction and fixed-price flows
/// can host it. The two edit sheets it opens are bloc-free.
///
/// When [showVerifiedSellerOptions] is false the step renders the
/// not-available state instead, mirroring the webapp's
/// `useListingContext().showVerifiedSellerOptions` check.
class AdditionalOptionsStep extends StatelessWidget {
  const AdditionalOptionsStep({
    required this.showVerifiedSellerOptions,
    required this.includePhysical,
    required this.physical,
    required this.includeRewards,
    required this.rewardsDescription,
    required this.askForShippingAddress,
    required this.showPhysicalUnlockPrice,
    required this.onIncludePhysicalChanged,
    required this.onPhysicalChanged,
    required this.onIncludeRewardsChanged,
    required this.onRewardsDescriptionChanged,
    required this.onAskForShippingAddressChanged,
    super.key,
  });

  final bool showVerifiedSellerOptions;
  final bool includePhysical;
  final PhysicalDetailsPayload? physical;
  final bool includeRewards;
  final String rewardsDescription;
  final bool askForShippingAddress;

  /// Whether the physical-edit sheet should expose the optional unlock-price
  /// field — auction listings only, mirroring the webapp.
  final bool showPhysicalUnlockPrice;

  final ValueChanged<bool> onIncludePhysicalChanged;
  final ValueChanged<PhysicalDetailsPayload> onPhysicalChanged;
  final ValueChanged<bool> onIncludeRewardsChanged;
  final ValueChanged<String> onRewardsDescriptionChanged;
  final ValueChanged<bool> onAskForShippingAddressChanged;

  Future<PhysicalEditResult?> _openPhysicalSheet(BuildContext context) =>
      showPhysicalEditSheet(
        context,
        initial: physical,
        showUnlockPrice: showPhysicalUnlockPrice,
      );

  Future<RewardsEditResult?> _openRewardsSheet(BuildContext context) =>
      showRewardsEditSheet(context, initial: rewardsDescription);

  @override
  Widget build(BuildContext context) {
    if (!showVerifiedSellerOptions) {
      return _NotAvailableState();
    }

    final colors = context.mallowColors;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MallowTheme.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _OptionRow(
            included: includePhysical,
            label: 'Add physical artwork to the sale',
            onTap: () async {
              if (includePhysical) {
                onIncludePhysicalChanged(false);
                return;
              }
              // Opening from the disabled state: configure first, enable on
              // save. Cancel/Remove leaves the option off.
              switch (await _openPhysicalSheet(context)) {
                case PhysicalEditSaved(:final payload):
                  onPhysicalChanged(payload);
                  onIncludePhysicalChanged(true);
                case PhysicalEditRemoved():
                case null:
                  break;
              }
            },
            onEdit: () async {
              switch (await _openPhysicalSheet(context)) {
                case PhysicalEditSaved(:final payload):
                  onPhysicalChanged(payload);
                case PhysicalEditRemoved():
                  onIncludePhysicalChanged(false);
                case null:
                  break;
              }
            },
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          _OptionRow(
            included: includeRewards,
            label: 'Add rewards to the sale',
            onTap: () async {
              if (includeRewards) {
                onIncludeRewardsChanged(false);
                return;
              }
              switch (await _openRewardsSheet(context)) {
                case RewardsEditSaved(:final description):
                  onRewardsDescriptionChanged(description);
                  onIncludeRewardsChanged(true);
                case RewardsEditRemoved():
                case null:
                  break;
              }
            },
            onEdit: () async {
              switch (await _openRewardsSheet(context)) {
                case RewardsEditSaved(:final description):
                  onRewardsDescriptionChanged(description);
                case RewardsEditRemoved():
                  onIncludeRewardsChanged(false);
                case null:
                  break;
              }
            },
          ),
          if (includePhysical) ...[
            const SizedBox(height: MallowTheme.spacingXl),
            MallowCheckbox(
              value: askForShippingAddress,
              onChanged: onAskForShippingAddressChanged,
              label: 'Require shipping details from collectors',
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              'Details will be sent to your email address',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
          const Spacer(),
          Text(
            'Physicals and rewards are the responsibility of the seller to '
            'distribute. No disputes will be resolved by mallow. Any abuse '
            'of this feature will result in suspension from selling on mallow.',
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Single opt-in row: leading status icon (green check when included, plus
/// when not), label, and an outlined "Edit" pill that appears once the
/// option is on. Tapping the row toggles inclusion; tapping the pill opens
/// the edit sheet.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.included,
    required this.label,
    required this.onTap,
    required this.onEdit,
  });

  final bool included;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Center(
                child: included
                    ? MallowSvgIcon(
                        'assets/icons/checkmark.svg',
                        width: 16,
                        color: colors.positive,
                      )
                    : MallowSvgIcon(
                        'assets/icons/plus.svg',
                        width: 16,
                        color: colors.textPrimary,
                      ),
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            Expanded(
              child: Text(
                label,
                style: MallowTheme.uiMeta.copyWith(color: colors.textPrimary),
              ),
            ),
            if (included) ...[
              const SizedBox(width: MallowTheme.spacingSm),
              _EditPill(onTap: onEdit),
            ],
          ],
        ),
      ),
    );
  }
}

class _EditPill extends StatelessWidget {
  const _EditPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return TapTargetExpander(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: colors.textPrimary),
            borderRadius: BorderRadius.circular(MallowTheme.radiusFull),
          ),
          child: Text(
            'Edit',
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _NotAvailableState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MallowTheme.spacing20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MallowSvgIcon(
              'assets/icons/truck.svg',
              width: 48,
              height: 48,
              color: colors.textTertiary,
            ),
            const SizedBox(height: MallowTheme.spacingMd),
            Text(
              'No additional options available',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: MallowTheme.spacingSm),
            Text(
              'Physical artworks and rewards are available on primary-market '
              'sales.',
              style: MallowTheme.uiCaption.copyWith(
                color: colors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
