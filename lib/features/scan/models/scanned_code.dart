import '../../../core/services/deep_link_service.dart';
import '../../../shared/utils/chain.dart';
import '../../browser/models/browser_models.dart';
import '../../send/models/payment_request.dart';
import '../../send/models/recipient_address.dart';
import '../../walletconnect/walletconnect_module.dart';

/// What a QR code scanned from the account menu holds, read before the
/// scanner closes so a code the app cannot open keeps the camera running.
sealed class ScannedCode {
  const ScannedCode();

  /// Reads [raw], the text of a scanned code.
  factory ScannedCode.parse(String raw) {
    final text = raw.trim();
    // First, and before anything parses it as a link: a WalletConnect code
    // holds a pairing key and must go to WalletConnect or nowhere.
    if (isWalletConnectText(text)) return WalletConnectCode(text);
    // A bare address, which is what the receive sheet and most wallets
    // encode. Each chain's own validator decides, never [Chain.fromAddress],
    // which reads any unrecognized string as Solana. The Ethereum check is
    // shape-only on purpose: an address that fails its EIP-55 checksum still
    // opens the flow, and the recipient field says why it cannot be used.
    for (final chain in Chain.values) {
      if (chain.isValidAddress(text)) {
        return WalletAddressCode(RecipientAddress(address: text, chain: chain));
      }
    }
    // An address or a payment request behind its chain's scheme.
    switch (parsePaymentUri(text)) {
      case PaymentUriAddress(:final recipient):
        return WalletAddressCode(recipient);
      case PaymentUriRequest(:final request):
        return PaymentRequestCode(request);
      case PaymentUriRefused(:final message):
        return UnsupportedCode(message);
      case null:
        break;
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) return const UnsupportedCode.notALink();
    // The login redirect belongs to the login SDK, never to a scan.
    if (uri.isScheme('mallowwallet') && uri.host == 'auth') {
      return const UnsupportedCode.notALink();
    }
    if (DeepLinkService.isTrustedOrigin(uri)) return MallowLinkCode(uri);
    if (isBrowserUrl(uri)) return WebsiteCode(uri);
    if (uri.isScheme('http')) return const UnsupportedCode.insecure();
    return const UnsupportedCode.notALink();
  }
}

/// A WalletConnect pairing link, or this app's wrapper of one.
final class WalletConnectCode extends ScannedCode {
  const WalletConnectCode(this.text);
  final String text;
}

/// A wallet address, to send tokens or transfer an artwork to.
final class WalletAddressCode extends ScannedCode {
  const WalletAddressCode(this.recipient);
  final RecipientAddress recipient;
}

/// A request to be paid, which goes straight to the send flow.
final class PaymentRequestCode extends ScannedCode {
  const PaymentRequestCode(this.request);
  final PaymentRequest request;
}

/// A link to the app's own website, or one in its custom scheme. It goes
/// where the same link would go had it opened the app.
final class MallowLinkCode extends ScannedCode {
  const MallowLinkCode(this.uri);
  final Uri uri;
}

/// Any other HTTPS website, for the in-app browser.
final class WebsiteCode extends ScannedCode {
  const WebsiteCode(this.url);
  final Uri url;
}

/// A code the app does not open. [message] says why.
final class UnsupportedCode extends ScannedCode {
  const UnsupportedCode(this.message);
  const UnsupportedCode.notALink()
    : message = "This QR code isn't a link or wallet address mallow can open";
  const UnsupportedCode.insecure()
    : message = 'Only secure (HTTPS) websites can be opened';

  final String message;
}
