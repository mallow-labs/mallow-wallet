import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mallow_api/mallow_api.dart';

import '../../../di.dart';
import '../../../features/artwork/widgets/collection_curation_row.dart';
import '../../../features/profile/data/user_profile_repository.dart';
import '../../../features/profile/models/user_profile.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../../../shared/widgets/animated_tab_content.dart';
import '../../../shared/widgets/artwork_info/artwork_info_tabs.dart';
import '../../../shared/widgets/artwork_info/artwork_info_view_data.dart';
import '../../../shared/widgets/mallow_network_image.dart';
import '../../../shared/widgets/mallow_svg_icon.dart';
import '../../../shared/widgets/mallow_underline_tab_bar.dart';
import '../../../shared/widgets/user_handle_text.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../models/picked_mint_asset.dart';
import '../pickers/category_picker_sheet.dart';
import '../services/mint_bloc.dart';
import '../widgets/mint_drop_zone.dart';

/// Review step.
///
/// Preview tab bar (only tabs with content are shown), dashed 1:1 preview,
/// artwork name + creator, then the shared [ArtworkInfoTabs] block.
class ReviewStep extends StatefulWidget {
  const ReviewStep({super.key});

  @override
  State<ReviewStep> createState() => _ReviewStepState();
}

class _ReviewStepState extends State<ReviewStep> {
  int _previewTab = 0;
  int _exclusivePage = 0;
  late final PageController _exclusiveController = PageController();
  UserProfile? _profile;
  String? _loadedAddress;

  /// Resolved mallow usernames for creator/royalty addresses other than the
  /// current user (the current user's profile lives in [_profile]).
  final Map<String, String?> _creatorUsernames = {};
  List<String>? _loadedCreatorAddresses;

  void _maybeLoadProfile(String address) {
    if (address.isEmpty || address == _loadedAddress) return;
    _loadedAddress = address;
    sl<UserProfileRepository>()
        .getUserProfile(address)
        .then((profile) {
          if (!mounted || _loadedAddress != address) return;
          setState(() => _profile = profile);
        })
        .catchError((_) {
          // Silent fallback — review step shows the short address instead.
        });
  }

  @override
  void dispose() {
    _exclusiveController.dispose();
    super.dispose();
  }

