import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_api/mallow_api.dart' as api;
import 'package:mallow_wallet/features/activity/widgets/activity_preview.dart';
import 'package:mallow_wallet/shared/theme/mallow_colors.dart';

// The detail header restates the row's direction in words and colour, so it
// has to agree with the list row it was opened from. Anything that reverses a
// row's direction (a refund) must reverse it in both places, or the same
// transaction reads as a debit in one view and a credit in the other.

api.Activity _tokenTransfer({Map<String, dynamic> extra = const {}}) {
  return api.Activity(
    id: 'a1',
    type: api.ActivityType.send,
    timestamp: 1700000000,
    signature: 'sig1',
    status: api.ActivityStatus.confirmed,
    data: {
      'token': {
        'mint': 'So11111111111111111111111111111111111111112',
        'symbol': 'SOL',
        'amount': 1.5,
        'decimals': 9,
      },
      'counterparty': {
        'address': 'Counterparty1111111111111111111111111111111',
      },
      'isNft': false,
      ...extra,
    },
  );
}

Future<void> _pump(WidgetTester tester, api.Activity activity) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ActivityPreview(activity: activity)),
    ),
  );
}

void main() {
  testWidgets('a refunded row reads as money returning', (tester) async {
    // Escrow coming back keeps the type of the movement it reverses, so
    // type-only direction rendered the refund as a second debit.
    await _pump(tester, _tokenTransfer(extra: const {'isRefund': true}));

    final amount = find.text('+1.5000 SOL');
    expect(amount, findsOneWidget);
    expect(
      tester.widget<Text>(amount).style?.color,
      MallowColors.light.positive,
    );
  });

  testWidgets('an ordinary send still reads as a debit', (tester) async {
    // The refund path must not neutralise real outflows.
    await _pump(tester, _tokenTransfer());

    final amount = find.text('-1.5000 SOL');
    expect(amount, findsOneWidget);
    expect(
      tester.widget<Text>(amount).style?.color,
      MallowColors.light.negative,
    );
  });
}
