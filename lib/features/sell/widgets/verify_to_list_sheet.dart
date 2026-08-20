import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';
import '../services/listing_eligibility.dart';

/// The mallow creator application form — `applyUrl` in
/// `Constants`.
const String applyUrl = 'https://apply.mallow.art';

/// Mobile port of the webapp's `VerifyToList`
/// (`VerifyToList`), shown in
/// place of the sale-type chooser when [evaluateListingEligibility] blocks
/// the flow. Copy and CTAs are branch-for-branch identical to the web page;
/// the layout is a mallow sheet instead of a card because that is how mobile
/// interrupts a flow.
///
/// Resolves to the action the user picked, so the caller — which owns the
/// listing flow's place on the navigation stack — does the navigating.
Future<VerifyToListAction?> showVerifyToListSheet(
  BuildContext context,
  ListingBlockReason reason,
) {
  return showMallowSheet<VerifyToListAction>(
    context: context,
    isScrollControlled: true,
    builder: (_) => VerifyToListSheet(reason: reason),
  );
}

/// What the sheet was dismissed with. `null` (plain dismissal) means the user
/// backed out; [editProfile] asks the caller to open the profile editor once
/// the listing flow itself has been unwound.
enum VerifyToListAction { editProfile }

class VerifyToListSheet extends StatelessWidget {
  const VerifyToListSheet({required this.reason, super.key});

  final ListingBlockReason reason;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MallowTheme.popupRadius),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacing20,
                MallowTheme.spacing20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Verify to list',
                    style: MallowTheme.uiLabel.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: colors.textPrimary,
                  ),
                  const SizedBox(height: MallowTheme.spacingMd),
                  Text(
                    'Sorry, this item cannot be listed.',
                    textAlign: TextAlign.center,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _body(reason),
                    textAlign: TextAlign.center,
                    style: MallowTheme.uiCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  ..._cta(context, reason),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `VerifyToList` — four mutually exclusive branches, verbatim.
  static String _body(ListingBlockReason reason) {
    switch (reason) {
      case ListingBlockReason.flagged:
        return 'The creator of this artwork has been flagged for suspicious '
            'activity. Please let us know in our discord if you think a '
            'mistake has been made.';
      case ListingBlockReason.notApprovedCreator:
        return 'There is an application process to go through before you can '
            'list primary sales - please fill out the form below.';
      case ListingBlockReason.incompleteProfile:
        return 'Please complete your profile with a username, profile picture, '
            'and twitter account.';
      case ListingBlockReason.twitterNotVerified:
        return 'Please connect a twitter account to your profile before '
            'listing primary sales.';
    }
  }

  /// `VerifyToList` — the application form for a non-approved
  /// creator, edit-profile for an incomplete profile, nothing otherwise.
  static List<Widget> _cta(BuildContext context, ListingBlockReason reason) {
    switch (reason) {
      case ListingBlockReason.notApprovedCreator:
        return [
          const SizedBox(height: MallowTheme.spacing20),
          MallowButton(
            label: 'Open application form',
            isFullWidth: true,
            onPressed: () async {
              final uri = Uri.parse(applyUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
              }
            },
          ),
        ];
      case ListingBlockReason.incompleteProfile:
        return [
          const SizedBox(height: MallowTheme.spacing20),
          MallowButton(
            label: 'Edit profile',
            isFullWidth: true,
            // Hands the navigation back to the caller: it has to unwind the
            // listing flow first, and a push from here would be popped right
            // back off by that unwind.
            onPressed: () =>
                Navigator.of(context).pop(VerifyToListAction.editProfile),
          ),
        ];
      case ListingBlockReason.flagged:
      case ListingBlockReason.twitterNotVerified:
        return const [];
    }
  }
}
