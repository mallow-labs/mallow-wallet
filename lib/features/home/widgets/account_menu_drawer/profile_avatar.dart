part of '../account_menu_drawer.dart';

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.size, this.imageUrl, this.seed = ''});

  final String? imageUrl;
  final double size;

  /// Generated-identicon seed for the missing-image fallback
  /// (see [avatarSeedOf]).
  final String seed;

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return MallowNetworkImage(
        imageUrl: imageUrl!,
        logicalSize: size,
        width: size,
        height: size,
        borderRadius: BorderRadius.circular(size / 2),
        errorBuilder: (_) => AccountAvatar(seed: seed, size: size),
      );
    }
    return AccountAvatar(seed: seed, size: size);
  }
}
