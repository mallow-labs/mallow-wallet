import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../shared/theme/mallow_theme.dart';
import '../../../../shared/utils/artwork_web_link.dart';
import '../../../../shared/widgets/mallow_button.dart';
import '../../services/artwork_bloc.dart';
import 'artwork_sheet_frame.dart';

/// Stand-in sheet for listing types that run on the mallow web app
/// (gumball / airdrop / store / jellybean). Links out to the artwork's web page
/// until the in-app surface for these flows exists.
///
/// Triggered by `gumball` ∨ `airdrop` ∨ `store` ∨ `jellybean` — see
/// `docs/artwork_state.md`.
class ArtworkExternalLinkSheet extends StatelessWidget {
  const ArtworkExternalLinkSheet({required this.listingType, super.key});

  final ListingType listingType;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;

    return ArtworkSheetFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title(),
            style: MallowTheme.uiBody.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'This sale runs on the mallow web app.',
            style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: MallowTheme.spacingMd),
          MallowButton(
            label: 'View on mallow web',
            onPressed: () => _openOnWeb(context),
            isFullWidth: true,
          ),
        ],
      ),
    );
  }

  /// The mint comes from the [ArtworkBloc] the artwork screen provides above
  /// this sheet — the sheet itself is only ever built from an [ArtworkLoaded]
  /// state, so the read is always populated.
  Future<void> _openOnWeb(BuildContext context) async {
    final state = context.read<ArtworkBloc>().state;
    if (state is! ArtworkLoaded) return;
    await openArtworkOnWeb(state.artwork.mintAccount);
  }

  String _title() {
    switch (listingType) {
      case ListingType.gumball:
        return 'Gumball drop';
      case ListingType.airdrop:
        return 'Airdrop';
      case ListingType.store:
        return 'Store listing';
      case ListingType.jellybean:
        return 'Jellybean drop';
      // ignore: no_default_cases
      default:
        return 'External listing';
    }
  }
}
