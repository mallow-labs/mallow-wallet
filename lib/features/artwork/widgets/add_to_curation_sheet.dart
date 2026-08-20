import 'package:flutter/material.dart';

import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/mallow_button.dart';
import '../../../shared/widgets/mallow_checkbox.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_sheet.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/sheet_drag_handle.dart';

/// A user's curation shown in the Add to Curation picker.
class UserCuration {
  const UserCuration({
    required this.id,
    required this.name,
    required this.artworkCount,
    this.thumbnailUrls = const [],
    this.isSelected = false,
    this.visibility = 'public',
  });

  final String id;
  final String name;
  final int artworkCount;

  /// Up to 4 thumbnail URLs for the 2×2 preview grid.
  final List<String> thumbnailUrls;

  /// Whether this curation currently contains the artwork.
  final bool isSelected;

  /// Backend visibility — `private` / `public` / `featured`.
  final String visibility;

  /// True when only the owner (signed-in) can see this curation.
  bool get isPrivate => visibility == 'private';

  UserCuration copyWith({bool? isSelected}) {
    return UserCuration(
      id: id,
      name: name,
      artworkCount: artworkCount,
      thumbnailUrls: thumbnailUrls,
      isSelected: isSelected ?? this.isSelected,
      visibility: visibility,
    );
  }
}

/// Shows the Add to Curation bottom sheet.
///
/// [onToggleCuration] is called each time the user taps a curation row, so
/// the artwork can be added to (or removed from) multiple curations in one
/// session.
/// [onCreateNew] is called when the user taps the "New Curation" button.
///   It should create the curation, add the artwork to it, and return the
///   new [UserCuration] (or null if creation was cancelled / failed). On
///   success the sheet dismisses.
Future<void> showAddToCurationSheet(
  BuildContext context, {
  required String artworkTitle,
  required List<UserCuration> curations,
  String? artworkImageUrl,
  String? artistUsername,
  void Function(String curationId, bool isSelected)? onToggleCuration,
  Future<UserCuration?> Function()? onCreateNew,
}) {
  return showMallowSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AddToCurationSheet(
      artworkTitle: artworkTitle,
      artworkImageUrl: artworkImageUrl,
      artistUsername: artistUsername,
      curations: curations,
      onToggleCuration: onToggleCuration,
      onCreateNew: onCreateNew,
    ),
  );
}

class _AddToCurationSheet extends StatefulWidget {
  const _AddToCurationSheet({
    required this.artworkTitle,
    required this.curations,
    this.artworkImageUrl,
    this.artistUsername,
    this.onToggleCuration,
    this.onCreateNew,
  });

  final String artworkTitle;
  final String? artworkImageUrl;
  final String? artistUsername;
  final List<UserCuration> curations;
  final void Function(String curationId, bool isSelected)? onToggleCuration;
  final Future<UserCuration?> Function()? onCreateNew;

  @override
  State<_AddToCurationSheet> createState() => _AddToCurationSheetState();
}

