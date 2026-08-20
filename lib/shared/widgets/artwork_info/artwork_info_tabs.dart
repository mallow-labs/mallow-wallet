import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/utils/address_format.dart';
import '../../../core/utils/file_size_format.dart';
import '../../theme/mallow_theme.dart';
import '../../utils/chain.dart';
import '../../utils/metadata_host.dart';
import '../../utils/token_standard_label.dart';
import '../animated_tab_content.dart';
import '../expandable_text.dart';
import '../mallow_kv_row.dart';
import '../mallow_pill_chip.dart';
import '../mallow_underline_tab_bar.dart';
import '../tap_target_expander.dart';
import 'artwork_info_view_data.dart';

/// Shared tabbed block (Description / Details / Categories / Tags / Traits)
/// used by the mint review step and the artwork detail screen.
///
/// Feed it an [ArtworkInfoViewData] built from the caller's own state.
/// Tabs whose underlying content is empty are dropped from both the tab
/// bar and the body, so callers can pass partial data without rendering
/// dead sections.
class ArtworkInfoTabs extends StatefulWidget {
  const ArtworkInfoTabs({required this.data, super.key});

  final ArtworkInfoViewData data;

  @override
  State<ArtworkInfoTabs> createState() => _ArtworkInfoTabsState();
}

class _ArtworkInfoTabsState extends State<ArtworkInfoTabs> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final detailsRows = _buildDetailsRows(context, data);

    final entries = <_TabEntry>[
      if (data.description.trim().isNotEmpty)
        _TabEntry('Description', () => _Description(text: data.description)),
      if (detailsRows.isNotEmpty)
        _TabEntry('Details', () => MallowKvList(rows: detailsRows)),
      if (data.categories.isNotEmpty)
        _TabEntry('Categories', () => _Chips(values: data.categories)),
      if (data.tags.isNotEmpty)
        _TabEntry(
          'Tags',
          () => _Chips(values: data.tags.map((t) => '#$t').toList()),
        ),
      if (data.traits.isNotEmpty)
        _TabEntry('Traits', () => _TraitsBlock(traits: data.traits)),
    ];

    if (entries.isEmpty) return const SizedBox.shrink();

    final safeIndex = _index.clamp(0, entries.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MallowUnderlineTabBar(
          tabs: [for (final e in entries) e.label],
          activeIndex: safeIndex,
          onTabSelected: (i) => setState(() => _index = i),
        ),
        const SizedBox(height: MallowTheme.spacingMd),
        AnimatedTabContent(
          activeIndex: safeIndex,
          builder: (_, i) => entries[i.clamp(0, entries.length - 1)].builder(),
        ),
      ],
    );
  }
}

class _TabEntry {
  const _TabEntry(this.label, this.builder);

  final String label;
  final Widget Function() builder;
}

class _Description extends StatelessWidget {
  const _Description({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ExpandableText(text: text.trim());
  }
}

class _Chips extends StatelessWidget {
  const _Chips({required this.values});

  final List<String> values;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MallowTheme.spacingSm,
      runSpacing: MallowTheme.spacingSm,
      children: [for (final v in values) MallowPillChip(v)],
    );
  }
}

class _TraitsBlock extends StatelessWidget {
  const _TraitsBlock({required this.traits});

  final List<({String name, String value})> traits;

  @override
  Widget build(BuildContext context) {
    return MallowKvList(
      rows: [
        for (final t in traits) MallowKvRow(label: t.name, value: t.value),
      ],
    );
  }
}

