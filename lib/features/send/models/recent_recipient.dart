/// A recent send recipient — a locally-saved address optionally enriched with
/// the local Account it belongs to (name + generated avatar) or, failing that,
/// the mallow profile (username + pfp) it resolves to.
class RecentRecipient {
  const RecentRecipient({
    required this.address,
    this.username,
    this.imageUrl,
    this.accountName,
    this.accountAvatarSeed,
  });

  final String address;
  final String? username;
  final String? imageUrl;

  /// When this address belongs to one of the user's local accounts, its
  /// `Account NN` name and stable `avatarSeed` — rendered (via `AccountAvatar`)
  /// when the address has no mallow profile to show instead.
  final String? accountName;
  final String? accountAvatarSeed;

  /// Name to show for this recipient: the mallow profile username first, then
  /// the local `Account NN`, then (at the call site) the truncated address.
  ///
  /// The username wins because it is the recipient's *public* identity — the
  /// one that also names them everywhere else in the app and on the web — while
  /// `Account NN` is a local label that says nothing about who holds the
  /// address. The send confirm step and the artwork transfer flow order these
  /// the same way; a recipient must not be named one thing on this list and
  /// another on the review screen.
  String? get displayName => username ?? accountName;

  RecentRecipient copyWith({
    String? username,
    String? imageUrl,
    String? accountName,
    String? accountAvatarSeed,
  }) => RecentRecipient(
    address: address,
    username: username ?? this.username,
    imageUrl: imageUrl ?? this.imageUrl,
    accountName: accountName ?? this.accountName,
    accountAvatarSeed: accountAvatarSeed ?? this.accountAvatarSeed,
  );
}
