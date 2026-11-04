import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/walletconnect/services/walletconnect_page_code.dart';

void main() {
  final link = 'wc:${'a' * 64}@2?symKey=${'b' * 64}&relay-protocol=irn';

  test('The WalletConnect code is picked from among other codes', () {
    expect(walletConnectCodeIn([null, 'https://mallow.art', ' $link ']), link);
  });

  test('A page without a WalletConnect code yields none', () {
    expect(walletConnectCodeIn(['solana:7xKX', null]), isNull);
    expect(walletConnectCodeIn(const []), isNull);
  });
}
