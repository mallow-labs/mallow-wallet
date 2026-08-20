import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  // byMint renders MarketEventV1: the resolved profile lives in `user`,
  // while `buyer`/`seller` leak through as bare address strings. History
  // rows must read `user` to show a pfp + username instead of degrading
  // to a blank avatar + truncated address.
  test('MarketActivityEvent parses v1 `user` alongside bare buyer/seller', () {
    final json = <String, dynamic>{
      'txId': 'tx1',
      'mintAccount': 'Mint111',
      'type': 2,
      'buyer': '9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin',
      'seller': 'BPFLoaderUpgradeab1e11111111111111111111111',
      'user': {
        'addresses': ['9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin'],
        'username': 'alice',
        'imageUrl': 'http://avatar',
      },
      'price': 1.5,
    };
    final event = MarketActivityEvent.fromJson(json);
    expect(event.type, MarketEventType.sale);
    expect(event.user?.username, 'alice');
    expect(event.user?.avatarUrl, 'http://avatar');
    expect(event.buyer, const ApiUserRef(address: '9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin'));
  });
}