List<Widget> _buildDetailsRows(BuildContext context, ArtworkInfoViewData data) {
  final rows = <Widget>[];

  final chain = Chain.tryParse(data.chain);
  final isEvmOrTezos = isEvmOrTezosArtwork(
    mintAccount: data.mintAddress ?? '',
    chain: data.chain,
  );

  if (isEvmOrTezos) {
    if (data.contractAddress != null && data.contractAddress!.isNotEmpty) {
      rows.add(
        MallowKvAddressRow(
          label: 'Contract address',
          address: data.contractAddress!,
          chain: chain,
          isAccount: true,
        ),
      );
    }
    if (data.tokenId != null && data.tokenId!.isNotEmpty) {
      rows.add(MallowKvRow(label: 'Token ID', value: data.tokenId!));
    }
  } else if (data.mintAddress != null && data.mintAddress!.isNotEmpty) {
    rows.add(
      MallowKvAddressRow(
        label: 'Mint address',
        address: data.mintAddress!,
        chain: chain,
      ),
    );
  }
  if (data.editionCountLabel != null) {
    rows.add(
      MallowKvRow(label: 'Edition count', value: data.editionCountLabel!),
    );
  } else if (data.editionNumber != null && data.maxSupply != null) {
    rows.add(
      MallowKvRow(
        label: 'Edition count',
        value: '${data.editionNumber} / ${data.maxSupply}',
      ),
    );
  }
  if (data.printedCount != null) {
    rows.add(
      MallowKvRow(label: 'Printed count', value: '${data.printedCount}'),
    );
  }
  if (data.updateAuthority != null) {
    rows.add(
      _UpdateAuthorityRow(
        ref: data.updateAuthority!,
        isDeployer: isEvmOrTezos,
        chain: chain,
      ),
    );
  }
  // Royalties is a trust surface: never render a number we aren't sure of.
  // Pending → placeholder; resolved → the value (including a real `0%`);
  // unknown / failed → no row at all (see [ArtworkInfoViewData.royaltyPercent]).
  if (data.royaltyPending) {
    rows.add(const MallowKvRow(label: 'Royalties', value: '—'));
  } else if (data.royaltyPercent != null &&
      data.royaltyPercent!.trim().isNotEmpty) {
    rows.add(
      MallowKvRow(label: 'Royalties', value: '${data.royaltyPercent!.trim()}%'),
    );
  }
  if (data.proceedsSplits.isNotEmpty) {
    rows.add(
      MallowKvRow(
        label: 'Proceeds splits',
        valueWidget: _proceedsSplitsText(context, data.proceedsSplits),
      ),
    );
  }
  if (data.mimeType != null && data.mimeType!.isNotEmpty) {
    rows.add(
      MallowKvRow(label: 'Medium', value: _formatMedium(data.mimeType!)),
    );
  }
  final dims = data.dimensions;
  if (dims != null) {
    rows.add(
      MallowKvRow(
        label: 'Dimensions',
        value: '${dims.width} x ${dims.height}px',
      ),
    );
  }
  if (data.fileSizeBytes != null) {
    rows.add(
      MallowKvRow(label: 'File size', value: formatBytes(data.fileSizeBytes!)),
    );
  }
  if (data.isImmutable != null) {
    rows.add(
      MallowKvRow(label: 'Immutable', value: data.isImmutable! ? 'Yes' : 'No'),
    );
  }
  if (data.tokenStandard != null && data.tokenStandard!.isNotEmpty) {
    rows.add(
      MallowKvRow(
        label: 'Token standard',
        value: tokenStandardLabelFromWire(data.tokenStandard!),
      ),
    );
  }
  final hostLabel = classifyMetadataHost(data.metadataUrl);
  if (hostLabel != null) {
    rows.add(
      MallowKvRow(
        label: 'Metadata host',
        value: hostLabel,
        onTap: () => launchUrl(
          Uri.parse(data.metadataUrl!.trim()),
          mode: LaunchMode.inAppBrowserView,
        ),
      ),
    );
  }
  final blockchainLabel = data.chain != null
      ? chainLabel(data.chain)
      : data.blockchain;
  if (blockchainLabel.isNotEmpty) {
    rows.add(MallowKvRow(label: 'Blockchain', value: blockchainLabel));
  }

  return rows;
}

/// Update authority row. When a username is set, renders `@handle` as a
/// link to that user's profile; otherwise falls back to an address row
/// (tap = copy, long-press = explorer). Labeled `Deployer address` for
/// ETH/Tezos artworks where there is no Solana-style update authority
/// concept.
class _UpdateAuthorityRow extends StatelessWidget {
  const _UpdateAuthorityRow({
    required this.ref,
    this.isDeployer = false,
    this.chain,
  });

  final CreatorRef ref;
  final bool isDeployer;
  final Chain? chain;

  @override
  Widget build(BuildContext context) {
    final label = isDeployer ? 'Deployer address' : 'Update authority';
    final username = ref.username;
    if (username != null && username.isNotEmpty) {
      return MallowKvRow(
        label: label,
        value: '@$username',
        onTap: () => context.push(AppRoutes.profileByUsernamePath(username)),
      );
    }
    return MallowKvAddressRow(
      label: label,
      address: ref.address,
      isAccount: true,
      chain: chain,
    );
  }
}

Widget _proceedsSplitsText(BuildContext context, List<CreatorRef> splits) {
  final colors = context.mallowColors;
  final linkStyle = MallowTheme.uiCaption.copyWith(
    color: colors.textPrimary,
    fontWeight: FontWeight.w500,
  );
  final addressStyle = MallowTheme.uiCaption.copyWith(
    color: colors.textSecondary,
    fontWeight: FontWeight.w500,
  );
  final secondary = MallowTheme.uiCaption.copyWith(color: colors.textSecondary);
  final spans = <InlineSpan>[];
  for (var i = 0; i < splits.length; i++) {
    if (i > 0) spans.add(TextSpan(text: ', ', style: secondary));
    final username = splits[i].username;
    if (username != null && username.isNotEmpty) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: TapTargetExpander(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  context.push(AppRoutes.profileByUsernamePath(username)),
              child: Text('@$username', style: linkStyle),
            ),
          ),
        ),
      );
    } else {
      spans.add(
        TextSpan(text: truncateAddress(splits[i].address), style: addressStyle),
      );
    }
    spans.add(
      TextSpan(text: ' [${splits[i].sharePercent}%]', style: secondary),
    );
  }
  return RichText(
    textAlign: TextAlign.right,
    text: TextSpan(children: spans),
  );
}

/// Maps a MIME type to a human-readable medium label.
///
/// `image/png` → `Image (PNG)`. Unknown types fall back to the raw value
/// so the row never renders empty.
String _formatMedium(String mime) {
  final parts = mime.split('/');
  if (parts.length != 2) return mime;
  final kind = parts[0];
  final ext = parts[1].toUpperCase();
  final prefix = switch (kind) {
    'image' => 'Image',
    'video' => 'Video',
    'audio' => 'Audio',
    'model' => '3D',
    'application' => 'File',
    _ => kind[0].toUpperCase() + kind.substring(1),
  };
  return '$prefix ($ext)';
}
