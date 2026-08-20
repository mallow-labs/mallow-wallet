import '../../core/utils/address_format.dart';
import 'chain.dart';

String? _formatUsername(String? username) {
  if (username == null || username.isEmpty) return null;

  // The API sometimes places an address in `username` when the wallet has no
  // profile handle. Treat those values as addresses so they use the same
  // middle-ellipsis treatment as the explicit address fallback.
  if (isEthereumAddress(username) || isLikelySolanaAddress(username)) {
    return truncateAddress(username);
  }
  return username;
}

/// Display label for a wallet user: `username` when set, otherwise the
/// truncated `address`. Empty string when neither is available.
///
/// Use this for general transaction/header contexts (e.g. activity rows,
/// shared header) where a `@` prefix isn't desired.
String formatUsernameOrAddress({String? username, String? address}) {
  final formattedUsername = _formatUsername(username);
  if (formattedUsername != null) return formattedUsername;
  if (address != null && address.isNotEmpty) return truncateAddress(address);
  return '';
}

/// Display label for an artist/handle context: `@username` when set,
/// otherwise the truncated `address`. Empty string when neither is set.
///
/// Use this for creator/artist surfaces (artwork detail, listing review)
/// where the `@` prefix is part of the visual treatment.
String formatHandleOrAddress({String? username, String? address}) {
  final formattedUsername = _formatUsername(username);
  if (formattedUsername != null) {
    if (formattedUsername == username) return '@$formattedUsername';
    return formattedUsername;
  }
  if (address != null && address.isNotEmpty) return truncateAddress(address);
  return '';
}

/// Display label preferring [displayName] (rendered as-is), falling back
/// to [username] (bare, no `@`), then to a truncated [address]. Empty
/// string when none are set.
///
/// Use this for general user-label surfaces (artwork cards, profile rows)
/// where a real name is preferred and the `@` prefix isn't desired.
String formatDisplayLabel({
  String? displayName,
  String? username,
  String? address,
}) {
  if (displayName != null && displayName.isNotEmpty) return displayName;
  return formatUsernameOrAddress(username: username, address: address);
}
