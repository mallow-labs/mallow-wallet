import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/core/crypto/eip712.dart';
import 'package:mallow_wallet/core/crypto/wallet_manager.dart';
import 'package:mallow_wallet/features/browser/models/dapp_request.dart';
import 'package:mallow_wallet/features/browser/services/ethereum_dapp_adapter.dart';
import 'package:mallow_wallet/features/browser/widgets/typed_data_signing_review.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/review_risk_card.dart';
import 'package:mallow_wallet/shared/widgets/review_wallet_identity.dart';
import 'package:mallow_wallet/shared/widgets/signing_review_layout.dart';
import 'package:mocktail/mocktail.dart';

class _WalletManager extends Mock implements WalletManager {}

const _me = '0x1111111111111111111111111111111111111111';
const _recipient = '0x2222222222222222222222222222222222222222';
const _usdc = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';

const _domainType = [
  {'name': 'name', 'type': 'string'},
  {'name': 'version', 'type': 'string'},
  {'name': 'chainId', 'type': 'uint256'},
  {'name': 'verifyingContract', 'type': 'address'},
];
const _authorizationType = [
  {'name': 'from', 'type': 'address'},
  {'name': 'to', 'type': 'address'},
  {'name': 'value', 'type': 'uint256'},
  {'name': 'validAfter', 'type': 'uint256'},
  {'name': 'validBefore', 'type': 'uint256'},
  {'name': 'nonce', 'type': 'bytes32'},
];
const _domain = {
  'name': 'USD Coin',
  'version': '2',
  'chainId': 1,
  'verifyingContract': _usdc,
};
final _message = <String, Object?>{
  'from': _me,
  'to': _recipient,
  'value': '5000000000',
  'validAfter': '0',
  'validBefore': '1893456000',
  'nonce': '0x${'ab' * 32}',
};

/// A USDC transfer authorization: a signature that moves 5,000 USDC to
/// [_recipient] when anyone submits it.
Map<String, Object?> _authorization({
  Map<String, Object?>? message,
  List<Map<String, String>> type = _authorizationType,
  Map<String, Object?> domain = _domain,
}) => {
  'types': {'EIP712Domain': _domainType, 'TransferWithAuthorization': type},
  'domain': domain,
  'primaryType': 'TransferWithAuthorization',
  'message': message ?? _message,
};

Future<EthereumTypedDataReview> _prepare(Object? typedData) =>
    EthereumDappAdapter(
      walletManager: _WalletManager(),
      rpc: (_, _) async => throw StateError('No token metadata available'),
    ).prepareTypedData(
      typedData: typedData,
      origin: 'https://app.example',
      address: _me,
      walletId: 'w',
    );

Matcher _refused(String because) => throwsA(
  isA<DappException>()
      .having((e) => e.code, 'code', -32602)
      .having((e) => e.message, 'message', contains(because)),
);

/// Shows [review] and reports whether a tap, then a press-and-hold, on
/// Approve signed.
Future<({bool tap, bool hold})> _approve(
  WidgetTester tester,
  EthereumTypedDataReview review,
) async {
  tester.view.physicalSize = const Size(390, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var approved = 0;
  // A second review in one test starts from a fresh hold button.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: TypedDataSigningReview(
            review: review,
            wallet: const ReviewWalletIdentity(address: _me, name: 'Main'),
            onReject: () {},
            onApprove: () => approved++,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final approve = find.byKey(const Key('approve-signing'));
  // Reject leads, and Approve is the press-and-hold button.
  expect(
    tester.getTopLeft(find.byKey(const Key('reject-signing'))).dy,
    lessThan(tester.getTopLeft(approve).dy),
  );
  expect(find.text('Hold to approve anyway'), findsOneWidget);
  await tester.tap(approve);
  await tester.pump();
  final tap = approved > 0;
  final gesture = await tester.startGesture(tester.getCenter(approve));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 1300));
  await gesture.up();
  await tester.pump();
  return (tap: tap, hold: approved > 0);
}

