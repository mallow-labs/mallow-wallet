import 'dart:convert';

import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  group('BurnTxRequest wire payload', () {
    // Lock down camelCase serialization. The backend `BurnTxRequest` is
    // `#[serde(rename_all = "camelCase")]` with `tokenStandard` **required**
    // (no default, no alias). A snake_case key like `token_standard` makes
    // serde reject the body (400/422), silently breaking the burn flow — a bug
    // this test exists to catch. We assert the wire keys (not the Dart fields),
    // and go through `jsonEncode` exactly like Dio does.
    test('serializes the full payload with camelCase keys', () {
      final request = BurnTxRequest(
        authority: 'AUTH',
        asset: 'ASSET',
        tokenStandard: TokenStandard.nft.apiValue,
        targetPriorityFeeLamports: 5000,
      );

      final wire = jsonDecode(jsonEncode(request)) as Map<String, dynamic>;

      expect(wire['authority'], 'AUTH');
      expect(wire['asset'], 'ASSET');
      expect(wire['tokenStandard'], 'nft');
      expect(wire['targetPriorityFeeLamports'], 5000);

      // The snake_case keys the backend never reads must be absent.
      expect(wire.containsKey('token_standard'), isFalse);
      expect(wire.containsKey('target_priority_fee_lamports'), isFalse);
    });

    // Collection membership and printed-edition parentage are resolved
    // on-chain by the builder — the contract dropped both fields (and the
    // `MasterEditionRef` schema with them). Sending them again would mean the
    // client is back to doing lookups the backend already does.
    test('omits the collection and masterEdition fields entirely', () {
      final request = BurnTxRequest(
        authority: 'AUTH',
        asset: 'ASSET',
        tokenStandard: TokenStandard.nft.apiValue,
      );

      final wire = jsonDecode(jsonEncode(request)) as Map<String, dynamic>;

      expect(wire.containsKey('collection'), isFalse);
      expect(wire.containsKey('masterEdition'), isFalse);
    });
  });
}
