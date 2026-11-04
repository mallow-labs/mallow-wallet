/// Ethereum Ledger app APDU constants.
///
/// Reference: https://github.com/LedgerHQ/app-ethereum
class EthereumApdu {
  EthereumApdu._();

  /// Class byte for the Ethereum Ledger app.
  static const int cla = 0xE0;

  /// Get a public key / address for a derivation path.
  static const int insGetAddress = 0x02;

  /// Sign an Ethereum transaction.
  static const int insSignTransaction = 0x04;

  /// Sign an EIP-191 `personal_sign` message. The device prepends the
  /// `\x19Ethereum Signed Message:\n<len>` prefix, keccak256-hashes, and signs.
  static const int insSignPersonalMessage = 0x08;

  /// Sign EIP-712 typed data. With P2 [p2Eip712Full] the device hashes the
  /// struct definitions and values streamed before it; with P2
  /// [p2Eip712Hashes] it signs a host-computed domain separator and message
  /// hash (app versions before 1.9.19).
  static const int insSignEip712 = 0x0C;

  /// EIP-712: send a struct definition (its name, then one APDU per field).
  static const int insEip712StructDefinition = 0x1A;

  /// EIP-712: send the values (root struct name, array sizes, field values).
  static const int insEip712StructImplementation = 0x1C;

  /// P2 for [insSignEip712]: sign the host-computed hashes ("v0").
  static const int p2Eip712Hashes = 0x00;

  /// P2 for [insSignEip712]: sign what the device hashed itself.
  static const int p2Eip712Full = 0x01;

  /// P2 for the EIP-712 struct commands: a struct (or root struct) name.
  static const int p2Eip712Name = 0x00;

  /// P2 for [insEip712StructImplementation]: the size of the next array.
  static const int p2Eip712Array = 0x0F;

  /// P2 for the EIP-712 struct commands: a field (definition or value).
  static const int p2Eip712Field = 0xFF;

  /// P1 for an EIP-712 APDU that completes its item.
  static const int p1Eip712Complete = 0x00;

  /// P1 for an EIP-712 field value that continues in the next APDU.
  static const int p1Eip712Partial = 0x01;

  /// P1: derive without prompting the user to confirm on the device screen.
  static const int p1NoConfirm = 0x00;

  /// P1: show the address on the device and require user confirmation.
  static const int p1Confirm = 0x01;

  /// P1: the first APDU of a personal-message sign — carries the BIP32 path and
  /// the 4-byte total message length ahead of the first message chunk.
  static const int p1SignFirst = 0x00;

  /// P1: a continuation APDU of a personal-message sign (message bytes only).
  static const int p1SignSubsequent = 0x80;

  /// P2: do not return the BIP32 chain code.
  static const int p2NoChainCode = 0x00;

  /// P2: return the BIP32 chain code alongside the address.
  static const int p2ChainCode = 0x01;

  /// P2 for personal-message signing (unused — always 0x00).
  static const int p2SignPersonalMessage = 0x00;
}