/// The rows the review lists, as `label: value`.
List<String> _rows(Eip712TypedData data, {int? limit}) => [
  for (final (label, value)
      in (limit == null
              ? typedDataReviewRows(data)
              : typedDataReviewRows(data, limit: limit))
          .rows)
    '$label: $value',
];

void main() {
  group('typed data whose rows the page wrote', () {
    // The signature covers only the fields the primary type declares. A
    // review that listed the message's keys as sent would show these twelve
    // and push the transfer's own fields off the list.
    final decoys = <String, Object?>{
      'Action': 'Sign in to mallow',
      'You send': 'Nothing',
      'You receive': 'Access to your account',
      'Cost': 'Free',
      'Network fee': 'None',
      'Risk': 'None',
      'Session': '24 hours',
      'Site': 'app.example',
      'Purpose': 'Authentication only',
      'Tokens moved': '0',
      'Approvals': 'None',
      'Note': 'This request cannot move funds',
    };

    test('twelve decoy fields ahead of a transfer authorization are '
        'refused', () async {
      expect(decoys, hasLength(12));
      await expectLater(
        _prepare(_authorization(message: {...decoys, ..._message})),
        _refused('undeclared field'),
      );
      // One is enough, wherever it sits.
      await expectLater(
        _prepare(_authorization(message: {..._message, 'Action': 'Sign in'})),
        _refused('undeclared field Action'),
      );
      // As the JSON string a page actually sends, too.
      expect(
        () => Eip712TypedData.parse(
          '{"types":{"Vote":[{"name":"proposal","type":"uint256"}]},'
          '"primaryType":"Vote","domain":{},'
          '"message":{"You send":"Nothing","proposal":1}}',
        ),
        throwsA(isA<Eip712Exception>()),
      );
    });

    test('a decoy in the domain, in a nested value or in an array item is '
        'refused, and so is a missing field', () async {
      await expectLater(
        _prepare(_authorization(domain: {..._domain, 'Action': 'Sign in'})),
        _refused('Domain field Action is not declared'),
      );
      Map<String, Object?> order(Object? maker, List<Object?> items) => {
        'types': {
          'EIP712Domain': _domainType,
          'Trade': [
            {'name': 'maker', 'type': 'Party'},
            {'name': 'items', 'type': 'Item[]'},
          ],
          'Party': [
            {'name': 'wallet', 'type': 'address'},
          ],
          'Item': [
            {'name': 'amount', 'type': 'uint256'},
          ],
        },
        'domain': _domain,
        'primaryType': 'Trade',
        'message': {'maker': maker, 'items': items},
      };
      final sound = await _prepare(
        order(
          {'wallet': _me},
          [
            {'amount': '1'},
          ],
        ),
      );
      expect(_rows(sound.data), ['maker.wallet: $_me', 'items[0].amount: 1']);
      await expectLater(
        _prepare(order({'wallet': _me, 'note': 'free'}, [])),
        _refused('undeclared field note'),
      );
      await expectLater(
        _prepare(
          order(
            {'wallet': _me},
            [
              {'amount': '1', 'gift': 'yes'},
            ],
          ),
        ),
        _refused('undeclared field gift'),
      );
      await expectLater(
        _prepare(order(<String, Object?>{}, [])),
        _refused('missing wallet'),
      );
    });

    testWidgets('without the decoys, the signed fields are listed in declared '
        'order and the transfer takes a hold', (tester) async {
      // The message's own key order is not the declared one.
      final shuffled = Map.fromEntries(_message.entries.toList().reversed);
      final review = (await tester.runAsync(
        () => _prepare(_authorization(message: shuffled)),
      ))!;
      expect(review.kind, TypedDataKind.transfer);
      expect(_rows(review.data), [
        'from: $_me',
        'to: $_recipient',
        'value: 5000000000',
        'validAfter: 0',
        'validBefore: 1893456000',
        'nonce: 0x${'ab' * 32}',
      ]);
      final transfer = review.transfers.single;
      expect(transfer.from, _me);
      expect(transfer.recipient, _recipient);
      expect(transfer.amount, BigInt.from(5000000000));
      expect(transfer.token, _usdc.toLowerCase());
      expect(transfer.validFrom, isNull, reason: 'valid at once');
      expect(transfer.expires, DateTime.utc(2030));

      expect(await _approve(tester, review), (tap: false, hold: true));
      expect(find.text('Authorize a token transfer'), findsOneWidget);
      final card = find.byKey(const Key('typed-data-transfer'));
      expect(tester.widget(card), isA<ReviewRiskCard>());
      expect(
        find.descendant(of: card, matching: find.text('Transfer 5,000 USDC')),
        findsOneWidget,
      );
      for (final label in ['From', 'To', 'USDC contract', 'Valid']) {
        expect(
          find.descendant(of: card, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      expect(
        tester
            .widgetList<ReviewAddress>(
              find.descendant(of: card, matching: find.byType(ReviewAddress)),
            )
            .map((chip) => chip.address),
        [_me, _recipient, _usdc.toLowerCase()],
      );
      expect(
        find.descendant(of: card, matching: find.textContaining('until ')),
        findsOneWidget,
      );
      // Every signed field is also a row under the primary type's name.
      for (final field in _authorizationType) {
        expect(find.text(field['name']!), findsOneWidget);
      }
      expect(find.byKey(const Key('typed-data-more-fields')), findsNothing);
      expect(find.byKey(const Key('unrecognised-typed-data')), findsNothing);
    });

    testWidgets('a transfer from another account says so', (tester) async {
      final review = (await tester.runAsync(
        () => _prepare(
          _authorization(message: {..._message, 'from': _recipient}),
        ),
      ))!;
      await _approve(tester, review);
      expect(
        find.text('The account the tokens leave is not this wallet.'),
        findsOneWidget,
      );
    });

    testWidgets('an authorization that is not the standard shape is not '
        'summarised, and is treated as unrecognised', (tester) async {
      for (final type in [
        // A recipient the digest would hash as text, not as an address.
        [
          for (final field in _authorizationType)
            field['name'] == 'to' ? {'name': 'to', 'type': 'string'} : field,
        ],
        // One declared field more than the standard has.
        [
          ..._authorizationType,
          {'name': 'memo', 'type': 'string'},
        ],
      ]) {
        final review = (await tester.runAsync(
          () => _prepare(
            _authorization(
              type: type,
              message: {..._message, 'memo': 'gm'}
                ..removeWhere(
                  (key, _) => !type.any((field) => field['name'] == key),
                ),
            ),
          ),
        ))!;
        expect(review.kind, TypedDataKind.generic);
        expect(review.transfers, isEmpty);
        expect(await _approve(tester, review), (tap: false, hold: true));
        expect(find.byKey(const Key('typed-data-transfer')), findsNothing);
        expect(
          find.byKey(const Key('unrecognised-typed-data')),
          findsOneWidget,
        );
      }
    });
  });

  group('typed data the wallet does not recognise', () {
    testWidgets('is cautioned, reject-first, and signs only on a hold', (
      tester,
    ) async {
      final review = (await tester.runAsync(
        () => _prepare({
          'types': {
            'EIP712Domain': _domainType,
            'Mystery': [
              {'name': 'target', 'type': 'address'},
              {'name': 'payload', 'type': 'bytes'},
            ],
          },
          'domain': _domain,
          'primaryType': 'Mystery',
          'message': {'target': _recipient, 'payload': '0xdeadbeef'},
        }),
      ))!;
      expect(review.kind, TypedDataKind.generic);
      expect(await _approve(tester, review), (tap: false, hold: true));
      expect(find.text('Sign typed data'), findsOneWidget);
      expect(
        find.text('The wallet does not recognise this request.'),
        findsOneWidget,
      );
      expect(find.textContaining('the contract below'), findsOneWidget);
      expect(find.text('0xdeadbeef'), findsOneWidget);
    });
  });

  group('typedDataReviewRows', () {
    Eip712TypedData numbers(int count) => Eip712TypedData.parse({
      'types': {
        'Batch': [
          {'name': 'ids', 'type': 'uint256[]'},
          {'name': 'last', 'type': 'address'},
        ],
      },
      'primaryType': 'Batch',
      'domain': {'name': 'Batcher'},
      'message': {
        'ids': [for (var i = 0; i < count; i++) i],
        'last': _recipient,
      },
    });

    test('caps the rows and counts every field past the cap', () {
      final all = typedDataReviewRows(numbers(kMaxTypedDataRows - 1));
      expect(all.rows, hasLength(kMaxTypedDataRows));
      expect(all.more, 0);
      expect(all.rows.last, ('last', _recipient));

      final capped = typedDataReviewRows(numbers(200));
      expect(capped.rows, hasLength(kMaxTypedDataRows));
      expect(capped.rows.last.$1, 'ids[${kMaxTypedDataRows - 1}]');
      expect(capped.more, 201 - kMaxTypedDataRows);

      expect(_rows(numbers(3), limit: 2), ['ids[0]: 0', 'ids[1]: 1']);
      expect(typedDataReviewRows(numbers(3), limit: 2).more, 2);
    });

    testWidgets('a capped review says how many fields it left out', (
      tester,
    ) async {
      final review = EthereumTypedDataReview(
        data: numbers(200),
        origin: 'https://app.example',
        address: _me,
        walletId: 'w',
        kind: TypedDataKind.generic,
      );
      expect(await _approve(tester, review), (tap: false, hold: true));
      final note = tester.widget<ReviewInfoLine>(
        find.byKey(const Key('typed-data-more-fields')),
      );
      expect(note.text, startsWith('and 81 more fields'));
      expect(find.text('ids[119]'), findsOneWidget);
      expect(find.text('ids[120]'), findsNothing);
      // The field past the cap is counted, not shown as though it were all.
      expect(find.text('last'), findsNothing);
    });

    test('follows structs and arrays as deep as the parser accepts', () {
      // Level0 { next: Level1 { … Level9 { amount } }, items: Leaf[][] }
      const depth = 10;
      Object? nest(int level) =>
          level == depth - 1 ? {'amount': '0x10'} : {'next': nest(level + 1)};
      final data = Eip712TypedData.parse({
        'types': {
          for (var i = 0; i < depth - 1; i++)
            'Level$i': [
              {'name': 'next', 'type': 'Level${i + 1}'},
            ],
          'Level${depth - 1}': [
            {'name': 'amount', 'type': 'uint256'},
          ],
          'Root': [
            {'name': 'chain', 'type': 'Level0'},
            {'name': 'grid', 'type': 'Leaf[][]'},
            {'name': 'none', 'type': 'Leaf[]'},
          ],
          'Leaf': [
            {'name': 'ok', 'type': 'bool'},
          ],
        },
        'primaryType': 'Root',
        'domain': {'name': 'Deep'},
        'message': {
          'chain': nest(0),
          'grid': [
            [
              {'ok': true},
              {'ok': false},
            ],
          ],
          'none': <Object?>[],
        },
      });
      expect(_rows(data), [
        'chain${'.next' * (depth - 1)}.amount: 16',
        'grid[0][0].ok: true',
        'grid[0][1].ok: false',
        'none: (empty)',
      ]);
    });

    test('a domain-only payload has no message rows', () {
      final data = Eip712TypedData.parse({
        'types': {
          'EIP712Domain': [
            {'name': 'name', 'type': 'string'},
          ],
        },
        'primaryType': 'EIP712Domain',
        'domain': {'name': 'Only'},
      });
      final (:rows, :more) = typedDataReviewRows(data);
      expect(rows, isEmpty);
      expect(more, 0);
    });
  });
}
