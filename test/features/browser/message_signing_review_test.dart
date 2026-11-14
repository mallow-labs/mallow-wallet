import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mallow_wallet/features/browser/models/solana_offchain_message.dart';
import 'package:mallow_wallet/features/browser/services/solana_dapp_adapter.dart';
import 'package:solana/base58.dart';
import 'package:mallow_wallet/features/browser/widgets/message_signing_review.dart';
import 'package:mallow_wallet/shared/theme/mallow_colors.dart';
import 'package:mallow_wallet/shared/theme/mallow_theme.dart';
import 'package:mallow_wallet/shared/widgets/app_snack_bar.dart';
import 'package:mallow_wallet/shared/widgets/signing_review_layout.dart';
import 'package:mallow_wallet/shared/widgets/review_wallet_identity.dart';

const _me = '7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU';

SolanaMessageReview _review(
  List<int> bytes, {
  String origin = 'https://mallow.art',
}) => SolanaMessageReview(
  bytes: Uint8List.fromList(bytes),
  origin: origin,
  address: _me,
  walletId: 'w',
  chain: 'solana:mainnet',
);

List<int> _siws(
  String domain, {
  String statement = 'Sign in to mallow.',
}) => utf8.encode(
  '$domain wants you to sign in with your Solana account:\n$_me\n\n$statement\n\nURI: https://$domain\nVersion: 1\nNonce: 8f3a91d0c21d77aa\nIssued At: 2026-09-23T10:00:00Z',
);

Future<(int, int)> _pump(
  WidgetTester tester,
  SolanaMessageReview review, {
  Size size = const Size(390, 1000),
  double textScale = 1,
  DateTime? now,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  var approved = 0, rejected = 0;
  // A second review in one test starts from fresh buttons.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MessageSigningReview(
            review: review,
            wallet: const ReviewWalletIdentity(address: _me, name: 'Wallet 2'),
            now: now,
            onReject: () => rejected++,
            onApprove: () => approved++,
          ),
        ),
      ),
    ),
  );
  // Approve ignores taps until it has been on screen for its arming delay.
  await tester.pump();
  await tester.pump(ReviewDecisionBar.armDelay * 2);
  await tester.tap(find.byKey(const Key('approve-signing')));
  await tester.tap(find.byKey(const Key('reject-signing')));
  return (approved, rejected);
}

/// Whether pressing and holding Approve signs, after [_pump] has shown that
/// a tap on it does not.
Future<bool> _holdApproves(WidgetTester tester) async {
  final approve = find.byKey(const Key('approve-signing'));
  expect(find.text('Hold to approve anyway'), findsOneWidget);
  // Reject leads: it is the first, primary action.
  expect(
    tester.getTopLeft(find.byKey(const Key('reject-signing'))).dy,
    lessThan(tester.getTopLeft(approve).dy),
  );
  final review = tester.widget<MessageSigningReview>(
    find.byType(MessageSigningReview),
  );
  var approved = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: MallowTheme.lightTheme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MessageSigningReview(
            review: review.review,
            wallet: review.wallet,
            now: review.now,
            onReject: () {},
            onApprove: () => approved = true,
          ),
        ),
      ),
    ),
  );
  final hold = await tester.startGesture(tester.getCenter(approve));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 1300));
  await hold.up();
  await tester.pump();
  return approved;
}

List<int> _signIn(List<String> lines, {String domain = 'mallow.art'}) =>
    utf8.encode(
      '$domain wants you to sign in with your Solana account:\n$_me\n\n'
      '${lines.join('\n')}',
    );

