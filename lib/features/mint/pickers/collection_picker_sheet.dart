import 'package:flutter/material.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../di.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/utils/address_utils.dart';
import '../../../shared/widgets/full_screen_sheet.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../data/mint_repository.dart';

/// Result returned by the collection picker — carries the on-chain
/// reference (for the mint request), the display name (for the pill),
/// and the full preview render so the bloc can auto-populate categories,
/// tags, traits, and royalties from the parent collection.
typedef PickedMintCollection = ({
  MintCollectionRef ref,
  String name,
  CollectionPreviewRender source,
});

/// A committed picker outcome. A null [selection] is an explicit
/// "No collection" — distinct from the picker returning `null`, which means
/// the user backed out without choosing. Clearing the parent of a Master
/// Edition is an irreversible on-chain detach, so a swipe-dismiss must never
/// be read as one.
typedef MintCollectionChoice = ({PickedMintCollection? selection});

/// Bottom-sheet picker backed by `/v0/collections/byCreator/{pubkey}`.
///
/// Returns `null` when the sheet is dismissed without a choice; otherwise a
/// [MintCollectionChoice] whose `selection` is null for the "No collection"
/// row.
Future<MintCollectionChoice?> showMintCollectionPicker({
  required BuildContext context,
  required String userPubkey,
  MintCollectionRef? current,
}) {
  return showFullScreenSheet<MintCollectionChoice?>(
    context: context,
    child: _CollectionPickerView(userPubkey: userPubkey, current: current),
  );
}

class _CollectionPickerView extends StatefulWidget {
  const _CollectionPickerView({
    required this.userPubkey,
    required this.current,
  });

  final String userPubkey;
  final MintCollectionRef? current;

  @override
  State<_CollectionPickerView> createState() => _CollectionPickerViewState();
}

class _CollectionPickerViewState extends State<_CollectionPickerView> {
  late Future<List<CollectionPreviewRender>> _future;

  @override
  void initState() {
    super.initState();
    _future = sl<MintRepository>().listCollectionsForCreator(widget.userPubkey);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacing20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: MallowTheme.spacingMd),
            child: Text(
              'Choose a collection',
              style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
              textAlign: TextAlign.left,
            ),
          ),
          const SizedBox(height: MallowTheme.spacing20),
          Expanded(
            child: FutureBuilder<List<CollectionPreviewRender>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: MallowLoadingIndicator());
                }
                if (snapshot.hasError) {
                  debugPrint(
                    '[CollectionPicker] load failed: ${snapshot.error}',
                  );
                  if (snapshot.stackTrace != null) {
                    debugPrintStack(
                      stackTrace: snapshot.stackTrace,
                      label: 'CollectionPicker',
                    );
                  }
                  return Center(
                    child: Text(
                      'Could not load collections',
                      style: MallowTheme.uiBody.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  );
                }
                // Collections without an on-chain `nft` can't be minted
                // into, so skip them in the picker.
                final collections = (snapshot.data ?? const [])
                    .where((c) => c.nft != null)
                    .toList(growable: false);
                return ListView.separated(
                  padding: EdgeInsets.only(bottom: sheetBottomInset(context)),
                  itemCount: collections.length + 1,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: MallowTheme.spacingSm),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _CollectionRow(
                        title: 'No collection',
                        selected: widget.current == null,
                        onTap: () => Navigator.of(
                          context,
                        ).pop<MintCollectionChoice>((selection: null)),
                      );
                    }
                    final c = collections[index - 1];
                    final mintAccount = c.nft!.mintAccount;
                    return _CollectionRow(
                      title: c.name,
                      subtitle: truncateAddress(mintAccount, lead: 4, trail: 4),
                      imageUrl: c.imageUrl ?? c.nft!.imageUrl,
                      selected: widget.current?.mintAccount == mintAccount,
                      onTap: () =>
                          Navigator.of(context).pop<MintCollectionChoice>((
                            selection: (
                              ref: MintCollectionRef(
                                mintAccount: mintAccount,
                                tokenStandard: TokenStandard.coreCollection,
                              ),
                              name: c.name,
                              source: c,
                            ),
                          )),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.imageUrl,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final String? imageUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(MallowTheme.spacingMd),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(MallowTheme.popupRadius),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: imageUrl != null
                  ? MallowNetworkImage(
                      imageUrl: imageUrl!,
                      logicalSize: 48,
                      width: 48,
                      height: 48,
                      borderRadius: BorderRadius.circular(
                        MallowTheme.radiusPrimary,
                      ),
                      errorBuilder: (_) =>
                          Container(color: colors.surfaceMuted),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(
                        MallowTheme.radiusPrimary,
                      ),
                      child: Container(color: colors.surfaceMuted),
                    ),
            ),
            const SizedBox(width: MallowTheme.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: MallowTheme.uiBody.copyWith(
                      color: colors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: MallowTheme.uiCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
