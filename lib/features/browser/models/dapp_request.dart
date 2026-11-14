import 'dart:typed_data';

import '../../../core/models/account.dart' show WalletType;

/// Provenance supplied exclusively by the platform WebView callback.
class DappFrameContext {
  const DappFrameContext({
    required this.tabId,
    required this.generation,
    required this.origin,
    required this.isMainFrame,
    required this.isActive,
    this.certificateException = false,
    this.documentToken = '',
    this.iconUrl,
  });
  final String tabId;
  final int generation;
  final Uri origin;
  final bool isMainFrame;
  final bool isActive;

  /// The user chose to open this origin despite an untrusted certificate, so
  /// the page may not be the site [origin] names. A saved grant does not
  /// vouch for such a page: it must connect again, under the certificate
  /// warning, before it may request a signature.
  final bool certificateException;

  /// The native host's random id for the document that sent the request.
  /// Generations restart with a new WebView; this does not, so it tells two
  /// documents apart where [generation] alone might not.
  final String documentToken;

  /// The icon a request from outside the browser came with, such as a
  /// WalletConnect website's own. Decoration only, like a tab's icon.
  final Uri? iconUrl;

  String get canonicalOrigin => origin.origin;
}

/// Whether a Solana wallet of [type] can sign a site's message verbatim, which
/// is what `solana:signMessage` promises: the site verifies the signature over
/// the exact bytes it sent.
///
/// A Ledger's Solana app signs only messages in the off-chain format, so it
/// cannot sign a site's raw bytes; it answers `solana:signOffchainMessage`
/// instead (see [solanaSignsOffchainMessages]). Keystone signs the bytes as given; the device shows a `\xffsolana
/// offchain` message structurally and anything else as UTF-8 or hex.
bool solanaSignsDappMessagesVerbatim(WalletType type) => switch (type) {
  WalletType.hd ||
  WalletType.importedKey ||
  WalletType.social ||
  WalletType.seedVault ||
  WalletType.keystone => true,
  WalletType.ledger || WalletType.viewOnly => false,
};

/// Whether a Solana wallet of [type] can answer `solana:signOffchainMessage`.
/// The wallet builds those bytes itself, in the off-chain format, so a Ledger
/// can sign them where it cannot sign a site's raw message. Its Solana app
/// needs version 1.14 or later for the version 1 format.
bool solanaSignsOffchainMessages(WalletType type) => switch (type) {
  WalletType.hd ||
  WalletType.importedKey ||
  WalletType.social ||
  WalletType.seedVault ||
  WalletType.keystone ||
  WalletType.ledger => true,
  WalletType.viewOnly => false,
};

class DappWallet {
  const DappWallet({
    required this.id,
    required this.address,
    required this.canSign,
    bool? canSignMessages,
    bool? canSignTypedData,
    this.chains = const ['solana:mainnet'],
    this.type,
  }) : canSignMessages = canSignMessages ?? canSign,
       canSignTypedData = canSignTypedData ?? canSign;
  final String id;
  final String address;
  final bool canSign;
  final bool canSignMessages;

  /// EIP-712 typed data (Ethereum only). A Ledger signs transactions and
  /// personal messages but has no typed-data path here.
  final bool canSignTypedData;

  /// Solana off-chain messages (`solana:signOffchainMessage`); see
  /// [solanaSignsOffchainMessages]. Follows [type], which a wallet id never
  /// changes, so the pinned copy of a request cannot drift from it.
  bool get canSignOffchainMessages =>
      canSign && type != null && solanaSignsOffchainMessages(type!);
  final List<String> chains;

  /// Picks the signing copy only (local key, Ledger, other external signer).
  /// Signing itself resolves the wallet row by [id].
  final WalletType? type;
}

class DappConnectionRequest {
  const DappConnectionRequest({
    required this.context,
    required this.wallet,
    required this.cancelled,
    required this.ensureActive,
  });
  final Future<void> cancelled;
  final void Function() ensureActive;
  final DappFrameContext context;
  final DappWallet wallet;
}

class DappSigningRequest {
  DappSigningRequest({
    required this.id,
    required this.method,
    required this.context,
    required this.wallet,
    required this.chain,
    required List<Uint8List> payloads,
    required this.payloadDigest,
    required this.cancelled,
    required Map<String, Object?> options,
    required this.ensureActive,
  }) : payloads = List.unmodifiable(
         payloads.map(
           (bytes) => Uint8List.fromList(bytes).asUnmodifiableView(),
         ),
       ),
       options = Map.unmodifiable(options);
  final String id;
  final String method;
  final DappFrameContext context;
  final DappWallet wallet;
  final String chain;
  final List<Uint8List> payloads;
  final String payloadDigest;
  final Future<void> cancelled;
  final Map<String, Object?> options;

  /// Must be called again after approval/auth/hardware waits, before each signature.
  final void Function() ensureActive;
}

class DappException implements Exception {
  const DappException(this.code, this.message, {this.data});
  final int code;
  final String message;

  /// Revert data for a failed read, so a website can decode its own
  /// contract's error. Never set from anything but a node's hex payload.
  final String? data;
  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    if (data != null) 'data': data,
  };
  @override
  String toString() => 'DappException($code, $message)';
}
