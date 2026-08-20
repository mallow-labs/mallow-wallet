/// A non-blocking heads-up about *what kind of account* the send recipient is.
///
/// Every one of these is a legitimate destination in some context — PDAs
/// receive assets, contract wallets (Safe/Argent) are normal EVM recipients,
/// and a brand-new wallet is unfunded by definition. So this never gates the
/// Send CTA; it only makes the user look before they sign.
enum RecipientAdvisoryKind {
  /// Solana: the account is owned by the SPL Token / Token-2022 program, i.e.
  /// the user pasted a token account instead of the wallet that owns it. The
  /// highest-value signal on Solana — it is a common, total loss.
  tokenAccount,

  /// Solana: the address is off the ed25519 curve, so it is a program-derived
  /// address rather than a keypair-backed wallet.
  programAddress,

  /// EVM: the address has deployed code. Tezos: the address is a `KT1`
  /// origination.
  contract,

  /// The address has never been funded — no Solana account, or a zero EVM
  /// balance *and* a zero nonce.
  unfunded,
}

/// A single advisory to render on the confirm step. Only one is ever shown:
/// stacking warnings is how users learn to dismiss them, so
/// [RecipientAdvisoryKind]'s declaration order doubles as the severity order
/// and the detector emits the most severe match only.
class RecipientAdvisory {
  const RecipientAdvisory(this.kind, this.message);

  final RecipientAdvisoryKind kind;

  /// User-facing copy. Deliberately per-kind and per-chain — an ERC-20 send to
  /// a contract fails differently than an NFT `safeTransferFrom` does, so the
  /// NFT flow's string must not be reused.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is RecipientAdvisory &&
      other.kind == kind &&
      other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'RecipientAdvisory(${kind.name}: $message)';
}
