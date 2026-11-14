import '../../../shared/utils/address_utils.dart';

/// One tappable row in the recipient username-search dropdown: a mallow profile
/// paired with **one** of its addresses.
///
/// A profile links a wallet per chain and often several on the same chain, so a
/// single user can produce several suggestions. That fan-out is deliberate and
/// diverges from the webapp, which collapses a user to `addresses[0]`: two
/// linked Solana wallets are two real destinations, and silently picking one
/// would send to the wrong wallet. [address] is therefore what separates two
/// rows for the same person, and the row renders it truncated for that reason.
class RecipientSuggestion {
  const RecipientSuggestion({
    required this.address,
    this.username,
    this.displayName,
    this.imageUrl,
  });

  /// Already filtered to the chain the send is on — safe to hand straight to
  /// the bloc without re-validating.
  final String address;

  final String? username;
  final String? displayName;
  final String? imageUrl;

  /// A username is unique and only its owner can hold it. A display name is free
  /// text that anyone can set to anyone else's handle, with or without the `@`,
  /// and the backend returns both for the same search. So the two never share a
  /// format: only a username is ever written with an `@`.
  String? get _handle => username?.isEmpty ?? true ? null : username;

  /// [displayName] as a row may show it, or null when nothing is left: without
  /// any `@` or its lookalikes, and without the invisible characters that could
  /// slip one past that or reorder the text around it.
  String? get _cleanDisplayName {
    final cleaned = displayName
        ?.replaceAll(_handleMimicry, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }

  /// Format and control characters, plus `@` in its plain, fullwidth and small
  /// forms.
  static final _handleMimicry = RegExp(
    r'[\p{Cf}\p{Cc}@\uFF20\uFE6B]',
    unicode: true,
  );

  /// Whether the row is named by a display name, which it must mark as such so
  /// that it cannot pass for the account that owns the same text as a username.
  bool get isDisplayNameOnly => _handle == null && _cleanDisplayName != null;

  /// What the row shows: `@username`, else the cleaned display name, else the
  /// truncated address.
  String get label {
    final handle = _handle;
    if (handle != null) return '@$handle';
    return _cleanDisplayName ?? truncateAddress(address);
  }

  /// What replaces the field's text once this row is picked: a real `@username`,
  /// or else the **full** address. Never a display name, which would put text
  /// the profile's owner chose into the recipient field, where it reads as the
  /// resolved recipient. Never [label]'s truncation, which is not a resolvable
  /// address.
  String get fieldText {
    final handle = _handle;
    return handle != null ? '@$handle' : address;
  }
}