  void _maybeLoadCreators(List<String> addresses) {
    final key = addresses.toList(growable: false);
    if (_loadedCreatorAddresses != null &&
        _listEquals(_loadedCreatorAddresses!, key)) {
      return;
    }
    _loadedCreatorAddresses = key;
    if (key.isEmpty) return;
    sl<UserProfileRepository>().getUserProfiles(key).then((map) {
      if (!mounted ||
          _loadedCreatorAddresses == null ||
          !_listEquals(_loadedCreatorAddresses!, key)) {
        return;
      }
      setState(() {
        _creatorUsernames
          ..clear()
          ..addEntries(
            map.entries.map((e) => MapEntry(e.key, e.value?.username)),
          );
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MintBloc, MintState>(
      listenWhen: (prev, next) =>
          prev.userPubkey != next.userPubkey || prev.creators != next.creators,
      listener: (context, state) {
        _maybeLoadProfile(state.userPubkey);
        _maybeLoadCreators(
          state.creators
              .map((c) => c.address.trim())
              .where((a) => a.isNotEmpty && a != state.userPubkey)
              .toList(),
        );
      },
      builder: (context, state) {
        _maybeLoadProfile(state.userPubkey);
        _maybeLoadCreators(
          state.creators
              .map((c) => c.address.trim())
              .where((a) => a.isNotEmpty && a != state.userPubkey)
              .toList(),
        );
        final colors = context.mallowColors;
        final isCollection = state.mintType == MintCreateType.collection;

        if (isCollection) {
          return ListView(
            padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
            children: [
              Text(
                'Preview collection',
                style: MallowTheme.uiMeta.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: MallowTheme.spacingMd),
              // Edit mode falls back to the on-chain IPFS URLs when the
              // user hasn't re-picked a file — same rule as the artwork
              // preview tabs in [_collectPreviewTabs].
              _CollectionPreviewCard(
                banner: state.banner,
                thumbnail: state.mainAsset,
                existingBannerUrl: state.isEdit
                    ? state.existingBannerUrl
                    : null,
                existingThumbnailUrl: state.isEdit
                    ? state.existingImageUrl
                    : null,
              ),
              const SizedBox(height: MallowTheme.spacingLg),
              Text(
                state.name.isEmpty ? 'Untitled' : state.name,
                style: MallowTheme.editorialQuote.copyWith(
                  color: colors.textPrimary,
                  fontSize: 24,
                  height: 28 / 24,
                  letterSpacing: 24 * MallowTheme.trackingTight,
                ),
              ),
              const SizedBox(height: MallowTheme.spacingXs),
              _CreatorRow(profile: _profile, fallbackAddress: state.userPubkey),
              const SizedBox(height: MallowTheme.spacingLg),
              ArtworkInfoTabs(data: _buildViewData(state)),
            ],
          );
        }

        final previews = _collectPreviewTabs(state);
        final previewIndex = previews.isEmpty
            ? 0
            : _previewTab.clamp(0, previews.length - 1);

        return ListView(
          padding: const EdgeInsets.only(bottom: MallowTheme.spacing20),
          children: [
            if (previews.isNotEmpty) ...[
              MallowUnderlineTabBar(
                tabs: previews.map((p) => p.label).toList(),
                activeIndex: previewIndex,
                onTabSelected: (i) {
                  setState(() {
                    _previewTab = i;
                    _exclusivePage = 0;
                  });
                  if (_exclusiveController.hasClients) {
                    _exclusiveController.jumpToPage(0);
                  }
                },
              ),
              const SizedBox(height: MallowTheme.spacingLg),
            ],
            AnimatedTabContent(
              activeIndex: previewIndex,
              builder: (_, i) {
                final items = i < previews.length
                    ? previews[i].items
                    : const <_PreviewItem>[];
                return _PreviewArea(
                  items: items,
                  controller: _exclusiveController,
                  page: _exclusivePage,
                  onPageChanged: (j) => setState(() => _exclusivePage = j),
                );
              },
            ),
            const SizedBox(height: MallowTheme.spacingLg),
            Text(
              state.name.isEmpty ? 'Untitled' : state.name,
              style: MallowTheme.editorialQuote.copyWith(
                color: colors.textPrimary,
                fontSize: 24,
                height: 28 / 24,
              ),
            ),
            const SizedBox(height: MallowTheme.spacingXs),
            _CreatorRow(profile: _profile, fallbackAddress: state.userPubkey),
            if (state.collectionName != null) ...[
              const SizedBox(height: MallowTheme.spacingLg),
              CollectionCurationRow(
                collectionName: state.collectionName,
                collectionImageUrl: state.collectionSource?.imageUrl,
              ),
            ],
            const SizedBox(height: MallowTheme.spacingLg),
            ArtworkInfoTabs(data: _buildViewData(state)),
          ],
        );
      },
    );
  }

  List<_PreviewTab> _collectPreviewTabs(MintState state) {
    // In edit mode, fall back to the on-chain IPFS URLs when the user
    // hasn't re-picked a file — otherwise the review preview would be
    // empty for an unchanged image.
    final tabs = <_PreviewTab>[];
    if (state.mainAsset != null) {
      tabs.add(_PreviewTab('Artwork', [_PreviewItem(asset: state.mainAsset)]));
    } else if (state.isEdit &&
        state.existingImageUrl != null &&
        state.existingImageUrl!.isNotEmpty) {
      tabs.add(
        _PreviewTab('Artwork', [
          _PreviewItem(
            existingUrl: state.existingImageUrl,
            existingKind: state.existingMainAssetIsVideo
                ? ExistingAssetKind.video
                : ExistingAssetKind.image,
          ),
        ]),
      );
    }
    if (state.thumbnail != null) {
      tabs.add(
        _PreviewTab('Thumbnail', [_PreviewItem(asset: state.thumbnail)]),
      );
    } else if (state.isEdit &&
        state.existingThumbnailUrl != null &&
        state.existingThumbnailUrl!.isNotEmpty) {
      tabs.add(
        _PreviewTab('Thumbnail', [
          _PreviewItem(existingUrl: state.existingThumbnailUrl),
        ]),
      );
    }
    if (state.processVideo != null) {
      tabs.add(
        _PreviewTab('Process Video', [_PreviewItem(asset: state.processVideo)]),
      );
    } else if (state.isEdit &&
        state.existingProcessVideoUrl != null &&
        state.existingProcessVideoUrl!.isNotEmpty) {
      tabs.add(
        _PreviewTab('Process Video', [
          _PreviewItem(
            existingUrl: state.existingProcessVideoUrl,
            existingKind: ExistingAssetKind.video,
          ),
        ]),
      );
    }
    if (state.exclusiveContentFiles.isNotEmpty) {
      tabs.add(
        _PreviewTab('Exclusive Content', [
          for (final a in state.exclusiveContentFiles) _PreviewItem(asset: a),
        ]),
      );
    }
    return tabs;
  }

  ArtworkInfoViewData _buildViewData(MintState state) {
    final royalty = state.royaltyPercent.trim();
    final splits = <CreatorRef>[
      for (final c in state.creators)
        CreatorRef(
          address: c.address.trim(),
          username: c.isSelf
              ? _profile?.username
              : _creatorUsernames[c.address.trim()],
          sharePercent: int.tryParse(c.shareText.trim()) ?? 0,
        ),
    ];

    final isEditions = state.mintType == MintCreateType.editions;
    final isCollection = state.mintType == MintCreateType.collection;
    final isOpenEdition =
        isEditions && state.editionType == MintEditionType.open;
    final limitedSupply = isEditions && !isOpenEdition
        ? int.tryParse(state.editionSupply.trim())
        : null;
    // For 1/1 we still want "1 / 1"; for editions/collections we drop the
    // numerator since no mint number exists yet (Limited shows just the
    // supply, Open shows "Open edition", Collection has no concept of one).
    final editionCountLabel = isOpenEdition
        ? 'Open edition'
        : (limitedSupply != null ? '$limitedSupply' : null);
    final hideEditionFields = isEditions || isCollection;

    return ArtworkInfoViewData(
      description: state.description,
      editionNumber: hideEditionFields ? null : 1,
      maxSupply: hideEditionFields ? null : 1,
      editionCountLabel: editionCountLabel,
      updateAuthority: state.userPubkey.isEmpty
          ? null
          : CreatorRef(address: state.userPubkey, username: _profile?.username),
      royaltyPercent: royalty.isEmpty ? '0' : royalty,
      proceedsSplits: splits,
      mimeType: state.mainAsset?.mimeType,
      fileSizeBytes: state.mainAsset?.sizeBytes,
      isImmutable: false,
      // Editions and Collections both land as `core-collection` on-chain.
      tokenStandard: hideEditionFields ? 'core-collection' : 'core',
      categories: mintCategoryDisplayNamesFromTags(state.tags),
      tags: mintFilterOutCategories(state.tags),
      // Collections persist trait names without values on-chain, so the
      // value column would always be blank — drop them so the tab hides
      // itself instead of rendering a column of empty rows.
      traits: [
        for (final t in state.traits)
          if (t.name.trim().isNotEmpty &&
              (!isCollection || t.value.trim().isNotEmpty))
            (name: t.name.trim(), value: t.value.trim()),
      ],
    );
  }
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _PreviewTab {
  _PreviewTab(this.label, this.items);

  final String label;
  final List<_PreviewItem> items;
}

/// A single preview slot. Carries either a freshly picked [asset] or, in
/// edit mode, an [existingUrl] pointing at the asset already on-chain so
/// the user sees what they're keeping.
class _PreviewItem {
  const _PreviewItem({
    this.asset,
    this.existingUrl,
    this.existingKind = ExistingAssetKind.image,
  });

  final PickedMintAsset? asset;
  final String? existingUrl;
  final ExistingAssetKind existingKind;
}

/// Renders a 1:1 preview. Single-item tabs show one [MintDropZone];
/// multi-item tabs (exclusive content) swipe between items via a
/// `PageView` with a dot indicator below.
class _PreviewArea extends StatelessWidget {
  const _PreviewArea({
    required this.items,
    required this.controller,
    required this.page,
    required this.onPageChanged,
  });

  final List<_PreviewItem> items;
  final PageController controller;
  final int page;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    if (items.length <= 1) {
      final item = items.isEmpty ? null : items.first;
      return MintDropZone(
        asset: item?.asset,
        existingUrl: item?.existingUrl,
        existingKind: item?.existingKind ?? ExistingAssetKind.image,
        onTap: () {},
        interactive: false,
        emptyHint: 'No preview available',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: PageView.builder(
            controller: controller,
            itemCount: items.length,
            onPageChanged: onPageChanged,
            itemBuilder: (context, i) => MintDropZone(
              asset: items[i].asset,
              existingUrl: items[i].existingUrl,
              existingKind: items[i].existingKind,
              onTap: () {},
              interactive: false,
            ),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        _PageDots(count: items.length, activeIndex: page),
      ],
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.activeIndex});

  final int count;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == activeIndex
                    ? colors.textPrimary
                    : colors.textTertiary,
              ),
            ),
          ),
      ],
    );
  }
}

