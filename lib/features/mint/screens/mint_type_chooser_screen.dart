import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/chooser_type_row.dart';
import '../../../shared/widgets/mallow_header.dart';
import '../widgets/mint_progress_bar.dart';

/// Entry screen for the mint flow — lets the user pick what they want to
/// mint. All three types (1/1 artwork, Editions, Collection) are implemented
/// and navigate into `Mint1Of1Screen` with the matching `MintCreateType`;
/// none of the rows is disabled.
///
class MintTypeChooserScreen extends StatelessWidget {
  const MintTypeChooserScreen({super.key});

  // Step 1 of 7 across the full mint flow (chooser + 5 form steps +
  // success). Matches the denominator used by `MintState.progressFraction`.
  static const _progressFraction = 1 / 7;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Scaffold(
      backgroundColor: colors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MallowTheme.spacing20,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const MallowHeader(title: 'Mint artwork'),
                        const SizedBox(height: MallowTheme.spacing20),
                        const MintProgressBar(fraction: _progressFraction),
                        const SizedBox(height: MallowTheme.spacing20),
                        Text(
                          'Choose artwork type',
                          style: MallowTheme.uiLabel.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: MallowTheme.spacing20),
                        ChooserTypeRow(
                          svgAsset: 'assets/icons/my_art.svg',
                          title: '1/1 artwork',
                          subtitle: 'One artwork, one owner',
                          onTap: () => context.push(AppRoutes.mint1Of1),
                        ),
                        const SizedBox(height: MallowTheme.spacing20),
                        ChooserTypeRow(
                          svgAsset: 'assets/icons/edition.svg',
                          title: 'Editions',
                          subtitle: 'One artwork, many collectors',
                          onTap: () => context.push(AppRoutes.mintEditions),
                        ),
                        const SizedBox(height: MallowTheme.spacing20),
                        ChooserTypeRow(
                          svgAsset: 'assets/icons/art_track.svg',
                          title: 'Collection',
                          subtitle: 'Group related artworks together',
                          onTap: () => context.push(AppRoutes.mintCollection),
                        ),
                        const Spacer(),
                        const _CoreStandardFooter(),
                        const SizedBox(height: MallowTheme.spacingXl),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CoreStandardFooter extends StatelessWidget {
  const _CoreStandardFooter();

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return RichText(
      text: TextSpan(
        style: MallowTheme.uiCaption.copyWith(color: colors.textSecondary),
        children: [
          const TextSpan(text: 'Please note:\n'),
          const TextSpan(
            text:
                'All tokens minted using mallow wallet will use Metaplex Core as the token standard. If you wish to mint using Metaplex Legacy, please use the website. ',
          ),
          TextSpan(
            text: 'https://mallow.art/create',
            style: MallowTheme.uiCaption.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}
