import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/network/logging_interceptor.dart';

void main() {
  test('redacts social-vault credentials and signing material', () {
    final redacted =
        PrettyLoggingInterceptor.redactSensitive({
              'idToken': 'eyJ.id.token',
              'identityToken': 'identity',
              'vaultId': 'kept',
              'payloadCiphertext': 'ciphertext',
              'slots': [
                {'slotId': 'kept', 'wrappedKey': 'wrapped'},
              ],
              'x-vault-signature': 'sig',
              'signedTransaction': 'tx',
            })
            as Map;
    expect(redacted['idToken'], '***redacted***');
    expect(redacted['identityToken'], '***redacted***');
    expect(redacted['payloadCiphertext'], '***redacted***');
    expect(redacted['x-vault-signature'], '***redacted***');
    expect(redacted['signedTransaction'], '***redacted***');
    expect(redacted['vaultId'], 'kept');
    final slot = (redacted['slots'] as List).single as Map;
    expect(slot['wrappedKey'], '***redacted***');
    expect(slot['slotId'], 'kept');
  });
}