class _CreatorRow extends StatelessWidget {
  const _CreatorRow({required this.profile, required this.fallbackAddress});

  final UserProfile? profile;
  final String fallbackAddress;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    final username = profile?.username;
    final hasUsername = username != null && username.isNotEmpty;
    final hasAddress = fallbackAddress.isNotEmpty;
    final style = MallowTheme.uiMeta.copyWith(color: colors.textSecondary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: hasUsername || hasAddress
              ? UserHandleText(
                  username: username,
                  address: fallbackAddress,
                  style: style,
                  overflow: TextOverflow.ellipsis,
                )
              : Text('@creator', style: style, overflow: TextOverflow.ellipsis),
        ),
        if ((profile?.isVerified ?? false) ||
            (profile?.roles.contains('admin') ?? false)) ...[
          const SizedBox(width: MallowTheme.spacingXs),
          VerifiedBadge(isAdmin: profile?.roles.contains('admin') ?? false),
        ],
      ],
    );
  }
}

/// Layered banner + thumbnail card for the Collection review preview
/// per the Figma spec. Banner is a 393:200 image with the
/// 80×80 main-image thumbnail overlapping its bottom-left.
class _CollectionPreviewCard extends StatelessWidget {
  const _CollectionPreviewCard({
    required this.banner,
    required this.thumbnail,
    this.existingBannerUrl,
    this.existingThumbnailUrl,
  });

