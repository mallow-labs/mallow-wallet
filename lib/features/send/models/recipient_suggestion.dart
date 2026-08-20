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

  /// What the row shows. The backend matches on display name and twitter handle
  /// as well as username, so a result with no username is a real match and is
  /// labelled by whatever it does have.
  String get label => username ?? displayName ?? truncateAddress(address);

  /// What replaces the field's text once this row is picked. Only a real
  /// username gets the `@` — prefixing a display name with one would read as a
  /// handle that doesn't exist. A profile with neither falls back to the **full**
  /// address, never [label]'s truncation, which is not a resolvable address.
  String get fieldText =>
      username != null ? '@$username' : (displayName ?? address);
}