class _AddToCurationSheetState extends State<_AddToCurationSheet> {
  late List<UserCuration> _curations;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _curations = List.of(widget.curations);
  }

  void _toggleCuration(int index) {
    // Block row toggles while a "New Curation" create is in flight — the
    // sheet stays open during that async work, so without this guard the
    // user could fire add/remove writes against a sheet that's about to
    // dismiss on success.
    if (_creating) return;
    final curation = _curations[index];
    final newSelected = !curation.isSelected;
    setState(() {
      _curations[index] = curation.copyWith(isSelected: newSelected);
    });
    widget.onToggleCuration?.call(curation.id, newSelected);
  }

  Future<void> _handleCreateNew() async {
    if (_creating || widget.onCreateNew == null) return;
    setState(() => _creating = true);
    try {
      // onCreateNew creates the curation and adds the artwork; on success
      // the picker's job is done, so dismiss it.
      final newCuration = await widget.onCreateNew!();
      if (newCuration != null && mounted) {
        Navigator.of(context).pop();
        return;
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = sheetBottomInset(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.8;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: BoxDecoration(
          color: context.mallowColors.bgPrimary,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MallowTheme.radiusLg),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetDragHandle(),
            // Title + artwork preview
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MallowTheme.spacing20,
                MallowTheme.spacingMd,
                MallowTheme.spacing20,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Add to Curation',
                    style: MallowTheme.editorialSubhead.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: MallowTheme.spacingXl),
                  _ArtworkPreviewRow(
                    title: widget.artworkTitle,
                    imageUrl: widget.artworkImageUrl,
                    artistUsername: widget.artistUsername,
                  ),
                ],
              ),
            ),
            // Curation list
            Flexible(
              child: _curations.isEmpty
                  ? const SizedBox(height: MallowTheme.spacingXl)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(
                        MallowTheme.spacing20,
                        MallowTheme.spacingXl,
                        MallowTheme.spacing20,
                        MallowTheme.spacingMd,
                      ),
                      shrinkWrap: true,
                      itemCount: _curations.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(
                            bottom: MallowTheme.spacingMd,
                          ),
                          child: _CurationRow(
                            curation: _curations[index],
                            enabled: !_creating,
                            onTap: () => _toggleCuration(index),
                          ),
                        );
                      },
                    ),
            ),
            // New curation button pinned at the bottom
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MallowTheme.spacing20,
              ),
              child: MallowButton(
                label: 'New Curation',
                onPressed: _handleCreateNew,
                isLoading: _creating,
                isFullWidth: true,
              ),
            ),
            SizedBox(height: bottomPad),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _ArtworkPreviewRow extends StatelessWidget {
  const _ArtworkPreviewRow({
    required this.title,
    this.imageUrl,
    this.artistUsername,
  });

  final String title;
  final String? imageUrl;
  final String? artistUsername;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Thumbnail
        imageUrl != null
            ? MallowNetworkImage(
                imageUrl: imageUrl!,
                logicalSize: 52,
                width: 52,
                height: 52,
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                errorBuilder: (_) => ClipRRect(
                  borderRadius: BorderRadius.circular(
                    MallowTheme.radiusPrimary,
                  ),
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: _ImagePlaceholder(),
                  ),
                ),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: _ImagePlaceholder(),
                ),
              ),
        const SizedBox(width: 10),
        // Title + collection
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: MallowTheme.editorialQuote.copyWith(
                  color: context.mallowColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (artistUsername != null) ...[
                const SizedBox(height: 4),
                Text(
                  artistUsername!,
                  style: MallowTheme.uiCaption.copyWith(
                    color: context.mallowColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.mallowColors.surfaceMuted,
      child: MallowSvgIcon(
        'assets/icons/stamp.svg',
        width: 24,
        height: 24,
        color: context.mallowColors.textTertiary,
      ),
    );
  }
}

class _CurationRow extends StatelessWidget {
  const _CurationRow({
    required this.curation,
    required this.onTap,
    this.enabled = true,
  });

  final UserCuration curation;
  final VoidCallback onTap;

  /// Disabled (dimmed + non-interactive) while another action — e.g. a
  /// "New Curation" create — is busy.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Row(
          children: [
            // 2×2 thumbnail grid
            _CurationThumbnailGrid(urls: curation.thumbnailUrls),
            const SizedBox(width: 10),
            // Name + count
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    curation.name,
                    style: MallowTheme.editorialQuote.copyWith(
                      color: context.mallowColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${curation.artworkCount} artworks',
                    style: MallowTheme.uiCaption.copyWith(
                      color: context.mallowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Checkbox
            MallowCheckbox(
              value: curation.isSelected,
              enabled: enabled,
              onChanged: (_) => onTap(),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurationThumbnailGrid extends StatelessWidget {
  const _CurationThumbnailGrid({required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
      child: SizedBox(
        width: 48,
        height: 48,
        child: urls.isEmpty
            ? Container(color: context.mallowColors.surfaceMuted)
            : GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: List.generate(4, (i) {
                  final url = i < urls.length ? urls[i] : null;
                  return url != null
                      ? MallowNetworkImage(
                          imageUrl: url,
                          logicalSize: 24,
                          errorBuilder: (_) => Container(
                            color: context.mallowColors.surfaceMuted,
                          ),
                        )
                      : Container(color: context.mallowColors.surfaceMuted);
                }),
              ),
      ),
    );
  }
}
