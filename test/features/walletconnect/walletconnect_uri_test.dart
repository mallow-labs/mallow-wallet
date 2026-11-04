import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_uri.dart';

void main() {
  final topic = 'a' * 64;
  final key = 'b' * 64;
  final pairing = 'wc:$topic@2?relay-protocol=irn&symKey=$key';

  test('Given a pairing link, it parses as a pairing', () {
    final uri = WalletConnectUri.tryParse(pairing);
    expect(uri, isNotNull);
    expect(uri!.isPairing, isTrue);
    expect(uri.uri.toString(), pairing);
    expect(uri.topic, topic);
  });

  test('Given the app wrapper, it unwraps the link inside', () {
    final wrapped = Uri(
      scheme: 'mallowwallet',
      host: 'wc',
      queryParameters: {'uri': pairing},
    );
    expect(WalletConnectUri.isWrapper(wrapped), isTrue);
    expect(WalletConnectUri.tryParse(wrapped.toString())?.isPairing, isTrue);
  });

  test('Given a request link with no key, it is not a pairing', () {
    final uri = WalletConnectUri.tryParse('wc:$topic@2?requestId=1');
    expect(uri?.isPairing, isFalse);
  });

  test('Given a malformed, expired or v1 link, nothing parses', () {
    for (final text in [
      'wc:$topic@1?bridge=x&key=$key',
      'wc:short@2?symKey=$key',
      'wc:$topic@2?symKey=short',
      'wc:$topic@2',
      'wc:$topic@2?symKey=$key&relay-protocol=waku',
      'wc:$topic@2?symKey=$key&expiryTimestamp=1',
      'https://example.com/wc?uri=${Uri.encodeComponent(pairing)}',
      'wc:$topic@2?symKey=$key&x=${'y' * 3000}',
    ]) {
      expect(WalletConnectUri.tryParse(text), isNull, reason: text);
    }
  });

  test('A parsed link never prints its key', () {
    expect(WalletConnectUri.tryParse(pairing).toString(), isNot(contains(key)));
  });
}
