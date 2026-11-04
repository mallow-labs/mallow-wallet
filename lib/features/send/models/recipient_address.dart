import '../../../shared/utils/chain.dart';

/// A recipient chosen before a send or artwork transfer starts, such as a
/// wallet address read from a QR code.
///
/// It carries its [chain] because a flow that receives one has to narrow to
/// what can go there: the token list to that chain's tokens, the artwork list
/// to that chain's artworks. Inferring the chain again from the address
/// would not be safe, as [Chain.fromAddress] reads any unrecognized string as
/// Solana.
class RecipientAddress {
  const RecipientAddress({required this.address, required this.chain});

  /// The address as read. An EVM address keeps its case, so the recipient
  /// field can still check its EIP-55 checksum.
  final String address;
  final Chain chain;

  @override
  bool operator ==(Object other) =>
      other is RecipientAddress &&
      other.address == address &&
      other.chain == chain;

  @override
  int get hashCode => Object.hash(address, chain);
}
