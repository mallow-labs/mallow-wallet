import 'package:test/test.dart';
import 'package:mallow_api/mallow_api.dart';
import 'package:mallow_api/src/generated/openapi.models.swagger.dart' as contract;

void main() {
  test('Given a SIWS request, serialization includes the format', () {
    const request = AuthTokenRequest(address: 'solana-address', format: 'siws');
    expect(request.toJson(), {'address': 'solana-address', 'format': 'siws'});
    expect(AuthTokenRequest.fromJson(request.toJson()), request);
  });

  test('Given a legacy request, serialization omits the format', () {
    expect(const AuthTokenRequest(address: 'ethereum-address').toJson(), {
      'address': 'ethereum-address',
    });
    expect(
      const AuthTokenVerifyRequest(
        address: 'tezos-address',
        message: 'login',
        signature: 'signature',
      ).toJson(),
      {'address': 'tezos-address', 'message': 'login', 'signature': 'signature'},
    );
  });

  test('The generated challenge contract preserves the SIWS format', () {
    final request = contract.AuthTokenRequest.fromJson({
      'address': 'solana-address',
      'format': 'siws',
    });
    expect(request.toJson()['format'], 'siws');
  });

  test('The generated verification contract preserves the SIWS format', () {
    final request = contract.AuthTokenVerifyRequest.fromJson({
      'address': 'solana-address',
      'message': 'server-issued message',
      'signature': 'signature',
      'format': 'siws',
    });
    expect(request.toJson()['format'], 'siws');
  });
}
