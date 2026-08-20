import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  test('ApiUserRef parses User-shaped JSON', () {
    final json = <String, dynamic>{
      'addresses': ['9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin'],
      'username': 'alice',
      'displayName': 'Alice',
      'imageUrl': 'http://avatar',
      'isTwitterVerified': true,
      'isFlagged': false,
      'followerCount': 100,
    };
    final ref = apiUserRefFromAny(json)!;
    expect(ref.username, 'alice');
    expect(ref.displayName, 'Alice');
    expect(ref.avatarUrl, 'http://avatar');
    expect(ref.isTwitterVerified, true);
    expect(ref.addresses, ['9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin']);
    expect(ref.effectiveAddress, '9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin');
  });
}
