import 'package:flutter/material.dart';

import '../../core/services/avatar_service.dart';
import '../../core/session/session_manager.dart';
import '../../core/utils/address_format.dart';
import '../../di.dart';
import '../theme/mallow_theme.dart';
import 'account_avatar.dart';

/// How a review sheet names the signing wallet: its Account's name (or its
/// Profile's username) and its address-seeded identicon, or just the short
/// address when the wallet is not in the session. A wallet's own stored name
/// is an internal label and is never shown.
///
/// Display only. The address it was resolved from is what gets signed with.
class ReviewWalletIdentity {
  const ReviewWalletIdentity({
    required this.address,
    this.name,
    this.avatarSeed,
  });

  factory ReviewWalletIdentity.resolve(String address) {
    final name = sl.isRegistered<SessionManager>()
        ? sl<SessionManager>().ownerNameFor(address)
        : null;
    return ReviewWalletIdentity(
      address: address,
      name: name,
      avatarSeed: avatarSeedOf(address: address),
    );
  }

  final String address;
  final String? name;
  final String? avatarSeed;

  String get shortAddress => truncateAddress(address, lead: 4, trail: 4);

  /// The name, or the short address when there is none.
  String get label {
    final n = name?.trim();
    return n == null || n.isEmpty ? shortAddress : n;
  }
}

/// The wallet's generated avatar, or an accent disc with its initials.
class ReviewWalletAvatar extends StatelessWidget {
  const ReviewWalletAvatar({
    required this.identity,
    required this.size,
    super.key,
  });

  final ReviewWalletIdentity identity;
  final double size;

  @override
  Widget build(BuildContext context) {
    final seed = identity.avatarSeed;
    if (seed != null && seed.isNotEmpty && sl.isRegistered<AvatarService>()) {
      return AccountAvatar(seed: seed, size: size);
    }
    final colors = context.mallowColors;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.accent, shape: BoxShape.circle),
      child: Text(
        _initials(identity),
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: MallowTheme.uiBody.copyWith(
          fontSize: size * 0.3,
          height: 1,
          fontWeight: FontWeight.w600,
          color: colors.textOnAccent,
        ),
      ),
    );
  }
}

/// "Wallet 2" reads as W2, "Savings" as S.
String _initials(ReviewWalletIdentity identity) {
  final words = (identity.name ?? '')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return identity.address.characters.take(2).toString();
  final first = words.first.characters.first.toUpperCase();
  return words.length == 1
      ? first
      : '$first${words.last.characters.first.toUpperCase()}';
}
