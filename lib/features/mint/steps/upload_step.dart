import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../core/observability/app_logger.dart';
import '../../../shared/pickers/asset_source_sheet.dart';
import '../../../shared/pickers/picked_file_validation.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/app_snack_bar.dart';
import '../../../shared/widgets/mallow_section_label.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/tap_target_expander.dart';
import '../models/mint_file_types.dart';
import '../models/picked_mint_asset.dart';
import '../services/mint_bloc.dart';
import '../widgets/mint_drop_zone.dart';

const _tag = 'UploadStep';

/// Upload step.
///
/// Tabs: Artwork / Thumbnail / Process Video. (Exclusive Content is built
/// but not offered — see the tab list in [_UploadStepState.build].)
/// Thumbnail is only present when the main asset needs one
/// (video / html / glb / pdf — enforced by [PickedMintAsset.needsThumbnail]).
class UploadStep extends StatefulWidget {
  const UploadStep({super.key});

  @override
  State<UploadStep> createState() => _UploadStepState();
}

class _UploadStepState extends State<UploadStep> {
  int _activeTab = 0;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MintBloc, MintState>(
      buildWhen: (prev, next) =>
          prev.mainAsset != next.mainAsset ||
          prev.thumbnail != next.thumbnail ||
          prev.processVideo != next.processVideo ||
          prev.banner != next.banner ||
          prev.exclusiveContentFiles != next.exclusiveContentFiles ||
          prev.mintType != next.mintType ||
          prev.existingImageUrl != next.existingImageUrl ||
          prev.existingThumbnailUrl != next.existingThumbnailUrl ||
          prev.existingProcessVideoUrl != next.existingProcessVideoUrl ||
          prev.existingBannerUrl != next.existingBannerUrl ||
          prev.existingMainAssetIsVideo != next.existingMainAssetIsVideo ||
          prev.editPrefillLoading != next.editPrefillLoading,
      builder: (context, state) {
        if (state.mintType == MintCreateType.collection) {
          return _CollectionUploadBody(
            banner: state.banner,
            mainImage: state.mainAsset,
            existingBannerUrl: state.banner == null
                ? state.existingBannerUrl
                : null,
            existingMainImageUrl: state.mainAsset == null
                ? state.existingImageUrl
                : null,
            loading: state.editPrefillLoading,
            onPickBanner: () => _pickBanner(context),
            onPickMain: () => _pickMainImage(context),
          );
        }

        final showThumbnailTab = state.mainAsset?.needsThumbnail ?? false;
        // `_UploadTab.exclusiveContent` is deliberately NOT offered. The
        // picker + preview work, but nothing uploads the picked files and
        // nothing attaches them: `unlockableContentIds` on the mint request
        // stays empty, so the content is discarded on an immutable mint.
        // Re-list it only together with (a) a corrected multipart contract
        // for `POST /v1/unlockableContent/upload` — the server wants
        // `assetFile` / `assetFile_$i` + `fileName_$i` +
        // `newAssetFilesCount` / `existingAssetUrlsCount` and answers with a
        // bare `number[]`, none of which matches
        // `MallowApiClient.uploadUnlockableContent` — and (b) a thumbnail
        // slot, which the route requires (`unlockableContentHelper`
        // `invariant(thumbnailHash != null)`) and this UI has no field for.
        final tabs = <_UploadTab>[
          _UploadTab.artwork,
          if (showThumbnailTab) _UploadTab.thumbnail,
          _UploadTab.processVideo,
        ];
        final safeIndex = _activeTab.clamp(0, tabs.length - 1);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MallowUnderlineTabBar(
              tabs: tabs.map((t) => t.label).toList(),
              activeIndex: safeIndex,
              onTabSelected: (i) => setState(() => _activeTab = i),
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            Expanded(
              child: _LazyIndexedTabs(
                activeIndex: safeIndex,
                length: tabs.length,
                builder: (i) => _buildTabBody(context, tabs[i], state),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTabBody(BuildContext context, _UploadTab tab, MintState state) {
    // In edit mode, surface the on-chain asset URLs as placeholders so
    // the user sees what they're editing. The fresh PickedMintAsset
    // wins as soon as the user picks a new file, so we null out the
    // existing URL when an asset is set.
    final loading = state.editPrefillLoading;
    switch (tab) {
      case _UploadTab.artwork:
        return _ArtworkBody(
          asset: state.mainAsset,
          existingUrl: state.mainAsset == null ? state.existingImageUrl : null,
          existingKind: state.existingMainAssetIsVideo
              ? ExistingAssetKind.video
              : ExistingAssetKind.image,
          loading: loading,
          onTap: () => _pickMainAsset(context),
        );
      case _UploadTab.thumbnail:
        return _SimpleAssetBody(
          label: 'Thumbnail',
          asset: state.thumbnail,
          existingUrl: state.thumbnail == null
              ? state.existingThumbnailUrl
              : null,
          loading: loading,
          onTap: () => _pickThumbnail(context),
          restrictions: kMintThumbnailRules.caption,
        );
      case _UploadTab.processVideo:
        return _SimpleAssetBody(
          label: 'Process Video',
          asset: state.processVideo,
          existingUrl: state.processVideo == null
              ? state.existingProcessVideoUrl
              : null,
          existingKind: ExistingAssetKind.video,
          loading: loading,
          onTap: () => _pickProcessVideo(context),
          restrictions: kMintProcessVideoRules.caption,
        );
      case _UploadTab.exclusiveContent:
        return _ExclusiveContentBody(
          files: state.exclusiveContentFiles,
          loading: loading,
          onAdd: () => _pickExclusiveContent(context),
          onRemove: (index) => context.read<MintBloc>().add(
            MintEvent.removeExclusiveContent(index),
          ),
        );
    }
  }

  /// Entry point for every upload slot: asks where the bytes should come from,
  /// then runs the matching system picker. Both sources land on
  /// [_buildPickedAsset], so the allowlist / size cap / MIME handling are
  /// applied exactly once regardless of which one the user chose.
  Future<PickedMintAsset?> _pickAsset(
    BuildContext context, {
    MintAcceptRules rules = kMintMainAssetRules,
  }) async {
    final source = await showAssetSourceSheet(context);
    if (source == null || !context.mounted) return null;
    return switch (source) {
      AssetSource.photos => _pickFromPhotos(context, rules: rules),
      AssetSource.files => _pickFromFiles(context, rules: rules),
    };
  }

  /// Files-app source, deliberately unfiltered.
  ///
  /// iOS filters the document browser by UTI, and half of what a mint slot
  /// takes has no system UTI to name — `.glb`, `.webm`, `.avif`, `.apng`. A
  /// UTI allowlist would grey those out and make them unmintable, so this
  /// opens on everything and lets [validatePickedFile] turn a wrong pick into
  /// the "File must be …" error. The trade is that an invalid file is
  /// selectable and rejected after the fact rather than being greyed out.
  Future<PickedMintAsset?> _pickFromFiles(
    BuildContext context, {
    required MintAcceptRules rules,
  }) async {
    XFile? file;
    try {
      file = await openFile();
    } catch (error) {
      // Logged for the same reason as the shared picker's openFile: the throw
      // alone does not say whether the picker failed to launch or
      // `file_selector_android` failed reading the picked content Uri inside
      // this call. The user-facing message cannot distinguish them; the log can.
      AppLogger.error(_tag, 'openFile failed', error);
      if (context.mounted) _showError(context, 'Could not open file picker');
      return null;
    }
    if (file == null) return null;
    // The browser hands back a handle, not bytes; a read failure here is
    // reported by [_buildPickedAsset] as an unreadable file rather than
    // escaping the drop zone's tap handler with nothing shown.
    final bytes = await readPickedBytes(file);
    if (!context.mounted) return null;
    return _buildPickedAsset(
      context,
      fileName: file.name,
      bytes: bytes,
      rules: rules,
    );
  }

  /// Photo-library source. On iOS 14+ `image_picker` presents
  /// `PHPickerViewController`, which is out of process — no photo-library
  /// permission is requested and none is needed, so `requestFullMetadata` is
  /// off (we only want the bytes; asking for EXIF is what would pull the
  /// permission back in).
  ///
  /// Which picker to open is derived from the slot's own allowlist so the
  /// video-only slot never offers stills and vice versa.
  Future<PickedMintAsset?> _pickFromPhotos(
    BuildContext context, {
    required MintAcceptRules rules,
  }) async {
    final wantsImages = rules.allowsStills;
    final wantsVideos = rules.extensions.any(kMintVideoExtensions.contains);
    final picker = ImagePicker();
    XFile? file;
    try {
      if (wantsImages && wantsVideos) {
        file = await picker.pickMedia(requestFullMetadata: false);
      } else if (wantsVideos) {
        file = await picker.pickVideo(source: ImageSource.gallery);
      } else {
        file = await picker.pickImage(
          source: ImageSource.gallery,
          requestFullMetadata: false,
        );
      }
    } catch (_) {
      if (context.mounted) _showError(context, 'Could not open photo library');
      return null;
    }
    if (file == null) return null;

    // Refuse on name/stat before buffering: the system picker has no notion
    // of our allowlist or size cap, and a multi-GB camera video must be
    // rejected on `length()` rather than after `readAsBytes` pulls the whole
    // file into memory.
    int sizeBytes;
    try {
      sizeBytes = await file.length();
    } catch (_) {
      sizeBytes = 0; // Unreadable — fall through and let readAsBytes decide.
    }
    if (!context.mounted) return null;
    if (rejectsNameOrSize(
      fileName: file.name,
      sizeBytes: sizeBytes,
      pickable: rules.pickable,
      maxSizeBytes: rules.maxSizeBytes,
      typeSummary: rules.summary,
      onError: (message) => _showError(context, message),
    )) {
      return null;
    }

    // Unlike the Files path there is no `withData` — the bytes are read off
    // the temp file only once the cheap checks above have passed.
    final bytes = await readPickedBytes(file);
    if (!context.mounted) return null;
    return _buildPickedAsset(
      context,
      fileName: file.name,
      bytes: bytes,
      rules: rules,
    );
  }

  /// Validation tail for both picker sources: the slot's rules go to the
  /// shared [validatePickedFile], and what survives becomes a
  /// [PickedMintAsset]. The rules are the only thing this flow contributes —
  /// the allowlist check, the size cap, the HEIC transcode and the wording of
  /// every rejection are shared with the profile / auction image boxes so a
  /// change to any of them is made once.
  ///
  /// The mime type is resolved here rather than there because it is what the
  /// mint metadata is classified by; nothing else in the app needs it.
  Future<PickedMintAsset?> _buildPickedAsset(
    BuildContext context, {
    required String fileName,
    required Uint8List? bytes,
    required MintAcceptRules rules,
  }) async {
    final file = await validatePickedFile(
      fileName: fileName,
      bytes: bytes,
      pickable: rules.pickable,
      maxSizeBytes: rules.maxSizeBytes,
      typeSummary: rules.summary,
      // Guarded inside the callback: the HEIC transcode is awaited mid-way, so
      // a rejection can land after the step has been popped.
      onError: (message) {
        if (context.mounted) _showError(context, message);
      },
    );
    if (file == null) return null;

    return PickedMintAsset(
      fileName: file.fileName,
      mimeType: mintMimeTypeForFileName(file.fileName),
      sizeBytes: file.bytes.lengthInBytes,
      bytes: file.bytes,
    );
  }

  Future<void> _pickMainAsset(BuildContext context) async {
    final asset = await _pickAsset(context);
    if (asset == null || !context.mounted) return;
    context.read<MintBloc>().add(MintEvent.pickMainAsset(asset));
  }

  Future<void> _pickThumbnail(BuildContext context) async {
    final asset = await _pickAsset(context, rules: kMintThumbnailRules);
    if (asset == null || !context.mounted) return;
    context.read<MintBloc>().add(MintEvent.pickThumbnail(asset));
  }

  Future<void> _pickProcessVideo(BuildContext context) async {
    final asset = await _pickAsset(context, rules: kMintProcessVideoRules);
    if (asset == null || !context.mounted) return;
    context.read<MintBloc>().add(MintEvent.pickProcessVideo(asset));
  }

  Future<void> _pickExclusiveContent(BuildContext context) async {
    final asset = await _pickAsset(context, rules: kMintUnlockableRules);
    if (asset == null || !context.mounted) return;
    context.read<MintBloc>().add(MintEvent.addExclusiveContent(asset));
  }

  // --- Collection variant ---

  Future<void> _pickMainImage(BuildContext context) async {
    final asset = await _pickAsset(context, rules: kMintCollectionRules);
    if (asset == null || !context.mounted) return;
    context.read<MintBloc>().add(MintEvent.pickMainAsset(asset));
  }

  Future<void> _pickBanner(BuildContext context) async {
    final asset = await _pickAsset(context, rules: kMintCollectionRules);
    if (asset == null || !context.mounted) return;
    context.read<MintBloc>().add(MintEvent.pickBanner(asset));
  }

  void _showError(BuildContext context, String message) {
    AppSnackBar.show(context, message, duration: const Duration(seconds: 2));
  }
}

enum _UploadTab {
  artwork('Artwork'),
  thumbnail('Thumbnail'),
  processVideo('Process Video'),
  exclusiveContent('Exclusive Content');

  const _UploadTab(this.label);
  final String label;
}

/// Tab body host that keeps each visited tab mounted via [IndexedStack],
/// so video controllers and network image state survive tab switches.
/// Tabs are built lazily on first visit to avoid eagerly downloading the
/// network video for tabs the user never opens.
class _LazyIndexedTabs extends StatefulWidget {
  const _LazyIndexedTabs({
    required this.activeIndex,
    required this.length,
    required this.builder,
  });

  final int activeIndex;
  final int length;
  final Widget Function(int index) builder;

  @override
  State<_LazyIndexedTabs> createState() => _LazyIndexedTabsState();
}

class _LazyIndexedTabsState extends State<_LazyIndexedTabs> {
  late final Set<int> _built = {widget.activeIndex};

  @override
  void didUpdateWidget(_LazyIndexedTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    _built.add(widget.activeIndex);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.activeIndex,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < widget.length; i++)
          _built.contains(i) ? widget.builder(i) : const SizedBox.shrink(),
      ],
    );
  }
}

/// Collection variant of the upload step. Two stacked
/// dropzones: optional Banner + required Main Image. Image-only formats,
/// 30MB cap.
class _CollectionUploadBody extends StatelessWidget {
  const _CollectionUploadBody({
    required this.banner,
    required this.mainImage,
    required this.onPickBanner,
    required this.onPickMain,
    this.existingBannerUrl,
    this.existingMainImageUrl,
    this.loading = false,
  });

  final PickedMintAsset? banner;
  final PickedMintAsset? mainImage;
  final String? existingBannerUrl;
  final String? existingMainImageUrl;
  final bool loading;
  final VoidCallback onPickBanner;
  final VoidCallback onPickMain;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final captionStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textSecondary,
    );
    final restrictions = kMintCollectionRules.caption;
    return ListView(
      padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
      children: [
        const MallowSectionLabel(label: 'Upload Banner'),
        const SizedBox(height: MallowTheme.spacingMd),
        MintDropZone(
          asset: banner,
          existingUrl: existingBannerUrl,
          loading: loading,
          onTap: onPickBanner,
          height: 195,
          imageAspectRatio: 2,
          imageFit: BoxFit.cover,
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Align(
          child: Text(
            restrictions,
            style: captionStyle,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: MallowTheme.spacingLg),
        const MallowSectionLabel(label: 'Upload Main Image'),
        const SizedBox(height: MallowTheme.spacingMd),
        MintDropZone(
          asset: mainImage,
          existingUrl: existingMainImageUrl,
          loading: loading,
          onTap: onPickMain,
          height: 195,
          imageAspectRatio: 1,
          imageFit: BoxFit.cover,
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Align(
          child: Text(
            restrictions,
            style: captionStyle,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _ArtworkBody extends StatelessWidget {
  const _ArtworkBody({
    required this.asset,
    required this.onTap,
    this.existingUrl,
    this.existingKind = ExistingAssetKind.image,
    this.loading = false,
  });

  final PickedMintAsset? asset;
  final String? existingUrl;
  final ExistingAssetKind existingKind;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final captionStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MallowSectionLabel(label: 'Upload main artwork'),
        const SizedBox(height: MallowTheme.spacingMd),
        MintDropZone(
          asset: asset,
          existingUrl: existingUrl,
          existingKind: existingKind,
          loading: loading,
          onTap: onTap,
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Align(
          child: Text(
            kMintMainAssetRules.caption,
            style: captionStyle,
            textAlign: TextAlign.center,
          ),
        ),
        const Spacer(),
        Text('Did you know?', style: captionStyle),
        Text(
          'You can add process videos and exclusive content to your token. Check out the tabs above to give the collector even more content!',
          style: captionStyle,
        ),
      ],
    );
  }
}

class _SimpleAssetBody extends StatelessWidget {
  const _SimpleAssetBody({
    required this.label,
    required this.asset,
    required this.onTap,
    this.existingUrl,
    this.existingKind = ExistingAssetKind.image,
    this.loading = false,
    this.restrictions,
  });

  final String label;
  final PickedMintAsset? asset;
  final String? existingUrl;
  final ExistingAssetKind existingKind;
  final bool loading;
  final VoidCallback onTap;
  final String? restrictions;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final captionStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MallowSectionLabel(label: label, optional: label != 'Thumbnail'),
        const SizedBox(height: MallowTheme.spacingMd),
        MintDropZone(
          asset: asset,
          existingUrl: existingUrl,
          existingKind: existingKind,
          loading: loading,
          onTap: onTap,
        ),
        if (restrictions != null) ...[
          const SizedBox(height: MallowTheme.spacingMd),
          Align(
            child: Text(
              restrictions!,
              style: captionStyle,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ],
    );
  }
}

class _ExclusiveContentBody extends StatefulWidget {
  const _ExclusiveContentBody({
    required this.files,
    required this.onAdd,
    required this.onRemove,
    this.loading = false,
  });

  final List<PickedMintAsset> files;
  final bool loading;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  State<_ExclusiveContentBody> createState() => _ExclusiveContentBodyState();
}

class _ExclusiveContentBodyState extends State<_ExclusiveContentBody> {
  int _selectedIndex = 0;

  @override
  void didUpdateWidget(_ExclusiveContentBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.files.isEmpty) {
      _selectedIndex = 0;
    } else if (widget.files.length > oldWidget.files.length) {
      // Newly-picked file is always appended — select it.
      _selectedIndex = widget.files.length - 1;
    } else if (_selectedIndex >= widget.files.length) {
      _selectedIndex = widget.files.length - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final captionStyle = MallowTheme.uiCaption.copyWith(
      color: colors.textSecondary,
    );
    final files = widget.files;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MallowSectionLabel(label: 'Exclusive content', optional: true),
        const SizedBox(height: MallowTheme.spacingMd),
        MintDropZone(
          asset: files.isEmpty ? null : files[_selectedIndex],
          loading: widget.loading,
          onTap: widget.onAdd,
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        Align(
          child: Text(
            kMintUnlockableRules.caption,
            style: captionStyle,
            textAlign: TextAlign.center,
          ),
        ),
        if (files.isNotEmpty) ...[
          const SizedBox(height: MallowTheme.spacingMd),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: files.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: MallowTheme.spacingSm),
              itemBuilder: (_, i) => _ExclusiveFileRow(
                file: files[i],
                selected: i == _selectedIndex,
                onTap: () => setState(() => _selectedIndex = i),
                onRemove: () => widget.onRemove(i),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ExclusiveFileRow extends StatelessWidget {
  const _ExclusiveFileRow({
    required this.file,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  final PickedMintAsset file;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: MallowTheme.spacingMd),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
          border: Border.all(color: selected ? colors.accent : colors.divider),
        ),
        child: Row(
          children: [
            MallowSvgIcon(
              'assets/icons/page.svg',
              width: 18,
              height: 18,
              color: colors.textSecondary,
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            Expanded(
              child: Text(
                file.fileName,
                style: MallowTheme.uiBody.copyWith(color: colors.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: MallowTheme.spacingSm),
            TapTargetExpander(
              child: GestureDetector(
                onTap: onRemove,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(MallowTheme.spacingXs),
                  child: SvgPicture.asset(
                    'assets/icons/x_circle.svg',
                    width: 20,
                    height: 20,
                    colorFilter: ColorFilter.mode(
                      colors.textSecondary,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