void main() {
  testWidgets('a matching sign-in message gets the structured card', (
    tester,
  ) async {
    expect(await _pump(tester, _review(_siws('mallow.art'))), (1, 1));
    expect(find.text('Sign in to mallow.art'), findsOneWidget);
    expect(find.text('“Sign in to mallow.'), findsNothing);
    expect(find.text('“Sign in to mallow.”'), findsOneWidget);
    expect(find.text('Wallet 2 · 7xKX…gAsU'), findsOneWidget);
    expect(find.text('https://mallow.art'), findsOneWidget);
    expect(find.text('8f3a…77aa'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(
      find.text('The sign-in domain does not match this website.'),
      findsNothing,
    );
    expect(find.textContaining('off-chain'), findsNothing);

    await tester.tap(find.text('View full message'));
    await tester.pumpAndSettle();
    expect(find.textContaining('wants you to sign in'), findsOneWidget);
  });

  testWidgets('a sign-in for another domain is flagged, names both sites and '
      'signs only on a hold', (tester) async {
    expect(
      await _pump(tester, _review(_siws('evil.example'))),
      (0, 1),
      reason: 'a tap on Approve signs nothing',
    );
    expect(find.text('Sign in to mallow.art'), findsNothing);
    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Review sign-in request'), findsOneWidget);
    expect(find.text('Message domain'), findsOneWidget);
    expect(find.text('Website'), findsNothing);
    expect(
      find.text('The sign-in domain does not match this website.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'mallow.art is asking, but the message signs you in to evil.example.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reject'), findsOneWidget);
    expect(await _holdApproves(tester), isTrue);
  });

  testWidgets('a sign-in whose URI is on another site signs only on a hold', (
    tester,
  ) async {
    expect(
      await _pump(
        tester,
        _review(_signIn(['URI: https://evil.example/login', 'Version: 1'])),
      ),
      (0, 1),
    );
    // The domain is this site's, but the sign-in as a whole is not.
    expect(find.text('Website'), findsOneWidget);
    expect(find.text('Sign in to mallow.art'), findsNothing);
    expect(find.text('Review sign-in request'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-domain-mismatch')), findsNothing);
    expect(find.byKey(const Key('sign-in-uri-mismatch')), findsOneWidget);
    expect(
      find.text(
        'mallow.art is asking, but the message signs you in at https://evil.example/login.',
      ),
      findsOneWidget,
    );
    final uri = tester.widget<Text>(find.text('https://evil.example/login'));
    expect(
      uri.style!.color,
      MallowTheme.lightTheme.extension<MallowColors>()!.warning,
    );
    expect(await _holdApproves(tester), isTrue);
  });

  testWidgets('a sign-in outside its validity window signs only on a hold', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 10, 28, 10);
    for (final (line, title) in [
      (
        'Expiration Time: 2026-10-28T09:59:00Z',
        'This sign-in request has expired.',
      ),
      (
        'Not Before: 2026-10-28T11:00:00Z',
        'This sign-in request is not valid yet.',
      ),
      (
        'Issued At: 2026-10-29T10:00:00Z',
        'This sign-in request is dated in the future.',
      ),
    ]) {
      expect(await _pump(tester, _review(_signIn([line])), now: now), (0, 1));
      expect(find.byKey(const Key('sign-in-time-problem')), findsOneWidget);
      expect(find.text(title), findsOneWidget);
      // It is still this site's own sign-in; only its timing is off.
      expect(find.text('Sign in to mallow.art'), findsOneWidget);
      expect(await _holdApproves(tester), isTrue);
    }
    expect(
      await _pump(
        tester,
        _review(_signIn(['Expiration Time: 2026-10-28T10:10:00Z'])),
        now: now,
      ),
      (1, 1),
      reason: 'inside its window it signs on a tap',
    );
    expect(find.text('in 10 minutes'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-time-problem')), findsNothing);
  });

  testWidgets('a sign-in naming another Solana network says which, and still '
      'signs on a tap', (tester) async {
    expect(await _pump(tester, _review(_signIn(['Chain ID: devnet']))), (1, 1));
    expect(find.byKey(const Key('sign-in-network-mismatch')), findsOneWidget);
    expect(
      find.text(
        'The message asks to sign in on the Solana network "devnet", not on mainnet.',
      ),
      findsOneWidget,
    );
    final chain = tester.widget<Text>(find.text('devnet'));
    expect(
      chain.style!.color,
      MallowTheme.lightTheme.extension<MallowColors>()!.warning,
    );

    await _pump(tester, _review(_signIn(['Chain ID: mainnet'])));
    expect(find.byKey(const Key('sign-in-network-mismatch')), findsNothing);
  });

  testWidgets('arbitrary text keeps the off-chain warning and exact bytes', (
    tester,
  ) async {
    final review = _review(utf8.encode('Place order #42'));
    await _pump(tester, review);
    expect(find.text('Sign a message'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Place order #42'), findsOneWidget);
    expect(find.textContaining('off-chain actions'), findsOneWidget);
    await tester.tap(find.text('Exact bytes and digest'));
    await tester.pumpAndSettle();
    expect(find.text(review.digest), findsOneWidget);
  });

  testWidgets('two blank lines do not change Solana sign-in parsing', (
    tester,
  ) async {
    final text =
        'mallow.art wants you to sign in with your Solana account:\n$_me\n\n\nURI: https://mallow.art\nVersion: 1\nNonce: abc12345';
    final review = _review(utf8.encode(text));
    expect(review.signInFields, isEmpty);
    await _pump(tester, review);
    expect(find.text('Sign a message'), findsOneWidget);
    expect(find.text(text), findsOneWidget);
    expect(
      find.text('The sign-in network does not match this wallet.'),
      findsNothing,
    );
  });

  testWidgets('binary messages are shown as hex and fit 320 dp at 2x', (
    tester,
  ) async {
    await _pump(
      tester,
      _review([0xff, 0x00, 0xab]),
      size: const Size(320, 700),
      textScale: 2,
    );
    expect(find.text('Message bytes (hex)'), findsOneWidget);
    expect(find.text('ff00ab'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a sign-in header with trailing arbitrary lines falls back to the raw view',
    (tester) async {
      final text =
          'mallow.art wants you to sign in with your Solana account:\n$_me\n\nSign in to mallow.\nI authorize transfer of all USDC to Hk3P\n\nNonce: 8f3a91d0c21d77aa';
      await _pump(tester, _review(utf8.encode(text)));
      expect(find.text('Sign in to mallow.art'), findsNothing);
      expect(find.text('Sign a message'), findsOneWidget);
      expect(find.textContaining('off-chain actions'), findsOneWidget);
      expect(find.text(text), findsOneWidget);
      expect(find.text('Sign'), findsOneWidget);
    },
  );

  testWidgets(
    'a message keeps its notice in one warning info line, and copies its digest',
    (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final review = _review(utf8.encode('Place order #42'));
      await _pump(tester, review);
      expect(find.byType(ReviewCautionCard), findsNothing);
      final line = tester.widget<ReviewInfoLine>(find.byType(ReviewInfoLine));
      expect(line.text, contains('costs nothing'));
      expect(line.text, contains('off-chain actions'));
      expect(
        line.iconColor,
        MallowTheme.lightTheme.extension<MallowColors>()!.warning,
      );

      await tester.tap(find.text('Exact bytes and digest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(review.digest));
      await tester.pump();
      expect(copied, [review.digest]);
      expect(find.text('SHA-256 copied'), findsOneWidget);
      await tester.tap(find.text('Hex'));
      await tester.pump();
      expect(
        copied.last,
        utf8
            .encode('Place order #42')
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
      );
      AppSnackBar.dismiss();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a Solana sign-in with resources keeps the sign-in card', (
    tester,
  ) async {
    final review = _review(
      utf8.encode(
        'mallow.art wants you to sign in with your Solana account:\n$_me\n\nNonce: 8f3a91d0c21d77aa\nResources:\n- https://mallow.art/terms\n- ipfs://bafy',
      ),
    );
    expect(
      review.signInFields['Resources'],
      'https://mallow.art/terms\nipfs://bafy',
    );
    await _pump(tester, review);
    expect(find.text('Sign in to mallow.art'), findsOneWidget);
    expect(find.text('https://mallow.art/terms\nipfs://bafy'), findsOneWidget);
  });

  group('off-chain messages', () {
    const other = 'So11111111111111111111111111111111111111112';
    SolanaOffchainMessageReview offchain(String text, List<String> signers) =>
        SolanaOffchainMessageReview(
          message: SolanaOffchainMessage.build(
            content: text,
            requiredSigners: [
              for (final s in signers) Uint8List.fromList(base58decode(s)),
            ],
          ),
          origin: 'https://mallow.art',
          address: _me,
          walletId: 'w',
          chain: 'solana:mainnet',
        );

    testWidgets('show the text, the other signers and the built bytes', (
      tester,
    ) async {
      final review = offchain('Place order #42', [_me, other]);
      await _pump(tester, review);
      expect(find.text('Place order #42'), findsOneWidget);
      expect(find.byKey(const Key('message-co-signers')), findsOneWidget);
      expect(find.text('So11…1112'), findsOneWidget);
      // The digest covers the whole message the wallet signs.
      expect(review.bytes.first, 0xff);
      expect(review.coSigners, [other]);
    });

    testWidgets('a sign-in for this wallet alone gets the sign-in card', (
      tester,
    ) async {
      final text = utf8.decode(_siws('mallow.art'));
      await _pump(tester, offchain(text, [_me]));
      expect(find.text('Sign in to mallow.art'), findsOneWidget);
      expect(find.byKey(const Key('message-co-signers')), findsNothing);

      // With another signer it is no longer a plain sign-in.
      expect(offchain(text, [_me, other]).signInFields, isEmpty);
    });
  });
}