  final PickedMintAsset? banner;
  final PickedMintAsset? thumbnail;

  /// Edit-mode fallbacks: the asset already on-chain, shown when the
  /// corresponding slot has no freshly-picked file.
  final String? existingBannerUrl;
  final String? existingThumbnailUrl;

  static const double _bannerAspect = 393 / 200;
  static const double _thumbSize = 80;
  static const double _thumbInset = 30;
  static const double _thumbOverlap = 50;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return CustomPaint(
      // Foreground so the dashed stroke draws over the opaque fill rather than
      // being covered by it (see MintDropZone).
      foregroundPainter: DashedBorderPainter(color: colors.accent),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MallowTheme.radiusPrimary),
        child: Container(
          color: colors.surfaceMuted,
          padding: const EdgeInsets.all(MallowTheme.spacing20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: _bannerAspect,
                child: _BannerSurface(
                  asset: banner,
                  existingUrl: existingBannerUrl,
                  colors: colors,
                ),
              ),
              SizedBox(
                height: _thumbSize - _thumbOverlap,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: _thumbInset,
                      top: -_thumbOverlap,
                      child: SizedBox(
                        width: _thumbSize,
                        height: _thumbSize,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            MallowTheme.radiusPrimary,
                          ),
                          child: _ThumbnailSurface(
                            asset: thumbnail,
                            existingUrl: existingThumbnailUrl,
                            colors: colors,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BannerSurface extends StatelessWidget {
  const _BannerSurface({
    required this.asset,
    required this.colors,
    this.existingUrl,
  });

  final PickedMintAsset? asset;
  final String? existingUrl;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    if (asset != null) {
      // Same measurement as the existing-URL branch below: the banner spans
      // the full card width at a fixed aspect, so cap the decode there rather
      // than holding the picked file at its native resolution.
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return Image.memory(
            asset!.bytes,
            fit: BoxFit.cover,
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 4096),
            gaplessPlayback: true,
          );
        },
      );
    }
    if (existingUrl != null && existingUrl!.isNotEmpty) {
      // Banner spans the full card width; measure it instead of assuming a
      // device width so the CDN bucket and decode cap track the real layout.
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return MallowNetworkImage(imageUrl: existingUrl!, logicalSize: width);
        },
      );
    }
    return Container(
      color: colors.bgPrimary,
      alignment: Alignment.center,
      child: MallowSvgIcon(
        'assets/icons/stamp.svg',
        width: 32,
        height: 32,
        color: colors.textTertiary,
      ),
    );
  }
}

class _ThumbnailSurface extends StatelessWidget {
  const _ThumbnailSurface({
    required this.asset,
    required this.colors,
    this.existingUrl,
  });

  final PickedMintAsset? asset;
  final String? existingUrl;
  final MallowColors colors;

  @override
  Widget build(BuildContext context) {
    if (asset != null) {
      return Image.memory(
        asset!.bytes,
        fit: BoxFit.cover,
        // Fixed square crop at the card's thumbnail size — the same
        // `logicalSize` the existing-URL branch below hands the CDN. Read
        // from the constant so it cannot drift from the layout.
        cacheWidth:
            (_CollectionPreviewCard._thumbSize *
                    MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 4096),
        gaplessPlayback: true,
      );
    }
    if (existingUrl != null && existingUrl!.isNotEmpty) {
      return MallowNetworkImage(
        imageUrl: existingUrl!,
        // Fixed square crop at the card's thumbnail size.
        logicalSize: _CollectionPreviewCard._thumbSize,
      );
    }
    return Container(
      color: colors.bgPrimary,
      alignment: Alignment.center,
      child: MallowSvgIcon(
        'assets/icons/stamp.svg',
        width: 24,
        height: 24,
        color: colors.textTertiary,
      ),
    );
  }
}
