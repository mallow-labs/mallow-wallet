import '../../../core/router/app_router.dart';
import '../../../core/services/deep_link_handler_registry.dart';
import '../../../core/services/deep_link_service.dart';
import '../../browser/models/browser_models.dart';
import '../../browser/models/browser_open_link.dart';
import '../../send/models/payment_request.dart';
import '../../send/models/recipient_address.dart';
import '../models/scanned_code.dart';

/// Sends a scanned code where it belongs: WalletConnect, a send to a wallet
/// address, a payment, a feature that claims the link, an in-app screen, or the browser.
class ScannedCodeRouter {
  ScannedCodeRouter({
    required this.handlers,
    required this.connect,
    required this.sendTo,
    required this.pay,
    required this.push,
    required this.browserEnabled,
    required this.showMessage,
  });

  final DeepLinkHandlerRegistry handlers;

  /// Takes a WalletConnect link; see `handleWalletConnectText`.
  final bool Function(String text) connect;

  /// Offers what can be sent to a scanned wallet address.
  final void Function(RecipientAddress recipient) sendTo;

  /// Opens the send flow for a payment request.
  final void Function(PaymentRequest request) pay;

  /// Pushes an app route onto the current stack.
  final void Function(String location, {Object? extra}) push;
  final bool Function() browserEnabled;
  final void Function(String message) showMessage;

  void open(ScannedCode code) {
    switch (code) {
      case WalletConnectCode(:final text):
        connect(text);
      case WalletAddressCode(:final recipient):
        sendTo(recipient);
      case PaymentRequestCode(:final request):
        pay(request);
      case MallowLinkCode(:final uri):
        _openMallowLink(uri);
      case WebsiteCode(:final url):
        _openWebsite(url);
      case UnsupportedCode(:final message):
        showMessage(message);
    }
  }

  void _openMallowLink(Uri uri) {
    // The order an inbound app link takes: a feature's own claim first, as
    // a link that names a path the route map does not know is otherwise
    // only a web page. Never a replay: every scan is a fresh one.
    if (handlers.handle(uri, replay: false)) return;
    final handoff = browserOpenLinkUrl(uri);
    if (handoff != null) return _openWebsite(handoff);
    final location = DeepLinkService.mapToLocation(uri);
    if (location != null) return push(location);
    // A page of the website the app has no screen for.
    if (isBrowserUrl(uri)) return _openWebsite(uri);
    showMessage(const UnsupportedCode.notALink().message);
  }

  void _openWebsite(Uri url) {
    if (!browserEnabled()) {
      showMessage('The browser is not available right now');
      return;
    }
    push(AppRoutes.browserOpen, extra: BrowserOpenRequest(url));
  }
}
