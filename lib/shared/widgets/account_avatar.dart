import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/services/avatar_service.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import 'loading_indicator.dart';
import 'mallow_svg_icon.dart';

/// Renders an auto-generated DiceBear `identicon` avatar from the on-disk
/// cache ([AvatarService]), keyed by a stable seed string.
///
/// Accounts pass their persisted `avatarSeed` UUID; users/profiles without an
/// uploaded picture pass `avatarSeedOf(address: …, username: …, id: …)` so
/// the same identity always renders the same identicon.
///
/// Shows a neutral placeholder while the SVG is being fetched on first use and
/// a graceful `anon.svg` fallback if the seed is empty or the fetch fails — so
/// a misconfigured avatar host degrades quietly rather than breaking the UI.
///
/// Profiles with an uploaded `avatarUrl` keep rendering it via
/// `MallowNetworkImage`; this widget is the missing-image path only.
class AccountAvatar extends StatefulWidget {
  const AccountAvatar({
    required this.seed,
    required this.size,
    this.borderRadius,
    this.showShimmerPlaceholder = false,
    super.key,
  });

  /// The stable avatar seed (account UUID, or `avatarSeedOf(...)`).
  final String seed;
  final double size;

  /// Clip shape — null renders the default circle; pass a radius for the
  /// rounded-square surfaces (activity rows, profile header, bidder strip).
  final BorderRadius? borderRadius;

  /// When true, the loading placeholder is the artwork shimmer rather than a
  /// flat divider-coloured fill. Used by the picker grid, where 28 avatars are
  /// fetched at once and an animated placeholder reads better than a static box.
  final bool showShimmerPlaceholder;

  @override
  State<AccountAvatar> createState() => _AccountAvatarState();
}

class _AccountAvatarState extends State<AccountAvatar> {
  late Future<File?> _file;

  /// Synchronously-available cached file, used as the FutureBuilder's
  /// [initialData] so a previously-fetched avatar paints on the first frame
  /// instead of flashing the placeholder before the (already complete) future
  /// resolves on the next microtask.
  File? _cached;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AccountAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seed != widget.seed) {
      _load();
    }
  }

  void _load() {
    final service = sl<AvatarService>();
    _cached = service.cachedFile(widget.seed);
    _file = service.avatarFile(widget.seed);
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius;
    final content = SizedBox(
      width: widget.size,
      height: widget.size,
      child: FutureBuilder<File?>(
        future: _file,
        initialData: _cached,
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (file != null) {
            return SvgPicture.file(
              file,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              placeholderBuilder: (_) => _placeholder(context),
            );
          }
          // No cached/resolved file: placeholder while loading, fallback once
          // the fetch has completed empty.
          if (snapshot.connectionState != ConnectionState.done) {
            return _placeholder(context);
          }
          return _fallback(context);
        },
      ),
    );
    return radius != null
        ? ClipRRect(borderRadius: radius, child: content)
        : ClipOval(child: content);
  }

  Widget _placeholder(BuildContext context) {
    if (widget.showShimmerPlaceholder) {
      // The outer ClipOval clips this square shimmer to a circle.
      return ShimmerBox(
        width: widget.size,
        height: widget.size,
        borderRadius: BorderRadius.circular(widget.size),
      );
    }
    return Container(
      width: widget.size,
      height: widget.size,
      color: context.mallowColors.divider,
    );
  }

  Widget _fallback(BuildContext context) => Container(
    width: widget.size,
    height: widget.size,
    color: context.mallowColors.divider,
    alignment: Alignment.center,
    child: MallowSvgIcon(
      'assets/icons/anon.svg',
      width: widget.size * 0.7,
      height: widget.size * 0.7,
    ),
  );
}
