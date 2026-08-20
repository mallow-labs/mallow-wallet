import 'dart:convert';

import 'package:mallow_api/mallow_api.dart';
import 'package:test/test.dart';

void main() {
  group('TransferTxRequest wire payload', () {
    // Lock down camelCase serialization. The backend `TransferTxRequest` is
    // `#[serde(rename_all = "camelCase")]` with `tokenStandard` **required**.
    // A snake_case key like `token_standard` makes serde reject the body
    // (400/422) — the same class of bug already fixed for burn. We assert the
    // wire keys (not the Dart fields) and go through `jsonEncode` exactly like
    // Dio does.
    test('serializes the full payload with camelCase keys', () {
      final request = TransferTxRequest(
        authority: 'AUTH',
        asset: 'ASSET',
        recipient: 'RECIPIENT',
        tokenStandard: TokenStandard.core.apiValue,
        targetPriorityFeeLamports: 5000,
      );

      final wire = jsonDecode(jsonEncode(request)) as Map<String, dynamic>;

      expect(wire['authority'], 'AUTH');
      expect(wire['asset'], 'ASSET');
      expect(wire['recipient'], 'RECIPIENT');
      expect(wire['tokenStandard'], 'core');
      expect(wire['targetPriorityFeeLamports'], 5000);

      // The snake_case keys the backend never reads must be absent.
      expect(wire.containsKey('token_standard'), isFalse);
      expect(wire.containsKey('target_priority_fee_lamports'), isFalse);
      // Collection membership is resolved on-chain; the contract dropped the
      // field, so the client must not send it.
      expect(wire.containsKey('collection'), isFalse);
    });

    // `amount` is a decimal **string** in the token's smallest unit — the old
    // int `amount` / string `amountRaw` pair collapsed into this one field
    // because uint256 EVM values overflow a 64-bit integer.
    test('EVM amount travels as a decimal string under `amount`', () {
      final request = TransferTxRequest(
        authority: 'AUTH',
        asset: 'native',
        recipient: 'RECIPIENT',
        tokenStandard: TokenStandard.native.apiValue,
        amount: '1000000000000000000',
      );

      final wire = jsonDecode(jsonEncode(request)) as Map<String, dynamic>;

      expect(wire['amount'], '1000000000000000000');
      expect(wire.containsKey('amountRaw'), isFalse);
    });

    // The cNFT path passes only authority/asset/recipient/tokenStandard — the
    // backend resolves leaf data + the canopy-trimmed merkle proof via DAS.
    test('cNFT minimal payload still carries camelCase tokenStandard', () {
      final request = TransferTxRequest(
        authority: 'AUTH',
        asset: 'ASSET',
        recipient: 'RECIPIENT',
        tokenStandard: TokenStandard.cnft.apiValue,
      );

      final wire = jsonDecode(jsonEncode(request)) as Map<String, dynamic>;

      expect(wire['tokenStandard'], 'cnft');
      expect(wire.containsKey('token_standard'), isFalse);
    });
  });
}
